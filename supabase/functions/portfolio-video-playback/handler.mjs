// Показ видео портфолио из Bunny Stream: короткоживущая подписанная HLS-ссылка.
// Кто видит: одобренный кейс — все (и гости), неодобренный — только владелец
// (решение в SQL: portfolio_video_playback_grant). Пока Bunny кодирует — 202 processing.
import {
  bearerToken,
  bunnyGetVideo,
  json,
  normalizeBunnyConfig,
  normalizeUUID,
  playbackTTLFor,
  playbackURL,
  unverifiedJWTRole,
} from "../_shared/bunny-stream.mjs";

// Bunny Stream: 3 = transcoding (часть качеств уже есть), 4 = finished.
const PLAYABLE_STATUSES = new Set([3, 4]);
const FAILED_STATUSES = new Set([5, 6]);
const MP4_RESOLUTIONS = ["720p", "480p", "360p", "240p"];

export async function handlePortfolioVideoPlayback(request, deps) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const token = bearerToken(request);
  let userID = null;
  const isPublicKey = !token ||
    unverifiedJWTRole(token) === "anon" ||
    token.startsWith("sb_publishable_") ||
    (deps.anonKey && token === deps.anonKey);
  if (!isPublicKey) {
    const user = await deps.verifyUser(token).catch(() => null);
    userID = normalizeUUID(user?.id) || null;
    if (!userID) return json({ error: "not_authenticated" }, 401);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  const itemID = normalizeUUID(body?.item_id);
  if (!itemID) return json({ error: "invalid_request" }, 400);

  const config = normalizeBunnyConfig(deps.env || {}, { requireApiKey: true, requireTokenKey: true });
  if (!config) return json({ error: "playback_unavailable" }, 503);

  const grant = await deps.rpc("portfolio_video_playback_grant", {
    p_item_id: itemID,
    p_user_id: userID,
  }).catch(() => null);
  switch (grant?.status) {
    case "granted":
      break;
    case "not_found":
      return json({ error: "not_found" }, 404);
    case "not_bunny":
      return json({ error: "not_bunny" }, 409);
    default:
      return json({ error: "playback_unavailable" }, 503);
  }
  const videoID = normalizeUUID(grant.video_id);
  if (!videoID) return json({ error: "playback_unavailable" }, 503);

  const info = await bunnyGetVideo(deps.fetchImpl, config, videoID);
  if (!info.ok) {
    return info.notFound ? json({ error: "not_found" }, 404) : json({ error: "playback_unavailable" }, 503);
  }
  if (FAILED_STATUSES.has(info.video.providerStatus)) return json({ error: "video_failed" }, 422);
  if (!PLAYABLE_STATUSES.has(info.video.providerStatus) || !info.video.availableResolutions) {
    return json({ status: "processing", encode_progress: info.video.encodeProgress }, 202);
  }

  const nowSeconds = Math.floor(Number(deps.now?.() ?? Date.now()) / 1_000);
  const expires = nowSeconds + playbackTTLFor(config, info.video.lengthSeconds);
  // MP4 (Bunny MP4 fallback) — для iOS-превью кадра, «Поделиться» и <video> на сайте
  // без hls.js; лучшее доступное качество до 720p.
  const resolutions = String(info.video.availableResolutions || "").split(",").map((r) => r.trim());
  const mp4Res = MP4_RESOLUTIONS.find((r) => resolutions.includes(r));
  return json({
    status: "ready",
    video_id: videoID,
    hls_url: await playbackURL(config, videoID, "playlist.m3u8", expires),
    mp4_url: mp4Res ? await playbackURL(config, videoID, `play_${mp4Res}.mp4`, expires) : null,
    thumbnail_url: info.video.thumbnailFileName
      ? await playbackURL(config, videoID, info.video.thumbnailFileName, expires)
      : null,
    expires_at: expires,
    length_seconds: info.video.lengthSeconds,
  });
}
