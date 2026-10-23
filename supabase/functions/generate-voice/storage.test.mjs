// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

let storage = null;
let importFailure = null;
try {
  storage = await import("./storage.mjs");
} catch (error) {
  importFailure = error;
}

test("voice audio storage module exists", () => {
  assert.ok(
    storage,
    `generate-voice/storage.mjs is missing: ${
      importFailure?.message || "unknown"
    }`,
  );
});

test("downloads bounded MP3 bytes and builds an owner-scoped object", {
  skip: !storage,
}, async () => {
  const bytes = Uint8Array.from([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 1, 2, 3]);
  const audio = await storage.downloadFalAudio({
    audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
    fetchImpl: async () =>
      new Response(bytes, {
        headers: {
          "Content-Type": "audio/mpeg",
          "Content-Length": String(bytes.byteLength),
        },
      }),
  });

  assert.equal(audio.mimeType, "audio/mpeg");
  assert.deepEqual(Array.from(audio.bytes), Array.from(bytes));
  assert.match(audio.sha256, /^[0-9a-f]{64}$/);
  assert.equal(
    storage.voiceAudioObjectPath({
      userID: "11111111-1111-4111-8111-111111111111",
      requestKey: `explicit:${"a".repeat(64)}`,
      attempt: 2,
    }),
    `11111111-1111-4111-8111-111111111111/explicit/${
      "a".repeat(64)
    }/2/audio.mp3`,
  );
});

test("rejects oversized or non-MP3 provider bytes", {
  skip: !storage,
}, async () => {
  await assert.rejects(
    storage.downloadFalAudio({
      audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
      maximumBytes: 8,
      fetchImpl: async () =>
        new Response(Uint8Array.from([0x49, 0x44, 0x33]), {
          headers: {
            "Content-Type": "audio/mpeg",
            "Content-Length": "9",
          },
        }),
    }),
    /audio_too_large/,
  );

  await assert.rejects(
    storage.downloadFalAudio({
      audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
      fetchImpl: async () =>
        new Response(Uint8Array.from([0x89, 0x50, 0x4e, 0x47]), {
          headers: { "Content-Type": "image/png" },
        }),
    }),
    /audio_format_invalid/,
  );
});

test("never follows fal.media redirects with the server credentialed fetch", {
  skip: !storage,
}, async () => {
  let redirectMode = null;
  await assert.rejects(
    storage.downloadFalAudio({
      audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
      fetchImpl: async (_url, options) => {
        redirectMode = options.redirect;
        return new Response(null, {
          status: 302,
          headers: { Location: "https://attacker.example/audio.mp3" },
        });
      },
    }),
    /audio_download_failed/,
  );
  assert.equal(redirectMode, "manual");
});
