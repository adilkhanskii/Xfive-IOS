import { extractFalVoiceResult } from "../generate-voice/fal-provider.mjs";
import {
  finalizeProviderResult,
  settleProviderFailure,
} from "../generate-voice/handler.mjs";

const MAXIMUM_WEBHOOK_BYTES = 1024 * 1024;
const CLAIM_TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,200}$/;
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const REQUEST_KEY_PATTERN = /^explicit:[0-9a-f]{64}$/;
const FINGERPRINT_PATTERN = /^[0-9a-f]{64}$/;

export function createVoiceWebhookHandler(deps) {
  return async function handleVoiceWebhook(req) {
    try {
      if (req.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
      }
      const url = new URL(req.url);
      const claimToken = String(url.searchParams.get("claim") || "");
      const attempt = Number(url.searchParams.get("attempt") || 0);
      if (
        !CLAIM_TOKEN_PATTERN.test(claimToken) ||
        !Number.isInteger(attempt) ||
        attempt <= 0
      ) {
        return json({ error: "invalid_callback_identity" }, 400);
      }

      const rawBody = await readBoundedRequestBody(req);
      if (
        rawBody.byteLength <= 0 || rawBody.byteLength > MAXIMUM_WEBHOOK_BYTES
      ) {
        return json({ error: "invalid_webhook_body" }, 400);
      }
      const verified = await deps.verifyWebhook({
        headers: req.headers,
        rawBody,
      });
      if (!verified) return json({ error: "invalid_webhook_signature" }, 401);

      const payload = JSON.parse(new TextDecoder().decode(rawBody));
      const providerRequestID = String(payload?.request_id || "");
      const signedRequestID = req.headers.get("X-Fal-Webhook-Request-Id") || "";
      if (
        !PROVIDER_REQUEST_ID_PATTERN.test(providerRequestID) ||
        providerRequestID !== signedRequestID
      ) {
        return json({ error: "webhook_request_id_mismatch" }, 401);
      }
      const status = String(payload?.status || "").toUpperCase();
      if (!["OK", "ERROR"].includes(status)) {
        return json({ error: "webhook_status_invalid" }, 400);
      }

      const binding = await deps.bindWebhook({
        p_claim_token: claimToken,
        p_attempt: attempt,
        p_provider_request_id: providerRequestID,
      });
      if (
        [
          "already_completed",
          "already_refunded",
          "account_deleting",
          "account_deleted",
          "not_found",
          "stale_attempt",
        ].includes(binding?.status)
      ) {
        return json({ ok: true, terminal: binding.status });
      }
      const ledger = ledgerFromBinding(binding, providerRequestID);
      if (!ledger) return json({ error: "webhook_binding_failed" }, 409);

      if (status === "ERROR") {
        const failure = await settleProviderFailure({ ledger, deps });
        return failure
          ? json({ ok: true, terminal: failure.status })
          : json({ error: "refund_pending" }, 503);
      }

      let providerResult;
      try {
        providerResult = extractFalVoiceResult(payload?.payload);
      } catch {
        const failure = await settleProviderFailure({ ledger, deps });
        return failure
          ? json({ ok: true, terminal: failure.status })
          : json({ error: "refund_pending" }, 503);
      }
      const finalized = await finalizeProviderResult({
        audioURL: providerResult.audioURL,
        ledger,
        deps,
      });
      if (["completed", "discarded"].includes(finalized.status)) {
        return json({ ok: true, terminal: finalized.status });
      }
      return json({ error: "completion_pending" }, 503);
    } catch {
      // fal retries non-2xx webhook deliveries. Never acknowledge an unknown
      // state because doing so could strand a charged generation.
      return json({ error: "webhook_temporarily_unavailable" }, 503);
    }
  };
}

export async function readBoundedRequestBody(
  request,
  maximumBytes = MAXIMUM_WEBHOOK_BYTES,
) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength) {
    if (!/^\d{1,20}$/.test(contentLength)) {
      throw new Error("webhook_content_length_invalid");
    }
    if (Number(contentLength) > maximumBytes) {
      throw new Error("webhook_body_too_large");
    }
  }
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel().catch(() => null);
      throw new Error("webhook_body_too_large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function ledgerFromBinding(binding, providerRequestID) {
  const userID = String(binding?.user_id || "");
  const requestKey = String(binding?.request_key || "");
  const requestFingerprint = String(binding?.request_fingerprint || "");
  const attempt = Number(binding?.attempt || 0);
  if (
    !["bound", "already_bound", "processing"].includes(binding?.status) ||
    !UUID_PATTERN.test(userID) ||
    !REQUEST_KEY_PATTERN.test(requestKey) ||
    !FINGERPRINT_PATTERN.test(requestFingerprint) ||
    !Number.isInteger(attempt) ||
    attempt <= 0
  ) {
    return null;
  }
  return {
    userID,
    requestKey,
    requestFingerprint,
    attempt,
    providerRequestID,
    creditsRemaining: Number(binding?.credits_remaining || 0),
  };
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
