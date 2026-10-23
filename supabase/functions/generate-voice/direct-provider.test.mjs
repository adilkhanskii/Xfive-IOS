import assert from "node:assert/strict";
import test from "node:test";

import { DirectVoiceProvider, MINIMAX_MODEL } from "./direct-provider.mjs";

const mp3 = Uint8Array.from([0x49, 0x44, 0x33, 4, 0, 0, 1, 2, 3]);
const input = {
  text: "Озвучь рекламный текст",
  voice: "Aria",
  stability: 0.5,
  speed: 1,
  languageCode: "ru",
};

test("uses official MiniMax HTTP MP3 endpoint first", async () => {
  let request;
  const provider = new DirectVoiceProvider({
    minimaxKey: "mini-secret",
    elevenLabsKey: "eleven-secret",
    fetchImpl: (url, options) => {
      request = { url: String(url), options };
      return Response.json({
        data: { audio: Buffer.from(mp3).toString("hex"), status: 2 },
        trace_id: "trace-12345678",
        base_resp: { status_code: 0, status_msg: "success" },
      });
    },
  });
  const result = await provider.generate({ input });
  assert.equal(request.url, "https://api.minimax.io/v1/t2a_v2");
  assert.equal(request.options.headers.Authorization, "Bearer mini-secret");
  const body = JSON.parse(request.options.body);
  assert.equal(body.model, MINIMAX_MODEL);
  assert.equal(body.language_boost, "Russian");
  assert.equal(body.audio_setting.format, "mp3");
  assert.equal(result.provider, "minimax");
  assert.equal(result.model, MINIMAX_MODEL);
  assert.deepEqual(result.audioBytes, mp3);
});

test("returns a terminal error on a definitive MiniMax rejection", async () => {
  let calls = 0;
  const provider = new DirectVoiceProvider({
    minimaxKey: "mini-secret",
    fetchImpl: () => {
      calls += 1;
      return Response.json(
        { base_resp: { status_code: 1004, status_msg: "rejected" } },
        { status: 400 },
      );
    },
  });
  await assert.rejects(
    provider.generate({ input }),
    (error) => error.code === "minimax_rejected" && error.terminal === true,
  );
  assert.equal(calls, 1);
});

test("never double-submits to fallback after an ambiguous MiniMax transport", async () => {
  let calls = 0;
  const provider = new DirectVoiceProvider({
    minimaxKey: "mini-secret",
    fetchImpl: () => {
      calls += 1;
      throw new Error("timeout");
    },
  });
  await assert.rejects(
    provider.generate({ input }),
    (error) => error.submissionAmbiguous === true,
  );
  assert.equal(calls, 1);
});

test("passes an explicitly selected MiniMax voice and auto-detects Kazakh", async () => {
  let request;
  const provider = new DirectVoiceProvider({
    minimaxKey: "mini-secret",
    fetchImpl: (url, options) => {
      request = { url: String(url), options };
      return Response.json({
        data: { audio: Buffer.from(mp3).toString("hex"), status: 2 },
        trace_id: "trace-kazakh-1234",
        base_resp: { status_code: 0, status_msg: "success" },
      });
    },
  });
  await provider.generate({
    input: {
      ...input,
      voice: "Russian_ReliableMan",
      languageCode: "kk",
    },
  });
  const body = JSON.parse(request.options.body);
  assert.equal(body.voice_setting.voice_id, "Russian_ReliableMan");
  assert.equal(body.language_boost, "auto");
});
