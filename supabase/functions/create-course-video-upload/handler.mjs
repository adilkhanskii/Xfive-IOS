// Course lesson video upload broker (Bunny Stream, TUS resumable upload).
//
// Flow: verify user JWT -> service-role RPC claims an idempotent upload slot
// (feature flag, course author/developer check, rate limit) -> create the
// Bunny video object -> service-role RPC records it -> return a TUS
// presigned signature. The Bunny API key never leaves the server.
import {
  BUNNY_STREAM_TUS_ENDPOINT,
  bunnyCreateVideo,
  bunnyFindVideoByTitle,
  json,
  normalizeBunnyConfig,
  normalizeLessonID,
  normalizeText,
  normalizeUUID,
  sha256Hex,
  tusSignature,
} from "../_shared/bunny-stream.mjs";

export { BUNNY_STREAM_TUS_ENDPOINT };

// Long lessons in source quality: 3 h of 1080p at ~20 Mbit/s is ~27 GB.
export const MAX_SOURCE_BYTES = 40 * 1024 * 1024 * 1024;

export async function handleCreateCourseVideoUpload(request, deps) {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authorization = request.headers.get("Authorization") || "";
  const tokenMatch = authorization.match(/^Bearer\s+(\S+)$/i);
  if (!tokenMatch) {
    return json({ error: "not_authenticated" }, 401);
  }
  const user = await deps.verifyUser(tokenMatch[1]).catch(() => null);
  const userID = normalizeUUID(user?.id);
  if (!userID) {
    return json({ error: "not_authenticated" }, 401);
  }

  let input;
  try {
    input = normalizeRequest(await request.json());
  } catch {
    return json({ error: "invalid_request" }, 400);
  }

  const config = normalizeBunnyConfig(deps.env || {});
  if (!config) {
    deps.logger?.error?.(JSON.stringify({
      event: "course_video_upload_not_configured",
    }));
    return json({ error: "video_upload_unavailable" }, 503);
  }

  const leaseToken = normalizeUUID(deps.randomUUID?.());
  if (!leaseToken) {
    return json({ error: "video_upload_unavailable" }, 503);
  }
  const requestFingerprint = await sha256Hex(JSON.stringify([
    input.courseID,
    input.lessonID,
    input.fileName,
    input.contentType,
    input.sourceBytes,
  ]));

  const claim = await deps.rpc("course_video_claim_upload", {
    p_user_id: userID,
    p_course_id: input.courseID,
    p_lesson_id: input.lessonID,
    p_upload_key: input.uploadKey,
    p_request_fingerprint: requestFingerprint,
    p_lease_token: leaseToken,
    p_source_bytes: input.sourceBytes,
  }).catch(() => null);

  switch (claim?.status) {
    case "claimed":
    case "replay":
      break;
    case "disabled":
      return json({ error: "video_upload_unavailable" }, 503);
    case "not_authorized":
    case "course_unavailable":
      return json({ error: "not_authorized" }, 403);
    case "rate_limited":
      return json({ error: "rate_limited", retry_after: 60 }, 429, {
        "Retry-After": "60",
      });
    case "in_progress":
      return json({ error: "upload_slot_in_progress", retry_after: 3 }, 425, {
        "Retry-After": "3",
      });
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
    if (claim.asset_status === "ready" || claim.asset_status === "processing") {
      // Bytes already arrived; never re-sign an upload over a finished video.
      return json({
        video_id: videoID,
        library_id: config.libraryID,
        status: claim.asset_status,
        upload_required: false,
      });
    }
  } else {
    // Title doubles as the reconciliation key after an ambiguous create.
    const providerTitle = [
      "X5 lesson",
      input.courseID,
      input.lessonID,
      input.uploadKey,
    ].join(" ").slice(0, 200);

    if (claim.reclaimed === true) {
      videoID = await bunnyFindVideoByTitle(
        deps.fetchImpl,
        config,
        providerTitle,
      );
    }
    if (!videoID) {
      const created = await bunnyCreateVideo(
        deps.fetchImpl,
        config,
        providerTitle,
      );
      if (created.ok) {
        videoID = created.videoID;
      } else if (created.retryable) {
        videoID = await bunnyFindVideoByTitle(
          deps.fetchImpl,
          config,
          providerTitle,
        );
      }
    }
    if (!videoID) {
      deps.logger?.error?.(JSON.stringify({
        event: "course_video_upload_create_failed",
        user_id: userID,
      }));
      return json({ error: "video_upload_unavailable" }, 502);
    }

    let completion = null;
    for (let attempt = 0; attempt < 3 && !completion; attempt += 1) {
      const result = await deps.rpc("course_video_complete_upload", {
        p_user_id: userID,
        p_upload_key: input.uploadKey,
        p_request_fingerprint: requestFingerprint,
        p_lease_token: leaseToken,
        p_video_id: videoID,
        p_library_id: config.libraryID,
      }).catch(() => null);
      if (
        result?.status === "completed" ||
        result?.status === "already_completed"
      ) {
        completion = result;
      } else if (attempt < 2) {
        await new Promise((resolve) =>
          setTimeout(resolve, 100 * (attempt + 1))
        );
      }
    }
    if (!completion) {
      // The Bunny object exists but is not in the ledger yet. The client
      // retries with the same upload_key; the reclaim path finds it by title.
      deps.logger?.error?.(JSON.stringify({
        event: "course_video_upload_completion_deferred",
        user_id: userID,
      }));
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
  const courseID = normalizeUUID(value.course_id);
  const lessonID = normalizeLessonID(value.lesson_id);
  const uploadKey = normalizeText(value.upload_key, 16, 128);
  const title = normalizeText(value.title, 1, 120);
  const fileName = normalizeText(value.file_name, 1, 255);
  const contentType = normalizeText(value.content_type, 1, 128).toLowerCase();
  const sourceBytes = Number(value.source_bytes);
  if (
    !courseID ||
    !lessonID ||
    !/^[A-Za-z0-9_-]{16,128}$/.test(uploadKey) ||
    !title ||
    !fileName ||
    !/^video\/[a-z0-9.+-]+$/.test(contentType) ||
    !Number.isSafeInteger(sourceBytes) ||
    sourceBytes <= 0 ||
    sourceBytes > MAX_SOURCE_BYTES
  ) {
    throw new Error("invalid_request");
  }
  return {
    courseID,
    lessonID,
    uploadKey,
    title,
    fileName,
    contentType,
    sourceBytes,
  };
}
