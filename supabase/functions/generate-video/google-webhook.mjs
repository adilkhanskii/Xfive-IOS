const GOOGLE_WEBHOOK_JWKS_URL =
  "https://generativelanguage.googleapis.com/.well-known/jwks.json";
const MAX_WEBHOOK_BYTES = 1024 * 1024;
const MAX_WEBHOOK_AGE_SECONDS = 5 * 60;
const JWKS_CACHE_MILLISECONDS = 60 * 60 * 1000;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CLAIM_TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,200}$/;
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const WEBHOOK_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const GOOGLE_ISSUERS = new Set([
  "https://accounts.google.com",
  "accounts.google.com",
]);

let cachedJwks = null;
let cachedAt = 0;

export async function getGoogleWebhookJwks(
  fetchImpl = fetch,
  nowMs = Date.now(),
) {
  if (cachedJwks && nowMs - cachedAt < JWKS_CACHE_MILLISECONDS) {
    return cachedJwks;
  }
  const response = await fetchImpl(GOOGLE_WEBHOOK_JWKS_URL, {
    headers: { "Accept": "application/json" },
    redirect: "error",
  });
  if (!response.ok) throw new Error("google_webhook_jwks_unavailable");
  const rawBody = await readBoundedResponseBody(response, MAX_WEBHOOK_BYTES);
  const payload = parseObjectJson(rawBody);
  if (!Array.isArray(payload.keys) || payload.keys.length === 0) {
    throw new Error("google_webhook_jwks_invalid");
  }
  cachedJwks = payload;
  cachedAt = nowMs;
  return payload;
}

export async function readBoundedRequestBody(
  request,
  maximumBytes = MAX_WEBHOOK_BYTES,
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
  return await readBoundedStream(request.body, maximumBytes, "webhook");
}

export async function verifyGoogleWebhookJwt({
  token,
  jwks,
  expectedAudience,
  nowSeconds = Math.floor(Date.now() / 1000),
}) {
  try {
    if (
      typeof token !== "string" ||
      token.length > 16_384 ||
      !Array.isArray(jwks?.keys)
    ) {
      return false;
    }
    const segments = token.split(".");
    if (segments.length !== 3) return false;
    const header = parseJwtSegment(segments[0]);
    const claims = parseJwtSegment(segments[1]);
    if (
      header.alg !== "RS256" ||
      typeof header.kid !== "string" ||
      !/^[A-Za-z0-9_-]{1,200}$/.test(header.kid) ||
      !GOOGLE_ISSUERS.has(String(claims.iss || "")) ||
      !audienceMatches(claims.aud, expectedAudience) ||
      !Number.isSafeInteger(claims.iat) ||
      !Number.isSafeInteger(claims.exp) ||
      claims.iat < nowSeconds - MAX_WEBHOOK_AGE_SECONDS ||
      claims.iat > nowSeconds + 60 ||
      claims.exp <= nowSeconds ||
      claims.exp > claims.iat + 60 * 60 ||
      (claims.nbf != null &&
        (!Number.isSafeInteger(claims.nbf) || claims.nbf > nowSeconds + 60))
    ) {
      return false;
    }
    const keyInfo = jwks.keys.find((candidate) =>
      candidate?.kid === header.kid &&
      candidate?.kty === "RSA" &&
      (!candidate.alg || candidate.alg === "RS256") &&
      (!candidate.use || candidate.use === "sig")
    );
    if (!keyInfo) return false;
    const key = await crypto.subtle.importKey(
      "jwk",
      keyInfo,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      base64UrlToBytes(segments[2]),
      new TextEncoder().encode(`${segments[0]}.${segments[1]}`),
    );
  } catch {
    return false;
  }
}

