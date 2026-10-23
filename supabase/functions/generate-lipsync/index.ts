// deno-lint-ignore-file no-explicit-any
import {
  aiREST,
  aiServiceRPC,
  aiStudioCorsHeaders,
  aiStudioError,
  aiStudioJSON,
  readBoundedBytes,
  requiredAIEnvironment,
  sha256AIBytes,
  signAIStorageObject,
  uploadAIStorageObject,
  verifyAIStudioUser,
} from "../_shared/ai-studio.mjs";
import {
  buildLipsyncFingerprint,
  LipsyncRequestError,
  normalizeLipsyncRequest,
  publicLipsyncJob,
} from "./contract.mjs";
import {
  FalSyncError,
  FalSyncProvider,
  isFalMediaURL,
} from "./fal-sync-provider.mjs";

const supabaseURL = requiredAIEnvironment("SUPABASE_URL");
const anonKey = requiredAIEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredAIEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const falKey = String(Deno.env.get("FAL_KEY") || "").trim();
const provider = falKey ? new FalSyncProvider({ apiKey: falKey }) : null;
const RESULT_BUCKET = "lipsync-generation-results";
const MAXIMUM_RESULT_BYTES = 100 * 1024 * 1024;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type JSONRecord = Record<string, any>;
type NormalizedLipsyncRequest = ReturnType<typeof normalizeLipsyncRequest>;

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
      return await reconcileJob(jobID, user.id);
    }
    if (req.method === "POST") return await startJob(req, user.id);
    return aiStudioError("method_not_allowed", "Метод не поддерживается.", 405);
  } catch (error) {
    console.error(JSON.stringify({
      event: "lipsync_request_failed",
      reason: String(error instanceof Error ? error.message : "unknown").slice(
        0,
        120,
      ),
    }));
    return aiStudioError(
      "lipsync_unavailable",
      "Сервис синхронизации временно недоступен. Кредиты не потеряются.",
      503,
      true,
    );
  }
});

async function startJob(req: Request, userID: string) {
  if (!provider) {
    return aiStudioError(
      "provider_not_configured",
      "Синхронизация губ временно недоступна: провайдер не подключён.",
      503,
      true,
    );
  }
  let normalized;
  try {
    normalized = normalizeLipsyncRequest(await req.json());
  } catch (error) {
    if (error instanceof LipsyncRequestError) {
      return aiStudioError(
        error.code,
        "Проверьте видео, голос и длительность.",
        error.status,
      );
    }
    return aiStudioError(
      "invalid_request",
      "Проверьте параметры синхронизации.",
      400,
    );
  }

  const assets = await loadOwnedInputs(normalized, userID);
  if (!assets) {
    return aiStudioError("asset_not_found", "Видео или аудио не найдено.", 404);
  }
  // Sign inputs before claiming credits. A storage outage therefore cannot
  // debit the user.
  const [videoSigned, audioSigned] = await Promise.all([
    signAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: assets.video.bucket_id,
      path: assets.video.object_path,
      expiresIn: 1_800,
    }),
    signAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: assets.audio.bucket_id,
      path: assets.audio.object_path,
      expiresIn: 1_800,
    }),
  ]);

  const fingerprint = await buildLipsyncFingerprint(normalized);
  const claimToken = crypto.randomUUID().replaceAll("-", "") +
    crypto.randomUUID().replaceAll("-", "");
  const claim = await rpc("claim_lipsync_generation_job", {
    p_user_id: userID,
    p_request_id: normalized.requestID,
    p_request_fingerprint: fingerprint,
    p_video_asset_id: normalized.videoAssetID,
    p_audio_asset_id: normalized.audioAssetID,
    p_duration_seconds: normalized.durationSeconds,
    p_cost_credits: normalized.costCredits,
    p_claim_token: claimToken,
  });
  if (claim?.status === "insufficient_credits") {
    return aiStudioJSON({
      error: {
        code: "insufficient_credits",
        message: "Недостаточно кредитов для синхронизации.",
        retryable: false,
      },
      cost_credits: normalized.costCredits,
      credits_remaining: Number(claim.credits_remaining || 0),
    }, 402);
  }
  if (claim?.status === "idempotency_conflict") {
    return aiStudioError(
      "idempotency_conflict",
      "Этот запрос уже использован с другими файлами.",
      409,
    );
  }
  if (claim?.status === "replay") {
    return await reconcileJob(String(claim.job_id || ""), userID);
  }
  if (
    claim?.status !== "claimed" || !uuidPattern.test(String(claim.job_id || ""))
  ) {
    return aiStudioError(
      "credit_service_unavailable",
      "Не удалось зарезервировать кредиты.",
      503,
      true,
    );
  }

  let submitted;
  try {
    submitted = await provider.submit({
      videoURL: videoSigned.signedURL,
      audioURL: audioSigned.signedURL,
    });
  } catch (error) {
    if (error instanceof FalSyncError && error.submissionAmbiguous === true) {
      return aiStudioJSON(
        {
          job: publicLipsyncJob({
            id: claim.job_id,
            job_status: "queued",
            progress: 0.05,
            cost_credits: normalized.costCredits,
            credits_remaining: claim.credits_remaining,
          }),
          status_pending: true,
        },
        202,
        { "Retry-After": "4" },
      );
    }
    const failure = await failJob(claim.job_id, null, "provider_rejected");
    await recordHealth(false, "provider_rejected");
    return aiStudioJSON({
      error: {
        code: "lipsync_unavailable",
        message: "Синхронизация не запущена. Кредиты возвращены.",
        retryable: true,
      },
      refunded: true,
      credits_remaining: Number(failure?.credits_remaining || 0),
    }, 503);
  }

  let binding = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    binding = await rpc("mark_lipsync_generation_submitted", {
      p_job_id: claim.job_id,
      p_user_id: userID,
      p_claim_token: claimToken,
      p_provider_request_id: submitted.requestID,
    }).catch(() => null);
    if (["submitted", "already_submitted"].includes(binding?.status)) break;
  }
  if (!["submitted", "already_submitted"].includes(binding?.status)) {
    return aiStudioJSON(
      {
        job: publicLipsyncJob({
          id: claim.job_id,
          job_status: "queued",
          progress: 0.05,
          cost_credits: normalized.costCredits,
          credits_remaining: claim.credits_remaining,
        }),
        status_pending: true,
      },
      202,
      { "Retry-After": "4" },
    );
  }
  return aiStudioJSON(
    {
      job: publicLipsyncJob({
        id: claim.job_id,
        job_status: "processing",
        progress: 0.1,
        cost_credits: normalized.costCredits,
        credits_remaining: claim.credits_remaining,
      }),
    },
    202,
    { "Retry-After": "4" },
  );
}

