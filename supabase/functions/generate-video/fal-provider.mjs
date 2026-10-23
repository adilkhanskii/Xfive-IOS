const FAL_QUEUE_ROOT = "https://queue.fal.run";
const TEXT_MODEL = "fal-ai/kling-video/v3/standard/text-to-video";
const IMAGE_MODEL = "fal-ai/kling-video/v3/standard/image-to-video";
const SEEDANCE_TEXT_MODEL = "fal-ai/bytedance/seedance/v1.5/pro/text-to-video";
const SEEDANCE_IMAGE_MODEL =
  "fal-ai/bytedance/seedance/v1.5/pro/image-to-video";
const SEEDANCE_MODEL = "seedance-1.5-pro";
const SEEDANCE_RESOLUTIONS = new Set(["480p", "720p", "1080p"]);
const NEGATIVE_PROMPT =
  "blur, distort, low quality, explicit sexual content, gore";
const SAFE_FALLBACK_HTTP_STATUSES = new Set([429]);

export class FalProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "FalProviderError";
    this.code = code;
    const normalized = typeof options === "boolean"
      ? { retryable: options }
      : options;
    this.retryable = normalized.retryable !== false;
    this.safeToFallback = normalized.safeToFallback === true;
    this.submissionAmbiguous = normalized.submissionAmbiguous === true;
    this.httpStatus = Number.isInteger(normalized.httpStatus)
      ? normalized.httpStatus
      : null;
  }
}

export class FalKlingProvider {
  constructor({ apiKey, fetchImpl = fetch }) {
    if (!apiKey || typeof apiKey !== "string") {
      throw new FalProviderError("provider_not_configured", {
        retryable: false,
      });
    }
    this.apiKey = apiKey;
    this.fetchImpl = fetchImpl;
  }

  async submit({
    model = "auto",
    prompt,
    aspectRatio,
    durationSeconds,
    resolution = "720p",
    generateAudio = false,
    startImageUrl,
    webhookUrl,
  }) {
    if (!["auto", SEEDANCE_MODEL].includes(model)) {
      throw new FalProviderError("provider_model_invalid", {
        retryable: false,
      });
    }
    if (model === SEEDANCE_MODEL && !SEEDANCE_RESOLUTIONS.has(resolution)) {
      throw new FalProviderError("provider_resolution_invalid", {
        retryable: false,
      });
    }
    if (typeof generateAudio !== "boolean") {
      throw new FalProviderError("provider_audio_invalid", {
        retryable: false,
      });
    }

    const endpoint = modelForKind(
      startImageUrl ? "image" : "text",
      model,
    );
    const url = new URL(`${FAL_QUEUE_ROOT}/${endpoint}`);
    if (webhookUrl) url.searchParams.set("fal_webhook", webhookUrl);

    const body = model === SEEDANCE_MODEL
      ? {
        prompt,
        aspect_ratio: aspectRatio,
        resolution,
        duration: String(durationSeconds),
        enable_safety_checker: true,
        generate_audio: generateAudio,
        ...(startImageUrl ? { image_url: startImageUrl } : {}),
      }
      : {
        prompt,
        duration: String(durationSeconds),
        generate_audio: false,
        shot_type: "customize",
        ...(startImageUrl
          ? { start_image_url: startImageUrl }
          : { aspect_ratio: aspectRatio }),
        negative_prompt: NEGATIVE_PROMPT,
        cfg_scale: 0.5,
      };
    let response;
    try {
      response = await this.fetchImpl(url, {
        method: "POST",
        headers: this.#headers(),
        body: JSON.stringify(body),
      });
    } catch {
      // A network error does not prove whether fal accepted the request.
      // Starting another provider could therefore create duplicate videos.
      throw new FalProviderError("provider_transport_ambiguous", {
        retryable: true,
        safeToFallback: false,
        submissionAmbiguous: true,
      });
    }
    const payload = await response.json().catch(() => ({}));
    const requestId = String(payload?.request_id || "");
    if (!response.ok) {
      const safeToFallback = SAFE_FALLBACK_HTTP_STATUSES.has(response.status);
      const submissionAmbiguous = response.status === 408 ||
        response.status >= 500;
      throw new FalProviderError(
        response.status >= 400 && response.status < 500
          ? "provider_rejected"
          : "provider_unavailable",
        {
          retryable: safeToFallback || submissionAmbiguous,
          safeToFallback,
          submissionAmbiguous,
          httpStatus: response.status,
        },
      );
    }
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(requestId)) {
      throw new FalProviderError("provider_response_ambiguous", {
        retryable: true,
        safeToFallback: false,
        submissionAmbiguous: true,
        httpStatus: response.status,
      });
    }
    return {
      requestId,
      kind: startImageUrl ? "image" : "text",
    };
  }

  async status({ requestId, kind }) {
    const response = await this.#fetchQueueResource({
      requestId,
      kind,
      suffix: "/status",
    });
    return mapFalQueueStatus(await response.json().catch(() => ({})));
  }

  async result({ requestId, kind }) {
    const response = await this.#fetchQueueResource({
      requestId,
      kind,
      suffix: "",
    });
    return extractFalVideo(await response.json().catch(() => ({})));
  }

  async #fetchQueueResource({ requestId, kind, suffix }) {
    const models = modelCandidatesForKind(kind);
    for (let index = 0; index < models.length; index += 1) {
      const response = await this.fetchImpl(
        `${FAL_QUEUE_ROOT}/${models[index]}/requests/${
          encodeURIComponent(requestId)
        }${suffix}`,
        { headers: this.#headers(false) },
      );
      if (response.ok) return response;
      if (response.status !== 404 || index === models.length - 1) {
        throw new FalProviderError("provider_unavailable", {
          retryable: true,
          httpStatus: response.status,
        });
      }
    }
    throw new FalProviderError("provider_unavailable", { retryable: true });
  }

  #headers(withContentType = true) {
    return {
      "Authorization": `Key ${this.apiKey}`,
      ...(withContentType ? { "Content-Type": "application/json" } : {}),
    };
  }
}

