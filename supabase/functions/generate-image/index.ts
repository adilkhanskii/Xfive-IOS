// Supabase Edge Function: generate-image
//
// Required env:
//   OPENAI_API_KEY
//   GOOGLE_API_KEY or GEMINI_API_KEY
//   SUPABASE_URL
//   SUPABASE_ANON_KEY
//   SUPABASE_SERVICE_ROLE_KEY

import {
  buildFinalPrompt,
  buildGenerationIdentity,
  buildGenerationResponse,
  buildGenerationResultManifest,
  detectGeneratedImageFormat,
  extractGoogleErrorMessage,
  extractGoogleImageData,
  GenerationRequestError,
  googleResponseFormat,
  hasUsableGenerationProvider,
  normalizeGenerationRequest,
  normalizeProviderKeys,
  safeProviderErrorMessage,
  sanitizeProviderDiagnostic,
  shouldFallbackGoogleToGPT,
  shouldRetryGoogleWithNextKey,
} from "./economy.mjs";

const OPENAI_URL = "https://api.openai.com/v1/images/generations";
const OPENAI_EDIT_URL = "https://api.openai.com/v1/images/edits";
const GOOGLE_INTERACTIONS_URL =
  "https://generativelanguage.googleapis.com/v1beta/interactions";
const GOOGLE_MODEL = "gemini-3.1-flash-image";
const RESULT_BUCKET = "image-generation-results";
const SIGNED_URL_TTL_SECONDS = 15 * 60;

type NormalizedGenerationRequest = ReturnType<
  typeof normalizeGenerationRequest
>;
type ReferenceImage = NormalizedGenerationRequest["images"][number];
type GenerationSize = NormalizedGenerationRequest["size"];
type GenerationResultObject = {
  path: string;
  mimeType: string;
  sha256: string;
};
type GenerationResultManifest = {
  version: number;
  provider: string;
  model: string;
  fallbackFrom?: string;
  objects: GenerationResultObject[];
};
type LedgerResponse = {
  status?: string;
  attempt?: number | string;
  credits_remaining?: number | string;
  result_manifest?: GenerationResultManifest;
  previous_result_manifest?: GenerationResultManifest;
  asset_ids?: unknown[];
};
type ProviderPayload = {
  error?: { message?: string };
  data?: Array<{ b64_json?: string }>;
  [key: string]: unknown;
};