async function reconcileJob(jobID: string, userID: string) {
  const row = await rpc("get_lipsync_generation_job_service", {
    p_job_id: jobID,
    p_user_id: userID,
    p_provider_request_id: null,
  });
  if (row?.status !== "found" || String(row.user_id || "") !== userID) {
    return aiStudioError("job_not_found", "Задача не найдена.", 404);
  }
  if (row.job_status === "completed" && row.result_object_path) {
    const signed = await signAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: RESULT_BUCKET,
      path: row.result_object_path,
    });
    return aiStudioJSON({ job: publicLipsyncJob(row, signed, 1) });
  }
  if (row.job_status === "refunded") {
    return aiStudioJSON({ job: publicLipsyncJob(row, null, 1) });
  }
  if (!provider) {
    return aiStudioError(
      "provider_not_configured",
      "Сервис временно недоступен. Принятое задание остаётся сохранённым.",
      503,
      true,
    );
  }
  const providerRequestID = String(row.provider_request_id || "");
  if (!providerRequestID) {
    return aiStudioJSON({ job: publicLipsyncJob(row, null, 0.05) }, 202, {
      "Retry-After": "4",
    });
  }

  let state;
  try {
    state = await provider.status(providerRequestID);
  } catch (error) {
    if (error instanceof FalSyncError && error.terminal === true) {
      const failure = await failJob(
        jobID,
        providerRequestID,
        "provider_request_missing",
      );
      await recordHealth(false, "provider_request_missing");
      return aiStudioJSON({
        job: publicLipsyncJob(
          {
            ...row,
            job_status: "refunded",
            refunded: true,
            credits_remaining: failure?.credits_remaining,
          },
          null,
          1,
        ),
      });
    }
    return aiStudioJSON({ job: publicLipsyncJob(row) }, 202, {
      "Retry-After": "4",
    });
  }
  if (state.state === "processing") {
    return aiStudioJSON(
      { job: publicLipsyncJob(row, null, state.progress) },
      202,
      {
        "Retry-After": "4",
      },
    );
  }
  if (state.state === "failed") {
    const failure = await failJob(jobID, providerRequestID, "provider_failed");
    await recordHealth(false, "provider_failed");
    return aiStudioJSON({
      job: publicLipsyncJob(
        {
          ...row,
          job_status: "refunded",
          refunded: true,
          credits_remaining: failure?.credits_remaining,
        },
        null,
        1,
      ),
    });
  }

  try {
    const result = await provider.result(providerRequestID);
    const bytes = await downloadFalResult(result.url);
    if (String.fromCharCode(...bytes.slice(4, 8)) !== "ftyp") {
      throw new Error("result_not_mp4");
    }
    const objectPath = `${userID}/${jobID}/output.mp4`;
    await uploadAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: RESULT_BUCKET,
      path: objectPath,
      mimeType: "video/mp4",
      bytes,
      upsert: true,
    });
    const sha256 = await sha256AIBytes(bytes);
    const completion = await rpc("complete_lipsync_generation_job", {
      p_job_id: jobID,
      p_provider_request_id: providerRequestID,
      p_result_object_path: objectPath,
      p_result_sha256: sha256,
    });
    if (!["completed", "already_completed"].includes(completion?.status)) {
      throw new Error("completion_not_persisted");
    }
    await recordHealth(true, null);
    const signed = await signAIStorageObject({
      supabaseURL,
      serviceRoleKey,
      bucket: RESULT_BUCKET,
      path: objectPath,
    });
    return aiStudioJSON({
      job: publicLipsyncJob(
        {
          ...row,
          job_status: "completed",
          result_asset_id: completion.result_asset_id,
          credits_remaining: completion.credits_remaining,
        },
        signed,
        1,
      ),
    });
  } catch {
    const failure = await failJob(
      jobID,
      providerRequestID,
      "invalid_provider_result",
    );
    await recordHealth(false, "invalid_provider_result");
    return aiStudioJSON({
      job: publicLipsyncJob(
        {
          ...row,
          job_status: "refunded",
          refunded: true,
          credits_remaining: failure?.credits_remaining,
        },
        null,
        1,
      ),
    });
  }
}

