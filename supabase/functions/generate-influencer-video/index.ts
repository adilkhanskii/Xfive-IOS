// deno-lint-ignore-file no-explicit-any
import {
  aiREST,
  aiStudioCorsHeaders,
  aiStudioError,
  aiStudioJSON,
  downloadAIStorageObject,
  requiredAIEnvironment,
  signAIStorageObject,
  verifyAIStudioUser,
} from "../_shared/ai-studio.mjs";

const supabaseURL = requiredAIEnvironment("SUPABASE_URL");
const anonKey = requiredAIEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredAIEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const falConfigured = Boolean(String(Deno.env.get("FAL_KEY") || "").trim());
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type JSONRecord = Record<string, any>;
type AuthenticatedUser = { id: string; authorization: string };
type SignedAsset = { signedURL: string; expiresAt: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: aiStudioCorsHeaders });
  }
  const user = await verifyAIStudioUser(req, { supabaseURL, anonKey });
  if (!user) return aiStudioError("unauthorized", "Нужен вход в аккаунт.", 401);

  try {
    if (req.method === "GET") {
      const jobID = String(new URL(req.url).searchParams.get("job_id") || "");
      if (!uuidPattern.test(jobID)) {
        return aiStudioError("invalid_job_id", "Задача указана неверно.", 400);
      }
      return await reconcile(jobID, user);
    }
    if (req.method === "POST") return await start(req, user);
    return aiStudioError("method_not_allowed", "Метод не поддерживается.", 405);
  } catch (error) {
    console.error(JSON.stringify({
      event: "influencer_generation_failed",
      reason: String(error instanceof Error ? error.message : "unknown").slice(
        0,
        120,
      ),
    }));
    return aiStudioError(
      "influencer_service_unavailable",
      "Создание ролика временно недоступно. Кредиты не потеряются.",
      503,
      true,
    );
  }
});

async function start(req: Request, user: AuthenticatedUser) {
  if (!falConfigured) {
    return aiStudioError(
      "lipsync_not_configured",
      "Финальный ролик временно недоступен: синхронизация губ не подключена.",
      503,
      true,
    );
  }
  const body = await req.json().catch(() => null);
  const requestID = String(body?.request_id || "").toLowerCase();
  const characterID = String(body?.character_id || "").toLowerCase();
  const scene = String(body?.scene || "").trim();
  const speechText = String(body?.speech_text || "").trim();
  const aspectRatio = String(body?.aspect_ratio || "9:16");
  const durationSeconds = Number(body?.duration_seconds || 5);
  if (
    !uuidPattern.test(requestID) || !uuidPattern.test(characterID) ||
    scene.length < 3 || scene.length > 1_500 ||
    speechText.length < 1 || speechText.length > 5_000 ||
    !["9:16", "16:9"].includes(aspectRatio) ||
    ![5, 10].includes(durationSeconds)
  ) {
    return aiStudioError(
      "invalid_request",
      "Проверьте сцену, формат и длительность.",
      400,
    );
  }

  const existing = await findJobByRequest(requestID, user.id);
  if (existing) return await reconcile(existing.id, user);

  const characterRows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      `ai_characters?select=*&id=eq.${characterID}&user_id=eq.${user.id}&limit=1`,
  });
  const character = characterRows?.[0];
  if (
    !character || !["voice_approved", "ready"].includes(character.status) ||
    !character.approved_image_asset_id || !character.approved_voice_asset_id
  ) {
    return aiStudioError(
      "character_not_ready",
      "Сначала подтвердите изображение и тест голоса персонажа.",
      409,
    );
  }
  const image = await ownedAsset(
    character.approved_image_asset_id,
    user.id,
    "image",
  );
  if (!image) {
    return aiStudioError(
      "character_image_missing",
      "Изображение персонажа не найдено.",
      404,
    );
  }

  // The approved audio is a short audition only. Every final video receives a
  // fresh MiniMax track with the exact text entered for this scene. Reusing the
  // same request UUID is safe because voice/video/lipsync have separate
  // idempotency ledgers.
  const voiceResponse = await invokeUserFunction(
    "generate-voice",
    user.authorization,
    "POST",
    {
      request_id: requestID,
      text: speechText,
      voice: character.voice_id,
      language_code: character.voice_language || "ru",
      speed: Number(character.voice_speed || 1),
      stability: 0.5,
    },
  );
  if (!voiceResponse.ok) return passThrough(voiceResponse);
  const voiceEnvelope = await voiceResponse.json();
  const finalVoiceAssetID = String(voiceEnvelope?.asset_id || "");
  if (!uuidPattern.test(finalVoiceAssetID)) {
    throw new Error("voice_asset_missing");
  }
  const imageBytes = await downloadAIStorageObject({
    supabaseURL,
    serviceRoleKey,
    bucket: image.bucket_id,
    path: image.object_path,
    maximumBytes: 8 * 1024 * 1024,
  });
  const videoPayload = {
    idempotency_key: requestID,
    prompt: [
      scene,
      "Keep the exact approved synthetic character identity, face, age, outfit and anatomy.",
      "No speech and no generated voice. Natural mouth at rest; the separate approved audio will be synchronized later.",
    ].join("\n"),
    aspect_ratio: aspectRatio,
    duration_seconds: durationSeconds,
    model: "seedance-2.0-fast",
    resolution: "720p",
    generate_audio: false,
    start_image: {
      mime_type: image.mime_type,
      data_base64: bytesToBase64(imageBytes),
    },
  };
  const videoResponse = await invokeUserFunction(
    "generate-video",
    user.authorization,
    "POST",
    videoPayload,
  );
  if (!videoResponse.ok) return passThrough(videoResponse);
  const videoEnvelope = await videoResponse.json();
  const videoJobID = String(videoEnvelope?.job?.id || "");
  if (!uuidPattern.test(videoJobID)) throw new Error("video_job_missing");

  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: "ai_influencer_jobs",
    method: "POST",
    prefer: "return=representation",
    body: {
      user_id: user.id,
      request_id: requestID,
      character_id: characterID,
      voice_asset_id: finalVoiceAssetID,
      video_job_id: videoJobID,
      status: videoEnvelope.job.status === "completed"
        ? "video_rendering"
        : "video_rendering",
      scene,
      aspect_ratio: aspectRatio,
      duration_seconds: durationSeconds,
    },
  });
  return aiStudioJSON(
    { job: publicJob(rows?.[0], videoEnvelope.job.progress) },
    202,
    {
      "Retry-After": "5",
    },
  );
}

