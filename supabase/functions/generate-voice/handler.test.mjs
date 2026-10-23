// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import { createGenerateVoiceHandler } from "./handler.mjs";

const userID = "11111111-1111-4111-8111-111111111111";
const providerRequestID = "024ca5b1-45d3-4afd-883e-ad3abe2a1c4d";
const requestBody = {
  request_id: "22222222-2222-4222-8222-222222222222",
  text: "Озвучь рекламный текст",
  voice: "Aria",
  stability: 0.5,
  speed: 1,
  language_code: "ru",
};

function dependencies(overrides = {}) {
  const calls = [];
  return {
    calls,
    deps: {
      verifyUser: async () => ({ id: userID }),
      providerConfigured: () => true,
      directProviderConfigured: () => false,
      generateDirect: async (parameters) => {
        calls.push(["generate-direct", parameters]);
        return {
          provider: "minimax",
          model: "speech-2.8-turbo",
          requestID: "minimax_trace-12345678",
          audioBytes: Uint8Array.from([0x49, 0x44, 0x33, 1]),
          audioMimeType: "audio/mpeg",
        };
      },
      lookupGeneration: async () => ({ status: "not_found" }),
      claimGeneration: async (parameters) => {
        calls.push(["claim", parameters]);
        return {
          status: "claimed",
          attempt: 1,
          credits_remaining: 940,
        };
      },
      buildWebhookURL: ({ claimToken, attempt }) => {
        calls.push(["webhook-url", { claimToken, attempt }]);
        return `https://project.supabase.co/functions/v1/voice-generation-webhook?claim=${claimToken}&attempt=${attempt}`;
      },
      submitGeneration: async (parameters) => {
        calls.push(["submit", parameters]);
        return { requestID: providerRequestID };
      },
      bindProvider: async (parameters) => {
        calls.push(["bind", parameters]);
        return { status: "bound" };
      },
      markSubmissionAmbiguous: async (parameters) => {
        calls.push(["ambiguous", parameters]);
        return { status: "marked" };
      },
      markSubmissionRejected: async (parameters) => {
        calls.push(["rejected", parameters]);
        return { status: "marked" };
      },
      getProviderStatus: async (parameters) => {
        calls.push(["provider-status", parameters]);
        return { state: "pending" };
      },
      getProviderResult: async (parameters) => {
        calls.push(["provider-result", parameters]);
        return {
          audioURL: "https://v3.fal.media/files/zebra/generated.mp3",
        };
      },
      storeAudio: async (parameters) => {
        calls.push(["store", parameters]);
        return {
          path: `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`,
          mimeType: "audio/mpeg",
          sha256: "a".repeat(64),
        };
      },
      completeByProvider: async (parameters) => {
        calls.push(["complete-provider", parameters]);
        return {
          status: "completed",
          credits_remaining: 940,
          result_manifest: parameters.p_result_manifest,
        };
      },
      getByProvider: async (parameters) => {
        calls.push(["get-provider", parameters]);
        return { status: "processing" };
      },
      failByProvider: async (parameters) => {
        calls.push(["fail-provider", parameters]);
        return { status: "refunded", credits_remaining: 1_000 };
      },
      failGeneration: async (parameters) => {
        calls.push(["fail", parameters]);
        return { status: "refunded", credits_remaining: 1_000 };
      },
      deleteAudio: async (path) => calls.push(["delete", path]),
      signAudio: async (path) => {
        calls.push(["sign", path]);
        return {
          signedURL: "https://project.supabase.co/storage/v1/object/sign/audio",
          expiresAt: "2026-07-26T12:15:00.000Z",
        };
      },
      sleep: async () => {},
      ...overrides,
    },
  };
}

function request(body = requestBody, authorization = "Bearer user-token") {
  return new Request("https://example.test/generate-voice", {
    method: "POST",
    headers: {
      Authorization: authorization,
      "Content-Type": "application/json",
      "Idempotency-Key": body.request_id,
    },
    body: JSON.stringify(body),
  });
}

test("new request debits once, submits queue once, binds request ID, and returns pending", async () => {
  const { deps, calls } = dependencies();
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 425);
  assert.deepEqual(
    calls.map(([name]) => name),
    ["claim", "webhook-url", "submit", "bind"],
  );
  const submitted = calls.find(([name]) => name === "submit")[1];
  assert.match(submitted.webhookURL, /claim=[0-9a-f]{64}&attempt=1$/);
  assert.equal(
    calls.find(([name]) => name === "bind")[1].p_provider_request_id,
    providerRequestID,
  );
});

