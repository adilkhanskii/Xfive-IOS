import assert from "node:assert/strict";
import test from "node:test";

import {
  buildFalWebhookMessage,
  verifyFalWebhookSignature,
} from "./webhook.mjs";

function bytesToHex(bytes) {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function bytesToBase64Url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

test("verifies fal ED25519 signatures over the raw webhook body", async () => {
  const nowSeconds = 1_784_998_800;
  const rawBody = new TextEncoder().encode(JSON.stringify({
    request_id: "fal-request-3",
    status: "OK",
    payload: { video: { url: "https://v3.fal.media/result.mp4" } },
  }));
  const keys = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  );
  const rawPublicKey = await crypto.subtle.exportKey("raw", keys.publicKey);
  const message = await buildFalWebhookMessage({
    requestId: "fal-request-3",
    userId: "fal-user",
    timestamp: String(nowSeconds),
    rawBody,
  });
  const signature = await crypto.subtle.sign(
    { name: "Ed25519" },
    keys.privateKey,
    message,
  );
  const headers = new Headers({
    "X-Fal-Webhook-Request-Id": "fal-request-3",
    "X-Fal-Webhook-User-Id": "fal-user",
    "X-Fal-Webhook-Timestamp": String(nowSeconds),
    "X-Fal-Webhook-Signature": bytesToHex(signature),
  });
  const jwks = {
    keys: [{ kty: "OKP", crv: "Ed25519", x: bytesToBase64Url(rawPublicKey) }],
  };

  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody,
      jwks,
      nowSeconds,
    }),
    true,
  );
  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody: new TextEncoder().encode('{"tampered":true}'),
      jwks,
      nowSeconds,
    }),
    false,
  );
});

test("rejects missing headers and timestamps outside the five-minute window", async () => {
  const rawBody = new TextEncoder().encode("{}");
  assert.equal(
    await verifyFalWebhookSignature({
      headers: new Headers(),
      rawBody,
      jwks: { keys: [] },
      nowSeconds: 1_000,
    }),
    false,
  );

  const headers = new Headers({
    "X-Fal-Webhook-Request-Id": "fal-request",
    "X-Fal-Webhook-User-Id": "fal-user",
    "X-Fal-Webhook-Timestamp": "1",
    "X-Fal-Webhook-Signature": "00".repeat(64),
  });
  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody,
      jwks: { keys: [] },
      nowSeconds: 1_000,
    }),
    false,
  );
});
