// «Мои голоса» премиум-озвучки: цены, лимиты и проверка входа.
// Цены согласованы с владельцем 27.10; списывает только сервер.
export const VOICE_STUDIO_PRICES = Object.freeze({
  clone: 300,
  design: 50,
  save: 0,
  delete: 0,
});
export const VOICE_STUDIO_VOICE_LIMIT = 3;
export const CLONE_MIN_BYTES = 32 * 1024;
export const CLONE_MAX_BYTES = 10 * 1024 * 1024;
// Запись с микрофона: iOS — m4a, браузер — webm/ogg; загрузка — mp3/m4a/wav.
export const CLONE_AUDIO_TYPES = Object.freeze(
  new Set([
    "audio/mpeg",
    "audio/mp3",
    "audio/mp4",
    "audio/m4a",
    "audio/x-m4a",
    "audio/aac",
    "audio/wav",
    "audio/x-wav",
    "audio/wave",
    "audio/webm",
    "audio/ogg",
  ]),
);
// Текст превью для голоса по описанию: ElevenLabs требует 100–1000 символов.
export const DESIGN_PREVIEW_TEXT =
  "Здравствуйте! Это пример моего голоса. Я могу озвучить рекламу, видео " +
  "и подкаст — спокойно, ярко или с улыбкой. Как вам такой тембр?";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const VOICE_ID_PATTERN = /^[A-Za-z0-9]{8,40}$/;
const GENERATED_ID_PATTERN = /^[A-Za-z0-9_-]{8,80}$/;

export class VoiceStudioRequestError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "VoiceStudioRequestError";
    this.code = code;
    this.status = status;
  }
}

export function requestID(value) {
  const id = String(value || "").trim().toLowerCase();
  if (!UUID_PATTERN.test(id)) {
    throw new VoiceStudioRequestError("invalid_request_id");
  }
  return id;
}

export function voiceName(value) {
  const name = String(value || "").replace(/\s+/g, " ").trim();
  if (name.length < 1 || name.length > 40) {
    throw new VoiceStudioRequestError("invalid_name");
  }
  return name;
}

export function providerVoiceID(value) {
  const id = String(value || "").trim();
  if (!VOICE_ID_PATTERN.test(id)) {
    throw new VoiceStudioRequestError("invalid_voice");
  }
  return id;
}

export function generatedVoiceID(value) {
  const id = String(value || "").trim();
  if (!GENERATED_ID_PATTERN.test(id)) {
    throw new VoiceStudioRequestError("invalid_preview");
  }
  return id;
}

export function voiceDescription(value) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  if (text.length < 20 || text.length > 1000) {
    throw new VoiceStudioRequestError("invalid_description");
  }
  return text;
}

/** Согласие «это мой голос / у меня есть право» — обязательно для клона. */
export function cloneConsent(value) {
  if (value !== true && String(value).toLowerCase() !== "true") {
    throw new VoiceStudioRequestError("consent_required");
  }
  return true;
}

export function cloneAudio(file) {
  if (!file || typeof file.arrayBuffer !== "function") {
    throw new VoiceStudioRequestError("invalid_audio");
  }
  const type = String(file.type || "").split(";")[0].trim().toLowerCase();
  if (!CLONE_AUDIO_TYPES.has(type)) {
    throw new VoiceStudioRequestError("invalid_audio_type");
  }
  const size = Number(file.size || 0);
  if (size < CLONE_MIN_BYTES) {
    throw new VoiceStudioRequestError("audio_too_short");
  }
  if (size > CLONE_MAX_BYTES) {
    throw new VoiceStudioRequestError("audio_too_large", 413);
  }
  return { file, type };
}

export function safeStudioError(code, message, extra = {}) {
  return { error: { code, message }, ...extra };
}
