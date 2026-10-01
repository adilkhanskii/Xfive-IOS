// Readiness + cleanup for Bunny course videos. Three callers:
//
// 1. Bunny Stream webhook  POST {VideoLibraryId, VideoGuid, Status}
//    The payload is never trusted: only a VideoGuid already in our ledger is
//    refreshed, and its state is re-read from the Bunny API.
// 2. Course editor polling  POST {video_id} with the user's JWT
//    (uploader, course author or developer only).
// 3. pg_cron reconciler      POST ?reconcile=1 with X-X5-Reconcile-Secret
//    Refreshes stale in-flight assets and deletes abandoned / failed /
//    unreferenced ones from Bunny. Never touches Bunny videos that are not in
//    public.course_video_assets (the library holds older videos too).
import {
  bearerToken,
  bunnyDeleteVideo,
  bunnyGetVideo,
  json,
  normalizeBunnyConfig,
  normalizeUUID,
  timingSafeEqual,
} from "../_shared/bunny-stream.mjs";

const POLL_MIN_INTERVAL_MS = 5_000;

export async function handleCourseVideoStatus(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  const config = normalizeBunnyConfig(deps.env || {});
  if (!config) {
    deps.logger?.error?.(JSON.stringify({
      event: "course_video_status_not_configured",
    }));
    return json({ error: "status_unavailable" }, 503);
  }

  const url = new URL(request.url);
  if (url.searchParams.has("reconcile")) {
    const expected = String(deps.env?.COURSE_VIDEO_CRON_SECRET || "");
    const provided = request.headers.get("X-X5-Reconcile-Secret") || "";
    if (expected.length < 32 || !timingSafeEqual(provided, expected)) {
      return json({ error: "forbidden" }, 403);
    }
    return json(await reconcile(deps, config));
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }

  if (body && typeof body === "object" && "VideoGuid" in body) {
    return await handleWebhook(url, body, deps, config);
  }

  const token = bearerToken(request);
  const user = token ? await deps.verifyUser(token).catch(() => null) : null;
  const userID = normalizeUUID(user?.id);
  if (!userID) return json({ error: "not_authenticated" }, 401);
  const videoID = normalizeUUID(body?.video_id);
  if (!videoID) return json({ error: "invalid_request" }, 400);

  const lookup = await deps.rpc("course_video_owner_lookup", {
    p_user_id: userID,
    p_video_id: videoID,
  }).catch(() => null);
  if (!lookup) return json({ error: "status_unavailable" }, 503);
  if (lookup.status !== "found") return json({ error: "not_found" }, 404);

  let assetStatus = lookup.asset_status;
  let encodeProgress = lookup.encode_progress ?? null;
  let lengthSeconds = lookup.length_seconds ?? null;
  const lastChecked = Date.parse(lookup.last_checked_at || "");
  const fresh = Number.isFinite(lastChecked) &&
    Number(deps.now?.() ?? Date.now()) - lastChecked < POLL_MIN_INTERVAL_MS;
  if (
    (assetStatus === "awaiting_upload" || assetStatus === "processing") &&
    !fresh
  ) {
    const refreshed = await refresh(deps, config, videoID);
    if (refreshed) {
      assetStatus = refreshed.assetStatus ?? assetStatus;
      encodeProgress = refreshed.encodeProgress ?? encodeProgress;
      lengthSeconds = refreshed.lengthSeconds ?? lengthSeconds;
    }
  }
  return json({
    video_id: videoID,
    status: assetStatus,
    encode_progress: encodeProgress,
    length_seconds: lengthSeconds,
  });
}

async function handleWebhook(url, body, deps, config) {
  const secret = String(deps.env?.BUNNY_STREAM_WEBHOOK_SECRET || "");
  if (
    secret && !timingSafeEqual(url.searchParams.get("secret") || "", secret)
  ) {
    return json({ error: "forbidden" }, 403);
  }
  const videoID = normalizeUUID(body.VideoGuid);
  if (
    !videoID ||
    String(body.VideoLibraryId ?? "") !== config.libraryID
  ) {
    // Acknowledge so Bunny does not retry foreign / malformed events.
    return json({ ok: true, ignored: true });
  }
  await refresh(deps, config, videoID);
  return json({ ok: true });
}

async function refresh(deps, config, videoID) {
  const result = await bunnyGetVideo(deps.fetchImpl, config, videoID);
  if (!result.ok) {
    if (result.notFound) {
      // Gone at Bunny (deleted in dashboard): record as an upload failure so
      // the reconciler cleans the ledger row and the editor shows an error.
      const recorded = await deps.rpc("course_video_record_provider_status", {
        p_video_id: videoID,
        p_provider_status: 6,
        p_encode_progress: 0,
        p_length_seconds: 0,
        p_available_resolutions: null,
        p_thumbnail_file_name: null,
        p_width: null,
        p_height: null,
      }).catch(() => null);
      return recorded ? { assetStatus: recorded.asset_status } : null;
    }
    return null;
  }
  const video = result.video;
  const recorded = await deps.rpc("course_video_record_provider_status", {
    p_video_id: videoID,
    p_provider_status: video.providerStatus,
    p_encode_progress: video.encodeProgress,
    p_length_seconds: video.lengthSeconds,
    p_available_resolutions: video.availableResolutions,
    p_thumbnail_file_name: video.thumbnailFileName,
    p_width: video.width,
    p_height: video.height,
  }).catch(() => null);
  if (!recorded || recorded.status === "unknown_video") return null;
  return {
    assetStatus: recorded.asset_status,
    encodeProgress: video.encodeProgress,
    lengthSeconds: video.lengthSeconds,
  };
}

async function reconcile(deps, config) {
  const batch = await deps.rpc("course_video_reconcile_batch", {
    p_limit: 25,
  }).catch(() => null);
  if (!batch) return { ok: false };

  let refreshed = 0;
  for (const raw of Array.isArray(batch.refresh) ? batch.refresh : []) {
    const videoID = normalizeUUID(raw);
    if (videoID && await refresh(deps, config, videoID)) refreshed += 1;
  }

  let deleted = 0;
  let deleteFailed = 0;
  for (const raw of Array.isArray(batch.delete) ? batch.delete : []) {
    const videoID = normalizeUUID(raw);
    if (!videoID) continue;
    if (await bunnyDeleteVideo(deps.fetchImpl, config, videoID)) {
      const marked = await deps.rpc("course_video_mark_deleted", {
        p_video_id: videoID,
      }).catch(() => null);
      if (marked?.status === "deleted") deleted += 1;
    } else {
      // Stays 'deleting'; the next run retries after 30 minutes.
      deleteFailed += 1;
    }
  }

  const summary = {
    ok: true,
    refreshed,
    deleted,
    delete_failed: deleteFailed,
    abandoned: Number(batch.abandoned) || 0,
  };
  if (deleteFailed || summary.abandoned) {
    deps.logger?.warn?.(JSON.stringify({
      event: "course_video_reconcile_attention",
      ...summary,
    }));
  }
  return summary;
}