export function createGoogleWebhookHandler(deps) {
  return async function handleGoogleWebhook(request) {
    if (request.method !== "POST") {
      return jsonResponse({ accepted: false }, 405);
    }
    const contentLength = request.headers.get("Content-Length") || "";
    if (
      contentLength &&
      (!/^\d{1,20}$/.test(contentLength) ||
        Number(contentLength) > MAX_WEBHOOK_BYTES)
    ) {
      return jsonResponse(
        { accepted: false },
        /^\d{1,20}$/.test(contentLength) ? 413 : 400,
      );
    }

    const nowSeconds = deps.nowSeconds?.() ??
      Math.floor(Date.now() / 1000);
    const webhookId = request.headers.get("Webhook-Id") || "";
    const timestamp = request.headers.get("Webhook-Timestamp") || "";
    const parsedTimestamp = Number.parseInt(timestamp, 10);
    if (
      !WEBHOOK_ID_PATTERN.test(webhookId) ||
      !/^\d{1,20}$/.test(timestamp) ||
      !Number.isSafeInteger(parsedTimestamp) ||
      Math.abs(nowSeconds - parsedTimestamp) > MAX_WEBHOOK_AGE_SECONDS
    ) {
      return jsonResponse({ accepted: false }, 401);
    }

    let rawBody;
    try {
      rawBody = await readBoundedRequestBody(request);
    } catch (error) {
      return jsonResponse(
        { accepted: false },
        error?.message === "webhook_body_too_large" ? 413 : 400,
      );
    }

    let jwks;
    try {
      jwks = await deps.getJwks();
    } catch {
      return jsonResponse({ accepted: false }, 503);
    }
    const verified = await verifyGoogleWebhookJwt({
      token: request.headers.get("Webhook-Signature") || "",
      jwks,
      expectedAudience: deps.expectedAudience || deps.callbackUrl,
      nowSeconds,
    });
    if (!verified) return jsonResponse({ accepted: false }, 401);

    let event;
    try {
      event = extractGoogleWebhookEvent(parseObjectJson(rawBody));
    } catch {
      return jsonResponse({ accepted: false }, 400);
    }
    if (!event) return jsonResponse({ accepted: false }, 400);

    let binding;
    try {
      binding = await deps.bindJob({
        p_job_id: event.jobId,
        p_claim_token: event.claimToken,
        p_provider_request_id: event.requestId,
      });
    } catch {
      return jsonResponse({ accepted: false }, 503);
    }
    if (binding?.status === "stale_claim") {
      return jsonResponse({ accepted: false }, 401);
    }
    if (
      !["bound", "already_bound", "already_terminal"].includes(
        binding?.status,
      )
    ) {
      const missing = binding?.status === "not_found";
      return jsonResponse({ accepted: false }, missing ? 404 : 409);
    }

    let job;
    try {
      job = await deps.getJob({ jobId: event.jobId });
    } catch {
      return jsonResponse({ accepted: false }, 503);
    }
    if (
      !job ||
      job.provider_name !== "google" ||
      job.provider_request_id !== event.requestId
    ) {
      return jsonResponse({ accepted: false }, 409);
    }
    if (["completed", "failed"].includes(job.status)) {
      await deps.cleanupInput(job).catch(() => null);
      return jsonResponse({ accepted: true, replayed: true });
    }

    if (event.terminalFailure) {
      let outcome;
      try {
        outcome = await deps.failJob({
          p_job_id: event.jobId,
          p_provider_request_id: event.requestId,
          p_error_code: event.errorCode,
        });
      } catch {
        return jsonResponse({ accepted: false }, 503);
      }
      if (
        !["failed", "already_refunded", "already_completed"].includes(
          outcome?.status,
        )
      ) {
        return jsonResponse({ accepted: false }, 503);
      }
      await deps.cleanupInput(job).catch(() => null);
      return jsonResponse({ accepted: true });
    }

    if (!event.terminalSuccess) {
      return jsonResponse({ accepted: false }, 400);
    }
    if (event.resultHint && typeof deps.finalizeResult === "function") {
      let outcome;
      try {
        outcome = await deps.finalizeResult(job, event.resultHint);
      } catch {
        return jsonResponse({ accepted: false }, 503);
      }
      if (!["completed", "failed"].includes(outcome?.status)) {
        return jsonResponse({ accepted: false }, 503);
      }
      return jsonResponse({ accepted: true });
    }
    let reconciled;
    try {
      reconciled = await deps.reconcileJob(job, { strict: true });
    } catch {
      return jsonResponse({ accepted: false }, 503);
    }
    if (!["completed", "failed"].includes(reconciled?.status)) {
      return jsonResponse({ accepted: false }, 503);
    }
    await deps.cleanupInput(reconciled).catch(() => null);
    return jsonResponse({ accepted: true });
  };
}

