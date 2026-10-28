import {
  cloneAudio,
  cloneConsent,
  DESIGN_PREVIEW_TEXT,
  generatedVoiceID,
  providerVoiceID,
  requestID,
  safeStudioError,
  VOICE_STUDIO_PRICES,
  VOICE_STUDIO_VOICE_LIMIT,
  voiceDescription,
  voiceName,
  VoiceStudioRequestError,
} from "./contract.mjs";
import { PREMIUM_VOICES } from "../generate-voice/contract.mjs";

/**
 * «Мои голоса» премиума. Действия: catalog, clone (multipart), design,
 * save_design, delete. Деньги: сначала быстрая проверка (quote), потом
 * провайдер, потом атомарное списание (charge). Не списалось — созданный у
 * провайдера голос удаляем, пользователю — понятная ошибка, кредиты целы.
 */
export function createVoiceStudioHandler(deps) {
  const handle = async (req) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }
    if (req.method !== "POST") {
      return json(
        safeStudioError("method_not_allowed", "Method not allowed."),
        405,
      );
    }
    const user = await deps.verifyUser(req);
    if (!user?.id) {
      return json(
        safeStudioError("unauthorized", "Authentication is required."),
        401,
      );
    }

    let input;
    try {
      input = await readInput(req);
    } catch {
      return json(
        safeStudioError("invalid_request", "Request is invalid."),
        400,
      );
    }

    try {
      switch (input.action) {
        case "catalog":
          return await catalog(user, deps);
        case "clone":
          return await clone(user, input, deps);
        case "design":
          return await design(user, input, deps);
        case "save_design":
          return await saveDesign(user, input, deps);
        case "delete":
          return await deleteVoice(user, input, deps);
        default:
          return json(
            safeStudioError("invalid_action", "Unknown action."),
            400,
          );
      }
    } catch (error) {
      if (error instanceof VoiceStudioRequestError) {
        return json(
          safeStudioError(error.code, "Request is invalid."),
          error.status,
        );
      }
      if (error?.keyRejected) return premiumUnavailable();
      if (error?.name === "ElevenLabsVoicesError") {
        return json(
          safeStudioError(
            "provider_rejected",
            "Voice service did not accept the request. Nothing was charged.",
          ),
          502,
        );
      }
      throw error;
    }
  };

  return async function handleVoiceStudioSafely(req) {
    try {
      return await handle(req);
    } catch {
      return json(
        safeStudioError(
          "service_unavailable",
          "Voice service is temporarily unavailable.",
        ),
        503,
      );
    }
  };
}

async function catalog(user, deps) {
  const voices = await deps.listVoices(user.id);
  const client = deps.voicesClient();
  let previews = {};
  let premiumAvailable = client !== null;
  if (client) {
    const result = await client.premadePreviews(PREMIUM_VOICES.map((v) => v.id))
      .catch(() => ({ previews: {}, keyRejected: false }));
    previews = result.previews || {};
    if (result.keyRejected) premiumAvailable = false;
  }
  return json({
    premium_available: premiumAvailable,
    clone_available: premiumAvailable && cloneEnabled(deps),
    prices: VOICE_STUDIO_PRICES,
    voice_limit: VOICE_STUDIO_VOICE_LIMIT,
    premade: PREMIUM_VOICES.map((voice) => ({
      id: voice.id,
      name: voice.name,
      gender: voice.gender,
      // Без ключа образцов нет: клиент рисует карточку без ▶.
      preview_url: premiumAvailable ? previews[voice.id] || null : null,
    })),
    my_voices: Array.isArray(voices?.voices) ? voices.voices : [],
  });
}

async function clone(user, input, deps) {
  const client = deps.voicesClient();
  if (!client) return premiumUnavailable();
  // До кредитов и до провайдера: без тарифа Starter ничего не списываем.
  if (!cloneEnabled(deps)) return cloneRequiresPlan();
  const key = requestID(input.request_id);
  const name = voiceName(input.name);
  cloneConsent(input.consent);
  const { file, type } = cloneAudio(input.file);

  const blocked = await quoteBlock(user, VOICE_STUDIO_PRICES.clone, true, deps);
  if (blocked) return blocked;

  let created;
  try {
    created = await client.clone({ name, audio: file, type });
  } catch (error) {
    // Тариф ElevenLabs не даёт клон (401/403) — это не «премиум скоро».
    if (error?.keyRejected) return cloneRequiresPlan();
    throw error;
  }
  return await chargeOrRollback({
    user,
    key,
    kind: "clone",
    cost: VOICE_STUDIO_PRICES.clone,
    voiceID: created.voiceID,
    name,
    client,
    deps,
    body: (charge) => ({
      voice: { id: created.voiceID, name, source: "clone" },
      credits_remaining: Number(charge.credits_remaining || 0),
      cost_credits: VOICE_STUDIO_PRICES.clone,
    }),
  });
}

async function design(user, input, deps) {
  const client = deps.voicesClient();
  if (!client) return premiumUnavailable();
  const key = requestID(input.request_id);
  const description = voiceDescription(input.description);

  const blocked = await quoteBlock(
    user,
    VOICE_STUDIO_PRICES.design,
    false,
    deps,
  );
  if (blocked) return blocked;

  const result = await client.design({
    description,
    text: DESIGN_PREVIEW_TEXT,
  });
  const charge = await deps.charge({
    p_user_id: user.id,
    p_request_key: key,
    p_kind: "design",
    p_cost_credits: VOICE_STUDIO_PRICES.design,
    p_provider_voice_id: null,
    p_voice_name: null,
  });
  if (charge?.status !== "charged") {
    return chargeFailure(charge, VOICE_STUDIO_PRICES.design);
  }
  return json({
    previews: result.previews.map((preview) => ({
      generated_voice_id: preview.generatedVoiceID,
      audio_base64: preview.audioBase64,
      media_type: preview.mediaType,
      duration_secs: preview.durationSecs,
    })),
    text: result.text,
    credits_remaining: Number(charge.credits_remaining || 0),
    cost_credits: VOICE_STUDIO_PRICES.design,
  });
}

