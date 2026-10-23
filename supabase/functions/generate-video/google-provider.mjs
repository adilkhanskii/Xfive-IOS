import { MAX_VIDEO_RESULT_BYTES } from "./contract.mjs";

const GOOGLE_INTERACTIONS_URL =
  "https://generativelanguage.googleapis.com/v1beta/interactions";
const GOOGLE_MODEL = "gemini-omni-flash-preview";
const MAX_GOOGLE_JSON_BYTES = 1024 * 1024;
const MAX_GOOGLE_INLINE_VIDEO_BASE64_BYTES =
  Math.ceil(MAX_VIDEO_RESULT_BYTES / 3) * 4;
const MAX_GOOGLE_INTERACTION_RESPONSE_BYTES =
  MAX_GOOGLE_INLINE_VIDEO_BASE64_BYTES + MAX_GOOGLE_JSON_BYTES;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CLAIM_TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,200}$/;

export class GoogleProviderError extends Error {
  constructor(code, options = true) {
    super(code);
    this.name = "GoogleProviderError";
    this.code = code;
    const normalized = typeof options === "boolean"
      ? { retryable: options }
      : options;
    this.retryable = normalized.retryable !== false;
    this.submissionAmbiguous = normalized.submissionAmbiguous === true;
    this.providerStatus = Number.isInteger(normalized.providerStatus)
      ? normalized.providerStatus
      : null;
    this.providerCode = safeProviderCode(normalized.providerCode);
  }
}

export class GoogleGeminiVideoProvider {
  constructor({ apiKey, fetchImpl = fetch }) {
    if (!apiKey || typeof apiKey !== "string") {
      throw new GoogleProviderError("provider_not_configured", false);
    }
    this.apiKey = apiKey;
    this.fetchImpl = fetchImpl;
  }

