import {
  buildVoiceGenerationIdentity,
  buildVoiceResultManifest,
  normalizeVoiceGenerationRequest,
  safeVoiceError,
  VoiceGenerationRequestError,
  voiceResultObject,
} from "./contract.mjs";

const FAILURE_ATTEMPTS = 3;
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const REFUND_STATUSES = new Set(["refunded", "already_refunded"]);
const COMPLETION_STATUSES = new Set([
  "completed",
  "already_completed",
  "succeeded",
]);
const DELETED_STATUSES = new Set([
  "account_deleting",
  "account_deleted",
  "not_found",
  "already_refunded",
  "refunded",
  "stale_attempt",
]);

export function createGenerateVoiceHandler(deps) {
  const handle = async (req) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }
    if (req.method !== "POST") {
      return json(
        safeVoiceError("method_not_allowed", "This method is not supported."),
        405,
      );
    }

    const authorization = req.headers.get("Authorization") || "";
    const user = authorization.startsWith("Bearer ")
      ? await deps.verifyUser(authorization)
      : null;
    if (!user?.id) {
      return json(
        safeVoiceError("unauthorized", "Authentication is required."),
        401,
      );
    }
    let normalized;
    let identity;
    try {
      normalized = normalizeVoiceGenerationRequest(await req.json());
      const headerKey = String(req.headers.get("Idempotency-Key") || "")
        .trim()
        .toLowerCase();
      if (headerKey && headerKey !== normalized.requestID) {
        throw new VoiceGenerationRequestError("idempotency_conflict", 409);
      }
      identity = await buildVoiceGenerationIdentity(normalized);
    } catch (error) {
      if (error instanceof VoiceGenerationRequestError) {
        return json(
          safeVoiceError(error.code, "Voice request is invalid."),
          error.status,
        );
      }
      return json(
        safeVoiceError("invalid_request", "Voice request is invalid."),
        400,
      );
    }

    const existing = await deps.lookupGeneration({
      p_user_id: user.id,
      p_request_key: identity.requestKey,
      p_request_fingerprint: identity.fingerprint,
    }).catch(() => null);
    if (existing?.status === "succeeded") {
      return await signedResponse({
        userID: user.id,
        normalized,
        creditsRemaining: Number(existing.credits_remaining || 0),
        manifest: existing.result_manifest,
        replayed: true,
        deps,
      }).catch(() => resultUnavailable());
    }
    if (!deps.providerConfigured()) {
      if (existing?.status === "processing") return pendingResponse();
      return json(
        safeVoiceError(
          "voice_unavailable",
          "Voice generation is temporarily unavailable.",
          true,
        ),
        503,
      );
    }

    const claimToken = createClaimToken();
    const ledgerIdentity = {
      userID: user.id,
      requestKey: identity.requestKey,
      requestFingerprint: identity.fingerprint,
    };
    const claim = await deps.claimGeneration({
      p_user_id: user.id,
      p_request_key: identity.requestKey,
      p_request_fingerprint: identity.fingerprint,
      p_cost_credits: normalized.costCredits,
      p_claim_token: claimToken,
    });

    if (!claim) return creditUnavailable();
    if (claim.status === "account_deleting") {
      return json(
        safeVoiceError(
          "account_deleting",
          "Account deletion is already in progress.",
        ),
        409,
      );
    }
    if (claim.status === "insufficient_credits") {
      return json({
        ...safeVoiceError(
          "insufficient_credits",
          "Not enough credits for this voice generation.",
        ),
        credits_remaining: Number(claim.credits_remaining || 0),
        cost_credits: normalized.costCredits,
      }, 402);
    }
    if (claim.status === "idempotency_conflict") {
      return json(
        safeVoiceError(
          "idempotency_conflict",
          "This request ID was used for different input.",
        ),
        409,
      );
    }
    if (claim.status === "replay") {
      return await signedResponse({
        userID: user.id,
        normalized,
        creditsRemaining: Number(claim.credits_remaining || 0),
        manifest: claim.result_manifest,
        replayed: true,
        deps,
      }).catch(() => resultUnavailable());
    }
    if (claim.status === "in_progress") {
      const providerRequestID = String(claim.provider_request_id || "");
      if (!PROVIDER_REQUEST_ID_PATTERN.test(providerRequestID)) {
        return pendingResponse();
      }
      if (isDirectProviderRequest(providerRequestID)) {
        if (!deps.directProviderConfigured?.()) return pendingResponse();
        return await runDirectGeneration({
          normalized,
          ledger: {
            ...ledgerIdentity,
            attempt: Number(claim.attempt || 0),
            providerRequestID,
            creditsRemaining: Number(claim.credits_remaining || 0),
          },
          deps,
        });
      }
      return await pollProvider({
        normalized,
        ledger: {
          ...ledgerIdentity,
          attempt: Number(claim.attempt || 0),
          providerRequestID,
          creditsRemaining: Number(claim.credits_remaining || 0),
        },
        deps,
      });
    }

    const attempt = Number(claim.attempt || 0);
    if (
      claim.status !== "claimed" ||
      !Number.isInteger(attempt) ||
      attempt <= 0
    ) {
      return creditUnavailable();
    }

    if (deps.directProviderConfigured?.()) {
      return await runDirectGeneration({
        normalized,
        ledger: {
          ...ledgerIdentity,
          attempt,
          claimToken,
          creditsRemaining: Number(claim.credits_remaining || 0),
        },
        deps,
      });
    }

    const webhookURL = deps.buildWebhookURL({ claimToken, attempt });
    let submitted;
    try {
      submitted = await deps.submitGeneration({
        input: normalized,
        webhookURL,
      });
    } catch (error) {
      if (error?.submissionAmbiguous === true) {
        await deps.markSubmissionAmbiguous({
          p_user_id: user.id,
          p_request_key: identity.requestKey,
          p_request_fingerprint: identity.fingerprint,
          p_attempt: attempt,
          p_claim_token: claimToken,
        }).catch(() => null);
        return pendingResponse();
      }
      const rejectionIdentity = {
        p_user_id: user.id,
        p_request_key: identity.requestKey,
        p_request_fingerprint: identity.fingerprint,
        p_attempt: attempt,
        p_claim_token: claimToken,
      };
      // Persist terminal provider evidence before attempting the refund. The
      // postgres reconciliation path may then safely restore credits if the
      // immediate exact-once refund RPC is interrupted.
      await deps.markSubmissionRejected(rejectionIdentity).catch(() => null);
      const failure = await settleFailure({
        parameters: {
          ...rejectionIdentity,
          p_error_code: "provider_submit_rejected",
        },
        deps,
      });
      return failedResponse(failure);
    }

    const providerRequestID = String(submitted?.requestID || "");
    if (!PROVIDER_REQUEST_ID_PATTERN.test(providerRequestID)) {
      await deps.markSubmissionAmbiguous({
        p_user_id: user.id,
        p_request_key: identity.requestKey,
        p_request_fingerprint: identity.fingerprint,
        p_attempt: attempt,
        p_claim_token: claimToken,
      }).catch(() => null);
      return pendingResponse();
    }

    try {
      const binding = await deps.bindProvider({
        p_user_id: user.id,
        p_request_key: identity.requestKey,
        p_request_fingerprint: identity.fingerprint,
        p_attempt: attempt,
        p_claim_token: claimToken,
        p_provider_request_id: providerRequestID,
      });
      if (binding?.status === "account_deleting") {
        return json(
          safeVoiceError(
            "account_deleting",
            "Account deletion is already in progress.",
          ),
          409,
        );
      }
    } catch {
      // The signed callback carries the original opaque claim token, so it can
      // still bind and finish this exact attempt after a lost bind response.
    }
    return pendingResponse();
  };

  return async function handleVoiceGenerationSafely(req) {
    try {
      return await handle(req);
    } catch {
      return json(
        safeVoiceError(
          "service_unavailable",
          "Voice service is temporarily unavailable.",
          true,
        ),
        503,
      );
    }
  };
}

