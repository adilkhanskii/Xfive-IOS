import { createGenerateVideoHandler } from "./handler.mjs";
import { extractFalVideo } from "./fal-provider.mjs";
import {
  finalizeVideoGenerationResult,
  handleFalTerminalWebhook,
} from "./lifecycle.mjs";
import {
  createBytePlusVideoModerator,
  createFailoverVideoModerator,
  createGoogleVideoModerator,
  createOpenAIVideoModerator,
} from "./moderation.mjs";
import { decodeBoundedProviderVideoBase64, VideoStorage } from "./storage.mjs";
import {
  selectVideoProvider,
  selectVideoProviderByName,
} from "./video-provider.mjs";
import { getFalJwks, verifyFalWebhookSignature } from "./webhook.mjs";
import {
  createGoogleWebhookHandler,
  getGoogleWebhookJwks,
} from "./google-webhook.mjs";
import { createVideoReconcileHandler } from "./reconcile.mjs";

type JsonRecord = Record<string, unknown>;

type ProviderVideoResult = {
  url?: string;
  dataBase64?: string;
  dataBytes?: Uint8Array;
  mimeType?: string;
};

type ProviderStatus = {
  status: string;
  progress: number;
  completed: boolean;
  errorCode?: string;
  result?: ProviderVideoResult;
};

type StartImageParameters = {
  userId: string;
  jobId: string;
  image: {
    mimeType: string;
    dataBase64: string;
  };
};

type VideoJobRow = {
  id: string;
  user_id: string;
  status: "queued" | "rendering" | "completed" | "failed";
  progress: number;
  cost_credits: number;
  provider_name: "byteplus" | "fal" | "google" | "openai";
  provider_kind: "text" | "image";
  provider_request_id?: string;
  input_object_path?: string;
  result_object_path?: string;
  error_code?: string;
  created_at: string;
  updated_at: string;
  refunded_at?: string;
};

const supabaseUrl = requiredEnvironment("SUPABASE_URL");
const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const videoReconcileCronSecret = requiredEnvironment(
  "VIDEO_RECONCILE_CRON_SECRET",
);
const bytePlusKey = Deno.env.get("ARK_API_KEY") || "";
const falKey = Deno.env.get("FAL_KEY") || "";
const googleKey = Deno.env.get("GOOGLE_API_KEY") ||
  Deno.env.get("GEMINI_API_KEY") || "";
const openAIKey = Deno.env.get("OPENAI_API_KEY") || "";
const moderateRequest = createFailoverVideoModerator([
  ...(openAIKey ? [createOpenAIVideoModerator({ apiKey: openAIKey })] : []),
  ...(googleKey ? [createGoogleVideoModerator({ apiKey: googleKey })] : []),
  ...(bytePlusKey
    ? [createBytePlusVideoModerator({ apiKey: bytePlusKey })]
    : []),
]);

const storage = new VideoStorage({
  supabaseUrl,
  serviceKey: serviceRoleKey,
});

const webhookUrl = `${supabaseUrl}/functions/v1/generate-video?webhook=fal`;
const googleWebhookUrl =
  `${supabaseUrl}/functions/v1/generate-video?webhook=google`;
const googleWebhookAudience =
  String(Deno.env.get("GOOGLE_WEBHOOK_AUDIENCE") || "").trim() ||
  googleWebhookUrl;

async function callServiceRpc(
  name: string,
  parameters: JsonRecord,
): Promise<JsonRecord> {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/rpc/${encodeURIComponent(name)}`,
    {
      method: "POST",
      headers: {
        "apikey": serviceRoleKey,
        "Authorization": `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
      body: JSON.stringify(parameters),
    },
  );
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload || typeof payload !== "object") {
    throw new Error(`video_rpc_${name}_failed_${response.status}`);
  }
  return payload as JsonRecord;
}

