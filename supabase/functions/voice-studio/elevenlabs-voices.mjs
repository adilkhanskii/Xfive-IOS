// Управление голосами через официальный API ElevenLabs. Ключ — только
// серверный секрет ELEVENLABS_API_KEY. Эндпоинты:
//   GET    /v1/voices/{voice_id}            — preview_url стандартного голоса
//   POST   /v1/voices/add                    — Instant Voice Cloning (multipart)
//   DELETE /v1/voices/{voice_id}             — удалить свой голос
//   POST   /v1/text-to-voice/design          — 3 превью по описанию
//   POST   /v1/text-to-voice                 — сохранить превью как голос
const ROOT = "https://api.elevenlabs.io/v1";
const DESIGN_MODEL = "eleven_ttv_v3";
const PREVIEW_CACHE_MS = 6 * 60 * 60 * 1000;
const MAX_PREVIEW_BASE64 = 8 * 1024 * 1024;

export class ElevenLabsVoicesError extends Error {
  constructor(code, providerStatus = null) {
    super(code);
    this.name = "ElevenLabsVoicesError";
    this.code = code;
    this.providerStatus = Number.isInteger(providerStatus)
      ? providerStatus
      : null;
    // 401/403 — у ключа нет прав или он отозван: для клиента это «скоро».
    this.keyRejected = providerStatus === 401 || providerStatus === 403;
  }
}

export class ElevenLabsVoicesClient {
  constructor({ apiKey = "", fetchImpl = fetch, now = () => Date.now() }) {
    this.apiKey = String(apiKey || "").trim();
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.previewCache = new Map();
    if (!this.apiKey) {
      throw new ElevenLabsVoicesError("provider_not_configured");
    }
  }

  /** preview_url стандартных голосов; кэш на 6 часов, ошибки — null. */
  async premadePreviews(voiceIDs) {
    const result = {};
    let keyRejected = false;
    await Promise.all(voiceIDs.map(async (id) => {
      const cached = this.previewCache.get(id);
      if (cached && this.now() - cached.at < PREVIEW_CACHE_MS) {
        result[id] = cached.url;
        return;
      }
      try {
        const payload = await this.#json(
          `${ROOT}/voices/${encodeURIComponent(id)}`,
          { method: "GET" },
        );
        const url = safeHTTPS(payload?.preview_url);
        this.previewCache.set(id, { url, at: this.now() });
        result[id] = url;
      } catch (error) {
        if (error?.keyRejected) keyRejected = true;
        result[id] = null;
      }
    }));
    return { previews: result, keyRejected };
  }

  async clone({ name, audio, type, filename = "sample" }) {
    const form = new FormData();
    form.set("name", name);
    form.set("remove_background_noise", "false");
    form.set("description", "X5: свой голос пользователя");
    form.append(
      "files",
      new Blob([await audio.arrayBuffer()], { type }),
      `${filename}.${extensionFor(type)}`,
    );
    const payload = await this.#json(`${ROOT}/voices/add`, {
      method: "POST",
      body: form,
    }, 120_000);
    const voiceID = String(payload?.voice_id || "");
    if (!/^[A-Za-z0-9]{8,40}$/.test(voiceID)) {
      throw new ElevenLabsVoicesError("elevenlabs_clone_invalid");
    }
    return {
      voiceID,
      requiresVerification: payload?.requires_verification === true,
    };
  }

  async deleteVoice(voiceID) {
    let response;
    try {
      response = await this.fetchImpl(
        `${ROOT}/voices/${encodeURIComponent(voiceID)}`,
        {
          method: "DELETE",
          headers: this.#headers(),
          signal: AbortSignal.timeout(30_000),
        },
      );
    } catch {
      throw new ElevenLabsVoicesError("elevenlabs_transport");
    }
    await response.body?.cancel().catch(() => null);
    // 404 — голоса у провайдера уже нет: считаем удалённым.
    if (response.ok || response.status === 404) return { deleted: true };
    throw new ElevenLabsVoicesError("elevenlabs_rejected", response.status);
  }

  async design({ description, text }) {
    const url = new URL(`${ROOT}/text-to-voice/design`);
    url.searchParams.set("output_format", "mp3_44100_128");
    const payload = await this.#json(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        voice_description: description,
        model_id: DESIGN_MODEL,
        text,
        auto_generate_text: false,
      }),
    }, 120_000);
    const previews = (Array.isArray(payload?.previews) ? payload.previews : [])
      .slice(0, 3)
      .map((preview) => ({
        generatedVoiceID: String(preview?.generated_voice_id || ""),
        audioBase64: String(preview?.audio_base_64 || ""),
        mediaType: String(preview?.media_type || "audio/mpeg"),
        durationSecs: Number(preview?.duration_secs || 0),
      }))
      .filter((preview) =>
        /^[A-Za-z0-9_-]{8,80}$/.test(preview.generatedVoiceID) &&
        preview.audioBase64.length > 0 &&
        preview.audioBase64.length <= MAX_PREVIEW_BASE64 &&
        /^[A-Za-z0-9+/=]+$/.test(preview.audioBase64)
      );
    if (previews.length === 0) {
      throw new ElevenLabsVoicesError("elevenlabs_design_empty");
    }
    return { previews, text: String(payload?.text || text) };
  }

  async createFromPreview({ name, description, generatedVoiceID }) {
    const payload = await this.#json(`${ROOT}/text-to-voice`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        voice_name: name,
        voice_description: description,
        generated_voice_id: generatedVoiceID,
      }),
    }, 60_000);
    const voiceID = String(payload?.voice_id || "");
    if (!/^[A-Za-z0-9]{8,40}$/.test(voiceID)) {
      throw new ElevenLabsVoicesError("elevenlabs_save_invalid");
    }
    return { voiceID };
  }

  #headers(extra = {}) {
    return {
      "xi-api-key": this.apiKey,
      "Accept": "application/json",
      ...extra,
    };
  }

  async #json(url, options, timeout = 30_000) {
    let response;
    try {
      response = await this.fetchImpl(url, {
        ...options,
        headers: this.#headers(options.headers || {}),
        signal: AbortSignal.timeout(timeout),
      });
    } catch {
      throw new ElevenLabsVoicesError("elevenlabs_transport");
    }
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      throw new ElevenLabsVoicesError("elevenlabs_rejected", response.status);
    }
    return payload;
  }
}

function safeHTTPS(value) {
  try {
    const url = new URL(String(value || ""));
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function extensionFor(type) {
  if (type.includes("wav") || type === "audio/wave") return "wav";
  if (type.includes("webm")) return "webm";
  if (type.includes("ogg")) return "ogg";
  if (type.includes("mp4") || type.includes("m4a") || type.includes("aac")) {
    return "m4a";
  }
  return "mp3";
}