  async submit({
    prompt,
    aspectRatio,
    durationSeconds,
    startImage,
    webhookUrl,
    webhookMetadata,
  }) {
    if (!["16:9", "9:16"].includes(aspectRatio)) {
      throw new GoogleProviderError("unsupported_aspect_ratio", {
        retryable: false,
      });
    }
    const body = {
      model: GOOGLE_MODEL,
      input: startImage
        ? [
          {
            type: "image",
            data: startImage.dataBase64,
            mime_type: startImage.mimeType,
          },
          { type: "text", text: prompt },
        ]
        : prompt,
      response_format: {
        type: "video",
        delivery: "uri",
        aspect_ratio: aspectRatio,
        duration: `${durationSeconds}s`,
      },
      background: true,
      store: true,
      stream: false,
      ...(buildWebhookConfig(webhookUrl, webhookMetadata)),
    };
    let response;
    try {
      response = await this.fetchImpl(GOOGLE_INTERACTIONS_URL, {
        method: "POST",
        headers: this.#headers(),
        body: JSON.stringify(body),
      });
    } catch {
      throw new GoogleProviderError("provider_transport_ambiguous", {
        retryable: true,
        submissionAmbiguous: true,
      });
    }
    const ambiguousStatus = response.status === 408 ||
      response.status >= 500;
    let payload;
    try {
      payload = await readBoundedGoogleJson(response, {
        submissionAmbiguous: ambiguousStatus || response.ok,
      });
    } catch (error) {
      if (
        error instanceof GoogleProviderError &&
        !Number.isInteger(error.providerStatus)
      ) {
        throw new GoogleProviderError(error.code, {
          retryable: error.retryable,
          submissionAmbiguous: error.submissionAmbiguous,
          providerStatus: response.status,
          providerCode: error.providerCode,
        });
      }
      throw error;
    }
    const requestId = String(payload?.id || "");
    if (!response.ok) {
      const diagnostics = {
        providerStatus: response.status,
        providerCode: payload?.error?.status,
      };
      if (response.status === 429) {
        throw new GoogleProviderError("provider_rate_limited", {
          retryable: true,
          submissionAmbiguous: false,
          ...diagnostics,
        });
      }
      throw new GoogleProviderError(
        response.status >= 400 && response.status < 500 && !ambiguousStatus
          ? "provider_rejected"
          : "provider_unavailable",
        {
          retryable: ambiguousStatus,
          submissionAmbiguous: ambiguousStatus,
          ...diagnostics,
        },
      );
    }
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(requestId)) {
      throw new GoogleProviderError("provider_response_ambiguous", {
        retryable: true,
        submissionAmbiguous: true,
      });
    }
    const mapped = mapGoogleInteractionStatus(payload, {
      allowMissingResult: true,
    });
    return {
      requestId,
      kind: startImage ? "image" : "text",
      status: mapped.status,
      ...(mapped.result ? { result: mapped.result } : {}),
    };
  }

  async status({ requestId }) {
    const response = await this.fetchImpl(
      `${GOOGLE_INTERACTIONS_URL}/${encodeURIComponent(requestId)}`,
      { headers: this.#headers(false) },
    );
    if (!response.ok) {
      throw new GoogleProviderError("provider_unavailable", true);
    }
    let payload;
    try {
      payload = await readGoogleInteractionStatus(response);
    } catch (error) {
      if (
        error instanceof GoogleProviderError &&
        ["provider_result_invalid", "provider_result_too_large"].includes(
          error.code,
        )
      ) {
        return {
          status: "failed",
          progress: 1,
          completed: true,
          errorCode: error.code,
        };
      }
      throw error;
    }
    const mapped = mapGoogleInteractionStatus(payload);
    if (mapped.status !== "completed" || !mapped.result?.url) return mapped;

    const fileName = extractGoogleFileName(mapped.result.url);
    if (!fileName) return mapped;
    const fileResponse = await this.fetchImpl(
      `https://generativelanguage.googleapis.com/v1beta/${fileName}`,
      { headers: this.#headers(false) },
    );
    if (!fileResponse.ok) {
      throw new GoogleProviderError("provider_unavailable", true);
    }
    const file = await readBoundedGoogleJson(fileResponse);
    const state = String(file?.state?.name || file?.state || "").toUpperCase();
    if (state === "FAILED") {
      return {
        status: "failed",
        progress: 1,
        completed: true,
        errorCode: "provider_failed",
      };
    }
    if (state && state !== "ACTIVE") {
      return { status: "rendering", progress: 0.8, completed: false };
    }
    return mapped;
  }

  async result({ requestId }) {
    const status = await this.status({ requestId });
    if (status.status !== "completed" || !status.result) {
      throw new GoogleProviderError("provider_result_not_ready", true);
    }
    return status.result;
  }

  async download(result) {
    if (result?.dataBytes instanceof Uint8Array) {
      return result.dataBytes;
    }
    if (result?.dataBase64) {
      return decodeBase64(result.dataBase64);
    }
    if (!/^https:\/\//i.test(String(result?.url || ""))) {
      throw new GoogleProviderError("provider_result_invalid", true);
    }
    const response = await this.fetchImpl(result.url, {
      headers: this.#headers(false),
      redirect: "follow",
    });
    if (!response.ok) {
      throw new GoogleProviderError("provider_result_unavailable", true);
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  #headers(withContentType = true) {
    return {
      "x-goog-api-key": this.apiKey,
      ...(withContentType ? { "Content-Type": "application/json" } : {}),
    };
  }
}

function safeProviderCode(value) {
  const code = String(value || "").trim().toUpperCase();
  return /^[A-Z][A-Z0-9_]{1,79}$/.test(code) ? code : null;
}

export function mapGoogleInteractionStatus(
  payload,
  { allowMissingResult = false } = {},
) {
  const status = String(payload?.status || "").toLowerCase();
  if (["queued", "pending"].includes(status)) {
    return { status: "queued", progress: 0.05, completed: false };
  }
  if (["in_progress", "running"].includes(status)) {
    return { status: "rendering", progress: 0.5, completed: false };
  }
  if (["failed", "cancelled", "timed_out", "incomplete"].includes(status)) {
    return {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: status === "incomplete"
        ? "provider_incomplete"
        : "provider_failed",
    };
  }
  if (status === "completed") {
    const result = extractGoogleVideo(payload);
    if (!result && !allowMissingResult) {
      throw new GoogleProviderError("provider_result_invalid", true);
    }
    return {
      status: "completed",
      progress: 0.9,
      completed: true,
      ...(result ? { result } : {}),
    };
  }
  throw new GoogleProviderError("provider_status_invalid", true);
}

export function extractGoogleVideo(payload) {
  const direct = payload?.output_video;
  const stepVideos = Array.isArray(payload?.steps)
    ? payload.steps.flatMap((step) =>
      Array.isArray(step?.content) ? step.content : []
    )
    : [];
  const video = direct ||
    stepVideos.find((part) => part?.type === "video") ||
    null;
  const mimeType = String(video?.mime_type || "video/mp4").toLowerCase();
  if (mimeType !== "video/mp4") return null;
  if (
    video?.dataBytes instanceof Uint8Array &&
    video.dataBytes.byteLength > 0 &&
    video.dataBytes.byteLength <= MAX_VIDEO_RESULT_BYTES
  ) {
    return { dataBytes: video.dataBytes, mimeType };
  }
  if (/^https:\/\//i.test(String(video?.uri || ""))) {
    return { url: String(video.uri), mimeType };
  }
  const dataBase64 = String(video?.data || "");
  if (dataBase64 && /^[A-Za-z0-9+/]*={0,2}$/.test(dataBase64)) {
    return { dataBase64, mimeType };
  }
  return null;
}

function extractGoogleFileName(url) {
  const match = String(url).match(/\/v1beta\/(files\/[A-Za-z0-9_-]+)/);
  return match?.[1] || null;
}

function decodeBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function buildWebhookConfig(webhookUrl, webhookMetadata) {
  const url = String(webhookUrl || "");
  const jobId = String(webhookMetadata?.job_id || "");
  const claimToken = String(webhookMetadata?.claim_token || "");
  if (
    !/^https:\/\/[^\s]{1,500}$/.test(url) ||
    !UUID_PATTERN.test(jobId) ||
    !CLAIM_TOKEN_PATTERN.test(claimToken)
  ) {
    throw new GoogleProviderError("provider_webhook_invalid", {
      retryable: false,
    });
  }
  return {
    webhook_config: {
      uris: [url],
      user_metadata: {
        job_id: jobId,
        claim_token: claimToken,
      },
    },
  };
}

async function readGoogleInteractionStatus(response) {
  const contentLength = response.headers.get("Content-Length");
  if (contentLength && !/^\d{1,20}$/.test(contentLength)) {
    throw new GoogleProviderError("provider_response_invalid", true);
  }
  if (
    contentLength &&
    Number(contentLength) > MAX_GOOGLE_INTERACTION_RESPONSE_BYTES
  ) {
    throw new GoogleProviderError("provider_result_too_large", {
      retryable: false,
    });
  }
  if (!response.body) {
    throw new GoogleProviderError("provider_response_invalid", true);
  }

  const parser = new GoogleInteractionJsonParser();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const reader = response.body.getReader();
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_GOOGLE_INTERACTION_RESPONSE_BYTES) {
        await reader.cancel().catch(() => null);
        throw new GoogleProviderError("provider_result_too_large", {
          retryable: false,
        });
      }
      parser.push(decoder.decode(value, { stream: true }));
      if (
        totalBytes - parser.inlineEncodedCharacters >
          MAX_GOOGLE_JSON_BYTES
      ) {
        await reader.cancel().catch(() => null);
        throw new GoogleProviderError("provider_response_too_large", true);
      }
    }
    parser.push(decoder.decode());
    return parser.finish();
  } catch (error) {
    if (error instanceof GoogleProviderError) throw error;
    throw new GoogleProviderError("provider_response_invalid", true);
  } finally {
    reader.releaseLock();
  }
}

