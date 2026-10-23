// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import {
  createVoiceWebhookHandler,
  readBoundedRequestBody,
} from "./handler.mjs";

const claim = "c".repeat(64);
const requestID = "024ca5b1-45d3-4afd-883e-ad3abe2a1c4d";
const userID = "11111111-1111-4111-8111-111111111111";
const requestKey = `explicit:${"a".repeat(64)}`;
const requestFingerprint = "b".repeat(64);

function request(payload, headerRequestID = requestID) {
  return new Request(
    `https://project.supabase.co/functions/v1/voice-generation-webhook?claim=${claim}&attempt=1`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Fal-Webhook-Request-Id": headerRequestID,
      },
      body: JSON.stringify(payload),
    },
  );
}

function dependencies(overrides = {}) {
  const calls = [];
  return {
    calls,
    deps: {
      verifyWebhook: async (parameters) => {
        calls.push(["verify", parameters]);
        return true;
      },
      bindWebhook: async (parameters) => {
        calls.push(["bind", parameters]);
        return {
          status: "bound",
          user_id: userID,
          request_key: requestKey,
          request_fingerprint: requestFingerprint,
          attempt: 1,
          credits_remaining: 940,
        };
      },
      storeAudio: async (parameters) => {
        calls.push(["store", parameters]);
        return {
          path: `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`,
          mimeType: "audio/mpeg",
          sha256: "d".repeat(64),
        };
      },
      completeByProvider: async (parameters) => {
        calls.push(["complete", parameters]);
        return {
          status: "completed",
          result_manifest: parameters.p_result_manifest,
          credits_remaining: 940,
        };
      },
      getByProvider: async () => ({ status: "processing" }),
      failByProvider: async (parameters) => {
        calls.push(["fail", parameters]);
        return { status: "refunded", credits_remaining: 1_000 };
      },
      deleteAudio: async (path) => calls.push(["delete", path]),
      sleep: async () => {},
      ...overrides,
    },
  };
}

test("lost submit response is recovered by signed webhook claim correlation", async () => {
  const { deps, calls } = dependencies();
  const response = await createVoiceWebhookHandler(deps)(request({
    request_id: requestID,
    status: "OK",
    payload: {
      audio: {
        url: "https://v3.fal.media/files/zebra/generated.mp3",
      },
    },
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.map(([name]) => name),
    ["verify", "bind", "store", "complete"],
  );
  const binding = calls.find(([name]) => name === "bind")[1];
  assert.equal(binding.p_claim_token, claim);
  assert.equal(binding.p_provider_request_id, requestID);
});

test("header/body request ID mismatch is rejected before ledger access", async () => {
  const { deps, calls } = dependencies();
  const response = await createVoiceWebhookHandler(deps)(request({
    request_id: "different-request",
    status: "OK",
    payload: {},
  }));
  assert.equal(response.status, 401);
  assert.deepEqual(calls.map(([name]) => name), ["verify"]);
});

test("invalid signature fails closed before binding", async () => {
  const { deps, calls } = dependencies({
    verifyWebhook: async () => {
      calls.push(["verify"]);
      return false;
    },
  });
  const response = await createVoiceWebhookHandler(deps)(request({
    request_id: requestID,
    status: "OK",
    payload: {},
  }));
  assert.equal(response.status, 401);
  assert.deepEqual(calls.map(([name]) => name), ["verify"]);
});

test("duplicate delivery after completion is idempotently acknowledged", async () => {
  const { deps, calls } = dependencies({
    bindWebhook: async () => {
      calls.push(["bind"]);
      return { status: "already_completed" };
    },
  });
  const response = await createVoiceWebhookHandler(deps)(request({
    request_id: requestID,
    status: "OK",
    payload: {
      audio: {
        url: "https://v3.fal.media/files/zebra/generated.mp3",
      },
    },
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(calls.map(([name]) => name), ["verify", "bind"]);
});

test("late callback for deleting account fetches and stores no media", async () => {
  const { deps, calls } = dependencies({
    bindWebhook: async () => {
      calls.push(["bind"]);
      return { status: "account_deleting" };
    },
  });
  const response = await createVoiceWebhookHandler(deps)(request({
    request_id: requestID,
    status: "OK",
    payload: {
      audio: {
        url: "https://v3.fal.media/files/zebra/generated.mp3",
      },
    },
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(calls.map(([name]) => name), ["verify", "bind"]);
});

test("public webhook body is stream-bounded before signature verification", async () => {
  const oversized = new Request("https://example.test/webhook", {
    method: "POST",
    headers: { "Content-Length": "1048577" },
    body: "x",
  });
  await assert.rejects(
    readBoundedRequestBody(oversized),
    /webhook_body_too_large/,
  );
});