async function loadOwnedInputs(
  normalized: NormalizedLipsyncRequest,
  userID: string,
) {
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      `generated_assets?select=id,user_id,asset_type,status,bucket_id,object_path&id=in.(${normalized.videoAssetID},${normalized.audioAssetID})&user_id=eq.${
        encodeURIComponent(userID)
      }&status=eq.ready`,
  });
  const list = Array.isArray(rows) ? rows : [];
  const video = list.find((item) =>
    item.id === normalized.videoAssetID && item.asset_type === "video"
  );
  const audio = list.find((item) =>
    item.id === normalized.audioAssetID && item.asset_type === "audio"
  );
  return video && audio ? { video, audio } : null;
}

async function downloadFalResult(value: unknown) {
  let url = new URL(String(value || ""));
  if (!isFalMediaURL(url.toString())) throw new Error("provider_url_invalid");
  for (let redirects = 0; redirects <= 3; redirects += 1) {
    const response = await fetch(url, { redirect: "manual" });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("Location");
      if (!location || redirects === 3) {
        throw new Error("provider_redirect_invalid");
      }
      url = new URL(location, url);
      if (!isFalMediaURL(url.toString())) {
        throw new Error("provider_redirect_invalid");
      }
      continue;
    }
    if (!response.ok) throw new Error("provider_result_unavailable");
    return await readBoundedBytes(response, MAXIMUM_RESULT_BYTES);
  }
  throw new Error("provider_result_unavailable");
}

async function failJob(
  jobID: string,
  providerRequestID: string | null,
  errorCode: string,
) {
  return await rpc("fail_lipsync_generation_job", {
    p_job_id: jobID,
    p_provider_request_id: providerRequestID,
    p_error_code: errorCode,
  }).catch(() => null);
}

async function recordHealth(success: boolean, errorCode: string | null) {
  return await rpc("record_ai_provider_health", {
    p_provider: "fal",
    p_capability: "lipsync",
    p_success: success,
    p_model: "fal-ai/sync-lipsync",
    p_error_code: errorCode,
  }).catch(() => null);
}

async function rpc(name: string, parameters: JSONRecord): Promise<any> {
  return await aiServiceRPC({
    supabaseURL,
    serviceRoleKey,
    name,
    parameters,
  });
}
