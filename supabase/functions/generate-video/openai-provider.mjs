import { MAX_START_IMAGE_BYTES, MAX_VIDEO_RESULT_BYTES } from "./contract.mjs";

const OPENAI_VIDEOS_ROOT = "https://api.openai.com/v1/videos";
const OPENAI_VIDEO_MODEL = "sora-2";
const MAX_OPENAI_JSON_BYTES = 1024 * 1024;
const MAX_INPUT_REFERENCE_URL_LENGTH = 16 * 1024;
const VIDEO_ID_PATTERN = /^video_[A-Za-z0-9_-]{6,194}$/;
const IMAGE_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
]);

export class OpenAIProviderError extends Error {
  constructor(code, options = {}) {
    super(code);
    this.name = "OpenAIProviderError";
    this.code = code;
    const normalized = typeof options === "boolean"
      ? { retryable: options }
      : options;
    this.retryable = normalized.retryable === true;
    this.safeToFallback = normalized.safeToFallback === true;
    this.submissionAmbiguous = normalized.submissionAmbiguous === true;
    this.providerStatus = Number.isInteger(normalized.providerStatus)
      ? normalized.providerStatus
      : null;
    this.providerCode = safeProviderCode(normalized.providerCode);
  }
}

export class OpenAIVideoProvider {
  constructor({ apiKey, fetchImpl = fetch } = {}) {
    const normalizedKey = String(apiKey || "").trim();
    if (!normalizedKey) {
      throw new OpenAIProviderError("provider_not_configured", {
        retryable: false,
      });
    }
    this.apiKey = normalizedKey;
    this.fetchImpl = fetchImpl;
  }

  async submit({
    prompt,
    aspectRatio,
    durationSeconds,
    startImage = null,
    startImageUrl = null,
  }) {
    const inputReference = normalizeInputReference({
      startImage,
      startImageUrl,
    });
    const body = {
      model: OPENAI_VIDEO_MODEL,
      prompt: String(prompt || ""),
      seconds: mapOpenAIVideoDuration(durationSeconds),
      size: mapOpenAIVideoSize(aspectRatio),
      ...(inputReference
        ? { input_reference: { image_url: inputReference } }
        : {}),
    };

    let response;
    try {
      response = await this.fetchImpl(OPENAI_VIDEOS_ROOT, {
        method: "POST",
        headers: this.#headers(true),
        body: JSON.stringify(body),
      });
    } catch {
      throw new OpenAIProviderError("provider_transport_ambiguous", {
        retryable: true,
        safeToFallback: false,
        submissionAmbiguous: true,
      });
    }

    const ambiguous = response.status === 408 || response.status >= 500;
    let payload;
    try {
      payload = await readBoundedOpenAIJson(response, {
        submissionAmbiguous: response.ok || ambiguous,
      });
    } catch (error) {
      if (error instanceof OpenAIProviderError) {
        throw withResponseDiagnostics(error, response.status, {
          safeToFallback: definitiveSubmitFallbackIsSafe(
            response.status,
            error.providerCode,
          ),
        });
      }
      throw error;
    }
    const providerCode = payload?.error?.code || payload?.error?.type;

    if (!response.ok) {
      if (response.status === 429) {
        throw new OpenAIProviderError("provider_rate_limited", {
          retryable: true,
          safeToFallback: true,
          providerStatus: response.status,
          providerCode,
        });
      }
      throw new OpenAIProviderError(
        ambiguous ? "provider_unavailable" : "provider_rejected",
        {
          retryable: ambiguous,
          safeToFallback: !ambiguous &&
            definitiveSubmitFallbackIsSafe(response.status, providerCode),
          submissionAmbiguous: ambiguous,
          providerStatus: response.status,
          providerCode,
        },
      );
    }

    const requestId = String(payload?.id || "");
    if (!VIDEO_ID_PATTERN.test(requestId)) {
      throw new OpenAIProviderError("provider_response_ambiguous", {
        retryable: true,
        safeToFallback: false,
        submissionAmbiguous: true,
        providerStatus: response.status,
      });
    }
    const mapped = mapOpenAIVideoStatus(payload);
    return {
      requestId,
      kind: inputReference ? "image" : "text",
      status: mapped.status,
    };
  }