test("new direct request generates, stores, completes and signs in one call", async () => {
  const { deps, calls } = dependencies({
    directProviderConfigured: () => true,
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.model, "speech-2.8-turbo");
  assert.deepEqual(calls.map(([name]) => name), [
    "claim",
    "generate-direct",
    "bind",
    "store",
    "complete-provider",
    "sign",
  ]);
  const manifest = calls.find(([name]) => name === "complete-provider")[1]
    .p_result_manifest;
  assert.equal(manifest.provider, "minimax");
  assert.equal(manifest.model, "speech-2.8-turbo");
});

test("requires authentication before credit claim or provider submission", async () => {
  const { deps, calls } = dependencies();
  const response = await createGenerateVoiceHandler(deps)(
    request(requestBody, ""),
  );
  assert.equal(response.status, 401);
  assert.deepEqual(calls, []);
});

test("lost submit response is marked ambiguous and never refunded", async () => {
  const ambiguous = new Error("lost response");
  ambiguous.submissionAmbiguous = true;
  const { deps, calls } = dependencies({
    submitGeneration: async () => {
      calls.push(["submit"]);
      throw ambiguous;
    },
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 425);
  assert.equal(calls.filter(([name]) => name === "submit").length, 1);
  assert.equal(calls.filter(([name]) => name === "ambiguous").length, 1);
  assert.equal(calls.filter(([name]) => name === "fail").length, 0);
});

test("retry polls the bound queue request instead of resubmitting", async () => {
  const { deps, calls } = dependencies({
    claimGeneration: async (parameters) => {
      calls.push(["claim", parameters]);
      return {
        status: "in_progress",
        attempt: 1,
        credits_remaining: 940,
        provider_request_id: providerRequestID,
      };
    },
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 425);
  assert.equal(calls.filter(([name]) => name === "provider-status").length, 1);
  assert.equal(calls.filter(([name]) => name === "submit").length, 0);
});

test("retry finalizes a completed queue result and re-signs private audio", async () => {
  const { deps, calls } = dependencies({
    claimGeneration: async () => ({
      status: "in_progress",
      attempt: 1,
      credits_remaining: 940,
      provider_request_id: providerRequestID,
    }),
    getProviderStatus: async () => ({ state: "completed" }),
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.credits_remaining, 940);
  assert.equal(payload.replayed, false);
  assert.deepEqual(
    calls.map(([name]) => name),
    ["provider-result", "store", "complete-provider", "sign"],
  );
});

test("successful ledger replay only re-signs and never calls fal", async () => {
  const manifest = {
    version: 1,
    provider: "fal",
    model: "fal-ai/elevenlabs/tts/eleven-v3",
    object: {
      path: `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`,
      mimeType: "audio/mpeg",
      sha256: "a".repeat(64),
    },
  };
  const { deps, calls } = dependencies({
    claimGeneration: async () => ({
      status: "replay",
      credits_remaining: 940,
      result_manifest: manifest,
    }),
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 200);
  assert.deepEqual(calls.map(([name]) => name), ["sign"]);
});

test("saved result re-signs even while FAL_KEY is unavailable", async () => {
  const manifest = {
    version: 1,
    provider: "fal",
    model: "fal-ai/elevenlabs/tts/eleven-v3",
    object: {
      path: `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`,
      mimeType: "audio/mpeg",
      sha256: "a".repeat(64),
    },
  };
  const { deps, calls } = dependencies({
    providerConfigured: () => false,
    lookupGeneration: async () => ({
      status: "succeeded",
      credits_remaining: 940,
      result_manifest: manifest,
    }),
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 200);
  assert.deepEqual(calls.map(([name]) => name), ["sign"]);
});

test("definitive submit rejection refunds through the claim-bound exact-once RPC", async () => {
  const { deps, calls } = dependencies({
    submitGeneration: async () => {
      throw new Error("definitive rejection");
    },
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  const payload = await response.json();
  assert.equal(response.status, 503);
  assert.equal(payload.refunded, true);
  assert.equal(calls.filter(([name]) => name === "fail").length, 1);
  assert.equal(calls.filter(([name]) => name === "rejected").length, 1);
  assert.equal(calls.filter(([name]) => name === "ambiguous").length, 0);
});

test("definitive rejection persists terminal evidence when refund RPC is down", async () => {
  const { deps, calls } = dependencies({
    submitGeneration: async () => {
      throw new Error("definitive rejection");
    },
    failGeneration: async () => {
      throw new Error("database temporarily unavailable");
    },
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 503);
  assert.equal(calls.filter(([name]) => name === "rejected").length, 1);
  assert.equal(calls.filter(([name]) => name === "ambiguous").length, 0);
});

test("completion racing account deletion removes the just-stored object", async () => {
  const { deps, calls } = dependencies({
    claimGeneration: async () => ({
      status: "in_progress",
      attempt: 1,
      credits_remaining: 940,
      provider_request_id: providerRequestID,
    }),
    getProviderStatus: async () => ({ state: "completed" }),
    completeByProvider: async () => ({ status: "account_deleting" }),
    getByProvider: async () => ({ status: "account_deleting" }),
  });
  const response = await createGenerateVoiceHandler(deps)(request());
  assert.equal(response.status, 425);
  assert.equal(calls.filter(([name]) => name === "delete").length, 1);
});
