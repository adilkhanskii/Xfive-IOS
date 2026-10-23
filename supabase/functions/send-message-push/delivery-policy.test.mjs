import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyProviderFailure,
  deliverPushTargets,
  normalizePushPlatform,
} from "./delivery-policy.mjs";

const DELIVERY = {
  eventID: "11111111-1111-4111-8111-111111111111",
  collapseID: "11111111-1111-4111-8111-111111111111",
};

test("one success plus one transient target keeps recipient dispatch retryable", async () => {
  const attempts = [];
  const result = await deliverPushTargets({
    targets: [target("ios", "one"), target("web", "two")],
    delivery: DELIVERY,
    sendTarget: (item, delivery) => {
      attempts.push([item.platform, delivery.eventID, delivery.collapseID]);
      return item.platform === "ios"
        ? new Response(null, { status: 200 })
        : new Response(JSON.stringify({ error: { status: "UNAVAILABLE" } }), {
          status: 503,
        });
    },
    disableTarget: () => assert.fail("transient token must not be deleted"),
    logger: { error() {} },
  });

  assert.deepEqual(result, { status: "failed" });
  assert.deepEqual(attempts, [
    ["ios", DELIVERY.eventID, DELIVERY.collapseID],
    ["web", DELIVERY.eventID, DELIVERY.collapseID],
  ]);
});

test("a retry sends only the transient target and freezes prior success", async () => {
  const state = new Map();
  const sends = [];
  const ios = target("ios", "one");
  const web = target("web", "two");
  let webAttempt = 0;
  const options = {
    targets: [ios, web],
    delivery: DELIVERY,
    claimTarget: (item) => ({
      status: state.get(item.token) === "sent" ? "already_sent" : "claimed",
      targetKey: item.token,
    }),
    recordTargetOutcome: (item, _claim, outcome) => {
      state.set(item.token, outcome === "sent" ? "sent" : "pending");
    },
    sendTarget: (item) => {
      sends.push(item.token);
      if (item === ios) return new Response(null, { status: 200 });
      webAttempt += 1;
      return webAttempt === 1
        ? new Response("unavailable", { status: 503 })
        : new Response(null, { status: 200 });
    },
    disableTarget: () => assert.fail("transient token must not be deleted"),
    logger: { error() {} },
  };

  assert.deepEqual(await deliverPushTargets(options), { status: "failed" });
  assert.deepEqual(await deliverPushTargets(options), { status: "sent" });
  assert.deepEqual(sends, ["one", "two", "two"]);
});

test("one success plus one permanently invalid token completes after exact cleanup", async () => {
  const disabled = [];
  const invalid = target("android", "invalid-registration");
  const result = await deliverPushTargets({
    targets: [target("ios", "valid-apns"), invalid],
    delivery: DELIVERY,
    sendTarget: (item) =>
      item === invalid
        ? fcmError("UNREGISTERED", 404)
        : new Response(null, { status: 200 }),
    disableTarget: (item) => disabled.push(item),
    logger: { error() {} },
  });

  assert.deepEqual(result, { status: "sent" });
  assert.deepEqual(disabled, [invalid]);
});

test("permanent token cleanup failure remains retryable", async () => {
  const result = await deliverPushTargets({
    targets: [target("web", "invalid-web")],
    delivery: DELIVERY,
    sendTarget: () => fcmError("UNREGISTERED", 404),
    disableTarget: () => {
      throw new Error("database unavailable");
    },
    logger: { error() {} },
  });
  assert.deepEqual(result, { status: "failed" });
});

test("only explicit APNs and FCM invalid-token verdicts are permanent", async () => {
  assert.equal(
    await classifyProviderFailure(
      "ios",
      new Response('{"reason":"Unregistered"}', { status: 410 }),
    ),
    "permanent_invalid_token",
  );
  assert.equal(
    await classifyProviderFailure(
      "web",
      new Response('{"error":{"status":"INVALID_ARGUMENT"}}', { status: 400 }),
    ),
    "transient",
  );
});

test("platform mapping keeps web on FCM and rejects unknown values", () => {
  assert.equal(normalizePushPlatform("ios"), "ios");
  assert.equal(normalizePushPlatform("android"), "android");
  assert.equal(normalizePushPlatform("web"), "web");
  assert.equal(normalizePushPlatform("desktop"), null);
});

function target(platform, token) {
  return { platform, token, records: [] };
}

function fcmError(errorCode, status) {
  return new Response(
    JSON.stringify({
      error: {
        details: [{
          "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
          errorCode,
        }],
      },
    }),
    { status },
  );
}
