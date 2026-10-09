// Защищённый перенос старых уроков (videoUrl в открытом бакете `videos`)
// в Bunny Stream с токенами. SQL: 20261009231500_course_video_legacy_import.sql.
//
// Отличие от course-video-bunny-mirror: урок НЕ получает открытый m3u8.
// Он становится обычным Bunny-уроком (videoProvider/bunnyVideoId/videoStatus,
// без videoUrl), и видео выдаёт только course-video-playback после проверки
// покупки. Пока Bunny не готов — урок играет по-старому.
//
// Вызов: только оператор, POST с X-X5-Reconcile-Secret
// (COURSE_VIDEO_CRON_SECRET). Курс обязателен, по умолчанию — dry_run.
//   { course_id, action: "dry_run" }                     что будет сделано
//   { course_id, action: "import", retry_failed? }       шаг за шагом, запускать
//                                                        повторно до swapped
//   { course_id, action: "remove_originals", confirm: course_id,
//     mode: "archive" | "delete", grace_minutes?, job_id? }
//                                                        оригиналы из бакета
// Ключи Bunny и секреты в ответ и логи не попадают.
import {
  BUNNY_STREAM_API_BASE,
  bunnyFindVideoByTitle,
  bunnyGetVideo,
  json,
  normalizeBunnyConfig,
  normalizeUUID,
  playbackURL,
  timingSafeEqual,
} from "../_shared/bunny-stream.mjs";
// Та же проверка, что в mirror: master + rendition + первый сегмент отвечают.
import { verifyHLS } from "../course-video-bunny-mirror/handler.mjs";

export const ARCHIVE_BUCKET = "course-video-originals";
const SOURCE_BUCKET = "videos";
const FETCH_DISCOVERY_TIMEOUT_MS = 30 * 60 * 1000;
const PROCESSING_TIMEOUT_MS = 12 * 60 * 60 * 1000;
const DEFAULT_REMOVE_GRACE_MINUTES = 24 * 60;
// Подпись только для своей проверки HLS, наружу не отдаётся.
const VERIFY_URL_TTL_SECONDS = 10 * 60;

export async function handleCourseVideoLegacyImport(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  const expected = String(deps.env?.COURSE_VIDEO_CRON_SECRET || "");
  const provided = request.headers.get("X-X5-Reconcile-Secret") || "";
  if (expected.length < 32 || !timingSafeEqual(provided, expected)) {
    return json({ error: "forbidden" }, 403);
  }
  // Ключ токенов обязателен: проверяем ровно ту ссылку, которую получит ученик.
  const config = normalizeBunnyConfig(deps.env || {}, {
    requireTokenKey: true,
  });
  const storageBase = String(deps.env?.SUPABASE_URL || "").replace(/\/+$/, "");
  if (!config || !storageBase) {
    return json({ error: "import_unavailable" }, 503);
  }

  let body = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  // Без course_id ничего не делаем — ни один курс не трогается «случайно».
  const courseID = normalizeUUID(body?.course_id);
  if (!courseID) return json({ error: "course_id_required" }, 400);
  const action = body?.action ?? "dry_run";
  const limit = Math.min(20, Math.max(1, Number(body?.limit) || 5));

  if (action === "dry_run") {
    const candidates = await deps.rpcRows("course_video_mirror_candidates", {
      p_course_id: courseID,
    });
    const jobs = await deps.rpcRows("course_video_legacy_import_status", {
      p_course_id: courseID,
    });
    if (!candidates || !jobs) return json({ error: "import_unavailable" }, 503);
    return json({ dry_run: true, course_id: courseID, candidates, jobs });
  }

  if (action === "import") {
    const enqueued = await deps.rpc("course_video_legacy_import_enqueue", {
      p_course_id: courseID,
      p_retry_failed: body?.retry_failed === true,
    });
    const jobs = await deps.rpcRows("course_video_legacy_import_claim", {
      p_course_id: courseID,
      p_limit: limit,
    });
    if (!enqueued || !jobs) return json({ error: "import_unavailable" }, 503);
    const results = [];
    for (const job of jobs) {
      try {
        results.push(await advance(job, { deps, config }));
      } catch (error) {
        // Сбой сети/кода — не провал задачи: статус тот же, следующий запуск
        // продолжит. Ошибку пишем в last_error.
        await deps.rpc("course_video_legacy_import_set", {
          p_job_id: job.id,
          p_status: job.status,
          p_source_bytes: null,
          p_error: `exception: ${
            String(error?.message || error).slice(0, 200)
          }`,
        });
        results.push({ job_id: job.id, status: "error" });
      }
    }
    return json({ ok: true, enqueued, processed: results.length, results });
  }

  if (action === "remove_originals") {
    // Необратимое действие (mode=delete) — второе явное подтверждение.
    if (body?.confirm !== courseID) {
      return json({ error: "confirm_required" }, 400);
    }
    const mode = body?.mode === "delete" ? "delete" : "archive";
    const graceMinutes = Number.isFinite(Number(body?.grace_minutes))
      ? Math.max(0, Math.floor(Number(body.grace_minutes)))
      : DEFAULT_REMOVE_GRACE_MINUTES;
    const onlyJob = body?.job_id ? normalizeUUID(body.job_id) : null;
    if (body?.job_id && !onlyJob) {
      return json({ error: "invalid_request" }, 400);
    }
    const jobs = await deps.rpcRows("course_video_legacy_import_status", {
      p_course_id: courseID,
    });
    if (!jobs) return json({ error: "import_unavailable" }, 503);
    const results = [];
    for (
      const job of jobs.filter((item) =>
        item.status === "swapped" && (!onlyJob || item.id === onlyJob)
      )
    ) {
      try {
        results.push(
          await removeOriginal(job, {
            deps,
            config,
            storageBase,
            mode,
            graceMinutes,
          }),
        );
      } catch (error) {
        results.push({
          job_id: job.id,
          status: "error",
          error: String(error?.message || error).slice(0, 200),
        });
      }
    }
    return json({ ok: true, mode, processed: results.length, results });
  }

  return json({ error: "invalid_action" }, 400);
}