async function pollProvider({ normalized, ledger, deps }) {
  let status;
  try {
    status = await deps.getProviderStatus({
      requestID: ledger.providerRequestID,
    });
  } catch {
    return pendingResponse();
  }
  if (status?.state === "pending") return pendingResponse();
  if (status?.state === "failed") {
    const failure = await settleProviderFailure({ ledger, deps });
    return failedResponse(failure);
  }
  if (status?.state !== "completed") return pendingResponse();

  let providerResult;
  try {
    providerResult = await deps.getProviderResult({
      requestID: ledger.providerRequestID,
    });
  } catch (error) {
    if (error?.terminal === true) {
      const failure = await settleProviderFailure({ ledger, deps });
      return failedResponse(failure);
    }
    return pendingResponse();
  }
  const finalized = await finalizeProviderResult({
    audioURL: providerResult.audioURL,
    ledger,
    deps,
  });
  if (finalized.status !== "completed") return pendingResponse();
  return await signedResponse({
    userID: ledger.userID,
    normalized,
    creditsRemaining: Number(
      finalized.creditsRemaining ?? ledger.creditsRemaining ?? 0,
    ),
    manifest: finalized.manifest,
    replayed: false,
    deps,
  }).catch(() => resultUnavailable());
}

export async function finalizeProviderResult({
  audioURL,
  audioBytes,
  audioMimeType,
  ledger,
  deps,
}) {
  let storedObject;
  try {
    storedObject = await deps.storeAudio({
      audioURL,
      audioBytes,
      audioMimeType,
      userID: ledger.userID,
      requestKey: ledger.requestKey,
      attempt: ledger.attempt,
    });
  } catch {
    const recovered = await recoverByProvider({ ledger, deps });
    if (recovered?.status === "succeeded") {
      return {
        status: "completed",
        manifest: recovered.result_manifest,
        creditsRemaining: recovered.credits_remaining,
      };
    }
    return { status: "pending" };
  }

  const manifest = buildVoiceResultManifest(storedObject, {
    provider: ledger.provider || "fal",
    model: ledger.model,
  });
  let completion = null;
  try {
    completion = await deps.completeByProvider({
      p_user_id: ledger.userID,
      p_request_key: ledger.requestKey,
      p_request_fingerprint: ledger.requestFingerprint,
      p_provider_request_id: ledger.providerRequestID,
      p_result_manifest: manifest,
    });
  } catch {
    completion = await recoverByProvider({ ledger, deps });
  }

  if (COMPLETION_STATUSES.has(completion?.status)) {
    return {
      status: "completed",
      manifest: completion.result_manifest || manifest,
      creditsRemaining: completion.credits_remaining,
    };
  }
  if (DELETED_STATUSES.has(completion?.status)) {
    await deps.deleteAudio(storedObject.path).catch(() => null);
    return { status: "discarded" };
  }

  const recovered = await recoverByProvider({ ledger, deps });
  if (recovered?.status === "succeeded") {
    return {
      status: "completed",
      manifest: recovered.result_manifest,
      creditsRemaining: recovered.credits_remaining,
    };
  }
  if (DELETED_STATUSES.has(recovered?.status)) {
    await deps.deleteAudio(storedObject.path).catch(() => null);
    return { status: "discarded" };
  }
  // Keep the idempotently named object while the completion RPC is ambiguous.
  // A signed webhook retry or client poll will verify/reuse the same bytes.
  return { status: "pending" };
}

