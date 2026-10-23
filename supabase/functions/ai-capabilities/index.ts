import {
  aiREST,
  aiStudioCorsHeaders,
  aiStudioError,
  aiStudioJSON,
  requiredAIEnvironment,
  verifyAIStudioUser,
} from "../_shared/ai-studio.mjs";

const supabaseURL = requiredAIEnvironment("SUPABASE_URL");
const anonKey = requiredAIEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredAIEnvironment("SUPABASE_SERVICE_ROLE_KEY");

const configured = Object.freeze({
  openai: Boolean(String(Deno.env.get("OPENAI_API_KEY") || "").trim()),
  google: Boolean(String(Deno.env.get("GEMINI_API_KEY") || "").trim()),
  minimax: Boolean(String(Deno.env.get("MINIMAX_API_KEY") || "").trim()),
  byteplus: Boolean(String(Deno.env.get("ARK_API_KEY") || "").trim()),
  fal: Boolean(String(Deno.env.get("FAL_KEY") || "").trim()),
});
type Provider = keyof typeof configured;
type ProviderHealth = {
  configured: boolean;
  available: boolean;
  model: string | null;
  last_success_at: string | null;
  last_failure_at: string | null;
  last_error_code: string | null;
  updated_at: string | null;
};
type ProviderHealthRow = Omit<ProviderHealth, "configured"> & {
  provider: Provider;
  capability: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: aiStudioCorsHeaders });
  }
  if (req.method !== "GET") {
    return aiStudioError("method_not_allowed", "Метод не поддерживается.", 405);
  }
  const user = await verifyAIStudioUser(req, { supabaseURL, anonKey });
  if (!user) return aiStudioError("unauthorized", "Нужен вход в аккаунт.", 401);

  const healthRows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path:
      "ai_provider_health?select=provider,capability,available,model,last_success_at,last_failure_at,last_error_code,updated_at",
  }).catch(() => []);
  const rows =
    (Array.isArray(healthRows) ? healthRows : []) as ProviderHealthRow[];
  // A provider failure (quota, balance, outage) must not switch a tool off
  // forever: nothing re-probes a provider except a real generation, and the
  // clients hide the tool while it is marked unavailable. After the retry
  // window the failure is treated as stale so the next attempt is allowed;
  // a genuine failure simply records itself again.
  const PROVIDER_RETRY_AFTER_MS = 10 * 60 * 1000;
  const failureIsStale = (row: ProviderHealthRow) => {
    const stamp = Date.parse(row.updated_at ?? row.last_failure_at ?? "");
    return Number.isFinite(stamp) &&
      Date.now() - stamp >= PROVIDER_RETRY_AFTER_MS;
  };
  const health: Record<string, ProviderHealth> = Object.fromEntries(
    rows.map((row) => [
      `${row.provider}:${row.capability}`,
      {
        configured: Boolean(configured[row.provider]),
        available: Boolean(configured[row.provider]) &&
          (row.available !== false || failureIsStale(row)),
        model: row.model,
        last_success_at: row.last_success_at,
        last_failure_at: row.last_failure_at,
        last_error_code: row.last_error_code,
        updated_at: row.updated_at,
      },
    ]),
  );

  const providerAvailable = (
    provider: Provider,
    capability: string,
  ) => {
    if (!configured[provider]) return false;
    const current = health[`${provider}:${capability}`];
    return current?.available !== false;
  };
  const openAIImageAvailable = providerAvailable("openai", "image");
  const googleImageAvailable = providerAvailable("google", "image");
  const imageAvailable = openAIImageAvailable || googleImageAvailable;
  const voiceAvailable = providerAvailable("minimax", "voice");
  const videoAvailable = providerAvailable("byteplus", "video");
  const lipsyncAvailable = providerAvailable("fal", "lipsync");
  const imageUnavailableReason = imageAvailable
    ? null
    : health["openai:image"]?.last_error_code ||
      health["google:image"]?.last_error_code || "provider_not_configured";

  return aiStudioJSON({
    credit_currency: "KZT",
    credit_rate: { credits: 1, tenge: 1 },
    customer_price_multiplier: 2,
    prices: {
      image_frame: 60,
      voice_per_started_1000_characters: 60,
      video: { "5": 650, "10": 1200 },
      lipsync_per_second: 50,
    },
    providers: health,
    models: {
      image: [
        ...(openAIImageAvailable
          ? [{ id: "gpt-image-2", provider: "openai" }]
          : []),
        ...(googleImageAvailable
          ? [
            { id: "gemini-3.1-flash-image", provider: "google" },
            { id: "gemini-3.1-flash-lite-image", provider: "google" },
          ]
          : []),
      ],
      voice: voiceAvailable
        ? [{ id: "speech-2.8-turbo", provider: "minimax" }]
        : [],
      video: videoAvailable
        ? [{ id: "seedance-2.0-fast", provider: "byteplus" }]
        : [],
      lipsync: lipsyncAvailable
        ? [{ id: "fal-ai/sync-lipsync", provider: "fal" }]
        : [],
    },
    tools: {
      image_generation: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      image_editor: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      product_cards: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      youtube_cover: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      transparent_logo: {
        available: openAIImageAvailable,
        unavailable_reason: openAIImageAvailable
          ? null
          : health["openai:image"]?.last_error_code ||
            "provider_not_configured",
      },
      moodboard: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      content_pack: {
        available: imageAvailable,
        unavailable_reason: imageUnavailableReason,
      },
      voice: {
        available: voiceAvailable,
        unavailable_reason: voiceAvailable
          ? null
          : health["minimax:voice"]?.last_error_code ||
            "provider_not_configured",
      },
      video: {
        available: videoAvailable,
        unavailable_reason: videoAvailable
          ? null
          : health["byteplus:video"]?.last_error_code ||
            "provider_not_configured",
      },
      cinema: {
        available: videoAvailable,
        unavailable_reason: videoAvailable
          ? null
          : health["byteplus:video"]?.last_error_code ||
            "provider_not_configured",
      },
      vfx: {
        available: videoAvailable,
        unavailable_reason: videoAvailable
          ? null
          : health["byteplus:video"]?.last_error_code ||
            "provider_not_configured",
      },
      lipsync: {
        available: lipsyncAvailable,
        unavailable_reason: lipsyncAvailable ? null : "provider_not_configured",
      },
      ai_influencer: {
        available: imageAvailable && voiceAvailable && videoAvailable &&
          lipsyncAvailable,
        unavailable_reason: !imageAvailable
          ? imageUnavailableReason
          : !voiceAvailable
          ? health["minimax:voice"]?.last_error_code || "voice_unavailable"
          : !videoAvailable
          ? health["byteplus:video"]?.last_error_code || "video_unavailable"
          : !lipsyncAvailable
          ? health["fal:lipsync"]?.last_error_code || "lipsync_not_configured"
          : null,
      },
      presets: { available: true },
      live_products: { available: true },
    },
  });
});