async function verifyUser(
  authorization: string,
): Promise<{ id: string } | null> {
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: {
      "apikey": anonKey,
      "Authorization": authorization,
      "Cache-Control": "no-store",
    },
  }).catch(() => null);
  if (!response?.ok) return null;
  const payload = await response.json().catch(() => null);
  const id = String(payload?.id || "");
  return /^[0-9a-f-]{36}$/i.test(id) ? { id } : null;
}

async function getJob({
  jobId = null,
  userId = null,
  providerRequestId = null,
}: {
  jobId?: string | null;
  userId?: string | null;
  providerRequestId?: string | null;
}): Promise<VideoJobRow | null> {
  const payload = await callServiceRpc("get_video_generation_job_service", {
    p_job_id: jobId,
    p_user_id: userId,
    p_provider_request_id: providerRequestId,
  });
  if (payload.status !== "found") return null;
  return {
    ...payload,
    status: payload.job_status,
  } as VideoJobRow;
}

async function reconcileJob(
  row: VideoJobRow,
  { strict = false }: { strict?: boolean } = {},
): Promise<VideoJobRow> {
  if (
    !row.provider_request_id ||
    !["queued", "rendering"].includes(row.status)
  ) {
    return row;
  }

  let provider;
  try {
    provider = selectVideoProviderByName(row.provider_name, {
      falKey,
      bytePlusKey,
      googleKey,
      openAIKey,
    });
  } catch (error) {
    if (strict) throw error;
    return row;
  }

  let providerStatus: ProviderStatus;
  try {
    providerStatus = await provider.adapter.status({
      requestId: row.provider_request_id,
      kind: row.provider_kind,
    });
  } catch (error) {
    if (strict) throw error;
    return row;
  }

  if (providerStatus.status === "failed") {
    await callServiceRpc("fail_video_generation_job", {
      p_job_id: row.id,
      p_provider_request_id: row.provider_request_id,
      p_error_code: providerStatus.errorCode || "provider_failed",
    });
    const updated = await getJob({ jobId: row.id, userId: row.user_id }) || row;
    await recordVideoHealth(
      false,
      providerStatus.errorCode || "provider_failed",
    );
    if (["completed", "failed"].includes(updated.status)) {
      await cleanupStartImage(updated);
    }
    return updated;
  }

  if (providerStatus.status !== "completed") {
    if (providerStatus.status === "rendering") {
      await callServiceRpc("mark_video_generation_rendering", {
        p_job_id: row.id,
        p_provider_request_id: row.provider_request_id,
        p_progress: providerStatus.progress,
      }).catch(() => null);
    }
    return await getJob({ jobId: row.id, userId: row.user_id }) || row;
  }

  try {
    await finalizeResultForJob({
      row,
      providerName: row.provider_name,
      loadResult: async () =>
        providerStatus.result ||
        await provider.adapter.result({
          requestId: row.provider_request_id,
          kind: row.provider_kind,
        }),
    });
    await recordVideoHealth(true, null);
  } catch (error) {
    // Transient provider, storage, or ledger failures remain retryable.
    if (strict) throw error;
    return row;
  }

  return await getJob({ jobId: row.id, userId: row.user_id }) || row;
}

async function cleanupStartImage(row: VideoJobRow): Promise<void> {
  if (!row.input_object_path) return;
  await storage.deleteStartImage(row.input_object_path);
}

async function finalizeResultForJob({
  row,
  providerName,
  loadResult,
}: {
  row: VideoJobRow;
  providerName: "byteplus" | "fal" | "google" | "openai";
  loadResult: () => Promise<ProviderVideoResult> | ProviderVideoResult;
}) {
  return await finalizeVideoGenerationResult({
    job: row,
    providerName,
    loadResult,
    decodeBase64: decodeBoundedProviderVideoBase64,
    downloadVideo: (
      url: string,
      { providerName: downloadProviderName }: { providerName: string },
    ) =>
      storage.downloadProviderVideo(url, {
        providerName: downloadProviderName,
        headers: downloadProviderName === "google"
          ? { "x-goog-api-key": googleKey }
          : {},
      }),
    storeResult: (parameters: {
      userId: string;
      jobId: string;
      bytes: Uint8Array;
    }) => storage.storeResult(parameters),
    completeJob: (parameters: JsonRecord) =>
      callServiceRpc("complete_video_generation_job", parameters),
    failJob: (parameters: JsonRecord) =>
      callServiceRpc("fail_video_generation_job", parameters),
    cleanupInput: cleanupStartImage,
  });
}