class GenerationCompletionUncertainError extends Error {
  constructor() {
    super("generation_completion_uncertain");
    this.name = "GenerationCompletionUncertainError";
  }
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, idempotency-key, x-idempotency-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return json({ error: "not_authenticated" }, 401);
  }

  const user = await verifyUser(auth);
  if (!user?.id) {
    return json({ error: "not_authenticated" }, 401);
  }

  let body: Record<string, unknown>;
  let normalized: ReturnType<typeof normalizeGenerationRequest>;
  let identity: Awaited<ReturnType<typeof buildGenerationIdentity>>;
  try {
    const parsedBody: unknown = await req.json();
    if (
      !parsedBody || typeof parsedBody !== "object" ||
      Array.isArray(parsedBody)
    ) {
      throw new GenerationRequestError("invalid_request", 400);
    }
    body = parsedBody as Record<string, unknown>;
    normalized = normalizeGenerationRequest(body);
    identity = await buildGenerationIdentity(
      normalized,
      body,
      req.headers.get("Idempotency-Key") ||
        req.headers.get("X-Idempotency-Key") ||
        "",
    );
  } catch (error) {
    if (error instanceof GenerationRequestError) {
      return json({ error: error.code }, error.status);
    }
    return json({ error: "invalid_json" }, 400);
  }

  const providerKeys = getProviderKeys(normalized.provider);
  const fallbackOpenAIKey = normalized.provider === "google"
    ? getProviderKeys("gpt")[0]
    : undefined;
  if (
    !hasUsableGenerationProvider(
      normalized.provider,
      providerKeys.length,
      fallbackOpenAIKey ? 1 : 0,
    )
  ) {
    return json({
      error: "provider_not_configured",
      provider: normalized.provider,
      message: normalized.provider === "google"
        ? "Google Gemini API key is not configured."
        : "Image provider API key is not configured.",
    }, 503);
  }

  const claimToken = createClaimToken();
  const claimParameters = {
    p_user_id: user.id,
    p_request_key: identity.requestKey,
    p_request_fingerprint: identity.fingerprint,
    p_is_legacy: identity.isLegacy,
    p_cost_credits: normalized.costCredits,
    p_claim_token: claimToken,
  };
  let claim = await callServiceRpc(
    "claim_image_generation_request",
    claimParameters,
  );
  if (!claim) {
    return json({ error: "credit_service_unavailable" }, 503);
  }
  if (claim.status === "in_progress") {
    claim = await waitForClaimResolution(claimParameters, claim);
    if (!claim) {
      return json({ error: "credit_service_unavailable" }, 503);
    }
  }
  if (claim.status === "insufficient_credits") {
    return json({
      error: "insufficient_credits",
      creditsRequired: normalized.costCredits,
      creditsRemaining: Number(claim.credits_remaining || 0),
    }, 402);
  }
  if (claim.status === "idempotency_conflict") {
    return json({ error: "idempotency_conflict" }, 409);
  }
  if (claim.status === "invalid_request") {
    return json({ error: "invalid_request" }, 400);
  }
  if (claim.status === "profile_not_found") {
    return json({ error: "profile_not_found" }, 404);
  }
  if (claim.status === "in_progress") {
    return json(
      {
        error: "generation_in_progress",
        retryAfterSeconds: 2,
      },
      425,
      { "Retry-After": "2" },
    );
  }
  if (claim.status === "replay") {
    try {
      if (!claim.result_manifest) {
        throw new Error("generation_result_manifest_missing");
      }
      const replay = await readGenerationResult(claim.result_manifest);
      const assetIds = await decorateGenerationAssets(
        user.id,
        claim.result_manifest.objects,
        normalized,
      );
      return json(buildGenerationResponse({
        normalized,
        imageBase64s: replay.imageBase64s,
        imageUrls: replay.imageUrls,
        provider: claim.result_manifest.provider,
        model: claim.result_manifest.model,
        fallbackFrom: claim.result_manifest.fallbackFrom,
        creditsRemaining: Number(claim.credits_remaining || 0),
        assetIds,
      }));
    } catch (error) {
      console.error(JSON.stringify({
        event: "image_generation_replay_failed",
        request_key: identity.requestKey,
        reason: error instanceof Error ? error.message : "unknown",
      }));
      return json({ error: "generation_replay_unavailable" }, 503);
    }
  }
  if (claim.status !== "claimed") {
    return json({ error: "credit_service_unavailable" }, 503);
  }
  const claimAttempt = Number(claim.attempt || 0);
  if (!Number.isInteger(claimAttempt) || claimAttempt <= 0) {
    return json({ error: "credit_service_unavailable" }, 503);
  }

  const oldResultObjects = [
    ...(claim.previous_result_manifest?.objects || []),
    ...buildPriorAttemptCleanupCandidates(
      user.id,
      identity.requestKey,
      claimAttempt,
    ),
  ];
  if (oldResultObjects.length) {
    await deleteGenerationObjects(oldResultObjects).catch((error) => {
      console.error(JSON.stringify({
        event: "image_generation_old_result_cleanup_failed",
        request_key: identity.requestKey,
        reason: error instanceof Error ? error.message : "unknown",
      }));
    });
  }

  let responseProvider = normalized.provider;
  let responseModel = normalized.model;
  let fallbackFrom: string | undefined;
  let imageBase64s: string[] = [];
  const uploadedObjects: GenerationResultObject[] = [];
  let resultManifest: GenerationResultManifest | null = null;

  try {
    const finalPrompt = buildFinalPrompt(
      normalized.prompt,
      normalized.category,
      normalized.images,
    );
    if (normalized.provider === "google" && providerKeys.length === 0) {
      if (!fallbackOpenAIKey) {
        throw new Error("No image provider is configured");
      }
      console.warn(JSON.stringify({
        event: "google_image_fallback",
        google_status: 503,
        google_reason: "provider_not_configured",
        requested_model: normalized.model,
        fallback_provider: "gpt",
      }));
      imageBase64s = await generateWithGPT(
        fallbackOpenAIKey,
        finalPrompt,
        "gpt-image-2",
        normalized.images,
        normalized.quantity,
        normalized.size,
      );
      responseProvider = "gpt";
      responseModel = "gpt-image-2";
      fallbackFrom = "google";
    } else if (normalized.provider === "google") {
      try {
        imageBase64s = await generateWithGoogle(
          providerKeys,
          finalPrompt,
          normalized.model,
          normalized.images,
          normalized.quantity,
          normalized.size,
        );
      } catch (googleError) {
        const googleStatus = Number(
          googleError instanceof Error && "status" in googleError
            ? (googleError as Error & { status?: number }).status || 503
            : 503,
        );
        if (!fallbackOpenAIKey || !shouldFallbackGoogleToGPT(googleStatus)) {
          throw googleError;
        }

        console.warn(JSON.stringify({
          event: "google_image_fallback",
          google_status: googleStatus,
          google_reason: googleError instanceof Error
            ? sanitizeProviderDiagnostic(googleError.message)
            : "Google image generation failed",
          requested_model: normalized.model,
          fallback_provider: "gpt",
        }));
        imageBase64s = await generateWithGPT(
          fallbackOpenAIKey,
          finalPrompt,
          "gpt-image-2",
          normalized.images,
          normalized.quantity,
          normalized.size,
        );
        responseProvider = "gpt";
        responseModel = "gpt-image-2";
        fallbackFrom = "google";
      }
    } else {
      imageBase64s = await generateWithGPT(
        providerKeys[0],
        finalPrompt,
        normalized.model,
        normalized.images,
        normalized.quantity,
        normalized.size,
        normalized.transparentBackground,
      );
    }

    await storeGenerationResults(
      user.id,
      identity.requestKey,
      claimAttempt,
      imageBase64s,
      uploadedObjects,
    );
    resultManifest = buildGenerationResultManifest({
      provider: responseProvider,
      model: responseModel,
      fallbackFrom,
      objects: uploadedObjects,
    });

    await completeGenerationDurably(
      user.id,
      identity.requestKey,
      identity.fingerprint,
      claimAttempt,
      claimToken,
      resultManifest,
    );
    await callServiceRpc("record_ai_provider_health", {
      p_provider: responseProvider === "gpt" ? "openai" : responseProvider,
      p_capability: "image",
      p_success: true,
      p_model: responseModel,
      p_error_code: null,
    }).catch(() => null);
  } catch (error) {
    if (error instanceof GenerationCompletionUncertainError) {
      console.error(JSON.stringify({
        event: "image_generation_completion_uncertain",
        request_key: identity.requestKey,
      }));
      return json(
        { error: "generation_status_pending", retryAfterSeconds: 2 },
        425,
        { "Retry-After": "2" },
      );
    }
    const upstreamReason = error instanceof Error
      ? sanitizeProviderDiagnostic(error.message)
      : "Image generation failed";
    const providerStatus = Number(
      error instanceof Error && "status" in error
        ? (error as Error & { status?: number }).status || 0
        : 0,
    );
    const providerErrorCode = providerHealthErrorCode(providerStatus);
    console.error(JSON.stringify({
      event: "image_generation_provider_failed",
      provider: normalized.provider,
      model: normalized.model,
      reason: upstreamReason,
    }));
    await callServiceRpc("record_ai_provider_health", {
      p_provider: normalized.provider === "gpt"
        ? "openai"
        : normalized.provider,
      p_capability: "image",
      p_success: false,
      p_model: normalized.model,
      p_error_code: providerErrorCode,
    }).catch(() => null);
    const refund = await callServiceRpc("fail_image_generation_request", {
      p_user_id: user.id,
      p_request_key: identity.requestKey,
      p_request_fingerprint: identity.fingerprint,
      p_attempt: claimAttempt,
      p_claim_token: claimToken,
      p_error_code: providerErrorCode,
    });
    if (refund?.status === "already_completed") {
      return json(
        { error: "generation_status_pending", retryAfterSeconds: 2 },
        425,
        { "Retry-After": "2" },
      );
    }
    if (!refund) {
      const recoveryState = await callServiceRpc(
        "get_image_generation_request",
        {
          p_user_id: user.id,
          p_request_key: identity.requestKey,
          p_request_fingerprint: identity.fingerprint,
          p_attempt: claimAttempt,
          p_claim_token: claimToken,
        },
      );
      console.error(JSON.stringify({
        event: "image_generation_refund_deferred",
        request_key: identity.requestKey,
        durable_status: recoveryState?.status || "unknown",
      }));
    }
    await deleteGenerationObjects(uploadedObjects).catch((cleanupError) => {
      console.error(JSON.stringify({
        event: "image_generation_failed_result_cleanup_failed",
        request_key: identity.requestKey,
        reason: cleanupError instanceof Error
          ? cleanupError.message
          : "unknown",
      }));
    });
    return json({
      error: "provider_error",
      provider: normalized.provider,
      provider_status: providerStatus || null,
      error_code: providerErrorCode,
      message: safeProviderErrorMessage(
        normalized.provider,
        error instanceof Error ? error.message : "Image generation failed",
      ),
    }, 502);
  }

  let imageUrls: string[] = [];
  let assetIds: string[] = [];
  try {
    if (!resultManifest) throw new Error("generation_result_manifest_missing");
    imageUrls = await createSignedGenerationUrls(resultManifest.objects);
    assetIds = await decorateGenerationAssets(
      user.id,
      resultManifest.objects,
      normalized,
    );
  } catch (error) {
    console.error(JSON.stringify({
      event: "image_generation_signing_failed",
      request_key: identity.requestKey,
      reason: error instanceof Error ? error.message : "unknown",
    }));
  }

  return json(buildGenerationResponse({
    normalized,
    imageBase64s,
    imageUrls,
    provider: responseProvider,
    model: responseModel,
    fallbackFrom,
    creditsRemaining: Number(claim.credits_remaining || 0),
    assetIds,
  }));
});

