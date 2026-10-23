import assert from "node:assert/strict";
import test from "node:test";

let contract = null;
let importFailure = null;
try {
  contract = await import("./contract.mjs");
} catch (error) {
  importFailure = error;
}

test("voice generation contract module exists", () => {
  assert.ok(
    contract,
    `generate-voice/contract.mjs is missing: ${
      importFailure?.message || "unknown"
    }`,
  );
});

test("normalizes a supported MiniMax request and computes bounded credits", {
  skip: !contract,
}, async () => {
  const normalized = contract.normalizeVoiceGenerationRequest({
    request_id: "22222222-2222-4222-8222-222222222222",
    text: "  Привет из Xfive marketing  ",
    voice: "Russian_BrightHeroine",
    stability: 0.5,
    speed: 1,
    language_code: "ru",
  });

  assert.equal(normalized.text, "Привет из Xfive marketing");
  assert.equal(normalized.voice, "Russian_BrightHeroine");
  assert.equal(normalized.stability, 0.5);
  assert.equal(normalized.speed, 1);
  assert.equal(normalized.languageCode, "ru");
  assert.equal(normalized.outputFormat, "mp3_44100_128");
  assert.equal(normalized.costCredits, 60);
  assert.equal(normalized.characterCount, normalized.text.length);

  const identity = await contract.buildVoiceGenerationIdentity(normalized);
  assert.match(identity.requestKey, /^explicit:[0-9a-f]{64}$/);
  assert.match(identity.fingerprint, /^[0-9a-f]{64}$/);
});

test("charges 60 credits for every started 1000-character block", {
  skip: !contract,
}, () => {
  assert.equal(contract.voiceGenerationCost("a"), 60);
  assert.equal(contract.voiceGenerationCost("a".repeat(1_000)), 60);
  assert.equal(contract.voiceGenerationCost("a".repeat(1_001)), 120);
  assert.equal(contract.voiceGenerationCost("a".repeat(5_000)), 300);
});

test("rejects unsupported voices, malformed request IDs, and oversized text", {
  skip: !contract,
}, () => {
  assert.throws(
    () =>
      contract.normalizeVoiceGenerationRequest({
        request_id: "not-a-uuid",
        text: "Hello",
        voice: "Aria",
      }),
    /invalid_request_id/,
  );
  assert.throws(
    () =>
      contract.normalizeVoiceGenerationRequest({
        request_id: "22222222-2222-4222-8222-222222222222",
        text: "Hello",
        voice: "Unknown voice",
      }),
    /invalid_voice/,
  );
  assert.throws(
    () =>
      contract.normalizeVoiceGenerationRequest({
        request_id: "22222222-2222-4222-8222-222222222222",
        text: "a".repeat(5_001),
        voice: "Aria",
      }),
    /invalid_text/,
  );
});

test("fingerprint changes with every billable or audible input", {
  skip: !contract,
}, async () => {
  const base = {
    request_id: "22222222-2222-4222-8222-222222222222",
    text: "Read this advertisement",
    voice: "Aria",
    stability: 0.5,
    speed: 1,
    language_code: "en",
  };
  const first = await contract.buildVoiceGenerationIdentity(
    contract.normalizeVoiceGenerationRequest(base),
  );
  const changedVoice = await contract.buildVoiceGenerationIdentity(
    contract.normalizeVoiceGenerationRequest({ ...base, voice: "Sarah" }),
  );
  const changedText = await contract.buildVoiceGenerationIdentity(
    contract.normalizeVoiceGenerationRequest({
      ...base,
      text: "Read another advertisement",
    }),
  );

  assert.notEqual(first.fingerprint, changedVoice.fingerprint);
  assert.notEqual(first.fingerprint, changedText.fingerprint);
});
