import assert from "node:assert/strict";
import test from "node:test";

import {
  buildStartupChatModerationInput,
  createOpenAIStartupChatProvider,
  StartupChatProviderError,
} from "./provider.mjs";

const requestID = "11111111-1111-4111-8111-111111111111";
const messages = [
  { role: "assistant", content: "Опишите вашу идею." },
  { role: "user", content: "Сервис доставки обедов для офисов." },
];

test("builds one bounded moderation input from every client-supplied turn", () => {
  assert.equal(
    buildStartupChatModerationInput(messages),
    [
      "assistant: Опишите вашу идею.",
      "user: Сервис доставки обедов для офисов.",
    ].join("\n"),
  );
});

test("moderates before Responses and keeps the request idempotent", async () => {
  const requests = [];
  const generateReply = createOpenAIStartupChatProvider({
    apiKey: "openai-server-key",
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), init });
      if (requests.length === 1) {
        return Response.json({ results: [{ flagged: false }] });
      }
      return Response.json({ output_text: "Проверьте спрос интервью." });
    },
  });

  const reply = await generateReply({
    messages,
    model: "gpt-5.6-sol",
    requestID,
  });

  assert.equal(reply, "Проверьте спрос интервью.");
  assert.deepEqual(
    requests.map(({ url }) => url),
    [
      "https://api.openai.com/v1/moderations",
      "https://api.openai.com/v1/responses",
    ],
  );
  const moderationBody = JSON.parse(requests[0].init.body);
  assert.equal(moderationBody.model, "omni-moderation-latest");
  assert.equal(
    moderationBody.input,
    buildStartupChatModerationInput(messages),
  );
  assert.equal(
    requests[1].init.headers["Idempotency-Key"],
    requestID,
  );
  const responsesBody = JSON.parse(requests[1].init.body);
  assert.equal(responsesBody.model, "gpt-5.6-sol");
  assert.equal(responsesBody.store, false);
});

test("flagged moderation fails closed without calling Responses", async () => {
  let calls = 0;
  const generateReply = createOpenAIStartupChatProvider({
    apiKey: "openai-server-key",
    fetchImpl: async () => {
      calls += 1;
      return Response.json({ results: [{ flagged: true }] });
    },
  });

  await assert.rejects(
    () => generateReply({ messages, model: "gpt-5.6-sol", requestID }),
    (error) =>
      error instanceof StartupChatProviderError &&
      error.code === "content_rejected" &&
      error.status === 422 &&
      error.phase === "moderation",
  );
  assert.equal(calls, 1);
});

test("unavailable or malformed moderation fails closed without Responses", async () => {
  const responseFactories = [
    () => new Response("provider secret", { status: 429 }),
    () => Response.json({ results: [] }),
    () => Response.json({ results: [{ categories: {} }] }),
    () => Response.json({ results: [{ flagged: "false" }] }),
    () =>
      new Response('{"results":[{"flagged":false}]}', {
        headers: { "Content-Length": "262144" },
      }),
  ];

  for (const responseFactory of responseFactories) {
    let calls = 0;
    const generateReply = createOpenAIStartupChatProvider({
      apiKey: "openai-server-key",
      fetchImpl: async () => {
        calls += 1;
        return responseFactory();
      },
    });

    await assert.rejects(
      () => generateReply({ messages, model: "gpt-5.6-sol", requestID }),
      (error) =>
        error instanceof StartupChatProviderError &&
        error.code === "assistant_unavailable" &&
        error.status === 503 &&
        error.phase === "moderation" &&
        !error.message.includes("provider secret"),
    );
    assert.equal(calls, 1);
  }
});

test("Responses errors and malformed output stay private and retryable", async () => {
  const responseFactories = [
    () => new Response("provider secret", { status: 500 }),
    () => Response.json({ output: [] }),
    () =>
      new Response('{"output_text":"ok"}', {
        headers: { "Content-Length": "2097152" },
      }),
  ];

  for (const responseFactory of responseFactories) {
    let calls = 0;
    const generateReply = createOpenAIStartupChatProvider({
      apiKey: "openai-server-key",
      fetchImpl: async () => {
        calls += 1;
        return calls === 1
          ? Response.json({ results: [{ flagged: false }] })
          : responseFactory();
      },
    });

    await assert.rejects(
      () => generateReply({ messages, model: "gpt-5.6-sol", requestID }),
      (error) =>
        error instanceof StartupChatProviderError &&
        error.code === "assistant_unavailable" &&
        error.status === 503 &&
        error.phase === "responses" &&
        !error.message.includes("provider secret"),
    );
    assert.equal(calls, 2);
  }
});

test("missing server credentials are rejected before any provider request", () => {
  assert.throws(
    () => createOpenAIStartupChatProvider({ apiKey: " " }),
    /startup_chat_not_configured/,
  );
});