function extractGoogleWebhookEvent(payload) {
  const eventType = String(payload.event_type || payload.type || "")
    .toLowerCase();
  const interaction = payload.interaction ||
    payload.data?.interaction ||
    payload.data ||
    {};
  const metadata = interaction.user_metadata ||
    payload.user_metadata ||
    payload.data?.user_metadata ||
    {};
  const jobId = String(metadata.job_id || "");
  const claimToken = String(metadata.claim_token || "");
  const requestId = String(
    interaction.id ||
      interaction.interaction_id ||
      payload.interaction_id ||
      payload.data?.interaction_id ||
      payload.id ||
      "",
  );
  if (
    !UUID_PATTERN.test(jobId) ||
    !CLAIM_TOKEN_PATTERN.test(claimToken) ||
    !PROVIDER_REQUEST_ID_PATTERN.test(requestId)
  ) {
    return null;
  }
  const status = String(interaction.status || payload.status || "")
    .toLowerCase();
  const failureStatus = [
    "failed",
    "cancelled",
    "canceled",
    "timed_out",
    "incomplete",
  ].includes(status);
  const failureEvent = [
    "interaction.failed",
    "interaction.cancelled",
    "interaction.canceled",
    "interaction.incomplete",
  ].includes(eventType);
  const incomplete = status === "incomplete" ||
    eventType === "interaction.incomplete";
  const resultHint = eventType === "video.generated"
    ? extractGoogleWebhookResultHint(interaction)
    : null;
  return {
    jobId,
    claimToken,
    requestId,
    terminalFailure: failureStatus || failureEvent,
    terminalSuccess: ["interaction.completed", "video.generated"].includes(
      eventType,
    ) && !failureStatus,
    errorCode: incomplete ? "provider_incomplete" : "provider_failed",
    ...(resultHint ? { resultHint } : {}),
  };
}

function extractGoogleWebhookResultHint(data) {
  const rawUri = String(data?.output_file_uri || "");
  if (rawUri) {
    try {
      const url = new URL(rawUri);
      if (
        url.protocol === "https:" &&
        !url.username &&
        !url.password &&
        (!url.port || url.port === "443") &&
        isAllowedGoogleResultHost(url.hostname)
      ) {
        return { url: url.href, mimeType: "video/mp4" };
      }
    } catch {
      // Fall through to Google's canonical Files API URL when available.
    }
  }

  const fileName = String(data?.file_name || "");
  const match = fileName.match(/^files\/([a-z0-9][a-z0-9-]{0,39})$/);
  if (!match) return null;
  return {
    url: `https://generativelanguage.googleapis.com/v1beta/files/${
      encodeURIComponent(match[1])
    }:download?alt=media`,
    mimeType: "video/mp4",
  };
}

function isAllowedGoogleResultHost(rawHostname) {
  const hostname = String(rawHostname || "").toLowerCase();
  return hostname === "generativelanguage.googleapis.com" ||
    hostname === "storage.googleapis.com" ||
    hostname === "googleusercontent.com" ||
    hostname.endsWith(".googleusercontent.com");
}

async function readBoundedResponseBody(response, maximumBytes) {
  const contentLength = response.headers.get("Content-Length");
  if (
    contentLength &&
    (!/^\d{1,20}$/.test(contentLength) ||
      Number(contentLength) > maximumBytes)
  ) {
    throw new Error("google_webhook_jwks_too_large");
  }
  if (!response.body) throw new Error("google_webhook_jwks_invalid");
  return await readBoundedStream(response.body, maximumBytes, "jwks");
}

async function readBoundedStream(stream, maximumBytes, prefix) {
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel().catch(() => null);
      throw new Error(
        prefix === "webhook"
          ? "webhook_body_too_large"
          : "google_webhook_jwks_too_large",
      );
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

function parseObjectJson(bytes) {
  const payload = JSON.parse(new TextDecoder().decode(bytes));
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("json_object_required");
  }
  return payload;
}

function parseJwtSegment(segment) {
  if (!/^[A-Za-z0-9_-]{1,8192}$/.test(segment)) {
    throw new Error("jwt_segment_invalid");
  }
  return parseObjectJson(base64UrlToBytes(segment));
}

function audienceMatches(audience, expected) {
  if (typeof expected !== "string" || !expected) return false;
  if (typeof audience === "string") return audience === expected;
  return Array.isArray(audience) &&
    audience.length === 1 &&
    audience[0] === expected;
}

function base64UrlToBytes(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("base64url_invalid");
  }
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(
    normalized.length + ((4 - normalized.length % 4) % 4),
    "=",
  );
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