class GoogleInteractionJsonParser {
  constructor() {
    this.stack = [];
    this.mode = "default";
    this.rootState = "value";
    this.rootObjectSeen = false;
    this.stringInfo = null;
    this.stringRaw = "";
    this.stringEscape = false;
    this.stringUnicodeRemaining = 0;
    this.primitiveInfo = null;
    this.primitiveRaw = "";
    this.status = "";
    this.video = null;
    this.inlineEncodedCharacters = 0;
  }

  push(input) {
    let index = 0;
    while (index < input.length) {
      const character = input[index];
      if (this.mode === "string") {
        this.#pushStringCharacter(character);
        index += 1;
        continue;
      }
      if (this.mode === "primitive") {
        if (/[\s,\]}]/.test(character)) {
          this.#finishPrimitive();
          continue;
        }
        if (this.primitiveRaw.length >= 64) {
          throw new Error("json_primitive_too_large");
        }
        this.primitiveRaw += character;
        index += 1;
        continue;
      }
      if (/\s/.test(character)) {
        index += 1;
        continue;
      }
      if (character === '"') {
        this.#startString();
        index += 1;
        continue;
      }
      if (character === "{") {
        const value = this.#beginValue();
        this.stack.push({
          type: "object",
          state: "keyOrEnd",
          pendingKey: null,
          relationKey: value.key,
          fields: {},
        });
        if (this.stack.length === 1) this.rootObjectSeen = true;
        index += 1;
        continue;
      }
      if (character === "[") {
        const value = this.#beginValue();
        this.stack.push({
          type: "array",
          state: "valueOrEnd",
          relationKey: value.key,
        });
        index += 1;
        continue;
      }
      if (character === "}") {
        this.#closeContainer("object");
        index += 1;
        continue;
      }
      if (character === "]") {
        this.#closeContainer("array");
        index += 1;
        continue;
      }
      if (character === ":") {
        const context = this.#top();
        if (context?.type !== "object" || context.state !== "colon") {
          throw new Error("json_colon_invalid");
        }
        context.state = "value";
        index += 1;
        continue;
      }
      if (character === ",") {
        const context = this.#top();
        if (!context || context.state !== "commaOrEnd") {
          throw new Error("json_comma_invalid");
        }
        context.state = context.type === "object" ? "key" : "value";
        index += 1;
        continue;
      }
      this.primitiveInfo = this.#beginValue();
      this.primitiveRaw = character;
      this.mode = "primitive";
      index += 1;
    }
  }

  finish() {
    if (this.mode === "primitive") this.#finishPrimitive();
    if (
      this.mode !== "default" ||
      this.stack.length !== 0 ||
      this.rootState !== "complete" ||
      !this.rootObjectSeen
    ) {
      throw new Error("json_incomplete");
    }
    return {
      status: this.status,
      ...(this.video
        ? {
          output_video: {
            mime_type: this.video.mimeType,
            ...(this.video.dataBytes
              ? { dataBytes: this.video.dataBytes }
              : { uri: this.video.url }),
          },
        }
        : {}),
    };
  }

  #top() {
    return this.stack[this.stack.length - 1] || null;
  }

  #beginValue() {
    const context = this.#top();
    if (!context) {
      if (this.rootState !== "value") {
        throw new Error("json_root_value_invalid");
      }
      this.rootState = "pending";
      return { context: null, key: null };
    }
    if (context.type === "object") {
      if (context.state !== "value" || !context.pendingKey) {
        throw new Error("json_object_value_invalid");
      }
      const key = context.pendingKey;
      context.pendingKey = null;
      context.state = "commaOrEnd";
      return { context, key };
    }
    if (!["value", "valueOrEnd"].includes(context.state)) {
      throw new Error("json_array_value_invalid");
    }
    context.state = "commaOrEnd";
    return { context, key: null };
  }

  #finishScalar(value) {
    const { context, key } = value;
    if (!context) this.rootState = "complete";
    return { context, key };
  }

  #startString() {
    const context = this.#top();
    if (
      context?.type === "object" &&
      ["key", "keyOrEnd"].includes(context.state)
    ) {
      this.stringInfo = { role: "key", context, capture: "key" };
    } else {
      const value = this.#beginValue();
      const key = value.key;
      let capture = "discard";
      if (value.context?.type === "object") {
        if (
          key === "data" &&
          (
            value.context.relationKey === "output_video" ||
            value.context.fields.type === "video"
          )
        ) {
          capture = "inlineVideo";
        } else if (
          ["status", "type", "mime_type", "uri", "download_uri"].includes(
            key,
          )
        ) {
          capture = "field";
        }
      }
      this.stringInfo = {
        role: "value",
        context: value.context,
        key,
        capture,
        ...(capture === "inlineVideo"
          ? { collector: new BoundedBase64VideoCollector() }
          : {}),
      };
    }
    this.stringRaw = "";
    this.stringEscape = false;
    this.stringUnicodeRemaining = 0;
    this.mode = "string";
  }

  #pushStringCharacter(character) {
    const info = this.stringInfo;
    if (info.capture === "inlineVideo") {
      if (character === '"') {
        const dataBytes = info.collector.finish();
        info.context.fields.dataBytes = dataBytes;
        this.#finishScalar(info);
        this.#resetString();
        return;
      }
      if (character === "\\" || character.charCodeAt(0) < 0x20) {
        throw new GoogleProviderError("provider_result_invalid", {
          retryable: false,
        });
      }
      info.collector.push(character);
      this.inlineEncodedCharacters += 1;
      return;
    }

    if (this.stringUnicodeRemaining > 0) {
      if (!/[0-9a-f]/i.test(character)) {
        throw new Error("json_unicode_escape_invalid");
      }
      this.#captureStringCharacter(character);
      this.stringUnicodeRemaining -= 1;
      return;
    }
    if (this.stringEscape) {
      if (!/["\\/bfnrtu]/.test(character)) {
        throw new Error("json_escape_invalid");
      }
      this.#captureStringCharacter(character);
      this.stringEscape = false;
      if (character === "u") this.stringUnicodeRemaining = 4;
      return;
    }
    if (character === "\\") {
      this.#captureStringCharacter(character);
      this.stringEscape = true;
      return;
    }
    if (character === '"') {
      this.#finishString();
      return;
    }
    if (character.charCodeAt(0) < 0x20) {
      throw new Error("json_string_control_invalid");
    }
    this.#captureStringCharacter(character);
  }

  #captureStringCharacter(character) {
    if (this.stringInfo.capture === "discard") return;
    const limit = this.stringInfo.capture === "key" ? 256 : 4096;
    if (this.stringRaw.length >= limit) {
      if (this.stringInfo.capture === "key") {
        throw new Error("json_key_too_large");
      }
      this.stringInfo.capture = "discard";
      this.stringRaw = "";
      return;
    }
    this.stringRaw += character;
  }

  #finishString() {
    const info = this.stringInfo;
    const captured = info.capture === "discard"
      ? null
      : JSON.parse(`"${this.stringRaw}"`);
    if (info.role === "key") {
      if (!captured || info.context.state === "colon") {
        throw new Error("json_key_invalid");
      }
      info.context.pendingKey = captured;
      info.context.state = "colon";
    } else {
      if (info.capture === "field") {
        info.context.fields[info.key] = captured;
      }
      this.#finishScalar(info);
    }
    this.#resetString();
  }

  #resetString() {
    this.mode = "default";
    this.stringInfo = null;
    this.stringRaw = "";
    this.stringEscape = false;
    this.stringUnicodeRemaining = 0;
  }

  #finishPrimitive() {
    try {
      JSON.parse(this.primitiveRaw);
    } catch {
      throw new Error("json_primitive_invalid");
    }
    this.#finishScalar(this.primitiveInfo);
    this.primitiveInfo = null;
    this.primitiveRaw = "";
    this.mode = "default";
  }

  #closeContainer(expectedType) {
    const context = this.#top();
    if (!context || context.type !== expectedType) {
      throw new Error("json_container_invalid");
    }
    const validState = context.type === "object"
      ? ["keyOrEnd", "commaOrEnd"].includes(context.state)
      : ["valueOrEnd", "commaOrEnd"].includes(context.state);
    if (!validState) throw new Error("json_container_incomplete");
    this.stack.pop();
    if (context.type === "object") this.#captureObject(context);
    if (this.stack.length === 0) this.rootState = "complete";
  }

  #captureObject(context) {
    if (this.stack.length === 0) {
      this.status = String(context.fields.status || "");
    }
    const isVideo = context.relationKey === "output_video" ||
      context.fields.type === "video";
    if (!isVideo || this.video) return;
    const mimeType = String(context.fields.mime_type || "video/mp4")
      .toLowerCase();
    if (mimeType !== "video/mp4") {
      if (context.fields.dataBytes) {
        throw new GoogleProviderError("provider_result_invalid", {
          retryable: false,
        });
      }
      return;
    }
    if (context.fields.dataBytes instanceof Uint8Array) {
      this.video = { dataBytes: context.fields.dataBytes, mimeType };
      return;
    }
    const url = String(
      context.fields.download_uri || context.fields.uri || "",
    );
    if (/^https:\/\//i.test(url)) {
      this.video = { url, mimeType };
    }
  }
}

