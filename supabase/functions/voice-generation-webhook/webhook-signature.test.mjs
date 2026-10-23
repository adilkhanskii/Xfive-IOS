import assert from "node:assert/strict";
import test from "node:test";

import {
  buildFalWebhookMessage,
  verifyFalWebhookSignature,
} from "./webhook-signature.mjs";

function base64URL(bytes) {
  return Buffer.from(bytes).toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function hex(bytes) {
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

test("verifies fal Ed25519 signature over exact raw body and signed headers", async () => {
  const keys = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  );
  const rawBody = new TextEncoder().encode('{"status":"OK"}');
  const now = 1_785_000_000;
  const values = {
    requestId: "fal-request-3",
    userId: "fal-user",
    timestamp: String(now),
    rawBody,
  };
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "Ed25519" },
      keys.privateKey,
      await buildFalWebhookMessage(values),
    ),
  );
  const publicKey = new Uint8Array(
    await crypto.subtle.exportKey(
      "raw",
      keys.publicKey,
    ),
  );
  const headers = new Headers({
    "X-Fal-Webhook-Request-Id": values.requestId,
    "X-Fal-Webhook-User-Id": values.userId,
    "X-Fal-Webhook-Timestamp": values.timestamp,
    "X-Fal-Webhook-Signature": hex(signature),
  });
  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody,
      jwks: {
        keys: [{ kty: "OKP", crv: "Ed25519", x: base64URL(publicKey) }],
      },
      nowSeconds: now,
    }),
    true,
  );
  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody: new TextEncoder().encode('{"status":"ERROR"}'),
      jwks: {
        keys: [{ kty: "OKP", crv: "Ed25519", x: base64URL(publicKey) }],
      },
      nowSeconds: now,
    }),
    false,
  );
});

test("rejects webhook timestamps outside fal's five-minute window", async () => {
  const headers = new Headers({
    "X-Fal-Webhook-Request-Id": "fal-request",
    "X-Fal-Webhook-User-Id": "fal-user",
    "X-Fal-Webhook-Timestamp": "1",
    "X-Fal-Webhook-Signature": "00".repeat(64),
  });
  assert.equal(
    await verifyFalWebhookSignature({
      headers,
      rawBody: new Uint8Array([1]),
      jwks: { keys: [] },
      nowSeconds: 1_000,
    }),
    false,
  );
});