  async status({ requestId }) {
    const normalizedId = normalizeVideoId(requestId);
    let response;
    try {
      response = await this.fetchImpl(
        `${OPENAI_VIDEOS_ROOT}/${encodeURIComponent(normalizedId)}`,
        { headers: this.#headers(false) },
      );
    } catch {
      throw new OpenAIProviderError("provider_unavailable", {
        retryable: true,
      });
    }

    let payload;
    try {
      payload = await readBoundedOpenAIJson(response);
    } catch (error) {
      if (error instanceof OpenAIProviderError) {
        throw withResponseDiagnostics(error, response.status);
      }
      throw error;
    }
    if (!response.ok) {
      const retryable = response.status === 408 ||
        response.status === 429 ||
        response.status >= 500;
      throw new OpenAIProviderError(
        retryable ? "provider_unavailable" : "provider_rejected",
        {
          retryable,
          providerStatus: response.status,
          providerCode: payload?.error?.code || payload?.error?.type,
        },
      );
    }
    if (payload?.id && payload.id !== normalizedId) {
      throw new OpenAIProviderError("provider_response_invalid", {
        retryable: true,
        providerStatus: response.status,
      });
    }
    return mapOpenAIVideoStatus(payload);
  }

  async result({ requestId }) {
    const normalizedId = normalizeVideoId(requestId);
    const current = await this.status({ requestId: normalizedId });
    if (current.status !== "completed") {
      throw new OpenAIProviderError("provider_result_not_ready", {
        retryable: current.status !== "failed",
      });
    }
    const dataBytes = await this.download({ requestId: normalizedId });
    return {
      dataBytes,
      mimeType: "video/mp4",
      byteLength: dataBytes.byteLength,
    };
  }

  async download({ requestId }) {
    const normalizedId = normalizeVideoId(requestId);
    let response;
    try {
      response = await this.fetchImpl(
        `${OPENAI_VIDEOS_ROOT}/${encodeURIComponent(normalizedId)}/content`,
        {
          headers: this.#headers(false),
          redirect: "follow",
        },
      );
    } catch {
      throw new OpenAIProviderError("provider_result_unavailable", {
        retryable: true,
      });
    }

    if (!response.ok) {
      const retryable = response.status === 408 ||
        response.status === 429 ||
        response.status >= 500;
      throw new OpenAIProviderError("provider_result_unavailable", {
        retryable,
        providerStatus: response.status,
      });
    }
    const contentType = String(
      response.headers.get("Content-Type") || "",
    ).toLowerCase();
    if (!/^video\/mp4(?:\s*;|$)/.test(contentType)) {
      throw new OpenAIProviderError("provider_result_invalid", {
        retryable: true,
        providerStatus: response.status,
      });
    }
    const declaredLength = parseContentLength(
      response.headers.get("Content-Length"),
    );
    if (declaredLength > MAX_VIDEO_RESULT_BYTES) {
      await response.body?.cancel().catch(() => null);
      throw new OpenAIProviderError("provider_result_too_large", {
        retryable: false,
        providerStatus: response.status,
      });
    }
    const dataBytes = await readResponseBodyBounded(
      response,
      MAX_VIDEO_RESULT_BYTES,
    );
    if (
      dataBytes.byteLength < 12 ||
      String.fromCharCode(...dataBytes.subarray(4, 8)) !== "ftyp"
    ) {
      throw new OpenAIProviderError("provider_result_invalid", {
        retryable: true,
        providerStatus: response.status,
      });
    }
    return dataBytes;
  }

  #headers(withContentType) {
    return {
      "Authorization": `Bearer ${this.apiKey}`,
      ...(withContentType ? { "Content-Type": "application/json" } : {}),
    };
  }
}

export function mapOpenAIVideoDuration(durationSeconds) {
  if (durationSeconds === 5) return "4";
  if (durationSeconds === 10) return "8";
  throw new OpenAIProviderError("unsupported_duration", {
    retryable: false,
  });
}

export function mapOpenAIVideoSize(aspectRatio) {
  if (aspectRatio === "9:16") return "720x1280";
  if (aspectRatio === "16:9") return "1280x720";
  throw new OpenAIProviderError("unsupported_aspect_ratio", {
    retryable: false,
  });
}

export function mapOpenAIVideoStatus(payload) {
  const status = String(payload?.status || "").trim().toLowerCase();
  if (["queued", "pending"].includes(status)) {
    return { status: "queued", progress: 0.05, completed: false };
  }
  if (["in_progress", "running"].includes(status)) {
    const rawProgress = Number(payload?.progress);
    const progress = Number.isFinite(rawProgress)
      ? Math.max(0.05, Math.min(0.9, rawProgress / 100))
      : 0.5;
    return { status: "rendering", progress, completed: false };
  }
  if (status === "completed") {
    return { status: "completed", progress: 0.9, completed: true };
  }
  if (["failed", "cancelled", "canceled", "expired"].includes(status)) {
    return {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: "provider_failed",
    };
  }
  throw new OpenAIProviderError("provider_status_invalid", {
    retryable: true,
  });
}

