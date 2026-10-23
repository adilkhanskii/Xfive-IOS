import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  buildFCMV1Request,
  FCM_TOKEN_URI,
  normalizeFCMServiceAccount,
} from "./fcm-provider.mjs";

const PRIVATE_KEY = [
  "-----BEGIN PRIVATE KEY-----",
  "not-a-real-test-key",
  "-----END PRIVATE KEY-----",
].join("\n");

test("builds the official FCM HTTP v1 device contract", () => {
  const config = normalizeFCMServiceAccount(JSON.stringify({
    project_id: "x5-mobile-prod",
    client_email: "push@x5-mobile-prod.iam.gserviceaccount.com",
    private_key: PRIVATE_KEY,
    token_uri: FCM_TOKEN_URI,
  }));
  const request = buildFCMV1Request({
    config,
    accessToken: "short-lived-oauth-token",
    pushToken: "fcm_registration_token_with_enough_length",
    collapseID: "11111111-1111-4111-8111-111111111111",
    platform: "android",
    message: {
      title: "Task",
      body: "New message",
      data: {
        type: "message",
        task_id: "22222222-2222-4222-8222-222222222222",
      },
    },
  });

  assert.equal(
    request.url,
    "https://fcm.googleapis.com/v1/projects/x5-mobile-prod/messages:send",
  );
  assert.equal(
    request.init.headers.authorization,
    "Bearer short-lived-oauth-token",
  );
  const body = JSON.parse(request.init.body);
  assert.equal(body.message.token, "fcm_registration_token_with_enough_length");
  assert.equal(
    body.message.data.task_id,
    "22222222-2222-4222-8222-222222222222",
  );
  assert.equal(
    body.message.android.collapse_key,
    "11111111-1111-4111-8111-111111111111",
  );
  assert.equal(request.init.body.includes("PRIVATE KEY"), false);
});

test("builds web FCM delivery with an HTTPS click link instead of Android config", () => {
  const config = normalizeFCMServiceAccount(JSON.stringify({
    project_id: "x5-mobile-prod",
    client_email: "push@x5-mobile-prod.iam.gserviceaccount.com",
    private_key: PRIVATE_KEY,
    token_uri: FCM_TOKEN_URI,
  }));
  const request = buildFCMV1Request({
    config,
    accessToken: "short-lived-oauth-token",
    pushToken: "web_registration_token_with_enough_length",
    collapseID: "11111111-1111-4111-8111-111111111111",
    platform: "web",
    message: {
      title: "Task",
      body: "New message",
      data: { type: "message", chat_id: "chat-1" },
      link: "https://app.example.test/?push=1&chat_id=chat-1",
    },
  });
  const body = JSON.parse(request.init.body);
  assert.equal(body.message.android, undefined);
  assert.equal(body.message.webpush.headers.Urgency, "high");
  assert.equal(
    body.message.webpush.fcm_options.link,
    "https://app.example.test/?push=1&chat_id=chat-1",
  );
});

test("rejects malformed or redirectable service-account token configuration", () => {
  assert.throws(
    () => normalizeFCMServiceAccount("{}"),
    /fcm_credentials_invalid/,
  );
  assert.throws(
    () =>
      normalizeFCMServiceAccount(JSON.stringify({
        project_id: "x5-mobile-prod",
        client_email: "push@x5-mobile-prod.iam.gserviceaccount.com",
        private_key: PRIVATE_KEY,
        token_uri: "https://attacker.example/token",
      })),
    /fcm_credentials_invalid/,
  );
});

test("production source contains no legacy FCM server-key endpoint", async () => {
  const source = await readFile(new URL("./index.ts", import.meta.url), "utf8");
  assert.doesNotMatch(source, /FCM_SERVER_KEY/);
  assert.doesNotMatch(source, /fcm\.googleapis\.com\/fcm\/send/);
  assert.match(source, /FCM_SERVICE_ACCOUNT_JSON/);
  assert.match(source, /firebase\.messaging/);
});