async function decorateGenerationAssets(
  userId: string,
  objects: GenerationResultObject[],
  normalized: NormalizedGenerationRequest,
): Promise<string[]> {
  const result = await callServiceRpc("decorate_generated_assets", {
    p_user_id: userId,
    p_bucket_id: RESULT_BUCKET,
    p_object_paths: objects.map((object) => object.path),
    p_category: normalized.category.id,
    p_title: normalized.prompt,
    p_metadata: {
      size: normalized.size.id,
      transparent_background: normalized.transparentBackground,
    },
  }).catch(() => null);
  return Array.isArray(result?.asset_ids) ? result.asset_ids.map(String) : [];
}

function getProviderKeys(provider: string): string[] {
  if (provider === "google") {
    return normalizeProviderKeys([
      Deno.env.get("GEMINI_API_KEY"),
      Deno.env.get("GOOGLE_API_KEY"),
    ]);
  }
  return normalizeProviderKeys([Deno.env.get("OPENAI_API_KEY")]);
}

async function generateWithGPT(
  apiKey: string,
  finalPrompt: string,
  model: string,
  images: ReferenceImage[],
  quantity: number,
  size: GenerationSize,
  transparentBackground = false,
): Promise<string[]> {
  if (images.length > 0) {
    const results = [];
    for (let index = 0; index < quantity; index += 1) {
      results.push(
        await editWithGPT(
          apiKey,
          finalPrompt,
          model,
          images,
          size,
          transparentBackground,
        ),
      );
    }
    return results;
  }

  const response = await fetch(OPENAI_URL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: model || Deno.env.get("OPENAI_IMAGE_MODEL") || "gpt-image-2",
      prompt: finalPrompt,
      size: size.openaiSize || "1024x1024",
      quality: "low",
      ...(transparentBackground
        ? { background: "transparent", output_format: "png" }
        : {}),
      n: quantity,
    }),
  });

  const payload = await response.json().catch(() => ({})) as ProviderPayload;
  if (!response.ok) {
    throw Object.assign(
      new Error(payload?.error?.message || `OpenAI error ${response.status}`),
      { status: response.status },
    );
  }

  const imageBase64s = (payload.data || []).map((item) => item.b64_json)
    .filter((value): value is string => Boolean(value));
  if (imageBase64s.length === 0) {
    throw new Error("OpenAI returned no image");
  }
  return imageBase64s;
}

