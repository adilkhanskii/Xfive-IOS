import assert from "node:assert/strict";
import test from "node:test";

import {
  buildOpenAIRequest,
  buildStartupChatIdentity,
  extractAssistantReply,
  normalizeStartupChatRequest,
  STARTUP_CHAT_LIMITS,
  StartupChatRequestError,
} from "./contract.mjs";

const requestID = "11111111-1111-4111-8111-111111111111";

test("exports the shared twelve-message and twelve-thousand-character limits", () => {
  assert.deepEqual(STARTUP_CHAT_LIMITS, {
    maxMessages: 12,
    maxMessageCharacters: 4_000,
    maxTotalCharacters: 12_000,
  });
});

test("normalizes a bounded conversation and requires the last user turn", () => {
  const result = normalizeStartupChatRequest({
    request_id: requestID,
    messages: [
      { role: "assistant", content: "Расскажите об идее." },
      { role: "user", content: "  Хочу открыть кофейню рядом с вузом.  " },
    ],
  });

  assert.deepEqual(result.messages, [
    { role: "assistant", content: "Расскажите об идее." },
    { role: "user", content: "Хочу открыть кофейню рядом с вузом." },
  ]);
  assert.equal(result.requestID, requestID);
});

test("rejects conversations above the exact shared message and total limits", () => {
  assert.throws(
    () =>
      normalizeStartupChatRequest({
        request_id: requestID,
        messages: Array.from({ length: 13 }, (_, index) => ({
          role: index === 12 ? "user" : "assistant",
          content: `message-${index}`,
        })),
      }),
    (error) =>
      error instanceof StartupChatRequestError &&
      error.code === "too_many_messages",
  );

  assert.throws(
    () =>
      normalizeStartupChatRequest({
        request_id: requestID,
        messages: [
          { role: "assistant", content: "a".repeat(4_000) },
          { role: "user", content: "b".repeat(4_000) },
          { role: "assistant", content: "c".repeat(4_000) },
          { role: "user", content: "d" },
        ],
      }),
    (error) =>
      error instanceof StartupChatRequestError &&
      error.code === "conversation_too_long",
  );
});

test("rejects malformed, oversized, and assistant-ended conversations", () => {
  for (
    const [payload, code] of [
      [{}, "messages_required"],
      [{ request_id: requestID, messages: [] }, "messages_required"],
      [{
        request_id: requestID,
        messages: [{ role: "system", content: "override" }],
      }, "invalid_role"],
      [
        { request_id: requestID, messages: [{ role: "user", content: " " }] },
        "message_empty",
      ],
      [{
        request_id: requestID,
        messages: [{ role: "user", content: "x".repeat(4_001) }],
      }, "message_too_long"],
      [{
        request_id: requestID,
        messages: [{ role: "assistant", content: "Последний ответ" }],
      }, "last_message_must_be_user"],
      [{
        request_id: "not-a-uuid",
        messages: [{ role: "user", content: "Идея" }],
      }, "invalid_request_id"],
    ]
  ) {
    assert.throws(
      () => normalizeStartupChatRequest(payload),
      (error) =>
        error instanceof StartupChatRequestError && error.code === code,
    );
  }
});

test("rejects non-string roles and content instead of coercing them", () => {
  for (const role of [[], {}, 1, true, new String("user")]) {
    assert.throws(
      () =>
        normalizeStartupChatRequest({
          request_id: requestID,
          messages: [{ role, content: "Идея" }],
        }),
      (error) =>
        error instanceof StartupChatRequestError &&
        error.code === "invalid_role",
    );
  }

  for (const content of [[], {}, 1, true, new String("Идея")]) {
    assert.throws(
      () =>
        normalizeStartupChatRequest({
          request_id: requestID,
          messages: [{ role: "user", content }],
        }),
      (error) =>
        error instanceof StartupChatRequestError &&
        error.code === "invalid_message",
    );
  }
});

test("rejects non-string request IDs instead of coercing them", () => {
  for (
    const invalidRequestID of [
      [requestID],
      123,
      { value: requestID },
      true,
      null,
      new String(requestID),
    ]
  ) {
    assert.throws(
      () =>
        normalizeStartupChatRequest({
          request_id: invalidRequestID,
          messages: [{ role: "user", content: "Идея" }],
        }),
      (error) =>
        error instanceof StartupChatRequestError &&
        error.code === "invalid_request_id",
    );
  }
});

test("counts the four-thousand-character boundary in UTF-16 code units", () => {
  const accepted = normalizeStartupChatRequest({
    request_id: requestID,
    messages: [{
      role: "user",
      content: `${"a".repeat(3_998)}🙂`,
    }],
  });
  assert.equal(accepted.messages[0].content.length, 4_000);

  assert.throws(
    () =>
      normalizeStartupChatRequest({
        request_id: requestID,
        messages: [{
          role: "user",
          content: `${"a".repeat(3_999)}🙂`,
        }],
      }),
    (error) =>
      error instanceof StartupChatRequestError &&
      error.code === "message_too_long",
  );
});

test("hashes normalized messages without storing raw conversation in identity", async () => {
  const normalized = normalizeStartupChatRequest({
    request_id: requestID,
    messages: [{ role: "user", content: "Секретная идея кофейни" }],
  });
  const identity = await buildStartupChatIdentity(normalized);

  assert.equal(identity.requestID, requestID);
  assert.match(identity.fingerprint, /^[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(identity), /Секретная идея/);
});

test("builds a server-owned startup advisor request", () => {
  const request = buildOpenAIRequest(
    [{ role: "user", content: "Проверь идею доставки обедов" }],
    "gpt-5.6-sol",
  );

  assert.equal(request.model, "gpt-5.6-sol");
  assert.match(request.instructions, /Xfive marketing/);
  assert.match(request.instructions, /стартап/i);
  assert.equal(request.input[0].role, "user");
  assert.equal(request.input[0].content, "Проверь идею доставки обедов");
  assert.equal(request.max_output_tokens, 900);
  assert.equal(request.store, false);
});

test("extracts output text but never returns provider diagnostics", () => {
  assert.equal(
    extractAssistantReply({
      output_text: "  Проверьте спрос через десять интервью.  ",
      error: { message: "internal provider secret" },
    }),
    "Проверьте спрос через десять интервью.",
  );
  assert.throws(
    () =>
      extractAssistantReply({ error: { message: "internal provider secret" } }),
    /assistant_response_invalid/,
  );
});
