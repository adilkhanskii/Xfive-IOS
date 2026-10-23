import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import {
  createGoogleWebhookHandler,
  readBoundedRequestBody,
  verifyGoogleWebhookJwt,
} from "./google-webhook.mjs";

const callbackUrl =
  "https://project.supabase.co/functions/v1/generate-video?webhook=google";
const jobId = "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f";
const claimToken =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const requestId = "google_interaction_123";
const nowSeconds = 1_785_000_000;

const keyPair = await webcrypto.subtle.generateKey(
  {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: "SHA-256",
  },
  true,
  ["sign", "verify"],
);
const publicJwk = {
  ...(await webcrypto.subtle.exportKey("jwk", keyPair.publicKey)),
  kid: "google-webhook-test-key",
  alg: "RS256",
  use: "sig",
};

function base64Url(value) {
  return Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

async function signJwt(overrides = {}, signingKey = keyPair.privateKey) {
  const header = base64Url(JSON.stringify({
    alg: "RS256",
    typ: "JWT",
    kid: publicJwk.kid,
  }));
  const payload = base64Url(JSON.stringify({
    iss: "https://accounts.google.com",
    aud: callbackUrl,
    iat: nowSeconds - 1,
    exp: nowSeconds + 300,
    ...overrides,
  }));
  const input = `${header}.${payload}`;
  const signature = await webcrypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    signingKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${base64Url(Buffer.from(signature))}`;
}

async function webhookRequest(payload, overrides = {}) {
  return new Request(callbackUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Webhook-Id": "google_event_123",
      "Webhook-Timestamp": String(nowSeconds),
      "Webhook-Signature": await signJwt(overrides.jwt || {}),
      ...(overrides.headers || {}),
    },
    body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });
}

function completionPayload(overrides = {}) {
  return {
    event_type: "interaction.completed",
    interaction: {
      id: requestId,
      status: "completed",
      user_metadata: {
        job_id: jobId,
        claim_token: claimToken,
      },
    },
    ...overrides,
  };
}

function dependencies(overrides = {}) {
  const calls = [];
  return {
    calls,
    deps: {
      callbackUrl,
      nowSeconds: () => nowSeconds,
      getJwks: async () => ({ keys: [publicJwk] }),
      bindJob: async (parameters) => {
        calls.push(["bind", parameters]);
        return { status: "bound" };
      },
      getJob: async ({ jobId: loadedId }) => {
        calls.push(["get", loadedId]);
        return {
          id: jobId,
          user_id: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
          provider_name: "google",
          provider_kind: "text",
          provider_request_id: requestId,
          status: "rendering",
          progress: 0.5,
        };
      },
      reconcileJob: async (job) => {
        calls.push(["reconcile", job.id]);
        return { ...job, status: "completed", progress: 1 };
      },
      failJob: async (parameters) => {
        calls.push(["fail", parameters]);
        return { status: "failed", refunded: true };
      },
      cleanupInput: async (job) => {
        calls.push(["cleanup", job.id]);
      },
      ...overrides,
    },
  };
}

test("verifies a fresh Google RS256 JWT for the exact callback audience", async () => {
  assert.equal(
    await verifyGoogleWebhookJwt({
      token: await signJwt(),
      jwks: { keys: [publicJwk] },
      expectedAudience: callbackUrl,
      nowSeconds,
    }),
    true,
  );
  assert.equal(
    await verifyGoogleWebhookJwt({
      token: await signJwt({ aud: `${callbackUrl}&wrong=1` }),
      jwks: { keys: [publicJwk] },
      expectedAudience: callbackUrl,
      nowSeconds,
    }),
    false,
  );
  assert.equal(
    await verifyGoogleWebhookJwt({
      token: await signJwt({ aud: [callbackUrl, "https://attacker.example"] }),
      jwks: { keys: [publicJwk] },
      expectedAudience: callbackUrl,
      nowSeconds,
    }),
    false,
  );
});

test("rejects a stale timestamp, invalid audience, and invalid signature", async () => {
  const otherKeys = await webcrypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const handler = createGoogleWebhookHandler(dependencies().deps);

  for (
    const request of [
      await webhookRequest(completionPayload(), {
        headers: { "Webhook-Timestamp": String(nowSeconds - 301) },
      }),
      await webhookRequest(completionPayload(), {
        jwt: { aud: "https://attacker.example/webhook" },
      }),
      await webhookRequest(completionPayload(), {
        headers: {
          "Webhook-Signature": await signJwt({}, otherKeys.privateKey),
        },
      }),
    ]
  ) {
    const response = await handler(request);
    assert.equal(response.status, 401);
  }
});

test("hard-stops request streaming after one MiB", async () => {
  await assert.rejects(
    readBoundedRequestBody(
      new Request(callbackUrl, {
        method: "POST",
        body: "x".repeat(1024 * 1024 + 1),
      }),
    ),
    /webhook_body_too_large/,
  );

  const handler = createGoogleWebhookHandler(dependencies().deps);
  const response = await handler(
    new Request(callbackUrl, {
      method: "POST",
      headers: { "Content-Length": String(1024 * 1024 + 1) },
      body: "x",
    }),
  );
  assert.equal(response.status, 413);
});

test("binds by opaque metadata then finalizes a completed callback", async () => {
  const { deps, calls } = dependencies();
  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest(completionPayload()),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(calls[0], ["bind", {
    p_job_id: jobId,
    p_claim_token: claimToken,
    p_provider_request_id: requestId,
  }]);
  assert.deepEqual(
    calls.filter(([name]) => name === "reconcile"),
    [["reconcile", jobId]],
  );
  assert.deepEqual(
    calls.filter(([name]) => name === "cleanup"),
    [["cleanup", jobId]],
  );
});

test("accepts Google's documented thin envelope with top-level metadata", async () => {
  const resultUrl =
    "https://generativelanguage.googleapis.com/v1beta/files/video-123:download?alt=media";
  const { deps, calls } = dependencies({
    finalizeResult: async (job, resultHint) => {
      calls.push(["finalize", job.id, resultHint]);
      return { status: "completed" };
    },
  });
  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest({
      type: "video.generated",
      version: "v1",
      timestamp: "2026-07-26T15:00:00Z",
      data: {
        id: requestId,
        output_file_uri: resultUrl,
        file_name: "files/video-123",
      },
      user_metadata: {
        job_id: jobId,
        claim_token: claimToken,
      },
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(calls.filter(([name]) => name === "bind").length, 1);
  assert.deepEqual(
    calls.filter(([name]) => name === "finalize"),
    [["finalize", jobId, { url: resultUrl, mimeType: "video/mp4" }]],
  );
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
});

test("uses a canonical Google download URL when webhook URI is not HTTPS", async () => {
  const { deps, calls } = dependencies({
    finalizeResult: async (job, resultHint) => {
      calls.push(["finalize", job.id, resultHint]);
      return { status: "completed" };
    },
  });
  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest({
      type: "video.generated",
      data: {
        id: requestId,
        output_file_uri: "gs://provider-private/result.mp4",
        file_name: "files/video-123",
      },
      user_metadata: {
        job_id: jobId,
        claim_token: claimToken,
      },
    }),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.filter(([name]) => name === "finalize"),
    [["finalize", jobId, {
      url:
        "https://generativelanguage.googleapis.com/v1beta/files/video-123:download?alt=media",
      mimeType: "video/mp4",
    }]],
  );
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
});

test("never hands an untrusted webhook result host to storage", async () => {
  const { deps, calls } = dependencies({
    finalizeResult: async (job, resultHint) => {
      calls.push(["finalize", job.id, resultHint]);
      return { status: "completed" };
    },
  });
  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest({
      type: "video.generated",
      data: {
        id: requestId,
        output_file_uri: "https://attacker.example/result.mp4",
        file_name: "../../metadata",
      },
      user_metadata: {
        job_id: jobId,
        claim_token: claimToken,
      },
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(calls.filter(([name]) => name === "finalize").length, 0);
  assert.deepEqual(
    calls.filter(([name]) => name === "reconcile"),
    [["reconcile", jobId]],
  );
});

test("fails and refunds incomplete callbacks exactly once", async () => {
  const { deps, calls } = dependencies({
    bindJob: async (parameters) => {
      calls.push(["bind", parameters]);
      return { status: "already_bound" };
    },
  });
  const payload = completionPayload();
  payload.interaction.status = "incomplete";

  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest(payload),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.filter(([name]) => name === "fail"),
    [["fail", {
      p_job_id: jobId,
      p_provider_request_id: requestId,
      p_error_code: "provider_incomplete",
    }]],
  );
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("accepts a terminal replay without a second provider reconciliation", async () => {
  const { deps, calls } = dependencies({
    bindJob: async (parameters) => {
      calls.push(["bind", parameters]);
      return { status: "already_terminal" };
    },
    getJob: async () => ({
      id: jobId,
      provider_name: "google",
      provider_request_id: requestId,
      status: "failed",
    }),
  });

  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest(completionPayload()),
  );

  assert.equal(response.status, 200);
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("rejects a wrong claim token, provider, or provider request id", async () => {
  for (
    const overrides of [
      {
        bindJob: async () => ({ status: "stale_claim" }),
        expectedStatus: 401,
      },
      {
        getJob: async () => ({
          id: jobId,
          provider_name: "fal",
          provider_request_id: requestId,
          status: "rendering",
        }),
        expectedStatus: 409,
      },
      {
        bindJob: async () => ({ status: "submission_conflict" }),
        expectedStatus: 409,
      },
    ]
  ) {
    const { expectedStatus, ...depsOverrides } = overrides;
    const handler = createGoogleWebhookHandler(
      dependencies(depsOverrides).deps,
    );
    const response = await handler(
      await webhookRequest(completionPayload()),
    );
    assert.equal(response.status, expectedStatus);
  }
});

test("returns non-2xx so Google retries when completion is not yet durable", async () => {
  const { deps } = dependencies({
    reconcileJob: async (job) => job,
  });
  const response = await createGoogleWebhookHandler(deps)(
    await webhookRequest(completionPayload()),
  );
  assert.equal(response.status, 503);
});
