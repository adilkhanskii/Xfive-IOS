import { buildOpenAIRequest, extractAssistantReply } from "./contract.mjs";

const OPENAI_MODERATIONS_URL = "https://api.openai.com/v1/moderations";
const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const MODERATION_MODEL = "omni-moderation-latest";
const MAX_MODERATION_RESPONSE_BYTES = 128 * 1024;
const MAX_RESPONSES_RESPONSE_BYTES = 1024 * 1024;

export class StartupChatProviderError extends Error {
  constructor(
    code,
    {
      status = 503,
      phase = "provider",
      providerStatus = null,
      reason = "provider_failure",
    } = {},
  ) {
    super(code);
    this.name = "StartupChatProviderError";
    this.code = code;
    this.status = status;
    this.phase = phase;
    this.providerStatus = providerStatus;
    this.reason = reason;
  }
}

export function buildStartupChatModerationInput(messages) {
  return messages
    .map(({ role, content }) => `${role}: ${content}`)
    .join("\n");
}

export function createOpenAIStartupChatProvider({
  apiKey,
  fetchImpl = fetch,
  moderationTimeoutMs = 8_000,
  responseTimeoutMs = 30_000,
}) {
  const normalizedKey = String(apiKey || "").trim();
  if (!normalizedKey) {
    throw new Error("startup_chat_not_configured");
  }

  return async function generateStartupChatReply({
    messages,
    model,
    requestID,
  }) {
    const moderationResponse = await safeFetch(
      fetchImpl,
      OPENAI_MODERATIONS_URL,
      {
        method: "POST",
        headers: openAIHeaders(normalizedKey),
        body: JSON.stringify({
          model: MODERATION_MODEL,
          input: buildStartupChatModerationInput(messages),
        }),
        signal: AbortSignal.timeout(moderationTimeoutMs),
      },
      "moderation",
    );
    const moderationPayload = await readProviderJSON(
      moderationResponse,
      MAX_MODERATION_RESPONSE_BYTES,
      "moderation",
    );
    const moderationResults = moderationPayload?.results;
    const flagged = Array.isArray(moderationResults) &&
        moderationResults.length === 1
      ? moderationResults[0]?.flagged
      : undefined;
    if (!moderationResponse.ok || typeof flagged !== "boolean") {
      throw unavailable(
        "moderation",
        moderationResponse.status,
        "invalid_response",
      );
    }
    if (flagged) {
      throw new StartupChatProviderError("content_rejected", {
        status: 422,
        phase: "moderation",
        providerStatus: moderationResponse.status,
        reason: "flagged",
      });
    }

    const responsesResponse = await safeFetch(
      fetchImpl,
      OPENAI_RESPONSES_URL,
      {
        method: "POST",
        headers: {
          ...openAIHeaders(normalizedKey),
          "Idempotency-Key": requestID,
        },
        body: JSON.stringify(buildOpenAIRequest(messages, model)),
        signal: AbortSignal.timeout(responseTimeoutMs),
      },
      "responses",
    );
    const responsesPayload = await readProviderJSON(
      responsesResponse,
      MAX_RESPONSES_RESPONSE_BYTES,
      "responses",
    );
    if (!responsesResponse.ok) {
      throw unavailable(
        "responses",
        responsesResponse.status,
        "http_error",
      );
    }

    try {
      return extractAssistantReply(responsesPayload);
    } catch {
      throw unavailable(
        "responses",
        responsesResponse.status,
        "invalid_response",
      );
    }
  };
}

async function safeFetch(fetchImpl, url, init, phase) {
  try {
    return await fetchImpl(url, init);
  } catch (error) {
    throw unavailable(
      phase,
      null,
      error instanceof DOMException && error.name === "TimeoutError"
        ? "timeout"
        : "network_failure",
    );
  }
}

async function readProviderJSON(response, maxBytes, phase) {
  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw unavailable(phase, response.status, "response_too_large");
  }
  if (!response.body) {
    throw unavailable(phase, response.status, "invalid_response");
  }

  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => {});
        throw unavailable(phase, response.status, "response_too_large");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof StartupChatProviderError) throw error;
    throw unavailable(phase, response.status, "invalid_response");
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw unavailable(phase, response.status, "invalid_response");
  }
}

function openAIHeaders(apiKey) {
  return {
    "Authorization": `Bearer ${apiKey}`,
    "Content-Type": "application/json",
  };
}

function unavailable(phase, providerStatus, reason) {
  return new StartupChatProviderError("assistant_unavailable", {
    phase,
    providerStatus: Number.isInteger(providerStatus) && providerStatus > 0
      ? providerStatus
      : null,
    reason,
  });
}
