// Shared Bunny Stream helpers for the course-video Edge Functions.
// Pure ESM so the same code runs under Deno (Edge Runtime) and node:test.
// Never log or return BUNNY_STREAM_API_KEY / BUNNY_STREAM_TOKEN_KEY.

export const BUNNY_STREAM_API_BASE = "https://video.bunnycdn.com";
export const BUNNY_STREAM_TUS_ENDPOINT = "https://video.bunnycdn.com/tusupload";

export const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const LESSON_ID_PATTERN = /^[A-Za-z0-9._:-]{1,256}$/;

const DEFAULT_TUS_TTL_SECONDS = 24 * 60 * 60;
const MIN_TUS_TTL_SECONDS = 60 * 60;
const MAX_TUS_TTL_SECONDS = 48 * 60 * 60;
const DEFAULT_PLAYBACK_TTL_SECONDS = 2 * 60 * 60;
const MIN_PLAYBACK_TTL_SECONDS = 5 * 60;
const MAX_PLAYBACK_TTL_SECONDS = 12 * 60 * 60;

export const corsHeaders = Object.freeze({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
});

export function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

export function withCors(response) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(corsHeaders)) {
    headers.set(name, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function normalizeUUID(value) {
  if (typeof value !== "string") return "";
  const normalized = value.trim().toLowerCase();
  return UUID_PATTERN.test(normalized) ? normalized : "";
}

export function normalizeLessonID(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  return LESSON_ID_PATTERN.test(trimmed) ? trimmed : "";
}

export function normalizeText(value, minimumLength, maximumLength) {
  if (typeof value !== "string") return "";
  const normalized = value.trim().replace(/\s+/g, " ");
  if (
    normalized.length < minimumLength ||
    normalized.length > maximumLength
  ) {
    return "";
  }
  return normalized;
}

function clampSeconds(raw, fallback, minimum, maximum) {
  const text = String(raw ?? "").trim();
  const value = text ? Number(text) : Number.NaN;
  if (!Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(minimum, Math.floor(value)));
}

export function isSafeCdnHostname(value) {
  if (
    !value ||
    value.length > 253 ||
    !value.endsWith(".b-cdn.net") ||
    /^[0-9.]+$/.test(value)
  ) {
    return false;
  }
  return value.split(".").every((label) =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)
  );
}

/**
 * Reads Bunny configuration. Returns null when anything required is missing.
 * `requireTokenKey` is true for playback (signed URLs are mandatory there).
 */
export function normalizeBunnyConfig(
  env,
  { requireApiKey = true, requireTokenKey = false } = {},
) {
  const libraryID = String(env?.BUNNY_STREAM_LIBRARY_ID || "").trim();
  const apiKey = String(env?.BUNNY_STREAM_API_KEY || "").trim();
  const tokenKey = String(env?.BUNNY_STREAM_TOKEN_KEY || "").trim();
  const cdnHostname = String(env?.BUNNY_STREAM_CDN_HOSTNAME || "")
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/\/+$/, "");
  if (!/^[1-9][0-9]*$/.test(libraryID) || !isSafeCdnHostname(cdnHostname)) {
    return null;
  }
  // "token" (default): path-token signed URLs, requires pull-zone token
  // authentication ON. "none": plain URLs — ONLY for the switch window while
  // no paid lesson references Bunny (see docs/BUNNY-STREAM-HANDOFF.md).
  const signingMode =
    String(env?.BUNNY_STREAM_PLAYBACK_SIGNING || "token").trim() === "none"
      ? "none"
      : "token";
  if (requireApiKey && !apiKey) return null;
  if (requireTokenKey && signingMode === "token" && !tokenKey) return null;
  return {
    libraryID,
    signingMode,
    apiKey,
    tokenKey,
    cdnHostname,
    tusTTLSeconds: clampSeconds(
      env?.BUNNY_STREAM_TUS_TTL_SECONDS,
      DEFAULT_TUS_TTL_SECONDS,
      MIN_TUS_TTL_SECONDS,
      MAX_TUS_TTL_SECONDS,
    ),
    playbackTTLSeconds: clampSeconds(
      env?.BUNNY_STREAM_PLAYBACK_TTL_SECONDS,
      DEFAULT_PLAYBACK_TTL_SECONDS,
      MIN_PLAYBACK_TTL_SECONDS,
      MAX_PLAYBACK_TTL_SECONDS,
    ),
  };
}