async function createSignedVideoUrl(path: string) {
  return await storage.signResult(path);
}

async function assetForVideoResult(path: string, userId: string) {
  const asset = await callServiceRpc("generated_asset_by_object_service", {
    p_bucket_id: "video-generation-results",
    p_object_path: path,
  });
  return asset.status === "found" && String(asset.user_id || "") === userId
    ? asset
    : null;
}

async function recordVideoHealth(success: boolean, errorCode: string | null) {
  await callServiceRpc("record_ai_provider_health", {
    p_provider: "byteplus",
    p_capability: "video",
    p_success: success,
    p_model: "seedance-2.0-fast",
    p_error_code: errorCode,
  }).catch(() => null);
}

const userHandler = createGenerateVideoHandler({
  verifyUser,
  moderateRequest,
  selectProvider: (normalized: JsonRecord) =>
    selectVideoProvider({
      model: String(normalized.model || "auto"),
      bytePlusKey,
      falKey,
      googleKey,
      openAIKey,
    }),
  selectFallbackProvider: (providerName: string) => {
    const fallbackName = providerName === "fal"
      ? (googleKey ? "google" : openAIKey ? "openai" : null)
      : providerName === "google" && openAIKey
      ? "openai"
      : null;
    return fallbackName
      ? selectVideoProviderByName(fallbackName, {
        bytePlusKey,
        falKey,
        googleKey,
        openAIKey,
      })
      : null;
  },
  claimJob: (parameters: JsonRecord) =>
    callServiceRpc("claim_video_generation_job", parameters),
  switchProvider: (parameters: JsonRecord) =>
    callServiceRpc("switch_video_generation_provider", parameters),
  getJob: ({
    jobId,
    userId,
  }: {
    jobId: string;
    userId: string;
  }) => getJob({ jobId, userId }),
  markSubmitted: (parameters: JsonRecord) =>
    callServiceRpc("mark_video_generation_submitted", parameters),
  bindGoogleWebhook: (parameters: JsonRecord) =>
    callServiceRpc("bind_google_video_generation_webhook", parameters),
  recordInput: (parameters: JsonRecord) =>
    callServiceRpc("record_video_generation_input", parameters),
  markRendering: (parameters: JsonRecord) =>
    callServiceRpc("mark_video_generation_rendering", parameters),
  failJob: (parameters: JsonRecord) =>
    callServiceRpc("fail_video_generation_job", parameters),
  markSubmissionRejected: (parameters: JsonRecord) =>
    callServiceRpc(
      "mark_video_generation_submission_rejected",
      parameters,
    ),
  storeStartImage: (parameters: StartImageParameters) =>
    storage.storeStartImage(parameters),
  deleteStartImage: (path: string) => storage.deleteStartImage(path),
  signStartImage: (object: JsonRecord) => storage.signStartImage(object),
  signResult: createSignedVideoUrl,
  assetForResult: assetForVideoResult,
  reconcileJob,
  webhookUrl,
  googleWebhookUrl,
});

const googleWebhookHandler = createGoogleWebhookHandler({
  callbackUrl: googleWebhookUrl,
  expectedAudience: googleWebhookAudience,
  getJwks: () => getGoogleWebhookJwks(),
  bindJob: (parameters: JsonRecord) =>
    callServiceRpc("bind_google_video_generation_webhook", parameters),
  getJob: ({ jobId }: { jobId: string }) => getJob({ jobId }),
  reconcileJob,
  finalizeResult: (
    job: VideoJobRow,
    resultHint: ProviderVideoResult,
  ) =>
    finalizeResultForJob({
      row: job,
      providerName: "google",
      loadResult: () => resultHint,
    }),
  failJob: (parameters: JsonRecord) =>
    callServiceRpc("fail_video_generation_job", parameters),
  cleanupInput: cleanupStartImage,
});

