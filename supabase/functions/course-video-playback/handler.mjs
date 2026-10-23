// Entitlement-checked, short-lived Bunny Stream HLS URL for one lesson.
//
// The entitlement decision lives in SQL (course_video_playback_grant, which
// mirrors purchase_course / purchase_lesson semantics). This handler only
// verifies identity, asks the grant, and signs a directory token so every
// rendition/segment below /<video>/ is reachable until `expires_at`.
import {
  bearerToken,
  json,
  normalizeBunnyConfig,
  normalizeLessonID,
  normalizeUUID,
  playbackTTLFor,
  playbackURL,
  unverifiedJWTRole,
} from "../_shared/bunny-stream.mjs";

export async function handleCourseVideoPlayback(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // Guests call with the public anon key: they can only open free lessons.
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
  const courseID = normalizeUUID(body?.course_id);
  const lessonID = normalizeLessonID(body?.lesson_id);
  if (!courseID || !lessonID) {
    return json({ error: "invalid_request" }, 400);
  }

  const config = normalizeBunnyConfig(deps.env || {}, {
    requireApiKey: false,
    requireTokenKey: true,
  });
  if (!config) {
    deps.logger?.error?.(JSON.stringify({
      event: "course_video_playback_not_configured",
    }));
    return json({ error: "playback_unavailable" }, 503);
  }

  const grant = await deps.rpc("course_video_playback_grant", {
    p_user_id: userID,
    p_course_id: courseID,
    p_lesson_id: lessonID,
  }).catch(() => null);

  switch (grant?.status) {
    case "granted":
      break;
    case "processing":
      return json({ status: "processing" }, 202);
    case "failed":
      return json({ error: "video_failed" }, 422);
    case "not_authenticated":
      return json({ error: "not_authenticated" }, 401);
    case "not_entitled":
      return json({ error: "not_entitled" }, 403);
    case "not_bunny_lesson":
      return json({ error: "not_bunny_lesson" }, 409);
    case "lesson_unavailable":
      return json({ error: "lesson_unavailable" }, 404);
    default:
      return json({ error: "playback_unavailable" }, 503);
  }

  const videoID = normalizeUUID(grant.video_id);
  if (!videoID) return json({ error: "playback_unavailable" }, 503);

  const nowSeconds = Math.floor(Number(deps.now?.() ?? Date.now()) / 1_000);
  const expires = nowSeconds + playbackTTLFor(config, grant.length_seconds);
  const hlsURL = await playbackURL(config, videoID, "playlist.m3u8", expires);
  const thumbnailFile = typeof grant.thumbnail_file_name === "string" &&
      /^[A-Za-z0-9._-]{1,128}$/.test(grant.thumbnail_file_name)
    ? grant.thumbnail_file_name
    : "";
  const thumbnailURL = thumbnailFile
    ? await playbackURL(config, videoID, thumbnailFile, expires)
    : null;

  return json({
    status: "ready",
    video_id: videoID,
    hls_url: hlsURL,
    thumbnail_url: thumbnailURL,
    expires_at: expires,
    length_seconds: Number.isFinite(Number(grant.length_seconds))
      ? Number(grant.length_seconds)
      : null,
  });
}