async function saveDesign(user, input, deps) {
  const client = deps.voicesClient();
  if (!client) return premiumUnavailable();
  const key = requestID(input.request_id);
  const name = voiceName(input.name);
  const description = voiceDescription(input.description);
  const generated = generatedVoiceID(input.generated_voice_id);

  const blocked = await quoteBlock(user, VOICE_STUDIO_PRICES.save, true, deps);
  if (blocked) return blocked;

  const created = await client.createFromPreview({
    name,
    description,
    generatedVoiceID: generated,
  });
  return await chargeOrRollback({
    user,
    key,
    kind: "save",
    cost: VOICE_STUDIO_PRICES.save,
    voiceID: created.voiceID,
    name,
    client,
    deps,
    body: (charge) => ({
      voice: { id: created.voiceID, name, source: "design" },
      credits_remaining: Number(charge.credits_remaining || 0),
      cost_credits: 0,
    }),
  });
}

async function deleteVoice(user, input, deps) {
  const client = deps.voicesClient();
  if (!client) return premiumUnavailable();
  const voiceID = providerVoiceID(input.voice_id);
  const owned = await deps.ownsVoice({ userID: user.id, voiceID });
  if (!owned) {
    return json(safeStudioError("not_found", "Voice not found."), 404);
  }
  // Сначала у провайдера: если он недоступен, строка остаётся и удаление
  // можно повторить; голос не «потеряется» у ElevenLabs.
  await client.deleteVoice(voiceID);
  await deps.deleteVoiceRow({
    p_user_id: user.id,
    p_provider_voice_id: voiceID,
  });
  return json({ deleted: true, voice_id: voiceID });
}

async function quoteBlock(user, cost, needsSlot, deps) {
  const quote = await deps.quote(user.id);
  if (quote?.status === "account_deleting") {
    return json(
      safeStudioError("account_deleting", "Account deletion is in progress."),
      409,
    );
  }
  if (quote?.status !== "ok") {
    return json(
      safeStudioError("credit_service_unavailable", "Try again later."),
      503,
    );
  }
  if (needsSlot && Number(quote.voice_count) >= VOICE_STUDIO_VOICE_LIMIT) {
    return voiceLimit();
  }
  if (Number(quote.credits) < cost) {
    return insufficient(Number(quote.credits), cost);
  }
  return null;
}

async function chargeOrRollback(
  { user, key, kind, cost, voiceID, name, client, deps, body },
) {
  let charge = null;
  try {
    charge = await deps.charge({
      p_user_id: user.id,
      p_request_key: key,
      p_kind: kind,
      p_cost_credits: cost,
      p_provider_voice_id: voiceID,
      p_voice_name: name,
    });
  } catch {
    charge = null;
  }
  if (charge?.status === "charged") return json(body(charge));
  // Не списали (нет кредитов / лимит / повтор / сбой БД) — голос у
  // провайдера не оставляем.
  await client.deleteVoice(voiceID).catch(() => null);
  return chargeFailure(charge, cost);
}

function chargeFailure(charge, cost) {
  switch (charge?.status) {
    case "insufficient_credits":
      return insufficient(Number(charge.credits_remaining || 0), cost);
    case "voice_limit":
      return voiceLimit();
    case "duplicate":
      return json(
        safeStudioError(
          "duplicate_request",
          "This request was already completed.",
        ),
        409,
      );
    case "account_deleting":
      return json(
        safeStudioError("account_deleting", "Account deletion is in progress."),
        409,
      );
    default:
      return json(
        safeStudioError(
          "credit_service_unavailable",
          "Nothing was charged. Try again.",
        ),
        503,
      );
  }
}

function insufficient(credits, cost) {
  return json(
    safeStudioError(
      "insufficient_credits",
      "Not enough credits. Nothing was charged.",
      {
        credits_remaining: credits,
        cost_credits: cost,
      },
    ),
    402,
  );
}

function voiceLimit() {
  return json(
    safeStudioError("voice_limit", "Voice limit reached.", {
      voice_limit: VOICE_STUDIO_VOICE_LIMIT,
    }),
    409,
  );
}

function cloneEnabled(deps) {
  return typeof deps.cloneEnabled === "function" &&
    deps.cloneEnabled() === true;
}

function cloneRequiresPlan() {
  return json(
    safeStudioError(
      "clone_requires_plan",
      "Own voice needs the Starter plan. Nothing was charged.",
    ),
    403,
  );
}

function premiumUnavailable() {
  return json(
    safeStudioError(
      "premium_unavailable",
      "Premium voice is not available yet.",
    ),
    503,
  );
}

async function readInput(req) {
  const type = String(req.headers.get("Content-Type") || "").toLowerCase();
  if (type.startsWith("multipart/form-data")) {
    const form = await req.formData();
    return {
      action: String(form.get("action") || ""),
      request_id: form.get("request_id"),
      name: form.get("name"),
      consent: form.get("consent"),
      file: form.get("file"),
    };
  }
  const body = await req.json();
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("invalid_body");
  }
  return body;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
