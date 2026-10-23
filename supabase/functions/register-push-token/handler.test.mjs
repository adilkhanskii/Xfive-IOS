import assert from "node:assert/strict";
import test from "node:test";

import {
  createRegisterPushTokenHandler,
  normalizePlatform,
} from "./handler.mjs";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const ACCESS_TOKEN = "signed-user-access-token-value";

test("requires exact ios, android or web without accepting legacy Expo writes", async () => {
  assert.equal(normalizePlatform("ios"), "ios");
  assert.equal(normalizePlatform("android"), "android");
  assert.equal(normalizePlatform("web"), "web");
  assert.equal(normalizePlatform("expo"), null);
  assert.equal(normalizePlatform(undefined), null);

  const response = await handler()(request({
    platform: "desktop",
    token: "a".repeat(64),
  }));
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "invalid_platform" });
});

test("web uses the FCM token contract and supports browser preflight", async () => {
  let saved;
  const response = await handler({
    saveToken: (_userID, registration) => {
      saved = registration;
      return "2026-08-01T00:00:00.000Z";
    },
  })(request({ platform: "web", token: "valid_web_fcm_token_value" }));
  assert.equal(response.status, 200);
  assert.deepEqual(saved, {
    platform: "web",
    token: "valid_web_fcm_token_value",
  });

  const preflight = await handler()(
    new Request("https://example.test", {
      method: "OPTIONS",
    }),
  );
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get("access-control-allow-methods"), /DELETE/);
});

test("rejects malformed and oversized JSON without throwing", async () => {
  const malformed = await handler()(
    new Request("https://example.test", {
      method: "POST",
      headers: headers(),
      body: "{",
    }),
  );
  assert.equal(malformed.status, 400);
  assert.deepEqual(await malformed.json(), { error: "invalid_payload" });

  const oversized = await handler()(
    new Request("https://example.test", {
      method: "POST",
      headers: { ...headers(), "content-length": "6000" },
      body: JSON.stringify({ platform: "android", token: "a".repeat(30) }),
    }),
  );
  assert.equal(oversized.status, 413);
  assert.deepEqual(await oversized.json(), { error: "payload_too_large" });
});

test("saves only under the JWT-derived user id", async () => {
  let saved;
  const response = await handler({
    saveToken: (userID, registration) => {
      saved = { userID, registration };
      return "2026-08-01T00:00:00.000Z";
    },
  })(request({ platform: "android", token: "valid_fcm_token_with_length" }));

  assert.equal(response.status, 200);
  assert.deepEqual(saved, {
    userID: USER_ID,
    registration: {
      platform: "android",
      token: "valid_fcm_token_with_length",
    },
  });
});

test("database details are never returned to the caller", async () => {
  const response = await handler({
    saveToken: () => {
      throw new Error("relation push_tokens contains secret detail");
    },
  })(request({ platform: "ios", token: "a".repeat(64) }));

  assert.equal(response.status, 503);
  const body = await response.text();
  assert.equal(body.includes("relation"), false);
  assert.deepEqual(JSON.parse(body), { error: "push_token_save_failed" });
});

test("DELETE unregisters only the authenticated user's exact tuple", async () => {
  let deleted;
  const response = await handler({
    deleteToken: (userID, registration) => {
      deleted = { userID, registration };
      return { deleted: true, profileCleared: true };
    },
  })(request(
    { platform: "ios", token: "a".repeat(64) },
    "DELETE",
  ));

  assert.equal(response.status, 200);
  assert.deepEqual(deleted, {
    userID: USER_ID,
    registration: { platform: "ios", token: "a".repeat(64) },
  });
  assert.deepEqual(await response.json(), {
    ok: true,
    platform: "ios",
    deleted: true,
    profile_cleared: true,
  });
});

test("DELETE mismatch is idempotent and cannot clear a newer token", async () => {
  const response = await handler({
    deleteToken: () => ({ deleted: false, profileCleared: false }),
  })(request(
    { platform: "android", token: "valid_fcm_token_with_length" },
    "DELETE",
  ));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    platform: "android",
    deleted: false,
    profile_cleared: false,
  });
});

test("rejects payload identity fields and missing authorization", async () => {
  const extra = await handler()(request({
    platform: "ios",
    token: "a".repeat(64),
    user_id: "22222222-2222-4222-8222-222222222222",
  }));
  assert.equal(extra.status, 400);

  const unauthorized = await handler()(
    new Request("https://example.test", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ platform: "ios", token: "a".repeat(64) }),
    }),
  );
  assert.equal(unauthorized.status, 401);
});

function handler(overrides = {}) {
  return createRegisterPushTokenHandler({
    loadUserID: () => USER_ID,
    saveToken: () => "2026-08-01T00:00:00.000Z",
    deleteToken: () => ({ deleted: false, profileCleared: false }),
    ...overrides,
  });
}

function request(body, method = "POST") {
  return new Request("https://example.test", {
    method,
    headers: headers(),
    body: JSON.stringify(body),
  });
}

function headers() {
  return {
    authorization: `Bearer ${ACCESS_TOKEN}`,
    "content-type": "application/json",
  };
}