async function reconcile(jobID: string, user: AuthenticatedUser) {
  const job = await findJob(jobID, user.id);
  if (!job) return aiStudioError("job_not_found", "Задача не найдена.", 404);
  if (job.status === "completed" && job.result_asset_id) {
    const result = await ownedAsset(job.result_asset_id, user.id, "video");
    if (!result) {
      return aiStudioError(
        "result_unavailable",
        "Результат временно недоступен.",
        503,
        true,
      );
    }
    const signed = await signAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: result.bucket_id,
      path: result.object_path,
    });
    return aiStudioJSON({ job: publicJob(job, 1, signed) });
  }
  if (job.status === "failed") return aiStudioJSON({ job: publicJob(job, 1) });

  if (job.status === "video_rendering") {
    const response = await invokeUserFunction(
      `generate-video?job_id=${encodeURIComponent(job.video_job_id)}`,
      user.authorization,
      "GET",
    );
    if (!response.ok) return passThrough(response);
    const envelope = await response.json();
    const video = envelope?.job;
    if (video?.status === "failed") {
      const failed = await updateJob(job.id, user.id, {
        status: "failed",
        error_code: video.error_code || "video_failed",
      });
      return aiStudioJSON({ job: publicJob(failed, 1) });
    }
    if (video?.status !== "completed") {
      return aiStudioJSON(
        { job: publicJob(job, Number(video?.progress || 0) * 0.65) },
        202,
        {
          "Retry-After": "5",
        },
      );
    }
    const baseRows = await aiREST({
      supabaseURL,
      serviceRoleKey,
      path:
        `generated_assets?select=*&user_id=eq.${user.id}&source_kind=eq.video_generation&source_id=eq.${job.video_job_id}&status=eq.ready&limit=1`,
    });
    const baseVideo = baseRows?.[0];
    if (!baseVideo) {
      return aiStudioJSON({ job: publicJob(job, 0.66) }, 202, {
        "Retry-After": "3",
      });
    }
    const lipsyncResponse = await invokeUserFunction(
      "generate-lipsync",
      user.authorization,
      "POST",
      {
        request_id: job.request_id,
        video_asset_id: baseVideo.id,
        audio_asset_id: job.voice_asset_id,
        duration_seconds: job.duration_seconds,
      },
    );
    const lipsyncEnvelope = await lipsyncResponse.json().catch(() => null);
    if (!lipsyncResponse.ok && lipsyncResponse.status !== 202) {
      return aiStudioJSON(
        lipsyncEnvelope || { error: { code: "lipsync_unavailable" } },
        lipsyncResponse.status,
      );
    }
    const lipsyncJobID = String(lipsyncEnvelope?.job?.id || "");
    if (!uuidPattern.test(lipsyncJobID)) throw new Error("lipsync_job_missing");
    const updated = await updateJob(job.id, user.id, {
      status: "lipsync_processing",
      base_video_asset_id: baseVideo.id,
      lipsync_job_id: lipsyncJobID,
    });
    return aiStudioJSON({ job: publicJob(updated, 0.7) }, 202, {
      "Retry-After": "5",
    });
  }

  if (job.status === "lipsync_processing" && job.lipsync_job_id) {
    const response = await invokeUserFunction(
      `generate-lipsync?job_id=${encodeURIComponent(job.lipsync_job_id)}`,
      user.authorization,
      "GET",
    );
    const envelope = await response.json().catch(() => null);
    if (!response.ok && response.status !== 202) {
      return aiStudioJSON(
        envelope || { error: { code: "lipsync_unavailable" } },
        response.status,
      );
    }
    const lipsync = envelope?.job;
    if (lipsync?.status === "refunded") {
      const failed = await updateJob(job.id, user.id, {
        status: "failed",
        error_code: lipsync.error_code || "lipsync_failed",
      });
      return aiStudioJSON({ job: publicJob(failed, 1) });
    }
    if (lipsync?.status !== "completed") {
      return aiStudioJSON(
        { job: publicJob(job, 0.7 + Number(lipsync?.progress || 0) * 0.3) },
        202,
        {
          "Retry-After": "5",
        },
      );
    }
    const completed = await updateJob(job.id, user.id, {
      status: "completed",
      result_asset_id: lipsync.result_asset_id,
      completed_at: new Date().toISOString(),
      error_code: null,
    });
    return aiStudioJSON({
      job: publicJob(completed, 1, {
        signedURL: lipsync.result_url,
        expiresAt: lipsync.result_url_expires_at,
      }),
    });
  }
  return aiStudioJSON({ job: publicJob(job, 0.02) }, 202, {
    "Retry-After": "5",
  });
}

