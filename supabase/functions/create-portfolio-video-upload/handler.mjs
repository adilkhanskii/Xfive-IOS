// Портфолио: видео грузится в Bunny Stream (TUS), не в Supabase Storage
// (Диас 22.10: «любое видео — через Bunny»). Контракт запроса/ответа тот же, что
// у create-course-video-upload, чтобы iOS/сайт переиспользовали готовый загрузчик:
// course_id = id самого пользователя, lesson_id = "portfolio".
// Ключ Bunny не уходит из сервера — клиент получает только подпись TUS.
import {
  BUNNY_STREAM_TUS_ENDPOINT,
  bunnyCreateVideo,
  bunnyFindVideoByTitle,
  json,
  normalizeBunnyConfig,
  normalizeText,
  normalizeUUID,
  sha256Hex,
  tusSignature,
} from "../_shared/bunny-stream.mjs";

export const PORTFOLIO_LESSON_ID = "portfolio";
// Ролик с телефона: 4K-минута ≈ 400 МБ; 4 ГБ хватает с запасом.
export const MAX_PORTFOLIO_SOURCE_BYTES = 4 * 1024 * 1024 * 1024;

export async function handleCreatePortfolioVideoUpload(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  const authorization = request.headers.get("Authorization") || "";
  const tokenMatch = authorization.match(/^Bearer\s+(\S+)$/i);
  if (!tokenMatch) return json({ error: "not_authenticated" }, 401);
  const user = await deps.verifyUser(tokenMatch[1]).catch(() => null);
  const userID = normalizeUUID(user?.id);
  if (!userID) return json({ error: "not_authenticated" }, 401);

  let input;
  try {
    input = normalizeRequest(await request.json());
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  // Портфолио — только своё: «курс» в запросе обязан быть самим пользователем.
  if (input.ownerID !== userID) return json({ error: "not_authorized" }, 403);

  const config = normalizeBunnyConfig(deps.env || {});
  if (!config) {
    deps.logger?.error?.(JSON.stringify({ event: "portfolio_video_upload_not_configured" }));
    return json({ error: "video_upload_unavailable" }, 503);
  }

  const fingerprint = await sha256Hex(JSON.stringify([
    input.fileName,
    input.contentType,
    input.sourceBytes,
  ]));
  const claim = await deps.rpc("portfolio_video_claim_upload", {
    p_user_id: userID,
    p_upload_key: input.uploadKey,
    p_request_fingerprint: fingerprint,
  }).catch(() => null);

  switch (claim?.status) {
    case "claimed":
    case "replay":
      break;
    case "rate_limited":
      return json({ error: "rate_limited", retry_after: 60 }, 429, { "Retry-After": "60" });
    case "idempotency_conflict":
      return json({ error: "idempotency_conflict" }, 409);
    case "expired":
      return json({ error: "upload_expired" }, 410);
    case "invalid_request":
      return json({ error: "invalid_request" }, 400);
    default:
      return json({ error: "video_upload_unavailable" }, 503);
  }

  let videoID = "";
  if (claim.status === "replay") {
    videoID = normalizeUUID(claim.video_id);
    if (!videoID) return json({ error: "video_upload_unavailable" }, 503);
  } else {
    // Название = ключ сверки после «не понятно, создалось ли».
    const providerTitle = ["X5 portfolio", userID, input.uploadKey].join(" ").slice(0, 200);
    const created = await bunnyCreateVideo(deps.fetchImpl, config, providerTitle);
    if (created.ok) {
      videoID = created.videoID;
    } else if (created.retryable) {
      videoID = await bunnyFindVideoByTitle(deps.fetchImpl, config, providerTitle);
    }
    if (!videoID) {
      deps.logger?.error?.(JSON.stringify({ event: "portfolio_video_create_failed", user_id: userID }));
      return json({ error: "video_upload_unavailable" }, 502);
    }
    const recorded = await deps.rpc("portfolio_video_record_upload", {
      p_user_id: userID,
      p_upload_key: input.uploadKey,
      p_request_fingerprint: fingerprint,
      p_video_id: videoID,
      p_library_id: config.libraryID,
    }).catch(() => null);
    if (recorded?.status !== "recorded") {
      deps.logger?.error?.(JSON.stringify({ event: "portfolio_video_record_failed", user_id: userID }));
      return json({ error: "video_upload_unavailable" }, 503);
    }
  }

  const nowSeconds = Math.floor(Number(deps.now?.() ?? Date.now()) / 1_000);
  const expires = nowSeconds + config.tusTTLSeconds;
  const signature = await tusSignature({
    libraryID: config.libraryID,
    apiKey: config.apiKey,
    expires,
    videoID,
  });
  return json({
    tus_endpoint: BUNNY_STREAM_TUS_ENDPOINT,
    video_id: videoID,
    library_id: config.libraryID,
    authorization_signature: signature,
    authorization_expire: expires,
    upload_required: true,
    media_url: `bunny-stream:${videoID}`,
    upload_headers: {
      AuthorizationSignature: signature,
      AuthorizationExpire: String(expires),
      LibraryId: config.libraryID,
      VideoId: videoID,
    },
  });
}

function normalizeRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid_request");
  }
  const ownerID = normalizeUUID(value.course_id);
  const lessonID = String(value.lesson_id ?? "");
  const uploadKey = normalizeText(value.upload_key, 16, 128);
  const fileName = normalizeText(value.file_name, 1, 255);
  const contentType = normalizeText(value.content_type, 1, 128).toLowerCase();
  const sourceBytes = Number(value.source_bytes);
  if (
    !ownerID ||
    lessonID !== PORTFOLIO_LESSON_ID ||
    !/^[A-Za-z0-9_-]{16,128}$/.test(uploadKey) ||
    !fileName ||
    !/^video\/[a-z0-9.+-]+$/.test(contentType) ||
    !Number.isSafeInteger(sourceBytes) ||
    sourceBytes <= 0 ||
    sourceBytes > MAX_PORTFOLIO_SOURCE_BYTES
  ) {
    throw new Error("invalid_request");
  }
  return { ownerID, uploadKey, fileName, contentType, sourceBytes };
}
