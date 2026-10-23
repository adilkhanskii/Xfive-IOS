// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import {
  extractFalVoiceResult,
  FalVoiceQueueProvider,
} from "./fal-provider.mjs";

const input = {
  text: "[excited] Welcome!",
  voice: "Aria",
  stability: 0.5,
  speed: 1,
  languageCode: "en",
  outputFormat: "mp3_44100_128",
};

test("submits Eleven v3 to fal persistent queue with a correlation webhook", async () => {
  let captured;
  const provider = new FalVoiceQueueProvider({
    apiKey: "server-fal-key",
    fetchImpl: async (url, options) => {
      captured = { url: String(url), options };
      return Response.json({
        request_id: "024ca5b1-45d3-4afd-883e-ad3abe2a1c4d",
      });
    },
  });

  const result = await provider.submit({
    input,
    webhookURL:
      "https://project.supabase.co/functions/v1/voice-generation-webhook?claim=opaque&attempt=1",
  });

  const submittedURL = new URL(captured.url);
  assert.equal(
    `${submittedURL.origin}${submittedURL.pathname}`,
    "https://queue.fal.run/fal-ai/elevenlabs/tts/eleven-v3",
  );
  assert.match(submittedURL.searchParams.get("fal_webhook"), /^https:/);
  assert.equal(captured.options.headers.Authorization, "Key server-fal-key");
  assert.equal(captured.options.headers["X-Fal-Store-IO"], "0");
  assert.deepEqual(
    JSON.parse(
      captured.options.headers["X-Fal-Object-Lifecycle-Preference"],
    ),
    { expiration_duration_seconds: 10_800 },
  );
  assert.deepEqual(JSON.parse(captured.options.body), {
    text: "[excited] Welcome!",
    voice: "Aria",
    stability: 0.5,
    similarity_boost: 0.75,
    speed: 1,
    language_code: "en",
    apply_text_normalization: "auto",
    timestamps: false,
    output_format: "mp3_44100_128",
  });
  assert.equal(
    result.requestID,
    "024ca5b1-45d3-4afd-883e-ad3abe2a1c4d",
  );
});

test("a lost submit response is ambiguous and must not be resubmitted", async () => {
  const provider = new FalVoiceQueueProvider({
    apiKey: "server-fal-key",
    fetchImpl: async () => {
      throw new TypeError("connection reset after fal accepted");
    },
  });

  await assert.rejects(
    provider.submit({
      input,
      webhookURL:
        "https://project.supabase.co/functions/v1/voice-generation-webhook?claim=opaque&attempt=1",
    }),
    (error) => {
      assert.equal(error.code, "provider_transport_ambiguous");
      assert.equal(error.submissionAmbiguous, true);
      assert.doesNotMatch(error.message, /connection reset|accepted/i);
      return true;
    },
  );
});

test("a definitive 4xx submit rejection is terminal", async () => {
  const provider = new FalVoiceQueueProvider({
    apiKey: "server-fal-key",
    fetchImpl: async () => new Response("secret", { status: 422 }),
  });
  await assert.rejects(
    provider.submit({
      input,
      webhookURL:
        "https://project.supabase.co/functions/v1/voice-generation-webhook?claim=opaque&attempt=1",
    }),
    (error) => {
      assert.equal(error.code, "provider_rejected");
      assert.equal(error.terminal, true);
      assert.equal(error.submissionAmbiguous, false);
      assert.doesNotMatch(error.message, /secret/i);
      return true;
    },
  );
});

test("polls queue status and retrieves the allowlisted audio result", async () => {
  const calls = [];
  const provider = new FalVoiceQueueProvider({
    apiKey: "server-fal-key",
    fetchImpl: async (url) => {
      calls.push(String(url));
      if (String(url).endsWith("/status")) {
        return Response.json({ status: "COMPLETED" });
      }
      return Response.json({
        audio: {
          url: "https://v3.fal.media/files/zebra/generated_output.mp3",
        },
      });
    },
  });
  const requestID = "024ca5b1-45d3-4afd-883e-ad3abe2a1c4d";
  assert.deepEqual(await provider.status({ requestID }), {
    state: "completed",
  });
  assert.deepEqual(await provider.result({ requestID }), {
    audioURL: "https://v3.fal.media/files/zebra/generated_output.mp3",
  });
  assert.equal(calls.length, 2);
});

test("rejects provider output outside the fal.media allowlist", () => {
  assert.throws(
    () =>
      extractFalVoiceResult({
        audio: { url: "https://attacker.example/steal.mp3" },
      }),
    /provider_audio_url_invalid/,
  );
});
