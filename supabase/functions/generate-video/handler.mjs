import {
  buildPublicVideoJob,
  buildVideoGenerationIdentity,
  normalizeVideoGenerationRequest,
  safeVideoError,
  VideoRequestError,
} from "./contract.mjs";
import { FalProviderError } from "./fal-provider.mjs";
import { GoogleProviderError } from "./google-provider.mjs";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const SUBMISSION_RECORD_ATTEMPTS = 3;
const FAILURE_RECORD_ATTEMPTS = 3;
const FAILURE_RECORD_BACKOFF_MILLISECONDS = [25, 100];
const FAILURE_TERMINAL_STATUSES = new Set([
  "failed",
  "already_refunded",
  "already_completed",
]);
const REJECTION_MARKED_STATUSES = new Set([
  "marked",
  "already_marked",
  "already_refunded",
  "already_completed",
]);

export function createGenerateVideoHandler(deps) {
  const handleGenerateVideo = async (req) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }
    if (!["GET", "POST"].includes(req.method)) {
      return json(
        safeVideoError(
          "method_not_allowed",
          "This request method is not supported.",
        ),
        405,
      );
    }

    const authorization = req.headers.get("Authorization") || "";
    const user = authorization.startsWith("Bearer ")
      ? await deps.verifyUser(authorization)
      : null;
    if (!user?.id) {
      return json(
        safeVideoError(
          "unauthorized",
          "Authentication is required.",
        ),
        401,
      );
    }

    if (req.method === "GET") {
      return await handleStatus(req, user.id, deps);
    }
    return await handleSubmit(req, user.id, deps);
  };
  return async function handleGenerateVideoSafely(req) {
    try {
      return await handleGenerateVideo(req);
    } catch {
      return json(
        safeVideoError(
          "service_unavailable",
          "Video service is temporarily unavailable.",
          true,
        ),
        503,
      );
    }
  };
}