async function editWithGPT(
  apiKey: string,
  finalPrompt: string,
  model: string,
  images: ReferenceImage[],
  size: GenerationSize,
  transparentBackground = false,
): Promise<string> {
  const form = new FormData();
  form.append(
    "model",
    model || Deno.env.get("OPENAI_IMAGE_MODEL") || "gpt-image-2",
  );
  form.append("prompt", finalPrompt);
  form.append("size", size.openaiSize || "1024x1024");
  form.append("quality", "low");
  if (transparentBackground) {
    form.append("background", "transparent");
    form.append("output_format", "png");
  }

  images.slice(0, 6).forEach((image, index) => {
    const bytes = decodeBase64(image.data);
    const mimeType = image.mimeType || "image/jpeg";
    const ext = mimeType.includes("png")
      ? "png"
      : mimeType.includes("webp")
      ? "webp"
      : "jpg";
    form.append(
      "image[]",
      new Blob([bytes.buffer as ArrayBuffer], { type: mimeType }),
      `reference-${index + 1}.${ext}`,
    );
  });

  const response = await fetch(OPENAI_EDIT_URL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
    },
    body: form,
  });

  const payload = await response.json().catch(() => ({})) as ProviderPayload;
  if (!response.ok) {
    throw Object.assign(
      new Error(
        payload?.error?.message || `OpenAI edit error ${response.status}`,
      ),
      { status: response.status },
    );
  }

  const imageBase64 = payload?.data?.[0]?.b64_json;
  if (!imageBase64) {
    throw new Error("OpenAI returned no edited image");
  }
  return imageBase64;
}

