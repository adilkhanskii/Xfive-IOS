export const VIDEO_RESULT_SIGNED_URL_TTL_SECONDS = 15 * 60;
export const VIDEO_START_IMAGE_SIGNED_URL_TTL_SECONDS = 15 * 60;
export const MAX_START_IMAGE_BYTES = 8 * 1024 * 1024;
export const MAX_VIDEO_RESULT_BYTES = 50 * 1024 * 1024;
export const CUSTOMER_PRICE_MULTIPLIER = 2;
export const VIDEO_PROVIDER_COST_CREDITS = Object.freeze({
  5: 325,
  10: 600,
});
export const VIDEO_CREDIT_COSTS = Object.freeze(
  Object.fromEntries(
    Object.entries(VIDEO_PROVIDER_COST_CREDITS).map(([duration, cost]) => [
      duration,
      cost * CUSTOMER_PRICE_MULTIPLIER,
    ]),
  ),
);
export const VIDEO_GENERATION_MODELS = Object.freeze([
  "auto",
  "seedance-1.5-pro",
  "seedance-2.0-fast",
]);
export const VIDEO_GENERATION_RESOLUTIONS = Object.freeze([
  "480p",
  "720p",
  "1080p",
]);
export const VIDEO_JOB_STATUSES = Object.freeze([
  "queued",
  "rendering",
  "completed",
  "failed",
]);

const SUPPORTED_ASPECT_RATIOS = new Set(["16:9", "9:16"]);
const SUPPORTED_MODELS = new Set(VIDEO_GENERATION_MODELS);
const SUPPORTED_RESOLUTIONS = new Set(VIDEO_GENERATION_RESOLUTIONS);
const SUPPORTED_IMAGE_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
]);

export class VideoRequestError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "VideoRequestError";
    this.code = code;
    this.status = status;
  }
}

export function normalizeVideoGenerationRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new VideoRequestError("invalid_request");
  }

  const idempotencyKey = String(body.idempotency_key || "").trim();
  if (
    idempotencyKey.length < 8 ||
    idempotencyKey.length > 200 ||
    !/^[A-Za-z0-9._:-]+$/.test(idempotencyKey)
  ) {
    throw new VideoRequestError("invalid_idempotency_key");
  }

  const prompt = String(body.prompt || "").trim();
  if (prompt.length < 3) {
    throw new VideoRequestError("prompt_required");
  }
  if (prompt.length > 2500) {
    throw new VideoRequestError("prompt_too_long");
  }

  const aspectRatio = String(body.aspect_ratio || "16:9").trim();
  if (!SUPPORTED_ASPECT_RATIOS.has(aspectRatio)) {
    throw new VideoRequestError("unsupported_aspect_ratio");
  }

  const durationSeconds = Number(body.duration_seconds);
  if (
    !Number.isInteger(durationSeconds) || !VIDEO_CREDIT_COSTS[durationSeconds]
  ) {
    throw new VideoRequestError("unsupported_duration");
  }

  const model = String(body.model ?? "auto").trim();
  if (!SUPPORTED_MODELS.has(model)) {
    throw new VideoRequestError("unsupported_model");
  }

  const resolution = String(body.resolution ?? "720p").trim();
  if (!SUPPORTED_RESOLUTIONS.has(resolution)) {
    throw new VideoRequestError("unsupported_resolution");
  }
  if (model === "seedance-2.0-fast" && resolution === "1080p") {
    throw new VideoRequestError("unsupported_resolution");
  }

  const generateAudio = body.generate_audio == null
    ? model.startsWith("seedance-")
    : body.generate_audio;
  if (typeof generateAudio !== "boolean") {
    throw new VideoRequestError("invalid_generate_audio");
  }

  return {
    idempotencyKey,
    prompt,
    aspectRatio,
    durationSeconds,
    model,
    resolution,
    generateAudio,
    costCredits: VIDEO_CREDIT_COSTS[durationSeconds],
    startImage: normalizeStartImage(body.start_image),
  };
}

export function normalizeStartImage(rawImage) {
  if (rawImage == null) return null;
  if (!rawImage || typeof rawImage !== "object" || Array.isArray(rawImage)) {
    throw new VideoRequestError("unsupported_start_image");
  }

  const mimeType = String(rawImage.mime_type || "").trim().toLowerCase()
    .replace("image/jpg", "image/jpeg");
  if (!SUPPORTED_IMAGE_MIME_TYPES.has(mimeType)) {
    throw new VideoRequestError("unsupported_start_image");
  }

  const dataBase64 = String(rawImage.data_base64 || "").trim()
    .replace(/^data:[^;]+;base64,/i, "")
    .replace(/\s+/g, "");
  if (
    !dataBase64 ||
    dataBase64.length % 4 === 1 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(dataBase64)
  ) {
    throw new VideoRequestError("unsupported_start_image");
  }
  const byteLength = decodedBase64ByteLength(dataBase64);
  if (byteLength <= 0) {
    throw new VideoRequestError("unsupported_start_image");
  }
  if (byteLength > MAX_START_IMAGE_BYTES) {
    throw new VideoRequestError("start_image_too_large", 413);
  }

  return { mimeType, dataBase64, byteLength };
}

export async function buildVideoGenerationIdentity(normalized) {
  const requestKey = `explicit:${await sha256Hex(normalized.idempotencyKey)}`;
  const startImageSha256 = normalized.startImage
    ? await sha256Hex(normalized.startImage.dataBase64)
    : null;
  const fingerprint = await sha256Hex(JSON.stringify({
    prompt: normalized.prompt,
    aspect_ratio: normalized.aspectRatio,
    duration_seconds: normalized.durationSeconds,
    model: normalized.model,
    resolution: normalized.resolution,
    generate_audio: normalized.generateAudio,
    start_image: normalized.startImage
      ? {
        mime_type: normalized.startImage.mimeType,
        sha256: startImageSha256,
      }
      : null,
  }));
  return { requestKey, fingerprint, startImageSha256 };
}

export function buildPublicVideoJob(row, signedResult = null, assetID = null) {
  const status = VIDEO_JOB_STATUSES.includes(row?.status)
    ? row.status
    : "failed";
  const progress = Math.min(1, Math.max(0, Number(row?.progress || 0)));
  const completedResult = status === "completed" &&
      typeof signedResult?.signedUrl === "string" &&
      /^https:\/\//i.test(signedResult.signedUrl)
    ? signedResult
    : null;

  return {
    id: String(row?.id || ""),
    status,
    progress,
    credits_reserved: Number(row?.cost_credits || 0),
    refunded: Boolean(row?.refunded_at),
    result_url: completedResult?.signedUrl || null,
    result_url_expires_at: completedResult?.expiresAt || null,
    asset_id: assetID ? String(assetID) : null,
    error_code: row?.error_code ? String(row.error_code) : null,
    created_at: String(row?.created_at || ""),
    updated_at: String(row?.updated_at || ""),
  };
}

export function safeVideoError(code, message, retryable = false) {
  return {
    error: {
      code,
      message,
      retryable: Boolean(retryable),
    },
  };
}

export async function sha256Hex(value) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(String(value)),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function decodedBase64ByteLength(value) {
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return Math.floor((value.length * 3) / 4) - padding;
}
