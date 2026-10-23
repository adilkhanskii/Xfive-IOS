export const VOICE_MODEL = "speech-2.8-turbo";
// Keep the old fingerprint seed so an installed build can replay an accepted
// request after the provider display names changed. This value is never sent
// to a provider or exposed as the result model.
const LEGACY_IDENTITY_MODEL = "fal-ai/elevenlabs/tts/eleven-v3";
export const VOICE_RESULT_MODELS = Object.freeze({
  fal: LEGACY_IDENTITY_MODEL,
  minimax: "speech-2.8-turbo",
  elevenlabs: "eleven_v3",
});
export const VOICE_OUTPUT_FORMAT = "mp3_44100_128";
export const CUSTOMER_PRICE_MULTIPLIER = 2;
export const VOICE_PROVIDER_COST_PER_1000_CHARACTERS = 30;
export const VOICE_CREDITS_PER_1000_CHARACTERS =
  VOICE_PROVIDER_COST_PER_1000_CHARACTERS * CUSTOMER_PRICE_MULTIPLIER;
export const VOICE_MAX_CHARACTERS = 5_000;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SUPPORTED_VOICES = new Set([
  "Russian_BrightHeroine",
  "Russian_AmbitiousWoman",
  "Russian_CrazyQueen",
  "Russian_PessimisticGirl",
  "Russian_ReliableMan",
  "Russian_AttractiveGuy",
  "Russian_Bad-temperedBoy",
  "Russian_HandsomeChildhoodFriend",
  // Legacy app values remain valid only to replay or finish requests made by
  // earlier TestFlight builds. New UI versions send the MiniMax IDs above.
  "Aria",
  "Roger",
  "Sarah",
  "Laura",
  "Charlie",
  "George",
  "Callum",
  "River",
  "Liam",
  "Charlotte",
  "Alice",
  "Matilda",
  "Will",
  "Jessica",
  "Eric",
  "Chris",
  "Brian",
  "Daniel",
  "Lily",
  "Bill",
  "Rachel",
]);
const SUPPORTED_STABILITY = new Set([0, 0.5, 1]);

export class VoiceGenerationRequestError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "VoiceGenerationRequestError";
    this.code = code;
    this.status = status;
  }
}

export function voiceGenerationCost(text) {
  const characterCount = String(text || "").length;
  if (characterCount <= 0 || characterCount > VOICE_MAX_CHARACTERS) {
    throw new VoiceGenerationRequestError("invalid_text");
  }
  return Math.ceil(characterCount / 1_000) *
    VOICE_CREDITS_PER_1000_CHARACTERS;
}

export function normalizeVoiceGenerationRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new VoiceGenerationRequestError("invalid_request");
  }

  const requestID = String(body.request_id || "").trim().toLowerCase();
  if (!UUID_PATTERN.test(requestID)) {
    throw new VoiceGenerationRequestError("invalid_request_id");
  }

  const text = String(body.text || "").trim();
  const characterCount = text.length;
  if (characterCount <= 0 || characterCount > VOICE_MAX_CHARACTERS) {
    throw new VoiceGenerationRequestError("invalid_text");
  }

  const voice = String(body.voice || "Russian_BrightHeroine").trim();
  if (!SUPPORTED_VOICES.has(voice)) {
    throw new VoiceGenerationRequestError("invalid_voice");
  }

  const stability = body.stability === undefined ? 0.5 : Number(body.stability);
  if (!Number.isFinite(stability) || !SUPPORTED_STABILITY.has(stability)) {
    throw new VoiceGenerationRequestError("invalid_stability");
  }

  const speed = body.speed === undefined ? 1 : Number(body.speed);
  if (
    !Number.isFinite(speed) ||
    speed < 0.7 ||
    speed > 1.2 ||
    Math.abs(speed * 10 - Math.round(speed * 10)) > Number.EPSILON
  ) {
    throw new VoiceGenerationRequestError("invalid_speed");
  }

  const rawLanguageCode = String(body.language_code || "")
    .trim()
    .toLowerCase();
  const languageCode = rawLanguageCode === "" || rawLanguageCode === "auto"
    ? null
    : rawLanguageCode;
  if (languageCode !== null && !/^[a-z]{2}$/.test(languageCode)) {
    throw new VoiceGenerationRequestError("invalid_language_code");
  }

  return {
    requestID,
    text,
    characterCount,
    voice,
    stability,
    speed,
    languageCode,
    outputFormat: VOICE_OUTPUT_FORMAT,
    costCredits: voiceGenerationCost(text),
  };
}

export async function buildVoiceGenerationIdentity(normalized) {
  const requestDigest = await sha256Hex(normalized.requestID);
  const fingerprint = await sha256Hex(JSON.stringify({
    text: normalized.text,
    voice: normalized.voice,
    stability: normalized.stability,
    speed: normalized.speed,
    languageCode: normalized.languageCode,
    outputFormat: normalized.outputFormat,
    costCredits: normalized.costCredits,
    model: LEGACY_IDENTITY_MODEL,
  }));
  return {
    requestKey: `explicit:${requestDigest}`,
    fingerprint,
  };
}

export function buildVoiceResultManifest(object, result = {}) {
  const provider = String(result.provider || "minimax");
  const model = String(
    result.model || VOICE_RESULT_MODELS[provider] || VOICE_MODEL,
  );
  if (
    !object ||
    typeof object.path !== "string" ||
    object.mimeType !== "audio/mpeg" ||
    !/^[0-9a-f]{64}$/.test(String(object.sha256 || "")) ||
    VOICE_RESULT_MODELS[provider] !== model
  ) {
    throw new Error("voice_result_object_invalid");
  }
  return {
    version: 1,
    provider,
    model,
    object: {
      path: object.path,
      mimeType: object.mimeType,
      sha256: object.sha256,
    },
  };
}

export function voiceResultObject(manifest) {
  const object = manifest?.object;
  if (
    manifest?.version !== 1 ||
    VOICE_RESULT_MODELS[manifest?.provider] !== manifest?.model ||
    !object ||
    typeof object.path !== "string" ||
    object.mimeType !== "audio/mpeg" ||
    !/^[0-9a-f]{64}$/.test(String(object.sha256 || ""))
  ) {
    throw new Error("voice_result_manifest_invalid");
  }
  return object;
}

export function safeVoiceError(code, message, retryable = false) {
  return {
    error: {
      code,
      message,
      ...(retryable ? { retryable: true } : {}),
    },
  };
}

async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
