// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import { VoiceGenerationBackend } from "./backend.mjs";

const userID = "11111111-1111-4111-8111-111111111111";
const requestKey = `explicit:${"a".repeat(64)}`;
const mp3 = Uint8Array.from([0x49, 0x44, 0x33, 4, 0, 0, 1, 2, 3]);

test("idempotent storage verifies an existing private object after upload race", async () => {
  const calls = [];
  const backend = new VoiceGenerationBackend({
    supabaseURL: "https://project.supabase.co",
    serviceRoleKey: "service-secret",
    fetchImpl: async (url, options = {}) => {
      calls.push({ url: String(url), options });
      if (String(url).startsWith("https://v3.fal.media/")) {
        return new Response(mp3, {
          headers: { "Content-Type": "audio/mpeg" },
        });
      }
      if (options.method === "POST") {
        return new Response("duplicate", { status: 409 });
      }
      return new Response(mp3, {
        headers: { "Content-Type": "audio/mpeg" },
      });
    },
  });

  const stored = await backend.storeAudio({
    audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
    userID,
    requestKey,
    attempt: 1,
  });

  assert.equal(stored.path, `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`);
  assert.match(stored.sha256, /^[0-9a-f]{64}$/);
  assert.equal(calls[0].options.redirect, "manual");
  assert.match(calls[2].url, /\/object\/authenticated\//);
  assert.equal(calls[2].options.redirect, "manual");
});

test("an existing different object fails closed", async () => {
  const different = Uint8Array.from([0x49, 0x44, 0x33, 9, 9, 9]);
  let call = 0;
  const backend = new VoiceGenerationBackend({
    supabaseURL: "https://project.supabase.co",
    serviceRoleKey: "service-secret",
    fetchImpl: async (_url, options = {}) => {
      call += 1;
      if (call === 1) {
        return new Response(mp3, {
          headers: { "Content-Type": "audio/mpeg" },
        });
      }
      if (options.method === "POST") {
        return new Response("duplicate", { status: 409 });
      }
      return new Response(different, {
        headers: { "Content-Type": "audio/mpeg" },
      });
    },
  });
  await assert.rejects(
    backend.storeAudio({
      audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
      userID,
      requestKey,
      attempt: 1,
    }),
    /existing_object_conflict/,
  );
});
