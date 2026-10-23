import { isAllowedFalMediaURL } from "./fal-provider.mjs";

const DEFAULT_MAXIMUM_AUDIO_BYTES = 20 * 1024 * 1024;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const REQUEST_KEY_PATTERN = /^explicit:([0-9a-f]{64})$/;

export async function downloadFalAudio({
  audioURL,
  fetchImpl = fetch,
  maximumBytes = DEFAULT_MAXIMUM_AUDIO_BYTES,
}) {
  if (!isAllowedFalMediaURL(audioURL)) {
    throw new Error("audio_url_invalid");
  }
  const response = await fetchImpl(audioURL, {
    headers: { "Accept": "audio/mpeg,application/octet-stream" },
    cache: "no-store",
    redirect: "manual",
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) {
    throw new Error("audio_download_failed");
  }

  return await readBoundedMP3Response(response, maximumBytes);
}

export async function validateMP3Bytes(
  value,
  maximumBytes = DEFAULT_MAXIMUM_AUDIO_BYTES,
) {
  const bytes = value instanceof Uint8Array
    ? value
    : new Uint8Array(value || 0);
  if (bytes.byteLength <= 0 || bytes.byteLength > maximumBytes) {
    throw new Error(
      bytes.byteLength > maximumBytes ? "audio_too_large" : "audio_empty",
    );
  }
  if (!hasMP3Signature(bytes)) {
    throw new Error("audio_format_invalid");
  }
  return {
    bytes,
    mimeType: "audio/mpeg",
    sha256: await sha256Bytes(bytes),
  };
}

export async function readBoundedMP3Response(
  response,
  maximumBytes = DEFAULT_MAXIMUM_AUDIO_BYTES,
) {
  const declaredLength = Number(response.headers.get("Content-Length") || 0);
  if (declaredLength > maximumBytes) {
    throw new Error("audio_too_large");
  }

  const bytes = await readBoundedBody(response, maximumBytes);
  const mimeType = String(response.headers.get("Content-Type") || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (
    !["audio/mpeg", "audio/mp3", "application/octet-stream", ""].includes(
      mimeType,
    ) ||
    !hasMP3Signature(bytes)
  ) {
    throw new Error("audio_format_invalid");
  }

  return {
    bytes,
    mimeType: "audio/mpeg",
    sha256: await sha256Bytes(bytes),
  };
}

export function voiceAudioObjectPath({ userID, requestKey, attempt }) {
  const user = String(userID || "").toLowerCase();
  const keyMatch = String(requestKey || "").match(REQUEST_KEY_PATTERN);
  if (
    !UUID_PATTERN.test(user) ||
    !keyMatch ||
    !Number.isInteger(attempt) ||
    attempt <= 0
  ) {
    throw new Error("audio_object_identity_invalid");
  }
  return `${user}/explicit/${keyMatch[1]}/${attempt}/audio.mp3`;
}

async function readBoundedBody(response, maximumBytes) {
  if (!response.body?.getReader) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength <= 0 || bytes.byteLength > maximumBytes) {
      throw new Error(
        bytes.byteLength > maximumBytes ? "audio_too_large" : "audio_empty",
      );
    }
    return bytes;
  }

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel().catch(() => {});
      throw new Error("audio_too_large");
    }
    chunks.push(value);
  }
  if (total <= 0) throw new Error("audio_empty");

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function hasMP3Signature(bytes) {
  if (bytes.byteLength < 3) return false;
  const id3 = bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33;
  const frame = bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0;
  return id3 || frame;
}

async function sha256Bytes(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