async function advance(job, { deps, config }) {
  const now = Number(deps.now?.() ?? Date.now());
  const set = (status, extra = {}) =>
    deps.rpc("course_video_legacy_import_set", {
      p_job_id: job.id,
      p_status: status,
      p_source_bytes: extra.bytes ?? null,
      p_error: extra.error ?? null,
    });
  // Уникальное имя в Bunny: по нему находим видео, если fetch не вернул GUID.
  const title = `X5 legacy ${job.id}`;
  const register = async (videoID, bytes = null) => {
    const registered = await deps.rpc("course_video_legacy_import_register", {
      p_job_id: job.id,
      p_video_id: videoID,
      p_library_id: config.libraryID,
      p_source_bytes: bytes,
    });
    return {
      job_id: job.id,
      status: registered ?? "register_error",
      bunny_video_id: videoID,
    };
  };

  if (job.status === "queued") {
    const head = await deps.fetchImpl(job.source_url, { method: "HEAD" })
      .catch(() => null);
    if (!head?.ok) {
      await set("failed", { error: `source HEAD ${head?.status ?? "error"}` });
      return { job_id: job.id, status: "failed" };
    }
    const bytes = Number(head.headers.get("content-length")) || null;
    // Bunny сам скачивает файл по открытому URL — через функцию байты не идут.
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
        signal: AbortSignal.timeout(30_000),
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
    if (videoID) return await register(videoID, bytes);
    await set("fetching", { bytes });
    return { job_id: job.id, status: "fetching" };
  }

  if (job.status === "fetching") {
    const videoID = await bunnyFindVideoByTitle(deps.fetchImpl, config, title);
    if (videoID) return await register(videoID);
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

  // processing: статус берём у Bunny и пишем через общий
  // course_video_record_provider_status (тот же, что webhook/reconcile).
  const videoID = normalizeUUID(job.bunny_video_id);
  if (!videoID) {
    await set("failed", { error: "missing bunny video id" });
    return { job_id: job.id, status: "failed" };
  }
  const result = await bunnyGetVideo(deps.fetchImpl, config, videoID);
  if (!result.ok) {
    if (result.notFound) {
      await deps.rpc("course_video_record_provider_status", {
        p_video_id: videoID,
        p_provider_status: 6,
        p_encode_progress: 0,
        p_length_seconds: 0,
        p_available_resolutions: null,
        p_thumbnail_file_name: null,
        p_width: null,
        p_height: null,
      });
      await set("failed", { error: "bunny video deleted" });
      return { job_id: job.id, status: "failed" };
    }
    await set("processing");
    return { job_id: job.id, status: "processing" };
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
  });
  const assetStatus = recorded?.asset_status;
  if (assetStatus === "failed") {
    await set("failed", { error: `bunny status ${video.providerStatus}` });
    return { job_id: job.id, status: "failed" };
  }
  if (assetStatus !== "ready") {
    const created = Date.parse(job.created_at);
    if (Number.isFinite(created) && now - created > PROCESSING_TIMEOUT_MS) {
      await set("failed", { error: "encoding timeout" });
      return { job_id: job.id, status: "failed" };
    }
    await set("processing");
    return {
      job_id: job.id,
      status: "processing",
      progress: video.encodeProgress,
    };
  }

  // Проверяем ПОДПИСАННУЮ ссылку — так урок будет играть у покупателя.
  const expires = Math.floor(now / 1_000) + VERIFY_URL_TTL_SECONDS;
  const master = await playbackURL(config, videoID, "playlist.m3u8", expires);
  const verified = await verifyHLS(deps.fetchImpl, master);
  if (!verified.ok) {
    await set("processing", { error: `verify: ${verified.reason}` });
    return { job_id: job.id, status: "processing", verify: verified.reason };
  }
  const swap = await deps.rpc("course_video_legacy_import_swap", {
    p_job_id: job.id,
  });
  return {
    job_id: job.id,
    status: swap ?? "swap_error",
    bunny_video_id: videoID,
  };
}

