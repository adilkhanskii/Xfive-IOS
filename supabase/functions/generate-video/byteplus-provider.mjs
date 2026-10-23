const BYTEPLUS_TASKS_ROOT =
  "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks";

const MODEL_IDS = Object.freeze({
  "seedance-1.5-pro": "seedance-1-5-pro-251215",
  "seedance-2.0-fast": "dreamina-seedance-2-0-fast-260128",
});

const FAST_RESOLUTIONS = new Set(["480p", "720p"]);
const ALL_RESOLUTIONS = new Set(["480p", "720p", "1080p"]);

export class BytePlusProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "BytePlusProviderError";
    this.code = code;
    this.retryable = options.retryable !== false;
    this.submissionAmbiguous = options.submissionAmbiguous === true;
    this.httpStatus = Number.isInteger(options.httpStatus)
      ? options.httpStatus
      : null;
  }
}

export class BytePlusSeedanceProvider {
  constructor({ apiKey, fetchImpl = fetch }) {
    const normalizedKey = String(apiKey || "").trim();
    if (!normalizedKey) {
      throw new BytePlusProviderError("provider_not_configured", {
        retryable: false,
      });
    }
    this.apiKey = normalizedKey;
    this.fetchImpl = fetchImpl;
  }

  async submit({
    model,
    prompt,
    aspectRatio,
    durationSeconds,
    resolution = "720p",
    generateAudio = true,
    startImageUrl,
  }) {
    const providerModel = MODEL_IDS[model];
    if (!providerModel) {
      throw new BytePlusProviderError("provider_model_invalid", {
        retryable: false,
      });
    }
    const allowedResolutions = model === "seedance-2.0-fast"
      ? FAST_RESOLUTIONS
      : ALL_RESOLUTIONS;
    if (!allowedResolutions.has(resolution)) {
      throw new BytePlusProviderError("provider_resolution_invalid", {
        retryable: false,
      });
    }
    if (typeof generateAudio !== "boolean") {
      throw new BytePlusProviderError("provider_audio_invalid", {
        retryable: false,
      });
    }

    const content = [{ type: "text", text: String(prompt || "") }];
    if (startImageUrl) {
      content.push({
        type: "image_url",
        image_url: { url: String(startImageUrl) },
      });
    }
    const payload = await this.#request(BYTEPLUS_TASKS_ROOT, {
      method: "POST",
      body: JSON.stringify({
        model: providerModel,
        content,
        generate_audio: generateAudio,
        ratio: aspectRatio,
        duration: durationSeconds,
        resolution,
        watermark: false,
      }),
    }, { isSubmission: true });
    const requestId = String(payload?.id || "");
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(requestId)) {
      throw new BytePlusProviderError("provider_response_ambiguous", {
        retryable: true,
        submissionAmbiguous: true,
      });
    }
    return {
      requestId,
      kind: startImageUrl ? "image" : "text",
    };
  }

  async status({ requestId }) {
    const payload = await this.#request(
      `${BYTEPLUS_TASKS_ROOT}/${encodeURIComponent(requestId)}`,
      { method: "GET" },
    );
    return mapBytePlusStatus(payload);
  }

  async result({ requestId }) {
    const current = await this.status({ requestId });
    if (current.status !== "completed" || !current.result) {
      throw new BytePlusProviderError("provider_result_unavailable", {
        retryable: current.status !== "failed",
      });
    }
    return current.result;
  }

  async #request(url, init, { isSubmission = false } = {}) {
    let response;
    try {
      response = await this.fetchImpl(url, {
        ...init,
        headers: {
          "Authorization": `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
      });
    } catch {
      throw new BytePlusProviderError(
        isSubmission
          ? "provider_transport_ambiguous"
          : "provider_unavailable",
        {
          retryable: true,
          submissionAmbiguous: isSubmission,
        },
      );
    }

    const payload = await response.json().catch(() => ({}));
    if (response.ok) return payload;

    const ambiguous = isSubmission &&
      (response.status === 408 || response.status >= 500);
    const retryable = response.status === 408 || response.status === 429 ||
      response.status >= 500;
    throw new BytePlusProviderError(
      response.status >= 400 && response.status < 500 && response.status !== 408
        ? "provider_rejected"
        : "provider_unavailable",
      {
        retryable,
        submissionAmbiguous: ambiguous,
        httpStatus: response.status,
      },
    );
  }
}

export function mapBytePlusStatus(payload) {
  const status = String(payload?.status || "").trim().toLowerCase();
  if (["queued", "pending"].includes(status)) {
    return { status: "queued", progress: 0.05, completed: false };
  }
  if (["running", "processing", "in_progress"].includes(status)) {
    return { status: "rendering", progress: 0.5, completed: false };
  }
  if (status === "succeeded") {
    return {
      status: "completed",
      progress: 0.9,
      completed: true,
      result: extractBytePlusVideo(payload),
    };
  }
  if (["failed", "cancelled", "canceled", "expired"].includes(status)) {
    return {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: "provider_failed",
    };
  }
  throw new BytePlusProviderError("provider_status_invalid", {
    retryable: true,
  });
}

export function extractBytePlusVideo(payload) {
  const url = String(payload?.content?.video_url || "");
  if (!/^https:\/\//i.test(url)) {
    throw new BytePlusProviderError("provider_result_invalid", {
      retryable: true,
    });
  }
  return { url, mimeType: "video/mp4", byteLength: 0 };
}
