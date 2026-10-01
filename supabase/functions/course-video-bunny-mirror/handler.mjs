// "No-rebuild" Bunny mirror for course lesson videos (see migration
// 20261001120000_course_video_bunny_mirror.sql).
//
// For every lesson whose videoUrl is a public object in Supabase bucket
// `videos`: Bunny fetches the file from that public URL, encodes adaptive HLS,
// the lesson videoUrl is switched to https://<cdn>/<guid>/playlist.m3u8 after
// the playlist AND a media segment answer 200, and only after a grace period
// (re-verified, no lesson still pointing at the object) the Supabase object
// is deleted. Any failure stops the job before deletion.
//
// Caller: pg_cron (X-X5-Reconcile-Secret) or an operator with the same
// secret. Body: { course_id?, dry_run?, delete_grace_minutes?, limit? }.
import {
  BUNNY_STREAM_API_BASE,
  bunnyFindVideoByTitle,
  bunnyGetVideo,
  json,
  normalizeBunnyConfig,
  normalizeUUID,
  timingSafeEqual,
} from "../_shared/bunny-stream.mjs";

const DEFAULT_DELETE_GRACE_MINUTES = 24 * 60;
const FETCH_DISCOVERY_TIMEOUT_MS = 30 * 60 * 1000;
const ENCODING_TIMEOUT_MS = 12 * 60 * 60 * 1000;

export async function handleCourseVideoBunnyMirror(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  const expected = String(deps.env?.COURSE_VIDEO_CRON_SECRET || "");
  const provided = request.headers.get("X-X5-Reconcile-Secret") || "";
  if (expected.length < 32 || !timingSafeEqual(provided, expected)) {
    return json({ error: "forbidden" }, 403);
  }
  const config = normalizeBunnyConfig(deps.env || {});
  const storageBase = String(deps.env?.SUPABASE_URL || "").replace(/\/+$/, "");
  if (!config || !storageBase) {
    return json({ error: "mirror_unavailable" }, 503);
  }

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const courseID = body?.course_id ? normalizeUUID(body.course_id) : null;
  if (body?.course_id && !courseID) {
    return json({ error: "invalid_request" }, 400);
  }
  const graceMinutes = Number.isFinite(Number(body?.delete_grace_minutes))
    ? Math.max(0, Math.floor(Number(body.delete_grace_minutes)))
    : DEFAULT_DELETE_GRACE_MINUTES;
  const limit = Math.min(50, Math.max(1, Number(body?.limit) || 10));

  if (body?.dry_run === true) {
    const candidates = await deps.rpcRows("course_video_mirror_candidates", {
      p_course_id: courseID,
    });
    if (!candidates) return json({ error: "mirror_unavailable" }, 503);
    return json({ dry_run: true, candidates });
  }

  await deps.rpc("course_video_mirror_reopen_reverted", {});
  const enqueued = await deps.rpc("course_video_mirror_enqueue", {
    p_course_id: courseID,
  });
  const jobs = await deps.rpcRows("course_video_mirror_claim", {
    p_course_id: courseID,
    p_limit: limit,
  });
  if (!jobs) return json({ error: "mirror_unavailable" }, 503);

  const results = [];
  for (const job of jobs) {
    try {
      results.push(
        await advance(job, { deps, config, storageBase, graceMinutes }),
      );
    } catch (error) {
      await deps.rpc("course_video_mirror_set", {
        p_job_id: job.id,
        p_status: job.status === "swapped" ? "swapped" : "failed",
        p_error: `exception: ${String(error?.message || error).slice(0, 200)}`,
      });
      results.push({ job_id: job.id, status: "error" });
    }
  }
  return json({ ok: true, enqueued, processed: results.length, results });
}

