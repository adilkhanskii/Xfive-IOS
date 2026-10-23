const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EVENT_TYPES = new Set(["message_inserted", "notification_created"]);
const MAX_REQUEST_BYTES = 1_024;
const MAX_TITLE_LENGTH = 80;
const MAX_BODY_LENGTH = 180;

export function createPushWebhookHandler(deps) {
  return async function handlePushWebhook(request) {
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    if (
      !secureEqual(
        request.headers.get("X-X5-Push-Webhook-Secret") || "",
        deps.webhookSecret,
      )
    ) {
      return json({ error: "unauthorized" }, 401);
    }
    if (new URL(request.url).searchParams.get("health") === "1") {
      return json({ ok: true, healthy: true });
    }

    let input;
    try {
      input = await parseWebhookInput(request);
    } catch {
      return json({ error: "invalid_payload" }, 400);
    }

    let event;
    try {
      event = await deps.loadCanonicalEvent(input.eventType, input.eventID);
    } catch (error) {
      logFailure(deps, "push_event_lookup_failed", input, error);
      return json({ error: "push_temporarily_unavailable" }, 503);
    }
    if (event == null) return new Response(null, { status: 204 });
    if (!isCanonicalEvent(event, input)) {
      logFailure(deps, "push_event_invariant_failed", input);
      return json({ error: "push_temporarily_unavailable" }, 503);
    }

    const delivery = buildPushDelivery(event);
    let sent = 0;
    let skipped = 0;
    let inProgress = 0;
    let rateLimited = 0;
    let retryAfter = 0;
    let failed = 0;

    for (const recipientID of event.recipientIDs) {
      const leaseToken = String(deps.randomUUID?.() || "").toLowerCase();
      if (!UUID_PATTERN.test(leaseToken)) {
        logFailure(deps, "push_lease_generation_failed", input);
        failed += 1;
        continue;
      }

      const parameters = {
        p_event_type: event.eventType,
        p_event_id: event.eventID,
        p_recipient_id: recipientID,
        p_lease_token: leaseToken,
      };
      let claim;
      try {
        claim = await deps.claimDispatch(parameters);
      } catch (error) {
        logFailure(deps, "push_dispatch_claim_failed", input, error);
        failed += 1;
        continue;
      }

      if (["replay", "completed"].includes(claim?.status)) {
        skipped += 1;
        continue;
      }
      if (claim?.status === "in_progress") {
        inProgress += 1;
        retryAfter = Math.max(retryAfter, safeRetryAfter(claim.retry_after, 5));
        continue;
      }
      if (claim?.status === "rate_limited") {
        rateLimited += 1;
        retryAfter = Math.max(
          retryAfter,
          safeRetryAfter(claim.retry_after, 60),
        );
        continue;
      }
      if (claim?.status !== "claimed") {
        logFailure(deps, "push_dispatch_claim_invalid", input);
        failed += 1;
        continue;
      }

      let outcome;
      try {
        outcome = await deps.deliverPush(recipientID, delivery, parameters);
      } catch (error) {
        logFailure(deps, "push_provider_call_failed", input, error);
        outcome = { status: "failed" };
      }

      if (!["sent", "no_target"].includes(outcome?.status)) {
        await releaseSafely(deps, {
          ...parameters,
          p_error_code: "provider_failed",
        }, input);
        failed += 1;
        continue;
      }

      const completion = await completeWithRetry(deps, {
        ...parameters,
        p_outcome: outcome.status,
      });
      if (!completion) {
        logFailure(deps, "push_dispatch_completion_failed", input);
        failed += 1;
        continue;
      }
      if (outcome.status === "sent") sent += 1;
      else skipped += 1;
    }

    if (failed > 0) {
      return json({ error: "push_temporarily_unavailable" }, 503);
    }
    if (rateLimited > 0) {
      return json(
        { error: "rate_limited", retry_after: retryAfter },
        429,
        { "Retry-After": String(retryAfter) },
      );
    }
    if (inProgress > 0) {
      const seconds = Math.max(retryAfter, 1);
      return json(
        { error: "push_in_progress", retry_after: seconds },
        503,
        { "Retry-After": String(seconds) },
      );
    }
    if (sent > 0 || skipped > 0) {
      return json({ ok: true, sent, skipped });
    }
    return new Response(null, { status: 204 });
  };
}

