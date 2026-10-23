const MINIMAX_ENDPOINT = "https://api.minimax.io/v1/t2a_v2";
export const MINIMAX_MODEL = "speech-2.8-turbo";
const MAXIMUM_AUDIO_BYTES = 20 * 1024 * 1024;

const LEGACY_FEMALE_VOICES = new Set([
  "Aria",
  "Sarah",
  "Laura",
  "River",
  "Charlotte",
  "Alice",
  "Matilda",
  "Jessica",
  "Lily",
  "Rachel",
]);
const MINIMAX_FEMALE = [
  "Russian_BrightHeroine",
  "Russian_AmbitiousWoman",
  "Russian_CrazyQueen",
  "Russian_PessimisticGirl",
];
const MINIMAX_MALE = [
  "Russian_ReliableMan",
  "Russian_AttractiveGuy",
  "Russian_Bad-temperedBoy",
  "Russian_HandsomeChildhoodFriend",
];
const MINIMAX_VOICES = new Set([...MINIMAX_FEMALE, ...MINIMAX_MALE]);

export class DirectVoiceProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "DirectVoiceProviderError";
    this.code = code;
    this.submissionAmbiguous = options.submissionAmbiguous === true;
    this.terminal = options.terminal !== false;
    this.providerStatus = Number.isInteger(options.providerStatus)
      ? options.providerStatus
      : null;
  }
}

export class DirectVoiceProvider {
  constructor({ minimaxKey = "", fetchImpl = fetch }) {
    this.minimaxKey = String(minimaxKey || "").trim();
    this.fetchImpl = fetchImpl;
    if (!this.minimaxKey) {
      throw new DirectVoiceProviderError("provider_not_configured");
    }
  }

  async generate({ input }) {
    return await this.#generateMiniMax(input);
  }

  async #generateMiniMax(input) {
    let response;
    try {
      response = await this.fetchImpl(MINIMAX_ENDPOINT, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${this.minimaxKey}`,
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          model: MINIMAX_MODEL,
          text: input.text,
          stream: false,
          language_boost: languageBoost(input.languageCode),
          output_format: "hex",
          voice_setting: {
            voice_id: minimaxVoice(input.voice),
            speed: input.speed,
            vol: 1,
            pitch: 0,
          },
          audio_setting: {
            sample_rate: 44_100,
            bitrate: 128_000,
            format: "mp3",
            channel: 1,
          },
        }),
        signal: AbortSignal.timeout(90_000),
      });
    } catch {
      throw new DirectVoiceProviderError("minimax_transport_ambiguous", {
        submissionAmbiguous: true,
        terminal: false,
      });
    }
    const payload = await response.json().catch(() => null);
    const providerCode = Number(payload?.base_resp?.status_code ?? -1);
    if (!response.ok || providerCode !== 0) {
      throw new DirectVoiceProviderError("minimax_rejected", {
        providerStatus: response.status,
      });
    }
    const audioBytes = decodeBoundedHex(payload?.data?.audio);
    const traceID = normalizeRequestID(payload?.trace_id, "minimax");
    return {
      provider: "minimax",
      model: MINIMAX_MODEL,
      requestID: traceID,
      audioBytes,
      audioMimeType: "audio/mpeg",
    };
  }
}

function minimaxVoice(voice) {
  if (MINIMAX_VOICES.has(voice)) return voice;
  const source = LEGACY_FEMALE_VOICES.has(voice)
    ? MINIMAX_FEMALE
    : MINIMAX_MALE;
  let hash = 0;
  for (const character of String(voice || "")) {
    hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
  }
  return source[hash % source.length];
}

function languageBoost(code) {
  const map = {
    ru: "Russian",
    // MiniMax currently rejects the undocumented `Kazakh` boost value.
    // Auto-detection accepts Kazakh Cyrillic and produced a valid live MP3.
    kk: "auto",
    en: "English",
    uk: "Ukrainian",
    de: "German",
    fr: "French",
    es: "Spanish",
    it: "Italian",
    pt: "Portuguese",
    tr: "Turkish",
    pl: "Polish",
    ja: "Japanese",
    ko: "Korean",
  };
  return map[String(code || "").toLowerCase()] || "auto";
}

function decodeBoundedHex(value) {
  const hex = String(value || "");
  if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) {
    throw new DirectVoiceProviderError("minimax_audio_invalid");
  }
  const byteLength = hex.length / 2;
  if (byteLength <= 3 || byteLength > MAXIMUM_AUDIO_BYTES) {
    throw new DirectVoiceProviderError("minimax_audio_too_large");
  }
  const bytes = new Uint8Array(byteLength);
  for (let index = 0; index < byteLength; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function normalizeRequestID(value, prefix) {
  const clean = String(value || "").replace(/[^A-Za-z0-9_-]/g, "_");
  const candidate = `${prefix}_${clean}`.slice(0, 200);
  if (candidate.length < 8) {
    return `${prefix}_${crypto.randomUUID()}`;
  }
  return candidate;
}
