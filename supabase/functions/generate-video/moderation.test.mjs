import assert from "node:assert/strict";
import test from "node:test";

import {
  createBytePlusVideoModerator,
  createFailoverVideoModerator,
  createGoogleVideoModerator,
  createOpenAIVideoModerator,
} from "./moderation.mjs";

const normalized = {
  prompt: "A friendly mango dances in a clean studio",
  startImage: {
    mimeType: "image/jpeg",
    dataBase64: "/9j/2Q==",
  },
};

test("sends text and the optional image to omni moderation", async () => {
  const requests = [];
  const moderate = createOpenAIVideoModerator({
    apiKey: "openai-server-key",
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), init });
      return Response.json({ results: [{ flagged: false }] });
    },
  });

  assert.deepEqual(await moderate(normalized), { allowed: true });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.openai.com/v1/moderations");
  assert.equal(
    requests[0].init.headers.Authorization,
    "Bearer openai-server-key",
  );
  const body = JSON.parse(requests[0].init.body);
  assert.equal(body.model, "omni-moderation-latest");
  assert.deepEqual(body.input, [
    { type: "text", text: normalized.prompt },
    {
      type: "image_url",
      image_url: {
        url: "data:image/jpeg;base64,/9j/2Q==",
      },
    },
  ]);
});

test("returns rejected only for a valid flagged response", async () => {
  const moderate = createOpenAIVideoModerator({
    apiKey: "openai-server-key",
    fetchImpl: async () => Response.json({ results: [{ flagged: true }] }),
  });

  assert.deepEqual(
    await moderate({ prompt: "unsafe", startImage: null }),
    { allowed: false },
  );
});

test("fails closed for missing config, HTTP errors, and malformed responses", async () => {
  assert.throws(
    () => createOpenAIVideoModerator({ apiKey: "" }),
    /video_moderation_not_configured/,
  );

  for (
    const response of [
      new Response("provider details", { status: 429 }),
      Response.json({ results: [] }),
      Response.json({ results: [{ categories: {} }] }),
    ]
  ) {
    const moderate = createOpenAIVideoModerator({
      apiKey: "openai-server-key",
      fetchImpl: async () => response,
    });
    await assert.rejects(
      () => moderate({ prompt: "hello", startImage: null }),
      /video_moderation_unavailable/,
    );
  }
});

test("uses Google structured safety classification for text and images", async () => {
  const requests = [];
  const moderate = createGoogleVideoModerator({
    apiKey: "google-server-key",
    models: ["gemini-safety-test"],
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), init });
      return Response.json({
        candidates: [{
          finishReason: "STOP",
          content: { parts: [{ text: '{"allowed":true}' }] },
        }],
      });
    },
  });

  assert.deepEqual(await moderate(normalized), { allowed: true });
  assert.equal(requests.length, 1);
  assert.match(requests[0].url, /gemini-safety-test:generateContent$/);
  assert.equal(requests[0].init.headers["x-goog-api-key"], "google-server-key");
  const body = JSON.parse(requests[0].init.body);
  assert.equal(body.contents[0].parts[0].text, normalized.prompt);
  assert.deepEqual(body.contents[0].parts[1], {
    inlineData: { mimeType: "image/jpeg", data: "/9j/2Q==" },
  });
  assert.equal(body.generationConfig.responseMimeType, "application/json");
  assert.equal(body.generationConfig.responseSchema.properties.allowed.type, "BOOLEAN");
});

test("treats Google safety blocks as rejected and malformed output as unavailable", async () => {
  const blocked = createGoogleVideoModerator({
    apiKey: "google-server-key",
    models: ["gemini-safety-test"],
    fetchImpl: async () => Response.json({
      candidates: [{ finishReason: "SAFETY" }],
    }),
  });
  assert.deepEqual(await blocked(normalized), { allowed: false });

  const unavailable = createGoogleVideoModerator({
    apiKey: "google-server-key",
    models: ["first", "second"],
    fetchImpl: async () => Response.json({
      candidates: [{ finishReason: "STOP", content: { parts: [] } }],
    }),
  });
  await assert.rejects(
    () => unavailable(normalized),
    /video_moderation_unavailable/,
  );
});

test("uses BytePlus structured safety classification for text and images", async () => {
  const requests = [];
  const moderate = createBytePlusVideoModerator({
    apiKey: "byteplus-server-key",
    fetchImpl: async (url, init) => {
      requests.push({ url: String(url), init });
      return Response.json({
        choices: [{
          finish_reason: "stop",
          message: { content: '{"allowed":true}' },
        }],
      });
    },
  });

  assert.deepEqual(await moderate(normalized), { allowed: true });
  assert.equal(
    requests[0].url,
    "https://ark.ap-southeast.bytepluses.com/api/v3/chat/completions",
  );
  assert.equal(
    requests[0].init.headers.Authorization,
    "Bearer byteplus-server-key",
  );
  const body = JSON.parse(requests[0].init.body);
  assert.equal(body.model, "seed-2-0-lite-260428");
  assert.equal(body.messages[1].content[0].text, normalized.prompt);
  assert.equal(
    body.messages[1].content[1].image_url.url,
    "data:image/jpeg;base64,/9j/2Q==",
  );
  assert.equal(body.response_format.type, "json_schema");
  assert.equal(
    body.response_format.json_schema.schema.properties.allowed.type,
    "boolean",
  );
});

test("BytePlus rejects safety-filtered output and fails closed otherwise", async () => {
  const blocked = createBytePlusVideoModerator({
    apiKey: "byteplus-server-key",
    fetchImpl: async () => Response.json({
      choices: [{ finish_reason: "content_filter", message: {} }],
    }),
  });
  assert.deepEqual(await blocked(normalized), { allowed: false });

  for (const response of [
    new Response("provider details", { status: 429 }),
    Response.json({ choices: [] }),
    Response.json({
      choices: [{ finish_reason: "stop", message: { content: "not-json" } }],
    }),
  ]) {
    const unavailable = createBytePlusVideoModerator({
      apiKey: "byteplus-server-key",
      fetchImpl: async () => response,
    });
    await assert.rejects(
      () => unavailable(normalized),
      /video_moderation_unavailable/,
    );
  }
});

test("fails over only when a safety provider is unavailable", async () => {
  let fallbackCalls = 0;
  const allow = createFailoverVideoModerator([
    async () => {
      throw new Error("upstream unavailable");
    },
    async () => {
      fallbackCalls += 1;
      return { allowed: true };
    },
  ]);
  assert.deepEqual(await allow(normalized), { allowed: true });
  assert.equal(fallbackCalls, 1);

  fallbackCalls = 0;
  const reject = createFailoverVideoModerator([
    async () => ({ allowed: false }),
    async () => {
      fallbackCalls += 1;
      return { allowed: true };
    },
  ]);
  assert.deepEqual(await reject(normalized), { allowed: false });
  assert.equal(fallbackCalls, 0);
});

test("all safety providers unavailable remains fail-closed", async () => {
  const moderate = createFailoverVideoModerator([
    async () => {
      throw new Error("first unavailable");
    },
    async () => {
      throw new Error("second unavailable");
    },
  ]);
  await assert.rejects(
    () => moderate(normalized),
    /video_moderation_unavailable/,
  );
});