async function handleSubmit(req, userId, deps) {
  let normalized;
  let identity;
  try {
    normalized = normalizeVideoGenerationRequest(await req.json());
    identity = await buildVideoGenerationIdentity(normalized);
  } catch (error) {
    if (error instanceof VideoRequestError) {
      return json(
        safeVideoError(
          "invalid_request",
          error.code,
        ),
        error.status,
      );
    }
    if (error instanceof SyntaxError) {
      return json(
        safeVideoError(
          "invalid_request",
          "Request body must be valid JSON.",
        ),
        400,
      );
    }
    return json(
      safeVideoError(
        "invalid_request",
        "Request body must be valid JSON.",
      ),
      400,
    );
  }

  try {
    const moderation = await deps.moderateRequest(normalized);
    if (moderation?.allowed === false) {
      return json(
        safeVideoError(
          "content_rejected",
          "This request did not pass the safety check.",
        ),
        422,
      );
    }
    if (moderation?.allowed !== true) throw new Error();
  } catch {
    return json(
      safeVideoError(
        "safety_service_unavailable",
        "Safety check is temporarily unavailable.",
        true,
      ),
      503,
    );
  }

  let provider;
  try {
    provider = deps.selectProvider(normalized);
  } catch {
    return json(
      safeVideoError(
        "provider_unavailable",
        "Video generation is temporarily unavailable.",
        true,
      ),
      503,
    );
  }

  const claimToken = createClaimToken();
  const claim = await deps.claimJob({
    p_user_id: userId,
    p_request_key: identity.requestKey,
    p_request_fingerprint: identity.fingerprint,
    p_cost_credits: normalized.costCredits,
    p_has_start_image: Boolean(normalized.startImage),
    p_provider_name: provider.name,
    p_claim_token: claimToken,
  });
  if (!claim) {
    return json(
      safeVideoError(
        "credit_service_unavailable",
        "Credit service is temporarily unavailable.",
        true,
      ),
      503,
    );
  }
  if (claim.status === "insufficient_credits") {
    return json(
      safeVideoError(
        "insufficient_credits",
        "Not enough credits for this video.",
      ),
      402,
    );
  }
  if (claim.status === "idempotency_conflict") {
    return json(
      safeVideoError(
        "idempotency_conflict",
        "This request key was already used for different inputs.",
      ),
      409,
    );
  }
  if (claim.status === "replay") {
    const replay = await loadOwnedJob(
      String(claim.job_id || ""),
      userId,
      deps,
      true,
    );
    if (!replay) {
      return json(
        safeVideoError(
          "job_not_found",
          "Video job was not found.",
        ),
        404,
      );
    }
    return json({ job: replay, replayed: true });
  }
  if (claim.status !== "claimed" || !UUID_PATTERN.test(String(claim.job_id))) {
    return json(
      safeVideoError(
        "credit_service_unavailable",
        "Credit service is temporarily unavailable.",
        true,
      ),
      503,
    );
  }

  const jobId = String(claim.job_id);
  let inputObject = null;
  let providerRequestId = null;
  try {
    if (normalized.startImage) {
      inputObject = await deps.storeStartImage({
        userId,
        jobId,
        image: normalized.startImage,
      });
      const recordedInput = await deps.recordInput({
        p_job_id: jobId,
        p_user_id: userId,
        p_claim_token: claimToken,
        p_input_object_path: inputObject.path,
      });
      if (!["recorded", "already_recorded"].includes(recordedInput?.status)) {
        throw new Error("input_state_unavailable");
      }
    }
    let submitted;
    const visitedProviders = new Set([provider.name]);
    while (!submitted) {
      try {
        submitted = await submitToProvider(
          provider,
          normalized,
          inputObject,
          jobId,
          claimToken,
          deps,
        );
      } catch (error) {
        const fallback = isSafeProviderFallback(provider, error)
          ? selectFallbackSafely(deps, provider.name)
          : null;
        if (
          !fallback ||
          visitedProviders.has(fallback.name) ||
          visitedProviders.size >= 3
        ) {
          throw error;
        }
        const switched = await deps.switchProvider({
          p_job_id: jobId,
          p_user_id: userId,
          p_claim_token: claimToken,
          p_expected_provider_name: provider.name,
          p_new_provider_name: fallback.name,
        });
        if (!["switched", "already_switched"].includes(switched?.status)) {
          throw new Error("provider_switch_unavailable");
        }
        provider = fallback;
        visitedProviders.add(provider.name);
      }
    }
    providerRequestId = submitted.requestId;
    const isGoogle = provider.name === "google";
    const submissionParameters = isGoogle
      ? {
        p_job_id: jobId,
        p_claim_token: claimToken,
        p_provider_request_id: submitted.requestId,
      }
      : {
        p_job_id: jobId,
        p_user_id: userId,
        p_claim_token: claimToken,
        p_provider_request_id: submitted.requestId,
        p_input_object_path: inputObject?.path || null,
      };
    const recorded = await recordSubmissionWithRecovery({
      jobId,
      userId,
      providerRequestId: submitted.requestId,
      inputObjectPath: inputObject?.path || null,
      parameters: submissionParameters,
      recordSubmission: isGoogle ? deps.bindGoogleWebhook : deps.markSubmitted,
      acceptedStatuses: isGoogle
        ? ["bound", "already_bound", "already_terminal"]
        : ["submitted", "already_submitted"],
      deps,
    });
    if (
      !(
        isGoogle
          ? ["bound", "already_bound", "already_terminal"]
          : ["submitted", "already_submitted"]
      ).includes(recorded?.status)
    ) {
      throw new Error("submission_state_unavailable");
    }
    if (submitted.status === "rendering") {
      await deps.markRendering({
        p_job_id: jobId,
        p_provider_request_id: submitted.requestId,
        p_progress: 0.5,
      });
    }
  } catch (error) {
    if (providerRequestId || error?.submissionAmbiguous === true) {
      const pending = await loadOwnedJob(jobId, userId, deps, false)
        .catch(() => null);
      if (pending) {
        return json({
          job: pending,
          replayed: false,
          submission_pending: true,
        }, 202);
      }
      return json(
        safeVideoError(
          "submission_pending",
          "Video submission is being reconciled. Please check it again shortly.",
          true,
        ),
        503,
      );
    }
    const failure = await recordDefinitiveSubmissionFailure({
      jobId,
      claimToken,
      providerRequestId,
      errorCode: "provider_submission_failed",
      deps,
    });
    if (failure.status === "submission_exists") {
      const pending = await loadOwnedJob(jobId, userId, deps, false)
        .catch(() => null);
      if (pending) {
        return json({
          job: pending,
          replayed: false,
          submission_pending: true,
        }, 202);
      }
      return json(
        safeVideoError(
          "submission_pending",
          "Video submission is being reconciled. Please check it again shortly.",
          true,
        ),
        503,
      );
    }
    if (inputObject?.path) {
      await deps.deleteStartImage(inputObject.path).catch(() => null);
    }
    const payload = safeVideoError(
      "provider_unavailable",
      "Video generation is temporarily unavailable.",
      true,
    );
    const providerDiagnostic = safeProviderDiagnostic(provider?.name, error);
    if (providerDiagnostic) payload.error.provider = providerDiagnostic;
    return json(payload, 503);
  }

  const job = await loadOwnedJob(jobId, userId, deps, false);
  if (!job) {
    return json(
      safeVideoError(
        "job_not_found",
        "Video job was not found.",
      ),
      404,
    );
  }
  return json({ job, replayed: false }, 202);
}