function publicJob(
  job: JSONRecord | null | undefined,
  progress: number,
  signed: SignedAsset | null = null,
) {
  return {
    id: String(job?.id || ""),
    status: String(job?.status || "queued"),
    progress: Math.max(0, Math.min(1, Number(progress || 0))),
    character_id: job?.character_id || null,
    video_job_id: job?.video_job_id || null,
    lipsync_job_id: job?.lipsync_job_id || null,
    result_asset_id: job?.result_asset_id || null,
    result_url: signed?.signedURL || null,
    result_url_expires_at: signed?.expiresAt || null,
    error_code: job?.error_code || null,
    created_at: job?.created_at || null,
    updated_at: job?.updated_at || null,
  };
}

async function invokeUserFunction(
  name: string,
  authorization: string,
  method: string,
  body: unknown = null,
) {
  return await fetch(`${supabaseURL}/functions/v1/${name}`, {
    method,
    headers: {
      "apikey": anonKey,
      "Authorization": authorization,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function passThrough(response: Response) {
  const payload = await response.json().catch(() => ({
    error: {
      code: "upstream_unavailable",
      message: "Сервис временно недоступен.",
    },
  }));
  return aiStudioJSON(payload, response.status);
}

async function ownedAsset(
  id: string,
  userID: string,
  type: string,
): Promise<JSONRecord | null> {
  if (!uuidPattern.test(String(id || ""))) return null;
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      `generated_assets?select=*&id=eq.${id}&user_id=eq.${userID}&asset_type=eq.${type}&status=eq.ready&limit=1`,
  });
  return rows?.[0] || null;
}

async function findJob(id: string, userID: string): Promise<JSONRecord | null> {
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      `ai_influencer_jobs?select=*&id=eq.${id}&user_id=eq.${userID}&limit=1`,
  });
  return rows?.[0] || null;
}

async function findJobByRequest(
  requestID: string,
  userID: string,
): Promise<JSONRecord | null> {
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      `ai_influencer_jobs?select=*&request_id=eq.${requestID}&user_id=eq.${userID}&limit=1`,
  });
  return rows?.[0] || null;
}

async function updateJob(
  id: string,
  userID: string,
  changes: JSONRecord,
): Promise<JSONRecord | null> {
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: `ai_influencer_jobs?id=eq.${id}&user_id=eq.${userID}`,
    method: "PATCH",
    prefer: "return=representation",
    body: { ...changes, updated_at: new Date().toISOString() },
  });
  return rows?.[0] || null;
}

function bytesToBase64(bytes: Uint8Array) {
  let output = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    output += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(output);
}