async function advance(job, context) {
  const { deps, config } = context;
  const now = Number(deps.now?.() ?? Date.now());
  const set = (status, extra = {}) =>
    deps.rpc("course_video_mirror_set", {
      p_job_id: job.id,
      p_status: status,
      p_bunny_video_id: extra.videoID ?? null,
      p_hls_url: extra.hlsURL ?? null,
      p_source_bytes: extra.bytes ?? null,
      p_error: extra.error ?? null,
    });
  const title = `X5 mirror ${job.id}`;

  if (job.status === "queued") {
    const head = await deps.fetchImpl(job.source_url, { method: "HEAD" })
      .catch(() => null);
    if (!head?.ok) {
      await set("failed", { error: `source HEAD ${head?.status ?? "error"}` });
      return { job_id: job.id, status: "failed" };
    }
    const bytes = Number(head.headers.get("content-length")) || null;
    const response = await deps.fetchImpl(
      `${BUNNY_STREAM_API_BASE}/library/${config.libraryID}/videos/fetch`,
      {
        method: "POST",
        headers: {
          AccessKey: config.apiKey,
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ url: job.source_url, title }),
      },
    ).catch(() => null);
    if (!response?.ok) {
      await set("failed", {
        error: `bunny fetch ${response?.status ?? "error"}`,
      });
      return { job_id: job.id, status: "failed" };
    }
    const payload = await response.json().catch(() => ({}));
    const videoID = normalizeUUID(payload?.id) ||
      normalizeUUID(payload?.guid) ||
      normalizeUUID(payload?.videoId);
    await set(videoID ? "encoding" : "fetching", { videoID, bytes });
    return { job_id: job.id, status: videoID ? "encoding" : "fetching" };
  }

  if (job.status === "fetching") {
    const videoID = await bunnyFindVideoByTitle(deps.fetchImpl, config, title);
    if (videoID) {
      await set("encoding", { videoID });
      return { job_id: job.id, status: "encoding" };
    }
    const requested = Date.parse(job.fetch_requested_at || job.created_at);
    if (
      Number.isFinite(requested) && now - requested > FETCH_DISCOVERY_TIMEOUT_MS
    ) {
      await set("failed", { error: "bunny video not found after fetch" });
      return { job_id: job.id, status: "failed" };
    }
    await set("fetching");
    return { job_id: job.id, status: "fetching" };
  }

  const videoID = normalizeUUID(job.bunny_video_id);
  if (!videoID) {
    await set("failed", { error: "missing bunny video id" });
    return { job_id: job.id, status: "failed" };
  }
  const hlsURL = `https://${config.cdnHostname}/${videoID}/playlist.m3u8`;

  if (job.status === "encoding") {
    const result = await bunnyGetVideo(deps.fetchImpl, config, videoID);
    if (!result.ok) {
      if (result.notFound) {
        await set("failed", { error: "bunny video deleted" });
        return { job_id: job.id, status: "failed" };
      }
      await set("encoding");
      return { job_id: job.id, status: "encoding" };
    }
    const providerStatus = result.video.providerStatus;
    if (providerStatus === 5 || providerStatus === 6) {
      await set("failed", { error: `bunny status ${providerStatus}` });
      return { job_id: job.id, status: "failed" };
    }
    if (providerStatus !== 4) {
      const created = Date.parse(job.created_at);
      if (Number.isFinite(created) && now - created > ENCODING_TIMEOUT_MS) {
        await set("failed", { error: "encoding timeout" });
        return { job_id: job.id, status: "failed" };
      }
      await set("encoding");
      return {
        job_id: job.id,
        status: "encoding",
        progress: result.video.encodeProgress,
      };
    }
    const verified = await verifyHLS(deps.fetchImpl, hlsURL);
    if (!verified.ok) {
      // Stay in encoding: token auth / CDN propagation may be transient.
      await set("encoding", { error: `verify: ${verified.reason}` });
      return { job_id: job.id, status: "encoding", verify: verified.reason };
    }
    const swap = await deps.rpc("course_video_mirror_swap", {
      p_job_id: job.id,
      p_hls_url: hlsURL,
    });
    return { job_id: job.id, status: swap ?? "swap_error", hls_url: hlsURL };
  }

  if (job.status === "swapped") {
    const swappedAt = Date.parse(job.swapped_at || "");
    if (
      !Number.isFinite(swappedAt) ||
      now - swappedAt < context.graceMinutes * 60 * 1000
    ) {
      await set("swapped");
      return { job_id: job.id, status: "swapped_waiting_grace" };
    }
    const verified = await verifyHLS(deps.fetchImpl, job.hls_url || hlsURL);
    if (!verified.ok) {
      await set("swapped", { error: `pre-delete verify: ${verified.reason}` });
      return { job_id: job.id, status: "swapped", verify: verified.reason };
    }
    const allowed = await deps.rpc("course_video_mirror_can_delete", {
      p_job_id: job.id,
    });
    if (allowed !== true) {
      await set("swapped", { error: "delete guard refused" });
      return { job_id: job.id, status: "swapped_guarded" };
    }
    const objectPath = String(job.storage_path).split("/")
      .map(encodeURIComponent).join("/");
    const removed = await deps.fetchImpl(
      `${context.storageBase}/storage/v1/object/videos/${objectPath}`,
      { method: "DELETE", headers: deps.serviceHeaders() },
    ).catch(() => null);
    if (!removed?.ok) {
      await set("swapped", {
        error: `storage delete ${removed?.status ?? "error"}`,
      });
      return { job_id: job.id, status: "swapped" };
    }
    await set("storage_deleted");
    return { job_id: job.id, status: "storage_deleted" };
  }

  return { job_id: job.id, status: job.status };
}

/** Playlist, first rendition playlist and its first segment must all be 2xx. */
export async function verifyHLS(fetchImpl, masterURL) {
  const master = await fetchImpl(masterURL).catch(() => null);
  if (!master?.ok) {
    return { ok: false, reason: `master ${master?.status ?? "error"}` };
  }
  const masterText = await master.text().catch(() => "");
  if (!masterText.startsWith("#EXTM3U")) {
    return { ok: false, reason: "master not m3u8" };
  }
  const rendition = firstURI(masterText);
  if (!rendition) return { ok: false, reason: "no rendition" };
  const renditionURL = new URL(rendition, masterURL).toString();
  const media = await fetchImpl(renditionURL).catch(() => null);
  if (!media?.ok) {
    return { ok: false, reason: `rendition ${media?.status ?? "error"}` };
  }
  const mediaText = await media.text().catch(() => "");
  const segment = firstURI(mediaText);
  if (!segment) return { ok: false, reason: "no segment" };
  const segmentURL = new URL(segment, renditionURL).toString();
  const chunk = await fetchImpl(segmentURL, {
    headers: { Range: "bytes=0-1023" },
  }).catch(() => null);
  if (!chunk || (chunk.status !== 200 && chunk.status !== 206)) {
    return { ok: false, reason: `segment ${chunk?.status ?? "error"}` };
  }
  await chunk.body?.cancel?.().catch?.(() => {});
  return { ok: true };
}

function firstURI(playlist) {
  return playlist.split(/\r?\n/).map((line) => line.trim())
    .find((line) => line && !line.startsWith("#")) || "";
}
