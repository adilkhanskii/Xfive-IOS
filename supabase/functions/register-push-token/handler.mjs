const MAX_REQUEST_BYTES = 5_120;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createRegisterPushTokenHandler(deps) {
  return async function registerPushToken(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: responseHeaders() });
    }
    if (request.method !== "POST" && request.method !== "DELETE") {
      return json({ error: "method_not_allowed" }, 405);
    }

    const accessToken = bearerToken(request.headers.get("authorization"));
    if (!accessToken) return json({ error: "unauthorized" }, 401);

    let userID;
    try {
      userID = await deps.loadUserID(accessToken);
    } catch {
      return json({ error: "authentication_unavailable" }, 503);
    }
    if (!UUID_PATTERN.test(String(userID || ""))) {
      return json({ error: "unauthorized" }, 401);
    }

    let registration;
    try {
      registration = await parseRegistration(request);
    } catch (error) {
      const status = error?.message === "payload_too_large" ? 413 : 400;
      return json({ error: error?.message || "invalid_payload" }, status);
    }

    if (request.method === "DELETE") {
      let result;
      try {
        result = await deps.deleteToken(userID, registration);
      } catch {
        return json({ error: "push_token_delete_failed" }, 503);
      }
      return json({
        ok: true,
        platform: registration.platform,
        deleted: result.deleted === true,
        profile_cleared: result.profileCleared === true,
      });
    } else {
      let updatedAt;
      try {
        updatedAt = await deps.saveToken(userID, registration);
      } catch {
        return json({ error: "push_token_save_failed" }, 503);
      }
      return json({
        ok: true,
        platform: registration.platform,
        updated_at: updatedAt,
      });
    }
  };
}

export async function parseRegistration(request) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new Error("invalid_payload");
  }
  const declaredLength = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new Error("payload_too_large");
  }
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_REQUEST_BYTES) {
    throw new Error("payload_too_large");
  }

  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("invalid_payload");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid_payload");
  }
  const keys = Object.keys(value).sort();
  if (keys.length !== 2 || keys[0] !== "platform" || keys[1] !== "token") {
    throw new Error("invalid_payload");
  }
  const platform = normalizePlatform(value.platform);
  if (!platform) throw new Error("invalid_platform");
  const token = normalizePushToken(value.token, platform);
  if (!token) throw new Error("invalid_token");
  return { platform, token };
}

export function normalizePlatform(raw) {
  const value = String(raw || "").trim().toLowerCase();
  return value === "ios" || value === "android" || value === "web"
    ? value
    : null;
}

function normalizePushToken(raw, platform) {
  return platform === "ios" ? normalizeAPNsToken(raw) : normalizeFCMToken(raw);
}

function normalizeAPNsToken(raw) {
  const trimmed = typeof raw === "string" ? raw.trim() : "";
  if (!trimmed || trimmed.startsWith("ExponentPushToken")) return undefined;

  const compact = trimmed.replace(/[<>\s]/g, "").toLowerCase();
  if (/^[0-9a-f]+$/.test(compact) && compact.length >= 32) return compact;

  const bytes = trimmed.match(/bytes\s*=\s*0x([0-9a-fA-F\s]+)/i)?.[1];
  const normalized = bytes?.replace(/\s/g, "").toLowerCase();
  return normalized && /^[0-9a-f]+$/.test(normalized) && normalized.length >= 32
    ? normalized
    : undefined;
}

function normalizeFCMToken(raw) {
  const trimmed = typeof raw === "string" ? raw.trim() : "";
  if (!trimmed || trimmed.startsWith("ExponentPushToken")) return undefined;
  if (trimmed.length < 20 || trimmed.length > 4_096) return undefined;
  return /^[A-Za-z0-9:_-]+$/.test(trimmed) ? trimmed : undefined;
}

function bearerToken(value) {
  const match = String(value || "").match(/^Bearer ([^\s]{20,8192})$/i);
  return match?.[1] || null;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders(),
  });
}

function responseHeaders() {
  return {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, DELETE, OPTIONS",
    "access-control-allow-headers": "authorization, apikey, content-type",
  };
}
