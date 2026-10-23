import {
  downloadFalAudio,
  readBoundedMP3Response,
  validateMP3Bytes,
  voiceAudioObjectPath,
} from "./storage.mjs";

const RESULT_BUCKET = "voice-generation-results";
const SIGNED_URL_TTL_SECONDS = 60 * 60;

export class VoiceGenerationBackend {
  constructor({ supabaseURL, serviceRoleKey, fetchImpl = fetch }) {
    this.supabaseURL = String(supabaseURL || "").replace(/\/+$/, "");
    this.serviceRoleKey = String(serviceRoleKey || "").trim();
    this.fetchImpl = fetchImpl;
    if (!/^https:\/\//i.test(this.supabaseURL) || !this.serviceRoleKey) {
      throw new Error("voice_backend_not_configured");
    }
  }

  async rpc(name, parameters) {
    const response = await this.fetchImpl(
      `${this.supabaseURL}/rest/v1/rpc/${encodeURIComponent(name)}`,
      {
        method: "POST",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        },
        body: JSON.stringify(parameters),
      },
    );
    const payload = await response.json().catch(() => null);
    if (!response.ok || !payload || typeof payload !== "object") {
      throw new Error(`voice_rpc_${name}_failed_${response.status}`);
    }
    return payload;
  }

  /**
   * @param {{
   *   audioURL?: string,
   *   audioBytes?: Uint8Array | ArrayBuffer,
   *   audioMimeType?: string,
   *   userID: string,
   *   requestKey: string,
   *   attempt: number
   * }} input
   */
  async storeAudio({
    audioURL,
    audioBytes,
    audioMimeType,
    userID,
    requestKey,
    attempt,
  }) {
    const audio = audioBytes
      ? await validateMP3Bytes(audioBytes)
      : await downloadFalAudio({
        audioURL,
        fetchImpl: this.fetchImpl,
      });
    if (audioMimeType && audioMimeType !== "audio/mpeg") {
      throw new Error("audio_format_invalid");
    }
    const path = voiceAudioObjectPath({
      userID,
      requestKey,
      attempt,
    });
    const upload = await this.fetchImpl(
      `${this.supabaseURL}/storage/v1/object/${RESULT_BUCKET}/${
        encodeStoragePath(path)
      }`,
      {
        method: "POST",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": audio.mimeType,
          "cache-control": "3600",
          "x-upsert": "false",
        },
        body: Uint8Array.from(audio.bytes).buffer,
      },
    );
    if (!upload.ok && upload.status !== 409) {
      throw new Error(`voice_result_upload_failed_${upload.status}`);
    }
    if (upload.status === 409) {
      const existing = await this.#downloadStored(path);
      if (existing.sha256 !== audio.sha256) {
        throw new Error("voice_result_existing_object_conflict");
      }
    }
    return {
      path,
      mimeType: audio.mimeType,
      sha256: audio.sha256,
    };
  }

  async deleteAudio(path) {
    if (!path) return;
    const response = await this.fetchImpl(
      `${this.supabaseURL}/storage/v1/object/${RESULT_BUCKET}`,
      {
        method: "DELETE",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ prefixes: [path] }),
      },
    );
    if (!response.ok) {
      throw new Error(`voice_result_cleanup_failed_${response.status}`);
    }
  }

  async signAudio(path) {
    const response = await this.fetchImpl(
      `${this.supabaseURL}/storage/v1/object/sign/${RESULT_BUCKET}/${
        encodeStoragePath(path)
      }`,
      {
        method: "POST",
        headers: {
          ...this.#serviceHeaders(),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expiresIn: SIGNED_URL_TTL_SECONDS }),
      },
    );
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`voice_result_sign_failed_${response.status}`);
    }
    const signedPath = String(payload?.signedURL || payload?.signedUrl || "");
    if (!signedPath) throw new Error("voice_result_sign_missing_url");
    const signedURL = /^https?:\/\//i.test(signedPath) ? signedPath : new URL(
      signedPath.startsWith("/storage/v1/")
        ? signedPath
        : `/storage/v1${signedPath.startsWith("/") ? "" : "/"}${signedPath}`,
      this.supabaseURL,
    ).toString();
    return {
      signedURL,
      expiresAt: new Date(
        Date.now() + SIGNED_URL_TTL_SECONDS * 1_000,
      ).toISOString(),
    };
  }

  async #downloadStored(path) {
    const response = await this.fetchImpl(
      `${this.supabaseURL}/storage/v1/object/authenticated/${RESULT_BUCKET}/${
        encodeStoragePath(path)
      }`,
      {
        headers: {
          ...this.#serviceHeaders(),
          "Accept": "audio/mpeg,application/octet-stream",
        },
        redirect: "manual",
      },
    );
    if (!response.ok) {
      throw new Error(
        `voice_result_existing_download_failed_${response.status}`,
      );
    }
    return await readBoundedMP3Response(response);
  }

  #serviceHeaders() {
    return {
      "apikey": this.serviceRoleKey,
      "Authorization": `Bearer ${this.serviceRoleKey}`,
    };
  }
}

export function encodeStoragePath(path) {
  return String(path || "").split("/").map(encodeURIComponent).join("/");
}