class BoundedBase64VideoCollector {
  constructor() {
    this.buffer = new Uint8Array(MAX_VIDEO_RESULT_BYTES);
    this.offset = 0;
    this.pending = "";
    this.encodedLength = 0;
    this.paddingSeen = false;
  }

  push(character) {
    if (!/[A-Za-z0-9+/=]/.test(character)) {
      throw new GoogleProviderError("provider_result_invalid", {
        retryable: false,
      });
    }
    if (this.paddingSeen && character !== "=") {
      throw new GoogleProviderError("provider_result_invalid", {
        retryable: false,
      });
    }
    if (character === "=") this.paddingSeen = true;
    this.encodedLength += 1;
    if (this.encodedLength > MAX_GOOGLE_INLINE_VIDEO_BASE64_BYTES) {
      throw new GoogleProviderError("provider_result_too_large", {
        retryable: false,
      });
    }
    this.pending += character;
    if (!this.paddingSeen && this.pending.length >= 16_384) {
      const length = this.pending.length - this.pending.length % 4;
      this.#decode(this.pending.slice(0, length));
      this.pending = this.pending.slice(length);
    }
  }

  finish() {
    if (
      this.encodedLength === 0 ||
      this.encodedLength % 4 !== 0 ||
      (this.pending.match(/=/g) || []).length > 2
    ) {
      throw new GoogleProviderError("provider_result_invalid", {
        retryable: false,
      });
    }
    this.#decode(this.pending);
    this.pending = "";
    if (this.offset === 0) {
      throw new GoogleProviderError("provider_result_invalid", {
        retryable: false,
      });
    }
    return this.buffer.subarray(0, this.offset);
  }