function safeProviderDiagnostic(providerName, error) {
  if (
    providerName !== "google" ||
    !(error instanceof GoogleProviderError)
  ) {
    return null;
  }
  return {
    name: "google",
    ...(Number.isInteger(error.providerStatus)
      ? { status: error.providerStatus }
      : {}),
    code: error.providerCode || error.code,
  };
}

async function submitToProvider(
  provider,
  normalized,
  inputObject,
  jobId,
  claimToken,
  deps,
) {
  const startImageUrl =
    ["fal", "byteplus"].includes(provider.name) && inputObject
      ? (await deps.signStartImage(inputObject))?.signedUrl || null
      : null;
  const submitted = await provider.adapter.submit({
    model: normalized.model,
    prompt: normalized.prompt,
    aspectRatio: normalized.aspectRatio,
    durationSeconds: normalized.durationSeconds,
    resolution: normalized.resolution,
    generateAudio: normalized.generateAudio,
    startImageUrl,
    startImage: ["google", "openai"].includes(provider.name)
      ? normalized.startImage
      : null,
    webhookUrl: provider.name === "fal" ? deps.webhookUrl : null,
    ...(provider.name === "google"
      ? {
        webhookUrl: deps.googleWebhookUrl,
        webhookMetadata: {
          job_id: jobId,
          claim_token: claimToken,
        },
      }
      : {}),
  });
  if (
    !submitted ||
    !PROVIDER_REQUEST_ID_PATTERN.test(String(submitted.requestId || ""))
  ) {
    const error = new Error("provider_request_id_missing");
    error.submissionAmbiguous = true;
    throw error;
  }
  return submitted;
}

function isSafeProviderFallback(provider, error) {
  if (
    provider?.requestedModel &&
    provider.requestedModel !== "auto"
  ) {
    return false;
  }
  if (
    provider?.name === "fal" &&
    error instanceof FalProviderError
  ) {
    return error.safeToFallback === true;
  }
  if (
    provider?.name === "google" &&
    error instanceof GoogleProviderError &&
    error.submissionAmbiguous !== true
  ) {
    return [403, 429].includes(error.providerStatus);
  }
  return false;
}

function selectFallbackSafely(deps, providerName) {
  try {
    return deps.selectFallbackProvider?.(providerName) || null;
  } catch {
    return null;
  }
}