async function runDirectGeneration({ normalized, ledger, deps }) {
  let generated;
  try {
    generated = await deps.generateDirect({ input: normalized });
  } catch (error) {
    if (error?.submissionAmbiguous === true) {
      if (!ledger.providerRequestID && ledger.claimToken) {
        await deps.markSubmissionAmbiguous({
          p_user_id: ledger.userID,
          p_request_key: ledger.requestKey,
          p_request_fingerprint: ledger.requestFingerprint,
          p_attempt: ledger.attempt,
          p_claim_token: ledger.claimToken,
        }).catch(() => null);
      }
      return pendingResponse();
    }
    const failure = ledger.providerRequestID
      ? await settleProviderFailure({ ledger, deps })
      : await rejectDirectClaim({ ledger, deps });
    await deps.recordProviderHealth?.(false, "provider_failure").catch(() =>
      null
    );
    return failedResponse(failure);
  }

  const generatedRequestID = String(generated?.requestID || "");
  const providerRequestID = ledger.providerRequestID || generatedRequestID;
  if (!PROVIDER_REQUEST_ID_PATTERN.test(providerRequestID)) {
    const failure = ledger.providerRequestID
      ? await settleProviderFailure({ ledger, deps })
      : await rejectDirectClaim({ ledger, deps });
    return failedResponse(failure);
  }

  if (!ledger.providerRequestID) {
    try {
      const binding = await deps.bindProvider({
        p_user_id: ledger.userID,
        p_request_key: ledger.requestKey,
        p_request_fingerprint: ledger.requestFingerprint,
        p_attempt: ledger.attempt,
        p_claim_token: ledger.claimToken,
        p_provider_request_id: providerRequestID,
      });
      if (binding?.status === "account_deleting") {
        return json(
          safeVoiceError(
            "account_deleting",
            "Account deletion is already in progress.",
          ),
          409,
        );
      }
    } catch {
      return pendingResponse();
    }
  }

  const finalized = await finalizeProviderResult({
    audioBytes: generated.audioBytes,
    audioMimeType: generated.audioMimeType,
    ledger: {
      ...ledger,
      providerRequestID,
      provider: generated.provider,
      model: generated.model,
    },
    deps,
  });
  if (finalized.status !== "completed") return pendingResponse();
  await deps.recordProviderHealth?.(true, null).catch(() => null);
  return await signedResponse({
    userID: ledger.userID,
    normalized,
    creditsRemaining: Number(
      finalized.creditsRemaining ?? ledger.creditsRemaining ?? 0,
    ),
    manifest: finalized.manifest,
    replayed: false,
    deps,
  }).catch(() => resultUnavailable());
}

