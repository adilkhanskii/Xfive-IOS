const FAL_JWKS_URL = "https://rest.fal.ai/.well-known/jwks.json";
const MAX_WEBHOOK_AGE_SECONDS = 5 * 60;
const JWKS_CACHE_MILLISECONDS = 24 * 60 * 60 * 1000;

let cachedJwks = null;
let cachedAt = 0;

export async function getFalJwks(fetchImpl = fetch, nowMs = Date.now()) {
  if (cachedJwks && nowMs - cachedAt < JWKS_CACHE_MILLISECONDS) {
    return cachedJwks;
  }
  const response = await fetchImpl(FAL_JWKS_URL, {
    headers: { "Accept": "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("fal_jwks_unavailable");
  const payload = await response.json().catch(() => null);
  if (!payload || !Array.isArray(payload.keys) || payload.keys.length === 0) {
    throw new Error("fal_jwks_invalid");
  }
  cachedJwks = payload;
  cachedAt = nowMs;
  return payload;
}

export async function buildFalWebhookMessage({
  requestId,
  userId,
  timestamp,
  rawBody,
}) {
  const bodyHash = await sha256Hex(rawBody);
  return new TextEncoder().encode(
    [requestId, userId, timestamp, bodyHash].join("\n"),
  );
}

export async function verifyFalWebhookSignature({
  headers,
  rawBody,
  jwks,
  nowSeconds = Math.floor(Date.now() / 1000),
}) {
  const requestId = headers.get("X-Fal-Webhook-Request-Id") || "";
  const userId = headers.get("X-Fal-Webhook-User-Id") || "";
  const timestamp = headers.get("X-Fal-Webhook-Timestamp") || "";
  const signatureHex = headers.get("X-Fal-Webhook-Signature") || "";
  const parsedTimestamp = Number.parseInt(timestamp, 10);
  if (
    !requestId ||
    !userId ||
    !/^\d{1,20}$/.test(timestamp) ||
    !/^[0-9a-fA-F]{128}$/.test(signatureHex) ||
    !Number.isSafeInteger(parsedTimestamp) ||
    Math.abs(nowSeconds - parsedTimestamp) > MAX_WEBHOOK_AGE_SECONDS ||
    !Array.isArray(jwks?.keys)
  ) {
    return false;
  }

  const message = await buildFalWebhookMessage({
    requestId,
    userId,
    timestamp,
    rawBody,
  });
  const signature = hexToBytes(signatureHex);
  for (const keyInfo of jwks.keys) {
    if (
      keyInfo?.kty !== "OKP" ||
      keyInfo?.crv !== "Ed25519" ||
      typeof keyInfo?.x !== "string"
    ) {
      continue;
    }
    try {
      const key = await crypto.subtle.importKey(
        "raw",
        base64UrlToBytes(keyInfo.x),
        { name: "Ed25519" },
        false,
        ["verify"],
      );
      if (
        await crypto.subtle.verify(
          { name: "Ed25519" },
          key,
          signature,
          message,
        )
      ) {
        return true;
      }
    } catch {
      continue;
    }
  }
  return false;
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function hexToBytes(value) {
  return Uint8Array.from(
    value.match(/.{2}/g) || [],
    (pair) => Number.parseInt(pair, 16),
  );
}

function base64UrlToBytes(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(
    normalized.length + ((4 - normalized.length % 4) % 4),
    "=",
  );
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