async function recordSubmissionWithRecovery({
  jobId,
  userId,
  providerRequestId,
  inputObjectPath,
  parameters,
  recordSubmission,
  acceptedStatuses,
  deps,
}) {
  let lastError = new Error("submission_state_unavailable");
  for (let attempt = 0; attempt < SUBMISSION_RECORD_ATTEMPTS; attempt += 1) {
    try {
      const recorded = await recordSubmission(parameters);
      if (acceptedStatuses.includes(recorded?.status)) {
        return recorded;
      }
      lastError = new Error("submission_state_unavailable");
    } catch (error) {
      lastError = error;
    }

    const recovered = await deps.getJob({ jobId, userId }).catch(() => null);
    if (recovered?.provider_request_id) {
      if (
        recovered.provider_request_id === providerRequestId &&
        (recovered.input_object_path || null) === inputObjectPath
      ) {
        return { status: acceptedStatuses[1] };
      }
      throw new Error("submission_conflict");
    }
  }
  throw lastError;
}

async function recordDefinitiveSubmissionFailure({
  jobId,
  claimToken,
  providerRequestId,
  errorCode,
  deps,
}) {
  const failParameters = {
    p_job_id: jobId,
    p_provider_request_id: providerRequestId,
    p_error_code: errorCode,
  };
  for (let attempt = 0; attempt < FAILURE_RECORD_ATTEMPTS; attempt += 1) {
    try {
      const outcome = await deps.failJob(failParameters);
      if (FAILURE_TERMINAL_STATUSES.has(outcome?.status)) {
        return { status: "terminal", outcome };
      }
      if (outcome?.status === "stale_provider_request") {
        return { status: "submission_exists", outcome };
      }
    } catch {
      // The exact-once RPC is safe to retry after an ambiguous transport error.
    }
    if (attempt < FAILURE_RECORD_ATTEMPTS - 1) {
      await (deps.sleep || defaultSleep)(
        FAILURE_RECORD_BACKOFF_MILLISECONDS[attempt],
      );
    }
  }

  try {
    const marker = await deps.markSubmissionRejected({
      p_job_id: jobId,
      p_claim_token: claimToken,
      p_error_code: errorCode,
    });
    if (REJECTION_MARKED_STATUSES.has(marker?.status)) {
      return { status: "deferred", outcome: marker };
    }
    if (marker?.status === "submission_exists") {
      return { status: "submission_exists", outcome: marker };
    }
  } catch {
    // The 24-hour no-provider-id reconciliation remains the final fail-safe if
    // both immediate settlement and the short-age durable marker are offline.
  }
  return { status: "unresolved" };
}

function defaultSleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function handleStatus(req, userId, deps) {
  const jobId = new URL(req.url).searchParams.get("job_id") || "";
  if (!UUID_PATTERN.test(jobId)) {
    return json(
      safeVideoError(
        "invalid_request",
        "A valid job_id is required.",
      ),
      400,
    );
  }
  const job = await loadOwnedJob(jobId, userId, deps, true);
  if (!job) {
    return json(
      safeVideoError(
        "job_not_found",
        "Video job was not found.",
      ),
      404,
    );
  }
  return json({ job });
}

async function loadOwnedJob(jobId, userId, deps, reconcile) {
  let row = await deps.getJob({ jobId, userId });
  if (!row) return null;
  if (reconcile && ["queued", "rendering"].includes(row.status)) {
    row = await deps.reconcileJob(row).catch(() => row);
  }
  if (
    ["completed", "failed"].includes(row.status) &&
    row.input_object_path
  ) {
    await deps.deleteStartImage(row.input_object_path).catch(() => null);
  }
  const signedResult = row.status === "completed" && row.result_object_path
    ? await deps.signResult(row.result_object_path).catch(() => null)
    : null;
  const assetID = row.status === "completed" && row.result_object_path
    ? await deps.assetForResult?.(row.result_object_path, userId)
      .then((asset) => asset?.id || null)
      .catch(() => null)
    : null;
  return buildPublicVideoJob(row, signedResult, assetID);
}

function createClaimToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