const videoReconcileHandler = createVideoReconcileHandler({
  reconcileSecret: videoReconcileCronSecret,
  claimBatch: (parameters: JsonRecord) =>
    callServiceRpc(
      "claim_video_generation_reconciliation_batch",
      parameters,
    ),
  reconcileJob,
  failJob: (parameters: JsonRecord) =>
    callServiceRpc("fail_video_generation_job", parameters),
  cleanupInput: cleanupStartImage,
});

async function handleFalWebhook(req: Request): Promise<Response> {
  if (!falKey) {
    return jsonResponse({ accepted: false }, 503);
  }
  const contentLength = Number(req.headers.get("Content-Length") || 0);
  if (contentLength > 1024 * 1024) {
    return jsonResponse({ accepted: false }, 413);
  }
  const rawBody = await req.arrayBuffer();
  if (rawBody.byteLength > 1024 * 1024) {
    return jsonResponse({ accepted: false }, 413);
  }

  let verified = false;
  try {
    verified = await verifyFalWebhookSignature({
      headers: req.headers,
      rawBody,
      jwks: await getFalJwks(),
    });
  } catch {
    return jsonResponse({ accepted: false }, 503);
  }
  if (!verified) {
    return jsonResponse({ accepted: false }, 401);
  }

  const requestId = req.headers.get("X-Fal-Webhook-Request-Id") || "";
  const payload = JSON.parse(
    new TextDecoder().decode(rawBody),
  ) as JsonRecord;
  if (String(payload.request_id || "") !== requestId) {
    return jsonResponse({ accepted: false }, 400);
  }

  const job = await getJob({ providerRequestId: requestId });
  if (!job || job.provider_name !== "fal") {
    // A signed callback can race the bounded submission-record retry. Asking
    // fal to retry preserves the accepted provider request instead of dropping it.
    return jsonResponse({ accepted: false }, 503);
  }
  await handleFalTerminalWebhook({
    job,
    requestId,
    payload,
    extractResult: extractFalVideo,
    finalizeResult: ({
      job: webhookJob,
      loadResult,
    }: {
      job: VideoJobRow;
      loadResult: () => ProviderVideoResult;
    }) =>
      finalizeResultForJob({
        row: webhookJob,
        providerName: "fal",
        loadResult,
      }),
    failJob: ({
      job: failedJob,
      requestId: failedRequestId,
    }: {
      job: VideoJobRow;
      requestId: string;
    }) =>
      callServiceRpc("fail_video_generation_job", {
        p_job_id: failedJob.id,
        p_provider_request_id: failedRequestId,
        p_error_code: "provider_failed",
      }),
    cleanupInput: cleanupStartImage,
  });
  return jsonResponse({ accepted: true });
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  if (url.searchParams.get("webhook") === "fal") {
    if (req.method !== "POST") {
      return jsonResponse({ error: "method_not_allowed" }, 405);
    }
    return await handleFalWebhook(req).catch(() =>
      jsonResponse({ accepted: false }, 503)
    );
  }
  if (url.searchParams.get("webhook") === "google") {
    return await googleWebhookHandler(req).catch(() =>
      jsonResponse({ accepted: false }, 503)
    );
  }
  if (url.searchParams.get("reconcile") === "google") {
    return await videoReconcileHandler(req).catch(() =>
      jsonResponse({ accepted: false }, 503)
    );
  }
  if (
    req.method === "GET" ||
    req.method === "POST" ||
    req.method === "OPTIONS"
  ) {
    return await userHandler(req);
  }
  return jsonResponse({ error: "method_not_allowed" }, 405);
});

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
}

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
