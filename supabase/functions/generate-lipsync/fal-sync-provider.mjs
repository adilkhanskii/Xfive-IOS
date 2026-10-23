const ROOT = "https://queue.fal.run";
const MODEL = "fal-ai/sync-lipsync";

export class FalSyncError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "FalSyncError";
    this.code = code;
    this.retryable = options.retryable !== false;
    this.submissionAmbiguous = options.submissionAmbiguous === true;
    this.terminal = options.terminal === true;
    this.httpStatus = Number.isInteger(options.httpStatus)
      ? options.httpStatus
      : null;
  }
}

export class FalSyncProvider {
  constructor({ apiKey, fetchImpl = fetch }) {
    this.apiKey = String(apiKey || "").trim();
    this.fetchImpl = fetchImpl;
    if (!this.apiKey) {
      throw new FalSyncError("provider_not_configured", { terminal: true });
    }
  }

  async submit({ videoURL, audioURL }) {
    let response;
    try {
      response = await this.fetchImpl(`${ROOT}/${MODEL}`, {
        method: "POST",
        headers: this.#headers(true),
        body: JSON.stringify({ video_url: videoURL, audio_url: audioURL }),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      throw new FalSyncError("provider_transport_ambiguous", {
        submissionAmbiguous: true,
      });
    }
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new FalSyncError("provider_rejected", {
        terminal: response.status >= 400 && response.status < 500 &&
          response.status !== 408 && response.status !== 429,
        retryable: response.status === 408 || response.status === 429 ||
          response.status >= 500,
        submissionAmbiguous: response.status === 408 || response.status >= 500,
        httpStatus: response.status,
      });
    }
    const requestID = String(payload?.request_id || "");
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(requestID)) {
      throw new FalSyncError("provider_response_ambiguous", {
        submissionAmbiguous: true,
      });
    }
    return { requestID };
  }

  async status(requestID) {
    const payload = await this.#get(requestID, "/status");
    const status = String(payload?.status || "").toUpperCase();
    if (status === "IN_QUEUE") return { state: "processing", progress: 0.1 };
    if (status === "IN_PROGRESS") {
      return { state: "processing", progress: 0.55 };
    }
    if (status === "COMPLETED" && (payload?.error || payload?.error_type)) {
      return { state: "failed", progress: 1 };
    }
    if (status === "COMPLETED") return { state: "completed", progress: 0.9 };
    throw new FalSyncError("provider_status_invalid");
  }

  async result(requestID) {
    const payload = await this.#get(requestID, "");
    const video = payload?.video || payload?.output?.video ||
      payload?.data?.video;
    const url = String(video?.url || payload?.video_url || "");
    const mimeType = String(video?.content_type || "video/mp4").toLowerCase();
    if (!isFalMediaURL(url) || mimeType !== "video/mp4") {
      throw new FalSyncError("provider_result_invalid", { terminal: true });
    }
    return { url, mimeType };
  }

  async #get(requestID, suffix) {
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(String(requestID || ""))) {
      throw new FalSyncError("provider_request_id_invalid", { terminal: true });
    }
    let response;
    try {
      response = await this.fetchImpl(
        `${ROOT}/${MODEL}/requests/${encodeURIComponent(requestID)}${suffix}`,
        { headers: this.#headers(false), signal: AbortSignal.timeout(20_000) },
      );
    } catch {
      throw new FalSyncError("provider_transport_unavailable");
    }
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new FalSyncError("provider_unavailable", {
        terminal: response.status === 404,
        httpStatus: response.status,
      });
    }
    return payload;
  }

  #headers(withJSON) {
    return {
      "Authorization": `Key ${this.apiKey}`,
      ...(withJSON ? { "Content-Type": "application/json" } : {}),
    };
  }
}

export function isFalMediaURL(value) {
  try {
    const url = new URL(String(value || ""));
    return url.protocol === "https:" && !url.username && !url.password &&
      (!url.port || url.port === "443") &&
      (url.hostname === "fal.media" || url.hostname.endsWith(".fal.media"));
  } catch {
    return false;
  }
}
