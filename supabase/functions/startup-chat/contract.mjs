export const STARTUP_CHAT_LIMITS = Object.freeze({
  maxMessages: 12,
  maxMessageCharacters: 4_000,
  maxTotalCharacters: 12_000,
});

export class StartupChatRequestError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "StartupChatRequestError";
    this.code = code;
    this.status = status;
  }
}

export function normalizeStartupChatRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new StartupChatRequestError("invalid_request");
  }

  const source = body.messages;
  if (!Array.isArray(source) || source.length === 0) {
    throw new StartupChatRequestError("messages_required");
  }
  if (source.length > STARTUP_CHAT_LIMITS.maxMessages) {
    throw new StartupChatRequestError("too_many_messages");
  }

  let totalCharacters = 0;
  const messages = source.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new StartupChatRequestError("invalid_message");
    }

    if (typeof item.role !== "string") {
      throw new StartupChatRequestError("invalid_role");
    }
    const role = item.role.trim();
    if (role !== "user" && role !== "assistant") {
      throw new StartupChatRequestError("invalid_role");
    }

    if (typeof item.content !== "string") {
      throw new StartupChatRequestError("invalid_message");
    }
    const content = item.content.trim();
    if (!content) {
      throw new StartupChatRequestError("message_empty");
    }
    if (content.length > STARTUP_CHAT_LIMITS.maxMessageCharacters) {
      throw new StartupChatRequestError("message_too_long");
    }

    totalCharacters += content.length;
    if (totalCharacters > STARTUP_CHAT_LIMITS.maxTotalCharacters) {
      throw new StartupChatRequestError("conversation_too_long");
    }
    return { role, content };
  });

  if (messages.at(-1)?.role !== "user") {
    throw new StartupChatRequestError("last_message_must_be_user");
  }

  if (typeof body.request_id !== "string") {
    throw new StartupChatRequestError("invalid_request_id");
  }
  const requestID = body.request_id.trim().toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(requestID)
  ) {
    throw new StartupChatRequestError("invalid_request_id");
  }

  return { requestID, messages };
}

export async function buildStartupChatIdentity(normalized) {
  const canonical = JSON.stringify(normalized.messages);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return {
    requestID: normalized.requestID,
    fingerprint: Array.from(new Uint8Array(digest))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join(""),
  };
}

export function buildOpenAIRequest(messages, model) {
  return {
    model,
    instructions: [
      "Ты — стартап-наставник внутри приложения Xfive marketing.",
      "Отвечай по-русски, конкретно и без воды.",
      "Помогай проверять идею, аудиторию, ценность, конкурентов, экономику и следующий практический шаг.",
      "Не выдумывай факты и цифры. Если данных мало, задай не больше двух коротких уточняющих вопросов.",
      "Не обещай гарантированный доход и не выдавай юридические, медицинские или инвестиционные заключения.",
      "Структурируй ответ короткими абзацами или списком, когда это повышает ясность.",
    ].join(" "),
    input: messages.map(({ role, content }) => ({ role, content })),
    max_output_tokens: 900,
    store: false,
  };
}

export function extractAssistantReply(payload) {
  const direct = typeof payload?.output_text === "string"
    ? payload.output_text.trim()
    : "";
  if (direct) return direct.slice(0, 8_000);

  const output = Array.isArray(payload?.output) ? payload.output : [];
  const text = output
    .flatMap((item) => Array.isArray(item?.content) ? item.content : [])
    .map((item) => typeof item?.text === "string" ? item.text.trim() : "")
    .filter(Boolean)
    .join("\n")
    .trim();
  if (!text) throw new Error("assistant_response_invalid");
  return text.slice(0, 8_000);
}