function providerHealthErrorCode(status: number): string {
  if (status === 400 || status === 404 || status === 422) {
    return "provider_model_unavailable";
  }
  if (status === 401 || status === 403) return "provider_auth_failed";
  if (status === 402 || status === 429) return "provider_balance_or_quota";
  if (status >= 500) return "provider_temporarily_unavailable";
  return "provider_or_storage_error";
}

async function generateWithGoogle(
  apiKeys: string[],
  finalPrompt: string,
  requestedModel: string,
  images: ReferenceImage[],
  quantity: number,
  size: GenerationSize,
): Promise<string[]> {
  const results = [];
  for (let index = 0; index < quantity; index += 1) {
    results.push(
      await generateOneWithGoogle(
        apiKeys,
        finalPrompt,
        requestedModel,
        images,
        size,
      ),
    );
  }
  return results;
}

async function generateOneWithGoogle(
  apiKeys: string[],
  finalPrompt: string,
  requestedModel: string,
  images: ReferenceImage[],
  size: GenerationSize,
): Promise<string> {
  const model = requestedModel || Deno.env.get("GOOGLE_IMAGE_MODEL") ||
    GOOGLE_MODEL;
  const input = [
    { type: "text", text: finalPrompt },
    ...images.slice(0, 6).map((image) => ({
      type: "image",
      mime_type: image.mimeType || "image/jpeg",
      data: image.data,
    })),
  ];
  const bodyWithSize = {
    model,
    input,
    store: false,
    response_format: googleResponseFormat(size, model),
  };
  const bodyWithoutSize = {
    model,
    input,
    store: false,
    response_format: { type: "image", mime_type: "image/jpeg" },
  };
  let response: Response | undefined;
  let payload: ProviderPayload = {};
  for (let keyIndex = 0; keyIndex < apiKeys.length; keyIndex += 1) {
    const apiKey = apiKeys[keyIndex];
    response = await postGoogleImageRequest(apiKey, bodyWithSize);
    payload = await response.json().catch(() => ({})) as ProviderPayload;
    if (!response.ok && shouldRetryGoogleWithoutImageConfig(payload)) {
      response = await postGoogleImageRequest(apiKey, bodyWithoutSize);
      payload = await response.json().catch(() => ({})) as ProviderPayload;
    }
    if (response.ok) break;
    if (
      keyIndex < apiKeys.length - 1 &&
      shouldRetryGoogleWithNextKey(payload, response.status)
    ) {
      continue;
    }
    const providerError = Object.assign(
      new Error(extractGoogleErrorMessage(payload, response.status)),
      { status: response.status },
    );
    throw providerError;
  }

  if (!response?.ok) {
    const providerError = Object.assign(
      new Error(extractGoogleErrorMessage(payload, response?.status || 502)),
      { status: response?.status || 502 },
    );
    throw providerError;
  }

  const imageBase64 = extractGoogleImageData(payload);
  if (!imageBase64) {
    const providerError = Object.assign(new Error("Google returned no image"), {
      status: 422,
    });
    throw providerError;
  }
  return imageBase64;
}