async function rejectDirectClaim({ ledger, deps }) {
  const identity = {
    p_user_id: ledger.userID,
    p_request_key: ledger.requestKey,
    p_request_fingerprint: ledger.requestFingerprint,
    p_attempt: ledger.attempt,
    p_claim_token: ledger.claimToken,
  };
  await deps.markSubmissionRejected(identity).catch(() => null);
  return await settleFailure({
    parameters: { ...identity, p_error_code: "provider_submit_rejected" },
    deps,
  });
}

export async function settleProviderFailure({ ledger, deps }) {
  for (let attempt = 0; attempt < FAILURE_ATTEMPTS; attempt += 1) {
    try {
      const failure = await deps.failByProvider({
        p_user_id: ledger.userID,
        p_request_key: ledger.requestKey,
        p_request_fingerprint: ledger.requestFingerprint,
        p_provider_request_id: ledger.providerRequestID,
        p_error_code: "provider_terminal_failure",
      });
      if (
        REFUND_STATUSES.has(failure?.status) ||
        failure?.status === "already_completed" ||
        DELETED_STATUSES.has(failure?.status)
      ) {
        return failure;
      }
    } catch {
      // Provider ID + ledger identity make this refund exact-once.
    }
    if (attempt < FAILURE_ATTEMPTS - 1) {
      await (deps.sleep || defaultSleep)(100 * (attempt + 1));
    }
  }
  return null;
}

async function recoverByProvider({ ledger, deps }) {
  try {
    return await deps.getByProvider({
      p_user_id: ledger.userID,
      p_request_key: ledger.requestKey,
      p_request_fingerprint: ledger.requestFingerprint,
      p_provider_request_id: ledger.providerRequestID,
    });
  } catch {
    return null;
  }
}

async function signedResponse({
  userID,
  normalized,
  creditsRemaining,
  manifest,
  replayed,
  deps,
}) {
  const object = voiceResultObject(manifest);
  const signed = await deps.signAudio(object.path);
  if (!signed?.signedURL || !signed?.expiresAt) {
    throw new Error("voice_result_signing_failed");
  }
  const asset = await deps.assetForObject?.(
    userID,
    object.path,
  ).catch(() => null);
  return json({
    audio_url: signed.signedURL,
    audio_url_expires_at: signed.expiresAt,
    credits_remaining: creditsRemaining,
    cost_credits: normalized.costCredits,
    character_count: normalized.characterCount,
    voice: normalized.voice,
    model: String(manifest?.model || "unknown"),
    replayed,
    ...(asset?.id && String(asset.user_id || "") === String(userID)
      ? { asset_id: String(asset.id) }
      : {}),
  });
}

function isDirectProviderRequest(value) {
  return /^(minimax|eleven)_/.test(String(value || ""));
}

async function settleFailure({ parameters, deps }) {
  for (let attempt = 0; attempt < FAILURE_ATTEMPTS; attempt += 1) {
    try {
      const failure = await deps.failGeneration(parameters);
      if (
        REFUND_STATUSES.has(failure?.status) ||
        failure?.status === "already_completed"
      ) {
        return failure;
      }
    } catch {
      // Retrying the exact same claim-bound refund cannot double credit.
    }
    if (attempt < FAILURE_ATTEMPTS - 1) {
      await (deps.sleep || defaultSleep)(100 * (attempt + 1));
    }
  }
  return null;
}

function failedResponse(failure) {
  const refunded = Boolean(failure && REFUND_STATUSES.has(failure.status));
  return json({
    ...safeVoiceError(
      refunded ? "voice_unavailable" : "refund_pending",
      refunded
        ? "Voice generation is temporarily unavailable."
        : "Voice generation status is being reconciled.",
      true,
    ),
    refunded,
  }, 503);
}

function pendingResponse() {
  return json(
    safeVoiceError(
      "generation_status_pending",
      "Voice generation is still processing.",
      true,
    ),
    425,
    { "Retry-After": "2" },
  );
}

function creditUnavailable() {
  return json(
    safeVoiceError(
      "credit_service_unavailable",
      "Credit service is temporarily unavailable.",
      true,
    ),
    503,
  );
}

function resultUnavailable() {
  return json(
    safeVoiceError(
      "result_unavailable",
      "Saved audio is temporarily unavailable.",
      true,
    ),
    503,
  );
}

function createClaimToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function defaultSleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      ...extraHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
