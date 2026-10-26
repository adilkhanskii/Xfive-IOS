// Премиум-озвучка: прямой официальный API ElevenLabs (не через fal).
// Ключ — только серверный секрет ELEVENLABS_API_KEY в окружении функции.
// Док: https://elevenlabs.io/docs/api-reference/text-to-speech/convert
const ELEVENLABS_ROOT = "https://api.elevenlabs.io/v1/text-to-speech";
export const ELEVENLABS_MODEL = "eleven_v3";
const ELEVENLABS_OUTPUT_FORMAT = "mp3_44100_128";
const MAXIMUM_AUDIO_BYTES = 20 * 1024 * 1024;
// language_code шлём только для языков, где он точно принят; казахский и
// «Авто» — автоопределение eleven_v3 (как language_boost auto у MiniMax).
const EXPLICIT_LANGUAGES = new Set(["ru", "en"]);

export class ElevenLabsVoiceProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "ElevenLabsVoiceProviderError";
    this.code = code;
    this.submissionAmbiguous = options.submissionAmbiguous === true;
    this.terminal = options.terminal !== false;
    this.providerStatus = Number.isInteger(options.providerStatus)
      ? options.providerStatus
      : null;
  }
}

export class ElevenLabsVoiceProvider {
  constructor({ apiKey = "", fetchImpl = fetch }) {
    this.apiKey = String(apiKey || "").trim();
    this.fetchImpl = fetchImpl;
    if (!this.apiKey) {
      throw new ElevenLabsVoiceProviderError("provider_not_configured");
    }
  }

  async generate({ input }) {
    const voiceID = String(input?.voice || "");
    if (!/^[A-Za-z0-9]{8,40}$/.test(voiceID)) {
      throw new ElevenLabsVoiceProviderError("elevenlabs_voice_invalid");
    }
    const url = new URL(`${ELEVENLABS_ROOT}/${encodeURIComponent(voiceID)}`);
    url.searchParams.set("output_format", ELEVENLABS_OUTPUT_FORMAT);
    const language = String(input.languageCode || "").toLowerCase();

    let response;
    try {
      response = await this.fetchImpl(url, {
        method: "POST",
        headers: {
          "xi-api-key": this.apiKey,
          "Content-Type": "application/json",
          "Accept": "audio/mpeg",
        },
        body: JSON.stringify({
          text: input.text,
          model_id: ELEVENLABS_MODEL,
          ...(EXPLICIT_LANGUAGES.has(language)
            ? { language_code: language }
            : {}),
          apply_text_normalization: "auto",
          voice_settings: {
            // eleven_v3 принимает только 0 / 0.5 / 1 — контракт уже это
            // проверил (Живо / Баланс / Стабильно).
            stability: input.stability,
            similarity_boost: 0.75,
            speed: input.speed,
          },
        }),
        signal: AbortSignal.timeout(90_000),
      });
    } catch {
      // Ответ потерян: генерация могла пройти. Как у MiniMax — без возврата,
      // повтор клиента перегенерирует по тому же request_id.
      throw new ElevenLabsVoiceProviderError("elevenlabs_transport_ambiguous", {
        submissionAmbiguous: true,
        terminal: false,
      });
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => null);
      throw new ElevenLabsVoiceProviderError("elevenlabs_rejected", {
        providerStatus: response.status,
      });
    }
    const audioBytes = await readBoundedAudio(response);
    return {
      provider: "elevenlabs",
      model: ELEVENLABS_MODEL,
      requestID: normalizeRequestID(response.headers.get("request-id")),
      audioBytes,
      audioMimeType: "audio/mpeg",
    };
  }
}

async function readBoundedAudio(response) {
  const declared = Number(response.headers.get("Content-Length") || 0);
  if (declared > MAXIMUM_AUDIO_BYTES) {
    await response.body?.cancel().catch(() => null);
    throw new ElevenLabsVoiceProviderError("elevenlabs_audio_too_large");
  }
  let bytes;
  try {
    bytes = new Uint8Array(await response.arrayBuffer());
  } catch {
    throw new ElevenLabsVoiceProviderError("elevenlabs_audio_invalid");
  }
  if (bytes.byteLength <= 3) {
    throw new ElevenLabsVoiceProviderError("elevenlabs_audio_invalid");
  }
  if (bytes.byteLength > MAXIMUM_AUDIO_BYTES) {
    throw new ElevenLabsVoiceProviderError("elevenlabs_audio_too_large");
  }
  return bytes;
}

// Префикс eleven_ — handler узнаёт по нему прямого провайдера при повторе.
function normalizeRequestID(value) {
  const clean = String(value || "").replace(/[^A-Za-z0-9_-]/g, "_");
  const candidate = `eleven_${clean}`.slice(0, 200);
  if (clean.length < 4) return `eleven_${crypto.randomUUID()}`;
  return candidate;
}
