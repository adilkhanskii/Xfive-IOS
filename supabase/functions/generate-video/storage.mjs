import {
  MAX_START_IMAGE_BYTES,
  MAX_VIDEO_RESULT_BYTES,
  VIDEO_RESULT_SIGNED_URL_TTL_SECONDS,
  VIDEO_START_IMAGE_SIGNED_URL_TTL_SECONDS,
} from "./contract.mjs";

const INPUT_BUCKET = "video-generation-inputs";
const RESULT_BUCKET = "video-generation-results";

export class VideoStorage {
  constructor({
    supabaseUrl,
    serviceKey,
    fetchImpl = fetch,
    now = () => new Date(),
  }) {
    if (!supabaseUrl || !serviceKey) {
      throw new Error("video_storage_not_configured");
    }
    this.supabaseUrl = String(supabaseUrl).replace(/\/+$/, "");
    this.serviceKey = serviceKey;
    this.fetchImpl = fetchImpl;
    this.now = now;
  }

  async storeStartImage({ userId, jobId, image }) {
    const bytes = decodeBase64(image.dataBase64);
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_START_IMAGE_BYTES) {
      throw new Error("start_image_invalid");
    }
    const extension = extensionForImage(image.mimeType, bytes);
    const path = `${userId}/${jobId}/start.${extension}`;
    await this.#upload(INPUT_BUCKET, path, image.mimeType, bytes, false);
    return {
      path,
      mimeType: image.mimeType,
      sha256: await sha256Bytes(bytes),
    };
  }

  async signStartImage(object) {
    return await this.#sign(
      INPUT_BUCKET,
      object.path,
      VIDEO_START_IMAGE_SIGNED_URL_TTL_SECONDS,
    );
  }

  async deleteStartImage(path) {
    const uuid =
      "[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
    if (
      !new RegExp(
        `^${uuid}/${uuid}/start\\.(?:jpg|png|webp)$`,
        "i",
      ).test(String(path || ""))
    ) {
      throw new Error("start_image_path_invalid");
    }
    const response = await this.fetchImpl(
      `${this.supabaseUrl}/storage/v1/object/${INPUT_BUCKET}/${
        encodePath(path)
      }`,
      {
        method: "DELETE",
        headers: this.#serviceHeaders(),
      },
    );
    if (!response.ok && response.status !== 404) {
      throw new Error(`video_storage_delete_failed_${response.status}`);
    }
  }

  async storeResult({ userId, jobId, bytes }) {
    const normalized = Uint8Array.from(bytes || []);
    if (
      normalized.byteLength < 12 ||
      normalized.byteLength > MAX_VIDEO_RESULT_BYTES ||
      String.fromCharCode(...normalized.slice(4, 8)) !== "ftyp"
    ) {
      throw new Error("generated_video_invalid");
    }
    const path = `${userId}/${jobId}/result.mp4`;
    await this.#upload(
      RESULT_BUCKET,
      path,
      "video/mp4",
      normalized,
      true,
    );
    return {
      path,
      mimeType: "video/mp4",
      sha256: await sha256Bytes(normalized),
    };
  }

  async signResult(path) {
    return await this.#sign(
      RESULT_BUCKET,
      path,
      VIDEO_RESULT_SIGNED_URL_TTL_SECONDS,
    );
  }

  /**
   * @param {string} url
   * @param {{ providerName?: string, headers?: Record<string, string> }} options
   */
  async downloadProviderVideo(
    url,
    { providerName, headers = {} } = {},
  ) {
    let current = validatedProviderURL(url, providerName);
    for (let redirectCount = 0; redirectCount <= 3; redirectCount += 1) {
      const response = await this.fetchImpl(current, {
        headers: providerDownloadHeaders(current, providerName, headers),
        redirect: "manual",
      });
      if (isRedirect(response.status)) {
        const location = response.headers.get("Location");
        if (!location || redirectCount === 3) {
          throw new Error("provider_result_invalid");
        }
        current = validatedProviderURL(
          new URL(location, current).toString(),
          providerName,
        );
        continue;
      }

      const declaredLength = Number(
        response.headers.get("Content-Length") || 0,
      );
      if (!response.ok) {
        throw new Error("provider_result_unavailable");
      }
      if (declaredLength > MAX_VIDEO_RESULT_BYTES) {
        throw new Error("provider_result_too_large");
      }
      return await readResponseBodyBounded(
        response,
        MAX_VIDEO_RESULT_BYTES,
      );
    }
    throw new Error("provider_result_invalid");
  }

  async #upload(bucket, path, mimeType, bytes, upsert) {
    const response = await this.fetchImpl(
      `${this.supabaseUrl}/storage/v1/object/${bucket}/${encodePath(path)}`,
      {
        method: "POST",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": mimeType,
          "cache-control": "3600",
          "x-upsert": String(upsert),
        },
        body: Uint8Array.from(bytes).buffer,
      },
    );
    if (!response.ok) {
      throw new Error(`video_storage_upload_failed_${response.status}`);
    }
  }

  async #sign(bucket, path, expiresIn) {
    const response = await this.fetchImpl(
      `${this.supabaseUrl}/storage/v1/object/sign/${bucket}/${
        encodePath(path)
      }`,
      {
        method: "POST",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expiresIn }),
      },
    );
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`video_storage_sign_failed_${response.status}`);
    }
    const signedPath = String(payload?.signedURL || payload?.signedUrl || "");
    if (!signedPath) throw new Error("video_storage_sign_missing_url");
    const signedUrl = /^https:\/\//i.test(signedPath) ? signedPath : new URL(
      signedPath.startsWith("/storage/v1/")
        ? signedPath
        : `/storage/v1${signedPath.startsWith("/") ? "" : "/"}${signedPath}`,
      this.supabaseUrl,
    ).toString();
    return {
      signedUrl,
      expiresAt: new Date(
        this.now().getTime() + expiresIn * 1000,
      ).toISOString(),
    };
  }

  #serviceHeaders() {
    return {
      "apikey": this.serviceKey,
      "Authorization": `Bearer ${this.serviceKey}`,
    };
  }
}