export function mapFalQueueStatus(payload) {
  const status = String(payload?.status || "").toUpperCase();
  if (status === "IN_QUEUE") {
    return { status: "queued", progress: 0.05, completed: false };
  }
  if (status === "IN_PROGRESS") {
    return { status: "rendering", progress: 0.5, completed: false };
  }
  if (status === "COMPLETED" && (payload?.error || payload?.error_type)) {
    return {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: "provider_failed",
    };
  }
  if (status === "COMPLETED") {
    return { status: "completed", progress: 0.9, completed: true };
  }
  throw new FalProviderError("provider_status_invalid", { retryable: true });
}

export function extractFalVideo(payload) {
  const video = payload?.video;
  const url = String(video?.url || "");
  const mimeType = String(video?.content_type || "video/mp4").toLowerCase();
  const byteLength = Number(video?.file_size || 0);
  if (
    !/^https:\/\//i.test(url) ||
    mimeType !== "video/mp4" ||
    !Number.isFinite(byteLength) ||
    byteLength < 0
  ) {
    throw new FalProviderError("provider_result_invalid", { retryable: true });
  }
  return { url, mimeType, byteLength };
}

export function falModelKindFromStartImage(hasStartImage) {
  return hasStartImage ? "image" : "text";
}

function modelForKind(kind, model = "auto") {
  if (kind === "image") {
    return model === SEEDANCE_MODEL ? SEEDANCE_IMAGE_MODEL : IMAGE_MODEL;
  }
  if (kind === "text") {
    return model === SEEDANCE_MODEL ? SEEDANCE_TEXT_MODEL : TEXT_MODEL;
  }
  throw new FalProviderError("provider_model_invalid", { retryable: false });
}

function modelCandidatesForKind(kind) {
  return [
    modelForKind(kind, "auto"),
    modelForKind(kind, SEEDANCE_MODEL),
  ];
}
