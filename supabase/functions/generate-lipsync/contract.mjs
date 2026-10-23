export const LIPSYNC_MODEL = "fal-ai/sync-lipsync";
export const CUSTOMER_PRICE_MULTIPLIER = 2;
export const PROVIDER_COST_CREDITS_PER_SECOND = 25;
export const LIPSYNC_CREDITS_PER_SECOND = PROVIDER_COST_CREDITS_PER_SECOND *
  CUSTOMER_PRICE_MULTIPLIER;
export const MAXIMUM_LIPSYNC_SECONDS = 60;

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class LipsyncRequestError extends Error {
  /** @param {string} code @param {number} [status] */
  constructor(code, status = 400) {
    super(code);
    this.name = "LipsyncRequestError";
    this.code = code;
    this.status = status;
  }
}

/** @param {Record<string, unknown>} body */
export function normalizeLipsyncRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new LipsyncRequestError("invalid_request");
  }
  const requestID = String(body.request_id || "").trim().toLowerCase();
  const videoAssetID = String(body.video_asset_id || "").trim().toLowerCase();
  const audioAssetID = String(body.audio_asset_id || "").trim().toLowerCase();
  if (
    ![requestID, videoAssetID, audioAssetID].every((id) => uuidPattern.test(id))
  ) {
    throw new LipsyncRequestError("invalid_asset_or_request_id");
  }
  const durationSeconds = Number(body.duration_seconds);
  if (
    !Number.isInteger(durationSeconds) || durationSeconds < 1 ||
    durationSeconds > MAXIMUM_LIPSYNC_SECONDS
  ) {
    throw new LipsyncRequestError("unsupported_duration");
  }
  return {
    requestID,
    videoAssetID,
    audioAssetID,
    durationSeconds,
    model: LIPSYNC_MODEL,
    costCredits: durationSeconds * LIPSYNC_CREDITS_PER_SECOND,
  };
}

/** @param {ReturnType<typeof normalizeLipsyncRequest>} normalized */
export async function buildLipsyncFingerprint(normalized) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify({
      video_asset_id: normalized.videoAssetID,
      audio_asset_id: normalized.audioAssetID,
      duration_seconds: normalized.durationSeconds,
      model: normalized.model,
      cost_credits: normalized.costCredits,
    })),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * @param {Record<string, unknown>} row
 * @param {{signedURL: string, expiresAt: string}|null} [signed]
 * @param {number|null} [progressOverride]
 */
export function publicLipsyncJob(row, signed = null, progressOverride = null) {
  const state = String(row?.job_status || row?.status || "queued");
  return {
    id: String(row?.id || row?.job_id || ""),
    status: ["queued", "processing", "completed", "refunded"].includes(state)
      ? state
      : "queued",
    progress: Math.max(
      0,
      Math.min(1, Number(progressOverride ?? row?.progress ?? 0)),
    ),
    cost_credits: Number(row?.cost_credits || 0),
    credits_remaining: Number(row?.credits_remaining || 0),
    refunded: Boolean(row?.refunded),
    result_asset_id: row?.result_asset_id ? String(row.result_asset_id) : null,
    result_url: signed?.signedURL || null,
    result_url_expires_at: signed?.expiresAt || null,
    error_code: row?.error_code ? String(row.error_code) : null,
    created_at: row?.created_at || null,
    updated_at: row?.updated_at || null,
  };
}