  #decode(value) {
    if (!value) return;
    let binary;
    try {
      binary = atob(value);
    } catch {
      throw new GoogleProviderError("provider_result_invalid", {
        retryable: false,
      });
    }
    if (this.offset + binary.length > MAX_VIDEO_RESULT_BYTES) {
      throw new GoogleProviderError("provider_result_too_large", {
        retryable: false,
      });
    }
    for (let index = 0; index < binary.length; index += 1) {
      this.buffer[this.offset + index] = binary.charCodeAt(index);
    }
    this.offset += binary.length;
  }
}

async function readBoundedGoogleJson(
  response,
  { submissionAmbiguous = false } = {},
) {
  const contentLength = response.headers.get("Content-Length");
  if (
    contentLength &&
    (!/^\d{1,20}$/.test(contentLength) ||
      Number(contentLength) > MAX_GOOGLE_JSON_BYTES)
  ) {
    throw new GoogleProviderError("provider_response_too_large", {
      retryable: true,
      submissionAmbiguous,
    });
  }
  if (!response.body) {
    throw new GoogleProviderError("provider_response_invalid", {
      retryable: true,
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
      total += value.byteLength;
      if (total > MAX_GOOGLE_JSON_BYTES) {
        await reader.cancel().catch(() => null);
        throw new GoogleProviderError("provider_response_too_large", {
          retryable: true,
          submissionAmbiguous,
        });
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof GoogleProviderError) throw error;
    throw new GoogleProviderError("provider_response_unavailable", {
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
  try {
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw new Error();
    }
    return payload;
  } catch {
    throw new GoogleProviderError("provider_response_invalid", {
      retryable: true,
      submissionAmbiguous,
    });
  }
}