export async function sha256Hex(value) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function sha256Base64Url(value) {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

/** Bunny Stream TUS presigned upload signature. */
export async function tusSignature({ libraryID, apiKey, expires, videoID }) {
  return await sha256Hex(`${libraryID}${apiKey}${expires}${videoID}`);
}

/**
 * Bunny CDN token authentication, directory ("path") token variant.
 * Every HLS rendition playlist, segment and thumbnail below /<videoID>/
 * inherits the token from the URL path, so AVPlayer / hls.js / ExoPlayer can
 * follow relative URLs without extra signing.
 *
 * token = base64url(sha256(tokenKey + tokenPath + expires + "token_path=" + tokenPath))
 * url   = https://host/bcdn_token=<token>&expires=<expires>&token_path=<enc(tokenPath)>/<videoID>/<file>
 */
export async function signedDirectoryURL({
  cdnHostname,
  tokenKey,
  videoID,
  file,
  expires,
}) {
  const tokenPath = `/${videoID}/`;
  const token = await sha256Base64Url(
    `${tokenKey}${tokenPath}${expires}token_path=${tokenPath}`,
  );
  const safeFile = String(file || "playlist.m3u8").replace(/^\/+/, "");
  return `https://${cdnHostname}/bcdn_token=${token}&expires=${expires}` +
    `&token_path=${encodeURIComponent(tokenPath)}${tokenPath}${safeFile}`;
}

export async function playbackURL(config, videoID, file, expires) {
  if (config.signingMode === "none") {
    return `https://${config.cdnHostname}/${videoID}/${file}`;
  }
  return await signedDirectoryURL({
    cdnHostname: config.cdnHostname,
    tokenKey: config.tokenKey,
    videoID,
    file,
    expires,
  });
}

export function playbackTTLFor(config, lengthSeconds) {
  const length = Number(lengthSeconds);
  const wanted = Number.isFinite(length) && length > 0
    ? Math.max(config.playbackTTLSeconds, Math.ceil(length) + 3_600)
    : config.playbackTTLSeconds;
  return Math.min(MAX_PLAYBACK_TTL_SECONDS, wanted);
}

// ---------------------------------------------------------------------------
// Bunny Stream management API
// ---------------------------------------------------------------------------

export async function bunnyCreateVideo(fetchImpl, config, title) {
  const response = await fetchImpl(
    `${BUNNY_STREAM_API_BASE}/library/${config.libraryID}/videos`,
    {
      method: "POST",
      headers: {
        AccessKey: config.apiKey,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ title }),
      signal: AbortSignal.timeout(10_000),
    },
  ).catch(() => null);
  if (!response) return { ok: false, retryable: true };
  if (!response.ok) {
    return { ok: false, retryable: response.status >= 500 };
  }
  const created = await response.json().catch(() => null);
  const videoID = normalizeUUID(created?.guid);
  return videoID ? { ok: true, videoID } : { ok: false, retryable: true };
}

export async function bunnyFindVideoByTitle(fetchImpl, config, title) {
  const url = new URL(
    `${BUNNY_STREAM_API_BASE}/library/${config.libraryID}/videos`,
  );
  url.searchParams.set("page", "1");
  url.searchParams.set("itemsPerPage", "100");
  url.searchParams.set("search", title);
  const response = await fetchImpl(url, {
    method: "GET",
    headers: { AccessKey: config.apiKey, Accept: "application/json" },
    signal: AbortSignal.timeout(6_000),
  }).catch(() => null);
  if (!response?.ok) return "";
  const payload = await response.json().catch(() => null);
  if (!payload || !Array.isArray(payload.items)) return "";
  const matches = payload.items.filter((item) =>
    item?.title === title && normalizeUUID(item?.guid)
  );
  return matches.length === 1 ? normalizeUUID(matches[0].guid) : "";
}

/** Returns { ok, notFound, video } where video holds the fields we persist. */
export async function bunnyGetVideo(fetchImpl, config, videoID) {
  const response = await fetchImpl(
    `${BUNNY_STREAM_API_BASE}/library/${config.libraryID}/videos/${videoID}`,
    {
      method: "GET",
      headers: { AccessKey: config.apiKey, Accept: "application/json" },
      signal: AbortSignal.timeout(6_000),
    },
  ).catch(() => null);
  if (!response) return { ok: false, notFound: false };
  if (response.status === 404) return { ok: false, notFound: true };
  if (!response.ok) return { ok: false, notFound: false };
  const payload = await response.json().catch(() => null);
  if (!payload || normalizeUUID(payload.guid) !== videoID) {
    return { ok: false, notFound: false };
  }
  if (String(payload.videoLibraryId ?? config.libraryID) !== config.libraryID) {
    return { ok: false, notFound: true };
  }
  const integer = (value) =>
    Number.isFinite(Number(value)) ? Math.floor(Number(value)) : null;
  return {
    ok: true,
    notFound: false,
    video: {
      providerStatus: integer(payload.status),
      encodeProgress: integer(payload.encodeProgress),
      lengthSeconds: integer(payload.length),
      availableResolutions: typeof payload.availableResolutions === "string"
        ? payload.availableResolutions.slice(0, 200)
        : null,
      thumbnailFileName: typeof payload.thumbnailFileName === "string" &&
          /^[A-Za-z0-9._-]{1,128}$/.test(payload.thumbnailFileName)
        ? payload.thumbnailFileName
        : null,
      width: integer(payload.width),
      height: integer(payload.height),
    },
  };
}

