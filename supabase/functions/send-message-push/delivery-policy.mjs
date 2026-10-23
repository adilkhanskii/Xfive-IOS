const PERMANENT_APNS_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);
const PERMANENT_FCM_CODES = new Set([
  "UNREGISTERED",
  "SENDER_ID_MISMATCH",
]);

export function normalizePushPlatform(value) {
  const platform = String(value || "").trim().toLowerCase();
  return ["ios", "android", "web"].includes(platform) ? platform : null;
}

export async function deliverPushTargets({
  targets,
  delivery,
  sendTarget,
  disableTarget,
  claimTarget = (_target) => Promise.resolve({ status: "claimed" }),
  recordTargetOutcome = (_target, _claim, _outcome, _errorCode) =>
    Promise.resolve(),
  logger = console,
}) {
  if (!Array.isArray(targets) || targets.length === 0) {
    return { status: "no_target" };
  }

  let successes = 0;
  let permanentInvalid = 0;
  let transientFailures = 0;

  for (const target of targets) {
    let claim;
    try {
      claim = await claimTarget(target);
    } catch {
      transientFailures += 1;
      log(logger, "push_target_claim_failed", delivery, target);
      continue;
    }
    if (claim?.status === "already_sent") {
      successes += 1;
      continue;
    }
    if (claim?.status === "already_permanent") {
      permanentInvalid += 1;
      continue;
    }
    if (claim?.status !== "claimed") {
      transientFailures += 1;
      log(logger, "push_target_claim_unavailable", delivery, target);
      continue;
    }

    let response;
    try {
      response = await sendTarget(target, delivery);
    } catch {
      await recordOutcomeSafely(
        recordTargetOutcome,
        target,
        claim,
        "transient_failure",
        "provider_request_failed",
      );
      transientFailures += 1;
      log(logger, "push_provider_request_failed", delivery, target);
      continue;
    }

    if (response.ok) {
      await response.body?.cancel().catch(() => undefined);
      try {
        await recordTargetOutcome(target, claim, "sent");
        successes += 1;
      } catch {
        transientFailures += 1;
        log(logger, "push_target_completion_failed", delivery, target);
      }
      continue;
    }

    const classification = await classifyProviderFailure(
      target.platform,
      response,
    );
    log(logger, "push_provider_rejected", delivery, target, response.status);
    if (classification !== "permanent_invalid_token") {
      await recordOutcomeSafely(
        recordTargetOutcome,
        target,
        claim,
        "transient_failure",
        `provider_http_${response.status}`,
      );
      transientFailures += 1;
      continue;
    }

    try {
      await disableTarget(target);
      await recordTargetOutcome(target, claim, "permanent_failure");
      permanentInvalid += 1;
    } catch {
      await recordOutcomeSafely(
        recordTargetOutcome,
        target,
        claim,
        "transient_failure",
        "invalid_token_cleanup_failed",
      );
      transientFailures += 1;
      log(logger, "push_invalid_token_cleanup_failed", delivery, target);
    }
  }

  // A successful device must not hide a transient failure on another device.
  // The recipient dispatch remains retryable; the same APNs id / collapse id
  // bounds duplicate presentation on targets that already succeeded.
  if (transientFailures > 0) return { status: "failed" };
  if (successes > 0) return { status: "sent" };
  if (permanentInvalid > 0) return { status: "no_target" };
  return { status: "failed" };
}

async function recordOutcomeSafely(
  recordTargetOutcome,
  target,
  claim,
  outcome,
  errorCode,
) {
  try {
    await recordTargetOutcome(target, claim, outcome, errorCode);
  } catch {
    // The recipient dispatch stays retryable. A committed target completion is
    // idempotent and will be observed by the next claim.
  }
}

export async function classifyProviderFailure(platform, response) {
  const body = await response.text().catch(() => "");
  let payload = null;
  try {
    payload = JSON.parse(body);
  } catch {
    // Provider bodies are optional. Unknown failures remain retryable.
  }

  if (platform === "ios") {
    const reason = String(payload?.reason || "");
    return (response.status === 410 || PERMANENT_APNS_REASONS.has(reason))
      ? "permanent_invalid_token"
      : "transient";
  }

  const details = Array.isArray(payload?.error?.details)
    ? payload.error.details
    : [];
  const fcmCode = details
    .map((item) => String(item?.errorCode || ""))
    .find((value) => value.length > 0);
  return PERMANENT_FCM_CODES.has(fcmCode)
    ? "permanent_invalid_token"
    : "transient";
}

function log(logger, event, delivery, target, status) {
  logger?.error?.(JSON.stringify({
    event,
    event_id: delivery.eventID,
    platform: target.platform,
    ...(Number.isInteger(status) ? { status } : {}),
  }));
}