async function removeOriginal(job, context) {
  const { deps, config, storageBase, mode, graceMinutes } = context;
  // 1. SQL-проверка: урок Bunny+ready без videoUrl, никто не ссылается, грейс.
  const guard = await deps.rpc("course_video_legacy_import_can_remove", {
    p_job_id: job.id,
    p_grace_minutes: graceMinutes,
  });
  if (guard?.ok !== true) {
    return {
      job_id: job.id,
      status: "guarded",
      reason: guard?.reason ?? "guard_error",
    };
  }
  // 2. Bunny-видео живо и закодировано.
  const videoID = normalizeUUID(guard.bunny_video_id);
  const video = videoID
    ? await bunnyGetVideo(deps.fetchImpl, config, videoID)
    : { ok: false };
  if (!video.ok || video.video.providerStatus !== 4) {
    return { job_id: job.id, status: "guarded", reason: "bunny_not_finished" };
  }
  // 3. Подписанный HLS реально отдаётся.
  const now = Number(deps.now?.() ?? Date.now());
  const expires = Math.floor(now / 1_000) + VERIFY_URL_TTL_SECONDS;
  const verified = await verifyHLS(
    deps.fetchImpl,
    await playbackURL(config, videoID, "playlist.m3u8", expires),
  );
  if (!verified.ok) {
    return {
      job_id: job.id,
      status: "guarded",
      reason: `verify: ${verified.reason}`,
    };
  }

  const storagePath = String(guard.storage_path);
  const encodedPath = storagePath.split("/").map(encodeURIComponent).join("/");
  const headers = deps.serviceHeaders();

  if (mode === "archive") {
    // Копия в приватный бакет; если копия уже есть с прошлого запуска —
    // copy вернёт ошибку, это нормально: дальше сверяем размер.
    await deps.fetchImpl(`${storageBase}/storage/v1/object/copy`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({
        bucketId: SOURCE_BUCKET,
        sourceKey: storagePath,
        destinationBucket: ARCHIVE_BUCKET,
        destinationKey: storagePath,
      }),
    }).catch(() => null);
    const copied = await deps.fetchImpl(
      `${storageBase}/storage/v1/object/authenticated/${ARCHIVE_BUCKET}/${encodedPath}`,
      { method: "HEAD", headers },
    ).catch(() => null);
    const copiedBytes = Number(copied?.headers?.get("content-length")) || 0;
    const expectedBytes = Number(guard.source_bytes) || 0;
    // Без подтверждённой копии оригинал не трогаем.
    if (
      !copied?.ok || !copiedBytes ||
      (expectedBytes && copiedBytes !== expectedBytes)
    ) {
      return {
        job_id: job.id,
        status: "archive_unverified",
        http: copied?.status ?? "error",
      };
    }
  }

  const removed = await deps.fetchImpl(
    `${storageBase}/storage/v1/object/${SOURCE_BUCKET}/${encodedPath}`,
    { method: "DELETE", headers },
  ).catch(() => null);
  if (!removed?.ok) {
    return {
      job_id: job.id,
      status: "delete_failed",
      http: removed?.status ?? "error",
    };
  }
  const marked = await deps.rpc("course_video_legacy_import_mark_removed", {
    p_job_id: job.id,
    p_action: mode === "archive" ? "archived" : "deleted",
    p_archive_path: mode === "archive"
      ? `${ARCHIVE_BUCKET}/${storagePath}`
      : null,
  });
  // Для отчёта: открытая ссылка больше не должна отдавать файл.
  const publicCheck = await deps.fetchImpl(job.source_url, { method: "HEAD" })
    .catch(() => null);
  return {
    job_id: job.id,
    status: marked ?? "mark_error",
    public_url_status: publicCheck?.status ?? "error",
  };
}