export async function bunnyDeleteVideo(fetchImpl, config, videoID) {
  const response = await fetchImpl(
    `${BUNNY_STREAM_API_BASE}/library/${config.libraryID}/videos/${videoID}`,
    {
      method: "DELETE",
      headers: { AccessKey: config.apiKey, Accept: "application/json" },
      signal: AbortSignal.timeout(10_000),
    },
  ).catch(() => null);
  if (!response) return false;
  return response.ok || response.status === 404;
}

// ---------------------------------------------------------------------------
// Supabase helpers (service-role broker; user identity verified first)
// ---------------------------------------------------------------------------

export function bearerToken(request) {
  const header = request.headers.get("Authorization") || "";
  const match = header.match(/^Bearer\s+(\S+)$/i);
  return match ? match[1] : "";
}

/** Unverified JWT role claim; only used to recognise the public anon key. */
export function unverifiedJWTRole(token) {
  try {
    const part = token.split(".")[1];
    if (!part) return "";
    const padded = part.replace(/-/g, "+").replace(/_/g, "/") +
      "===".slice((part.length + 3) % 4);
    const payload = JSON.parse(atob(padded));
    return typeof payload?.role === "string" ? payload.role : "";
  } catch {
    return "";
  }
}

export function makeSupabaseDeps(getEnv, fetchImpl = fetch) {
  const supabaseURL = () => String(getEnv("SUPABASE_URL") || "");
  const anonKey = () => String(getEnv("SUPABASE_ANON_KEY") || "");
  const serviceKey = () => String(getEnv("SUPABASE_SERVICE_ROLE_KEY") || "");

  async function verifyUser(token) {
    if (!supabaseURL() || !anonKey() || !token) return null;
    try {
      const response = await fetchImpl(`${supabaseURL()}/auth/v1/user`, {
        headers: { apikey: anonKey(), Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(6_000),
      });
      if (!response.ok) return null;
      const payload = await response.json().catch(() => null);
      const id = normalizeUUID(payload?.id);
      return id ? { id } : null;
    } catch {
      return null;
    }
  }

  async function rpc(name, parameters) {
    if (!supabaseURL() || !serviceKey()) return null;
    try {
      const response = await fetchImpl(
        `${supabaseURL()}/rest/v1/rpc/${encodeURIComponent(name)}`,
        {
          method: "POST",
          headers: {
            apikey: serviceKey(),
            Authorization: `Bearer ${serviceKey()}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(parameters),
          signal: AbortSignal.timeout(6_000),
        },
      );
      if (!response.ok) return null;
      const payload = await response.json().catch(() => null);
      return payload && typeof payload === "object" && !Array.isArray(payload)
        ? payload
        : null;
    } catch {
      return null;
    }
  }

  return { verifyUser, rpc };
}

export function timingSafeEqual(left, right) {
  const a = new TextEncoder().encode(String(left ?? ""));
  const b = new TextEncoder().encode(String(right ?? ""));
  let diff = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    diff |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return diff === 0;
}

export function bunnyEnvFromDeno(getEnv) {
  return {
    BUNNY_STREAM_LIBRARY_ID: getEnv("BUNNY_STREAM_LIBRARY_ID"),
    BUNNY_STREAM_API_KEY: getEnv("BUNNY_STREAM_API_KEY"),
    BUNNY_STREAM_CDN_HOSTNAME: getEnv("BUNNY_STREAM_CDN_HOSTNAME"),
    BUNNY_STREAM_TOKEN_KEY: getEnv("BUNNY_STREAM_TOKEN_KEY"),
    BUNNY_STREAM_TUS_TTL_SECONDS: getEnv("BUNNY_STREAM_TUS_TTL_SECONDS"),
    BUNNY_STREAM_PLAYBACK_TTL_SECONDS: getEnv(
      "BUNNY_STREAM_PLAYBACK_TTL_SECONDS",
    ),
    BUNNY_STREAM_PLAYBACK_SIGNING: getEnv("BUNNY_STREAM_PLAYBACK_SIGNING"),
    BUNNY_STREAM_WEBHOOK_SECRET: getEnv("BUNNY_STREAM_WEBHOOK_SECRET"),
    COURSE_VIDEO_CRON_SECRET: getEnv("COURSE_VIDEO_CRON_SECRET"),
  };
}