function extensionForImage(mimeType, bytes) {
  if (
    mimeType === "image/png" &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47
  ) {
    return "png";
  }
  if (
    mimeType === "image/jpeg" &&
    bytes[0] === 0xff &&
    bytes[1] === 0xd8 &&
    bytes[2] === 0xff
  ) {
    return "jpg";
  }
  if (
    mimeType === "image/webp" &&
    String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" &&
    String.fromCharCode(...bytes.slice(8, 12)) === "WEBP"
  ) {
    return "webp";
  }
  throw new Error("start_image_format_mismatch");
}

export function decodeBoundedProviderVideoBase64(
  value,
  maxBytes = MAX_VIDEO_RESULT_BYTES,
) {
  const encoded = String(value || "");
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) {
    throw new Error("provider_result_invalid");
  }
  if (encoded.length > Math.ceil(maxBytes / 3) * 4) {
    throw new Error("provider_result_too_large");
  }
  if (
    !encoded ||
    encoded.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)
  ) {
    throw new Error("provider_result_invalid");
  }
  const padding = encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0;
  const decodedLength = encoded.length / 4 * 3 - padding;
  if (decodedLength > maxBytes) {
    throw new Error("provider_result_too_large");
  }
  try {
    const binary = atob(encoded);
    if (binary.length !== decodedLength) {
      throw new Error("provider_result_invalid");
    }
    return Uint8Array.from(
      binary,
      (character) => character.charCodeAt(0),
    );
  } catch (error) {
    if (
      error instanceof Error &&
      [
        "provider_result_invalid",
        "provider_result_too_large",
      ].includes(error.message)
    ) {
      throw error;
    }
    throw new Error("provider_result_invalid");
  }
}

export async function readResponseBodyBounded(
  response,
  maxBytes = MAX_VIDEO_RESULT_BYTES,
) {
  if (
    !Number.isSafeInteger(maxBytes) ||
    maxBytes < 1 ||
    !response?.body ||
    typeof response.body.getReader !== "function"
  ) {
    throw new Error("provider_result_unavailable");
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = Uint8Array.from(value || []);
      total += chunk.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new Error("provider_result_too_large");
      }
      chunks.push(chunk);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function decodeBase64(value) {
  const binary = atob(String(value || ""));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodePath(path) {
  return String(path).split("/").map(encodeURIComponent).join("/");
}

async function sha256Bytes(bytes) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(bytes).buffer,
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function validatedProviderURL(value, providerName) {
  let url;
  try {
    url = new URL(String(value || ""));
  } catch {
    throw new Error("provider_result_invalid");
  }
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    (url.port && url.port !== "443") ||
    !isAllowedProviderHost(url.hostname, providerName)
  ) {
    throw new Error("provider_result_invalid");
  }
  return url;
}

function isAllowedProviderHost(rawHostname, providerName) {
  const hostname = String(rawHostname || "").toLowerCase();
  if (providerName === "fal") {
    return hostname === "storage.googleapis.com" ||
      hostname === "fal.media" ||
      hostname.endsWith(".fal.media");
  }
  if (providerName === "google") {
    return hostname === "generativelanguage.googleapis.com" ||
      hostname === "storage.googleapis.com" ||
      hostname === "googleusercontent.com" ||
      hostname.endsWith(".googleusercontent.com");
  }
  if (providerName === "byteplus") {
    return hostname === "bytepluses.com" ||
      hostname.endsWith(".bytepluses.com") ||
      hostname === "volces.com" ||
      hostname.endsWith(".volces.com");
  }
  return false;
}

function providerDownloadHeaders(url, providerName, headers) {
  if (
    providerName === "google" &&
    url.hostname.toLowerCase() === "generativelanguage.googleapis.com"
  ) {
    return { ...headers };
  }
  return {};
}

function isRedirect(status) {
  return [301, 302, 303, 307, 308].includes(status);
}
