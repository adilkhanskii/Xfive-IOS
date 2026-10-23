const FAL_QUEUE_ROOT = "https://queue.fal.run";
export const FAL_VOICE_MODEL = "fal-ai/elevenlabs/tts/eleven-v3";
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;

export class FalVoiceProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "FalVoiceProviderError";
    this.code = code;
    this.providerStatus = Number.isInteger(options.providerStatus)
      ? options.providerStatus
      : null;
    this.submissionAmbiguous = options.submissionAmbiguous === true;
    this.terminal = options.terminal === true;
  }
}

export class FalVoiceQueueProvider {
  constructor({ apiKey, fetchImpl = fetch }) {
    const key = String(apiKey || "").trim();
    if (!key) {
      throw new FalVoiceProviderError("provider_not_configured", {
        terminal: true,
      });
    }
    this.apiKey = key;
    this.fetchImpl = fetchImpl;
  }

  async submit({ input, webhookURL }) {
    const webhook = parseHTTPSURL(webhookURL, "provider_webhook_url_invalid");
    const url = new URL(`${FAL_QUEUE_ROOT}/${FAL_VOICE_MODEL}`);
    url.searchParams.set("fal_webhook", webhook.toString());

    let response;
    try {
      response = await this.fetchImpl(url, {
        method: "POST",
        headers: this.#headers(true),
        body: JSON.stringify(providerInput(input)),
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new FalVoiceProviderError("provider_transport_ambiguous", {
        submissionAmbiguous: true,
      });
    }

    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const submissionAmbiguous = response.status === 408 ||
        response.status >= 500;
      throw new FalVoiceProviderError(
        submissionAmbiguous ? "provider_submit_ambiguous" : "provider_rejected",
        {
          providerStatus: response.status,
          submissionAmbiguous,
          terminal: !submissionAmbiguous,
        },
      );
    }

    const requestID = String(payload?.request_id || "");
    if (!PROVIDER_REQUEST_ID_PATTERN.test(requestID)) {
      throw new FalVoiceProviderError("provider_response_ambiguous", {
        providerStatus: response.status,
        submissionAmbiguous: true,
      });
    }
    return { requestID };
  }

  async status({ requestID }) {
    const id = normalizeProviderRequestID(requestID);
    const response = await this.#fetch(
      `${FAL_QUEUE_ROOT}/${FAL_VOICE_MODEL}/requests/${
        encodeURIComponent(id)
      }/status`,
    );
    const payload = await response.json().catch(() => null);
    const status = String(payload?.status || "").toUpperCase();
    if (status === "IN_QUEUE" || status === "IN_PROGRESS") {
      return { state: "pending" };
    }
    if (status === "COMPLETED" && (payload?.error || payload?.error_type)) {
      return { state: "failed", errorCode: "provider_failed" };
    }
    if (status === "COMPLETED") {
      return { state: "completed" };
    }
    throw new FalVoiceProviderError("provider_status_invalid");
  }

  async result({ requestID }) {
    const id = normalizeProviderRequestID(requestID);
    const response = await this.#fetch(
      `${FAL_QUEUE_ROOT}/${FAL_VOICE_MODEL}/requests/${encodeURIComponent(id)}`,
    );
    return extractFalVoiceResult(await response.json().catch(() => null));
  }

  async #fetch(url) {
    let response;
    try {
      response = await this.fetchImpl(url, {
        headers: this.#headers(false),
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new FalVoiceProviderError("provider_status_unavailable");
    }
    if (!response.ok) {
      throw new FalVoiceProviderError("provider_status_unavailable", {
        providerStatus: response.status,
      });
    }
    return response;
  }

  #headers(withContentType) {
    return {
      "Authorization": `Key ${this.apiKey}`,
      "Accept": "application/json",
      "X-Fal-Store-IO": "0",
      "X-Fal-Object-Lifecycle-Preference": JSON.stringify({
        expiration_duration_seconds: 3 * 60 * 60,
      }),
      ...(withContentType ? { "Content-Type": "application/json" } : {}),
    };
  }
}

export function extractFalVoiceResult(payload) {
  const audioURL = String(payload?.audio?.url || payload?.audio_url || "");
  if (!isAllowedFalMediaURL(audioURL)) {
    throw new FalVoiceProviderError("provider_audio_url_invalid", {
      terminal: true,
    });
  }
  return { audioURL };
}

export function isAllowedFalMediaURL(value) {
  try {
    const url = new URL(String(value || ""));
    const host = url.hostname.toLowerCase();
    return url.protocol === "https:" &&
      (host === "fal.media" || host.endsWith(".fal.media")) &&
      !url.username &&
      !url.password;
  } catch {
    return false;
  }
}

function providerInput(input) {
  return {
    text: input.text,
    voice: input.voice,
    stability: input.stability,
    similarity_boost: 0.75,
    speed: input.speed,
    ...(input.languageCode ? { language_code: input.languageCode } : {}),
    apply_text_normalization: "auto",
    timestamps: false,
    output_format: input.outputFormat,
  };
}

function normalizeProviderRequestID(value) {
  const requestID = String(value || "");
  if (!PROVIDER_REQUEST_ID_PATTERN.test(requestID)) {
    throw new FalVoiceProviderError("provider_request_id_invalid", {
      terminal: true,
    });
  }
  return requestID;
}

function parseHTTPSURL(value, code) {
  try {
    const url = new URL(String(value || ""));
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      url.hash
    ) {
      throw new Error(code);
    }
    return url;
  } catch {
    throw new FalVoiceProviderError(code, { terminal: true });
  }
}