export function buildPushDelivery(event) {
  const data = compactStrings({
    type: event.pushType,
    event_id: event.eventID,
    actor_id: event.actorID,
    sender_id: event.eventType === "message_inserted"
      ? event.actorID
      : undefined,
    message_id: event.messageID,
    chat_id: event.chatID,
    notification_id: event.notificationID,
    task_id: event.taskID,
    object_type: event.objectType,
    object_id: event.objectID,
  });
  const title = boundedText(event.title, MAX_TITLE_LENGTH, "Xfive marketing");
  const body = boundedText(event.body, MAX_BODY_LENGTH, "Новое уведомление");
  const alert = compactStrings({
    title,
    subtitle: boundedText(event.subtitle, MAX_TITLE_LENGTH),
    body,
  });

  return {
    eventID: event.eventID,
    collapseID: event.eventID,
    apns: {
      aps: {
        alert,
        sound: "default",
        badge: 1,
        "thread-id": boundedText(event.threadID, 128, event.eventID),
        category: event.category,
      },
      ...data,
    },
    fcm: {
      title,
      body,
      data,
    },
  };
}

async function parseWebhookInput(request) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new Error();
  }
  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new Error();
  }
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_REQUEST_BYTES) {
    throw new Error();
  }
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error();
  }
  const keys = Object.keys(parsed).sort();
  if (keys.length !== 2 || keys[0] !== "event_id" || keys[1] !== "event_type") {
    throw new Error();
  }
  const eventType = String(parsed.event_type || "");
  const eventID = String(parsed.event_id || "").toLowerCase();
  if (!EVENT_TYPES.has(eventType) || !UUID_PATTERN.test(eventID)) {
    throw new Error();
  }
  return { eventType, eventID };
}

function isCanonicalEvent(event, input) {
  if (
    event.eventType !== input.eventType ||
    String(event.eventID || "").toLowerCase() !== input.eventID ||
    !UUID_PATTERN.test(String(event.eventID || "")) ||
    !UUID_PATTERN.test(String(event.actorID || "")) ||
    !Array.isArray(event.recipientIDs) ||
    event.recipientIDs.length < 1 ||
    event.recipientIDs.length > 20 ||
    !event.recipientIDs.every((id) => UUID_PATTERN.test(String(id || ""))) ||
    new Set(event.recipientIDs).size !== event.recipientIDs.length ||
    event.recipientIDs.includes(event.actorID) ||
    !/^[a-z0-9_]{1,64}$/.test(String(event.pushType || "")) ||
    !["MESSAGE", "SOCIAL"].includes(event.category)
  ) {
    return false;
  }
  if (event.eventType === "message_inserted") {
    return event.pushType === "message" &&
      String(event.messageID || "").toLowerCase() === input.eventID &&
      typeof event.chatID === "string" && event.chatID.length > 0 &&
      event.chatID.length <= 200;
  }
  return String(event.notificationID || "").toLowerCase() === input.eventID;
}

async function completeWithRetry(deps, parameters) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const result = await deps.completeDispatch(parameters);
      if (["completed", "already_completed"].includes(result?.status)) {
        return true;
      }
      if (["stale_lease", "idempotency_conflict"].includes(result?.status)) {
        return false;
      }
    } catch {
      // A completion can have committed before a transient response failure.
      // Retrying the same lease is safe and avoids most ambiguous duplicates.
    }
  }
  return false;
}

async function releaseSafely(deps, parameters, input) {
  try {
    await deps.releaseDispatch(parameters);
  } catch (error) {
    logFailure(deps, "push_dispatch_release_failed", input, error);
  }
}

function boundedText(value, maximum, fallback = "") {
  const normalized = String(value || "").trim();
  const source = normalized || fallback;
  const characters = Array.from(source);
  return characters.length <= maximum
    ? source
    : `${characters.slice(0, Math.max(1, maximum - 1)).join("")}…`;
}

function compactStrings(value) {
  return Object.fromEntries(
    Object.entries(value)
      .filter(([, item]) => typeof item === "string" && item.length > 0),
  );
}

function safeRetryAfter(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 1 && number <= 86_400
    ? Math.ceil(number)
    : fallback;
}

function logFailure(deps, event, input, error) {
  deps.logger?.error?.(JSON.stringify({
    event,
    event_type: input?.eventType,
    event_id: input?.eventID,
    code: safeErrorCode(error),
  }));
}

function safeErrorCode(error) {
  const value = String(error?.message || "worker_failed").toLowerCase();
  return /^[a-z0-9_:-]{1,120}$/.test(value) ? value : "worker_failed";
}

export function secureEqual(candidate, expected) {
  const left = new TextEncoder().encode(String(candidate || ""));
  const right = new TextEncoder().encode(String(expected || ""));
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] || 0) ^ (right[index] || 0);
  }
  return difference === 0 && right.length >= 32;
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}