function postGoogleImageRequest(
  apiKey: string,
  body: Record<string, unknown>,
): Promise<Response> {
  return fetch(GOOGLE_INTERACTIONS_URL, {
    method: "POST",
    headers: {
      "x-goog-api-key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function shouldRetryGoogleWithoutImageConfig(
  payload: ProviderPayload,
): boolean {
  const message = String(payload?.error?.message || "").toLowerCase();
  return message.includes("imageconfig") ||
    message.includes("image_config") ||
    message.includes("imagesize") ||
    message.includes("image_size") ||
    message.includes("unknown field") ||
    message.includes("unsupported");
}

function decodeBase64(data: string): Uint8Array {
  const binary = atob(data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function verifyUser(
  authorization: string,
): Promise<{ id: string } | null> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return null;

  const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: {
      "Authorization": authorization,
      "apikey": anonKey,
    },
  });
  if (!res.ok) return null;
  return await res.json().catch(() => null);
}

async function callServiceRpc(
  name: string,
  parameters: Record<string, unknown>,
): Promise<LedgerResponse | null> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return null;

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "apikey": serviceKey,
      "Authorization": `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(parameters),
  });
  if (!response.ok) return null;
  const payload: unknown = await response.json().catch(() => null);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  return payload as LedgerResponse;
}

function createClaimToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function waitForClaimResolution(
  parameters: Record<string, unknown>,
  initial: LedgerResponse,
  timeoutMs = 18_000,
): Promise<LedgerResponse | null> {
  const deadline = Date.now() + timeoutMs;
  let latest: LedgerResponse | null = initial;
  while (latest?.status === "in_progress" && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 750));
    const polled = await callServiceRpc(
      "claim_image_generation_request",
      parameters,
    );
    if (polled) latest = polled;
  }
  return latest;
}

async function completeGenerationDurably(
  userId: string,
  requestKey: string,
  requestFingerprint: string,
  claimAttempt: number,
  claimToken: string,
  resultManifest: GenerationResultManifest,
): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const completion = await callServiceRpc(
      "complete_image_generation_request",
      {
        p_user_id: userId,
        p_request_key: requestKey,
        p_request_fingerprint: requestFingerprint,
        p_attempt: claimAttempt,
        p_claim_token: claimToken,
        p_result_manifest: resultManifest,
      },
    );
    if (
      completion &&
      ["completed", "already_completed", "succeeded"].includes(
        completion.status || "",
      )
    ) {
      return;
    }

    const recovered = await callServiceRpc("get_image_generation_request", {
      p_user_id: userId,
      p_request_key: requestKey,
      p_request_fingerprint: requestFingerprint,
      p_attempt: claimAttempt,
      p_claim_token: claimToken,
    });
    if (recovered?.status === "succeeded") return;
    if (
      completion ||
      ["refunded", "stale_attempt", "idempotency_conflict"].includes(
        recovered?.status || "",
      )
    ) {
      throw new Error(
        `generation_completion_rejected_${
          completion?.status || recovered?.status || "unknown"
        }`,
      );
    }
    if (attempt < 2) {
      await new Promise((resolve) => setTimeout(resolve, 150 * (attempt + 1)));
    }
  }
  throw new GenerationCompletionUncertainError();
}

async function storeGenerationResults(
  userId: string,
  requestKey: string,
  attempt: number,
  imageBase64s: string[],
  uploadedObjects: GenerationResultObject[],
): Promise<void> {
  const [, requestDigest = "invalid"] = requestKey.split(":", 2);
  const requestKind = requestKey.startsWith("legacy:") ? "legacy" : "explicit";
  for (let index = 0; index < imageBase64s.length; index += 1) {
    const imageBase64 = imageBase64s[index];
    const format = detectGeneratedImageFormat(imageBase64);
    const bytes = decodeBase64(imageBase64);
    if (bytes.byteLength === 0 || bytes.byteLength > 33554432) {
      throw new Error("generated_image_size_invalid");
    }
    const path = [
      userId,
      requestKind,
      requestDigest,
      String(attempt),
      `${index}.${format.extension}`,
    ].join("/");
    const object = {
      path,
      mimeType: format.mimeType,
      sha256: await sha256Bytes(bytes),
    };
    await uploadGenerationObject(object, bytes);
    uploadedObjects.push(object);
  }
}

async function uploadGenerationObject(
  object: { path: string; mimeType: string },
  bytes: Uint8Array,
): Promise<void> {
  const config = getStorageConfig();
  const response = await fetch(
    `${config.url}/storage/v1/object/${RESULT_BUCKET}/${
      encodeStoragePath(object.path)
    }`,
    {
      method: "POST",
      headers: {
        "apikey": config.serviceKey,
        "Authorization": `Bearer ${config.serviceKey}`,
        "Content-Type": object.mimeType,
        "cache-control": "3600",
        "x-upsert": "false",
      },
      body: Uint8Array.from(bytes).buffer,
    },
  );
  if (!response.ok) {
    throw new Error(`generation_result_upload_failed_${response.status}`);
  }
}

async function deleteGenerationObjects(
  objects: Array<{ path: string }>,
): Promise<void> {
  const prefixes = [
    ...new Set(
      (Array.isArray(objects) ? objects : [])
        .map((object) => String(object?.path || ""))
        .filter(Boolean),
    ),
  ];
  if (prefixes.length === 0) return;
  const config = getStorageConfig();
  const response = await fetch(
    `${config.url}/storage/v1/object/${RESULT_BUCKET}`,
    {
      method: "DELETE",
      headers: {
        "apikey": config.serviceKey,
        "Authorization": `Bearer ${config.serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prefixes }),
    },
  );
  if (!response.ok) {
    throw new Error(`generation_result_cleanup_failed_${response.status}`);
  }
}

