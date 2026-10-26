import assert from "node:assert/strict";
import test from "node:test";

import {
  ELEVENLABS_MODEL,
  ElevenLabsVoiceProvider,
} from "./elevenlabs-provider.mjs";

const mp3 = Uint8Array.from([0x49, 0x44, 0x33, 4, 0, 0, 1, 2, 3]);
const input = {
  tier: "premium",
  text: "Озвучь рекламный текст",
  voice: "JBFqnCBsd6RMkjVDRZzb",
  stability: 0.5,
  speed: 1.1,
  languageCode: "ru",
};

test("calls the official ElevenLabs TTS endpoint with eleven_v3 MP3", async () => {
  let request;
  const provider = new ElevenLabsVoiceProvider({
    apiKey: "eleven-secret",
    fetchImpl: (url, options) => {
      request = { url: new URL(String(url)), options };
      return new Response(mp3, {
        headers: { "Content-Type": "audio/mpeg", "request-id": "req-abc123" },
      });
    },
  });
  const result = await provider.generate({ input });
  assert.equal(
    request.url.origin + request.url.pathname,
    "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
  );
  assert.equal(request.url.searchParams.get("output_format"), "mp3_44100_128");
  assert.equal(request.options.headers["xi-api-key"], "eleven-secret");
  const body = JSON.parse(request.options.body);
  assert.equal(body.model_id, ELEVENLABS_MODEL);
  assert.equal(body.model_id, "eleven_v3");
  assert.equal(body.language_code, "ru");
  assert.equal(body.voice_settings.stability, 0.5);
  assert.equal(body.voice_settings.speed, 1.1);
  assert.equal(result.provider, "elevenlabs");
  assert.equal(result.model, "eleven_v3");
  assert.equal(result.requestID, "eleven_req-abc123");
  assert.deepEqual(result.audioBytes, mp3);
});

test("lets eleven_v3 auto-detect Kazakh and Auto", async () => {
  const bodies = [];
  const provider = new ElevenLabsVoiceProvider({
    apiKey: "eleven-secret",
    fetchImpl: (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return new Response(mp3);
    },
  });
  await provider.generate({ input: { ...input, languageCode: "kk" } });
  const auto = await provider.generate({
    input: { ...input, languageCode: null },
  });
  assert.equal("language_code" in bodies[0], false);
  assert.equal("language_code" in bodies[1], false);
  assert.match(auto.requestID, /^eleven_[A-Za-z0-9_-]{8,}$/);
});

test("a definitive ElevenLabs rejection is terminal", async () => {
  const provider = new ElevenLabsVoiceProvider({
    apiKey: "eleven-secret",
    fetchImpl: () => Response.json({ detail: "quota" }, { status: 401 }),
  });
  await assert.rejects(
    provider.generate({ input }),
    (error) =>
      error.code === "elevenlabs_rejected" && error.terminal === true &&
      error.submissionAmbiguous === false,
  );
});

test("a lost ElevenLabs response is ambiguous and not refunded", async () => {
  let calls = 0;
  const provider = new ElevenLabsVoiceProvider({
    apiKey: "eleven-secret",
    fetchImpl: () => {
      calls += 1;
      throw new Error("timeout");
    },
  });
  await assert.rejects(
    provider.generate({ input }),
    (error) => error.submissionAmbiguous === true && error.terminal === false,
  );
  assert.equal(calls, 1);
});

test("refuses to start without a server key", () => {
  assert.throws(
    () => new ElevenLabsVoiceProvider({ apiKey: " " }),
    (error) => error.code === "provider_not_configured",
  );
});