function normalizeInputReference({ startImage, startImageUrl }) {
  if (startImage && startImageUrl) {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  if (startImage) {
    const mimeType = normalizeImageMimeType(startImage.mimeType);
    const base64 = normalizeImageBase64(startImage.dataBase64);
    return `data:${mimeType};base64,${base64}`;
  }

  const rawUrl = String(startImageUrl || "").trim();
  if (!rawUrl) return null;
  if (/^data:/i.test(rawUrl)) {
    const match = rawUrl.match(
      /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/]*={0,2})$/i,
    );
    if (!match) {
      throw new OpenAIProviderError("unsupported_start_image", {
        retryable: false,
      });
    }
    const mimeType = normalizeImageMimeType(match[1]);
    const base64 = normalizeImageBase64(match[2]);
    return `data:${mimeType};base64,${base64}`;
  }
  if (rawUrl.length > MAX_INPUT_REFERENCE_URL_LENGTH) {
    throw new OpenAIProviderError("start_image_too_large", {
      retryable: false,
    });
  }

  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  if (
    parsed.protocol !== "https:" ||
    parsed.username ||
    parsed.password ||
    !parsed.hostname
  ) {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  return parsed.toString();
}

function normalizeImageMimeType(value) {
  const mimeType = String(value || "").trim().toLowerCase()
    .replace("image/jpg", "image/jpeg");
  if (!IMAGE_MIME_TYPES.has(mimeType)) {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  return mimeType;
}

function normalizeImageBase64(value) {
  const normalized = String(value || "").trim().replace(/\s+/g, "");
  if (
    !normalized ||
    normalized.length % 4 === 1 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(normalized)
  ) {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  const byteLength = decodedBase64ByteLength(normalized);
  if (byteLength <= 0) {
    throw new OpenAIProviderError("unsupported_start_image", {
      retryable: false,
    });
  }
  if (byteLength > MAX_START_IMAGE_BYTES) {
    throw new OpenAIProviderError("start_image_too_large", {
      retryable: false,
    });
  }
  return normalized;
}

function decodedBase64ByteLength(value) {
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return Math.floor((value.length * 3) / 4) - padding;
}

function normalizeVideoId(value) {
  const requestId = String(value || "").trim();
  if (!VIDEO_ID_PATTERN.test(requestId)) {
    throw new OpenAIProviderError("provider_request_id_invalid", {
      retryable: false,
    });
  }
  return requestId;
}

function safeProviderCode(value) {
  const code = String(value || "").trim().toUpperCase();
  return /^[A-Z][A-Z0-9_]{1,79}$/.test(code) ? code : null;
}

function definitiveSubmitFallbackIsSafe(status, providerCode) {
  const normalizedCode = safeProviderCode(providerCode);
  if (normalizedCode && /(CONTENT|SAFETY|POLICY)/.test(normalizedCode)) {
    return false;
  }
  return [401, 403, 404, 429].includes(status);
}

function withResponseDiagnostics(error, providerStatus, overrides = {}) {
  return new OpenAIProviderError(error.code, {
    retryable: error.retryable,
    safeToFallback: overrides.safeToFallback ?? error.safeToFallback,
    submissionAmbiguous: error.submissionAmbiguous,
    providerStatus,
    providerCode: error.providerCode,
  });
}

function parseContentLength(value) {
  if (value == null || value === "") return 0;
  if (!/^\d+$/.test(value)) {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: true,
    });
  }
  const length = Number(value);
  if (!Number.isSafeInteger(length) || length < 0) {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: true,
    });
  }
  return length;
}

async function readBoundedOpenAIJson(
  response,
  { submissionAmbiguous = false } = {},
) {
  const contentType = String(
    response.headers.get("Content-Type") || "",
  ).toLowerCase();
  if (
    !/^application\/(?:[a-z0-9.+-]*\+)?json(?:\s*;|$)/.test(contentType)
  ) {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: submissionAmbiguous,
      submissionAmbiguous,
    });
  }
  const declaredLength = parseContentLength(
    response.headers.get("Content-Length"),
  );
  if (declaredLength > MAX_OPENAI_JSON_BYTES) {
    await response.body?.cancel().catch(() => null);
    throw new OpenAIProviderError("provider_response_too_large", {
      retryable: submissionAmbiguous,
      submissionAmbiguous,
    });
  }
  const bytes = await readResponseBodyBounded(
    response,
    MAX_OPENAI_JSON_BYTES,
    {
      tooLargeCode: "provider_response_too_large",
      retryable: submissionAmbiguous,
      submissionAmbiguous,
    },
  );
  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: submissionAmbiguous,
      submissionAmbiguous,
    });
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: submissionAmbiguous,
      submissionAmbiguous,
    });
  }
  return payload;
}

async function readResponseBodyBounded(
  response,
  maxBytes,
  {
    tooLargeCode = "provider_result_too_large",
    retryable = false,
    submissionAmbiguous = false,
  } = {},
) {
  if (!response.body) {
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable,
      submissionAmbiguous,
    });
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = value instanceof Uint8Array
        ? value
        : new Uint8Array(value || []);
      total += chunk.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => null);
        throw new OpenAIProviderError(tooLargeCode, {
          retryable,
          submissionAmbiguous,
        });
      }
      chunks.push(chunk);
    }
  } catch (error) {
    if (error instanceof OpenAIProviderError) throw error;
    throw new OpenAIProviderError("provider_response_invalid", {
      retryable: true,
      submissionAmbiguous,
    });
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}