function buildPriorAttemptCleanupCandidates(
  userId: string,
  requestKey: string,
  currentAttempt: number,
): Array<{ path: string }> {
  if (!Number.isInteger(currentAttempt) || currentAttempt <= 1) return [];
  const [, requestDigest = "invalid"] = requestKey.split(":", 2);
  const requestKind = requestKey.startsWith("legacy:") ? "legacy" : "explicit";
  const candidates: Array<{ path: string }> = [];
  const firstAttempt = Math.max(1, currentAttempt - 3);
  for (let attempt = firstAttempt; attempt < currentAttempt; attempt += 1) {
    for (let index = 0; index < 4; index += 1) {
      for (const extension of ["png", "jpg", "webp"]) {
        candidates.push({
          path: [
            userId,
            requestKind,
            requestDigest,
            String(attempt),
            `${index}.${extension}`,
          ].join("/"),
        });
      }
    }
  }
  return candidates;
}

async function createSignedGenerationUrls(
  objects: GenerationResultObject[],
): Promise<string[]> {
  return await Promise.all(objects.map(async (object) => {
    const config = getStorageConfig();
    const response = await fetch(
      `${config.url}/storage/v1/object/sign/${RESULT_BUCKET}/${
        encodeStoragePath(object.path)
      }`,
      {
        method: "POST",
        headers: {
          "apikey": config.serviceKey,
          "Authorization": `Bearer ${config.serviceKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expiresIn: SIGNED_URL_TTL_SECONDS }),
      },
    );
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`generation_result_sign_failed_${response.status}`);
    }
    const signedPath = String(payload?.signedURL || payload?.signedUrl || "");
    if (!signedPath) throw new Error("generation_result_sign_missing_url");
    if (/^https?:\/\//i.test(signedPath)) return signedPath;
    const normalizedPath = signedPath.startsWith("/storage/v1/")
      ? signedPath
      : `/storage/v1${signedPath.startsWith("/") ? "" : "/"}${signedPath}`;
    return new URL(normalizedPath, config.url).toString();
  }));
}

async function readGenerationResult(
  manifest: GenerationResultManifest,
): Promise<{
  imageBase64s: string[];
  imageUrls: string[];
}> {
  const objects = Array.isArray(manifest?.objects) ? manifest.objects : [];
  if (objects.length === 0 || objects.length > 4) {
    throw new Error("generation_result_manifest_invalid");
  }
  const imageUrls = await createSignedGenerationUrls(objects);
  const imageBase64s = await Promise.all(
    imageUrls.map(async (imageUrl, index) => {
      const response = await fetch(imageUrl, { cache: "no-store" });
      if (!response.ok) {
        throw new Error(`generation_result_download_failed_${response.status}`);
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      const object = objects[index];
      if (await sha256Bytes(bytes) !== object.sha256) {
        throw new Error("generation_result_hash_mismatch");
      }
      const imageBase64 = bytesToBase64(bytes);
      if (
        detectGeneratedImageFormat(imageBase64).mimeType !== object.mimeType
      ) {
        throw new Error("generation_result_mime_mismatch");
      }
      return imageBase64;
    }),
  );
  return { imageBase64s, imageUrls };
}

function getStorageConfig(): { url: string; serviceKey: string } {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    throw new Error("generation_storage_not_configured");
  }
  return { url: supabaseUrl, serviceKey };
}

function encodeStoragePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

async function sha256Bytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(bytes).buffer,
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function bytesToBase64(bytes: Uint8Array): string {
  const chunkSize = 24576;
  let result = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, offset + chunkSize);
    let binary = "";
    for (const byte of chunk) binary += String.fromCharCode(byte);
    result += btoa(binary);
  }
  return result;
}

function json(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}
