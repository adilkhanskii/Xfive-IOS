import assert from "node:assert/strict";
import test from "node:test";

import * as helpers from "./entitlements.mjs";

const future = "2026-08-17T00:00:00Z";
const now = Date.parse("2026-07-17T00:00:00Z");

test("active subscription uses the matching line item's successful order", () => {
  assert.equal(typeof helpers.extractSubscriptionEntitlement, "function");
  if (typeof helpers.extractSubscriptionEntitlement !== "function") return;

  const result = helpers.extractSubscriptionEntitlement(
    "x5_pro_monthly_v2",
    {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      latestOrderId: "GPA.pending-do-not-use",
      acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
      lineItems: [{
        productId: "x5_pro_monthly_v2",
        expiryTime: future,
        latestSuccessfulOrderId: "GPA.successful-renewal",
      }],
    },
    now,
  );

  assert.deepEqual(result, {
    ok: true,
    expiry: future,
    orderId: "GPA.successful-renewal",
    acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
  });
});

test("grace and canceled snapshots keep the same successful-order claim", () => {
  assert.equal(typeof helpers.extractSubscriptionEntitlement, "function");
  assert.equal(typeof helpers.buildGooglePlayClaimKey, "function");
  if (
    typeof helpers.extractSubscriptionEntitlement !== "function" ||
    typeof helpers.buildGooglePlayClaimKey !== "function"
  ) return;

  const claims = [
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    "SUBSCRIPTION_STATE_CANCELED",
  ].map((subscriptionState) => {
    const result = helpers.extractSubscriptionEntitlement(
      "x5_lite_monthly_v2",
      {
        subscriptionState,
        latestOrderId: `GPA.${subscriptionState}.pending`,
        acknowledgementState: "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
        lineItems: [{
          productId: "x5_lite_monthly_v2",
          expiryTime: future,
          latestSuccessfulOrderId: "GPA.last-paid-order",
        }],
      },
      now,
    );
    assert.equal(result.ok, true);
    return helpers.buildGooglePlayClaimKey(
      "x5_lite_monthly_v2",
      "token-hash",
      result.orderId,
    );
  });

  assert.deepEqual(claims, [
    "x5_lite_monthly_v2:token-hash:GPA.last-paid-order",
    "x5_lite_monthly_v2:token-hash:GPA.last-paid-order",
  ]);
});

test("deferred or otherwise unowned subscription item is rejected", () => {
  assert.equal(typeof helpers.extractSubscriptionEntitlement, "function");
  if (typeof helpers.extractSubscriptionEntitlement !== "function") return;

  assert.deepEqual(
    helpers.extractSubscriptionEntitlement(
      "x5_max_monthly_v2",
      {
        subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
        lineItems: [{
          productId: "x5_max_monthly_v2",
          expiryTime: future,
          deferredItemReplacement: { productId: "x5_max_monthly_v2" },
        }],
      },
      now,
    ),
    { ok: false, status: 402, error: "subscription_item_not_owned" },
  );
});

test("changing deprecated top-level order id cannot create another claim", () => {
  assert.equal(typeof helpers.extractSubscriptionEntitlement, "function");
  assert.equal(typeof helpers.buildGooglePlayClaimKey, "function");
  if (
    typeof helpers.extractSubscriptionEntitlement !== "function" ||
    typeof helpers.buildGooglePlayClaimKey !== "function"
  ) return;

  const purchase = {
    subscriptionState: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    acknowledgementState: "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
    lineItems: [{
      productId: "x5_pro_monthly_v2",
      expiryTime: future,
      latestSuccessfulOrderId: "GPA.successful",
    }],
  };
  const first = helpers.extractSubscriptionEntitlement(
    "x5_pro_monthly_v2",
    { ...purchase, latestOrderId: "GPA.pending-1" },
    now,
  );
  const second = helpers.extractSubscriptionEntitlement(
    "x5_pro_monthly_v2",
    { ...purchase, latestOrderId: "GPA.declined-2" },
    now,
  );

  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.equal(first.orderId, "GPA.successful");
  assert.equal(second.orderId, "GPA.successful");
  assert.equal(
    helpers.buildGooglePlayClaimKey("x5_pro_monthly_v2", "hash", first.orderId),
    helpers.buildGooglePlayClaimKey(
      "x5_pro_monthly_v2",
      "hash",
      second.orderId,
    ),
  );
});

test("purchase account binding accepts only the authenticated user's opaque id", () => {
  assert.equal(typeof helpers.validateGooglePlayAccountBinding, "function");
  if (typeof helpers.validateGooglePlayAccountBinding !== "function") return;

  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "subscription",
      purchase: {
        externalAccountIdentifiers: {
          obfuscatedExternalAccountId: "bound-user",
        },
      },
      expectedBinding: "bound-user",
    }),
    { ok: true },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: { obfuscatedExternalAccountId: "other-user" },
      expectedBinding: "bound-user",
    }),
    { ok: false, status: 403, error: "purchase_account_mismatch" },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: {},
      expectedBinding: "bound-user",
    }),
    { ok: false, status: 409, error: "purchase_account_binding_required" },
  );
});

test("unbound APK37 purchases are grandfathered only by exact same-user token ownership", () => {
  const sameUserLedger = [{
    user_id: "user-1",
    app_account_token: "user-1",
    purchase_token_hash: "current-hash",
  }];
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: {},
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["current-hash"],
      ownershipLedgers: sameUserLedger,
    }),
    { ok: true, grandfathered: true },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: {},
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["current-hash"],
      ownershipLedgers: [],
    }),
    { ok: false, status: 409, error: "purchase_account_binding_required" },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: {},
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["current-hash"],
      ownershipLedgers: [{
        user_id: "user-2",
        app_account_token: "user-2",
        purchase_token_hash: "current-hash",
      }],
    }),
    { ok: false, status: 403, error: "purchase_account_mismatch" },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "inapp",
      purchase: { obfuscatedExternalAccountId: "wrong-binding" },
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["current-hash"],
      ownershipLedgers: sameUserLedger,
    }),
    { ok: false, status: 403, error: "purchase_account_mismatch" },
  );
});

test("subscription ownership accepts exact expired or linked predecessor evidence", () => {
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "subscription",
      purchase: {
        outOfAppPurchaseContext: {
          expiredExternalAccountIdentifiers: {
            obfuscatedExternalAccountId: "bound-user",
          },
        },
      },
      expectedBinding: "bound-user",
    }),
    { ok: true },
  );

  const predecessorTokens = helpers.getGooglePlayPredecessorPurchaseTokens({
    outOfAppPurchaseContext: { expiredPurchaseToken: "expired-token" },
    linkedPurchaseToken: "linked-token",
  });
  assert.deepEqual(predecessorTokens, ["expired-token", "linked-token"]);
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "subscription",
      purchase: {},
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["expired-hash", "linked-hash"],
      ownershipLedgers: [{
        user_id: "user-1",
        app_account_token: "user-1",
        purchase_token_hash: "linked-hash",
      }],
    }),
    { ok: true, grandfathered: true },
  );
  assert.deepEqual(
    helpers.validateGooglePlayAccountBinding({
      purchaseType: "subscription",
      purchase: {},
      expectedBinding: "bound-user",
      userId: "user-1",
      allowedTokenHashes: ["expired-hash", "linked-hash"],
      ownershipLedgers: [
        {
          user_id: "user-1",
          app_account_token: "user-1",
          purchase_token_hash: "expired-hash",
        },
        {
          user_id: "user-2",
          app_account_token: "user-2",
          purchase_token_hash: "linked-hash",
        },
      ],
    }),
    { ok: false, status: 403, error: "purchase_account_mismatch" },
  );
});

test("server finalization consumes products and acknowledges subscriptions", async () => {
  assert.equal(typeof helpers.finalizeGooglePlayPurchase, "function");
  if (typeof helpers.finalizeGooglePlayPurchase !== "function") return;

  const calls = [];
  const fetchImpl = (url, options) => {
    calls.push({ url, options });
    return new Response(null, { status: 200 });
  };

  const consumed = await helpers.finalizeGooglePlayPurchase({
    purchaseType: "inapp",
    purchase: { consumptionState: 0 },
    packageName: "com.x5marketing.mobile",
    productId: "x5_credits_1000_v2",
    purchaseToken: "secret-token",
    accessToken: "oauth",
    fetchImpl,
  });
  const acknowledged = await helpers.finalizeGooglePlayPurchase({
    purchaseType: "subscription",
    purchase: { acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING" },
    packageName: "com.x5marketing.mobile",
    productId: "x5_verified_monthly_v2",
    purchaseToken: "secret-token",
    accessToken: "oauth",
    fetchImpl,
  });

  assert.deepEqual(consumed, { ok: true, action: "consumed" });
  assert.deepEqual(acknowledged, { ok: true, action: "acknowledged" });
  assert.match(
    calls[0].url,
    /x5_credits_1000_v2\/tokens\/secret-token:consume$/,
  );
  assert.match(
    calls[1].url,
    /x5_verified_monthly_v2\/tokens\/secret-token:acknowledge$/,
  );
  assert.equal(calls[0].options.method, "POST");
  assert.equal(calls[1].options.method, "POST");
});

test("server finalization skips completed purchases and exposes retryable failure", async () => {
  assert.equal(typeof helpers.finalizeGooglePlayPurchase, "function");
  if (typeof helpers.finalizeGooglePlayPurchase !== "function") return;

  let calls = 0;
  const alreadyDone = await helpers.finalizeGooglePlayPurchase({
    purchaseType: "inapp",
    purchase: { consumptionState: 1 },
    packageName: "com.x5marketing.mobile",
    productId: "x5_credits_1000_v2",
    purchaseToken: "token",
    accessToken: "oauth",
    fetchImpl: () => {
      calls += 1;
      return new Response(null, { status: 200 });
    },
  });
  assert.deepEqual(alreadyDone, { ok: true, action: "already_finalized" });
  assert.equal(calls, 0);

  await assert.rejects(
    helpers.finalizeGooglePlayPurchase({
      purchaseType: "subscription",
      purchase: { acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING" },
      packageName: "com.x5marketing.mobile",
      productId: "x5_verified_monthly_v2",
      purchaseToken: "token",
      accessToken: "oauth",
      fetchImpl: () => new Response("temporary", { status: 503 }),
    }),
    /google_play_finalization_failed:503/,
  );
});

test("account binding is deterministic HMAC material and never exposes user id", async () => {
  assert.equal(typeof helpers.createGooglePlayAccountBinding, "function");
  if (typeof helpers.createGooglePlayAccountBinding !== "function") return;

  const first = await helpers.createGooglePlayAccountBinding(
    "11111111-1111-4111-8111-111111111111",
    "server-only-secret",
  );
  const second = await helpers.createGooglePlayAccountBinding(
    "11111111-1111-4111-8111-111111111111",
    "server-only-secret",
  );
  const other = await helpers.createGooglePlayAccountBinding(
    "22222222-2222-4222-8222-222222222222",
    "server-only-secret",
  );

  assert.equal(first, second);
  assert.notEqual(first, other);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.doesNotMatch(first, /11111111/);
});

test("consume races are retried only for known Google conflict/gone statuses", () => {
  assert.equal(
    helpers.isGooglePlayFinalizationRace(
      new Error("google_play_finalization_failed:409"),
    ),
    true,
  );
  assert.equal(
    helpers.isGooglePlayFinalizationRace(
      new Error("google_play_finalization_failed:410"),
    ),
    true,
  );
  assert.equal(
    helpers.isGooglePlayFinalizationRace(
      new Error("google_play_finalization_failed:503"),
    ),
    false,
  );
  assert.equal(helpers.isGooglePlayPurchaseGone({ status: 404 }), true);
  assert.equal(helpers.isGooglePlayPurchaseGone({ status: 410 }), true);
  assert.equal(helpers.isGooglePlayPurchaseGone({ status: 401 }), false);
});

test("missing consumed product recovers only from the exact owner ledger", () => {
  const base = {
    purchaseType: "inapp",
    googleStatus: 404,
    userId: "user-1",
    productId: "x5_credits_1000_v2",
    tokenHash: "token-hash",
    ledger: {
      user_id: "user-1",
      app_account_token: "user-1",
      product_id: "x5_credits_1000_v2",
      purchase_type: "inapp",
      purchase_token_hash: "token-hash",
      successful_order_id: "GPA.paid",
    },
  };
  assert.equal(helpers.canRecoverKnownConsumedPurchase(base), true);
  assert.equal(
    helpers.canRecoverKnownConsumedPurchase({
      ...base,
      ledger: { ...base.ledger, user_id: "other-user" },
    }),
    false,
  );
  assert.equal(
    helpers.canRecoverKnownConsumedPurchase({
      ...base,
      purchaseType: "subscription",
    }),
    false,
  );
  assert.equal(
    helpers.canRecoverKnownConsumedPurchase({
      ...base,
      googleStatus: 503,
    }),
    false,
  );
});

const testerRefusal = {
  ok: false,
  status: 402,
  error: "play_test_not_billable",
};

test("license-tester product purchases are refused instead of minting credits", () => {
  assert.equal(typeof helpers.validateBillablePurchase, "function");

  const state = helpers.validateInAppPurchaseState({
    purchaseState: 0,
    purchaseType: 0,
  });
  assert.deepEqual(state, testerRefusal);

  const entitlement = helpers.extractInAppEntitlement({
    purchaseState: 0,
    purchaseType: 0,
    orderId: "GPA.tester-order",
    quantity: 1,
  });
  assert.deepEqual(entitlement, testerRefusal);
});

test("license-tester subscriptions never become an entitlement", () => {
  const state = helpers.validateSubscriptionPurchaseState({
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    testPurchase: {},
  });
  assert.deepEqual(state, testerRefusal);

  const result = helpers.extractSubscriptionEntitlement(
    "x5_verified_monthly_v2",
    {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      testPurchase: {},
      lineItems: [{
        productId: "x5_verified_monthly_v2",
        expiryTime: future,
        latestSuccessfulOrderId: "GPA.tester-renewal",
      }],
    },
    now,
  );
  assert.equal(result.ok, false);
  assert.equal(result.error, "play_test_not_billable");
});

test("real billed purchases stay unaffected by the tester lockdown", () => {
  const billed = helpers.validateBillablePurchase({ purchaseState: 0 });
  assert.deepEqual(billed, { ok: true });

  // Promo (1) and rewarded (2) grants are deliberate, only Test (0) is blocked.
  const promo = helpers.validateBillablePurchase({ purchaseType: 1 });
  assert.deepEqual(promo, { ok: true });

  const state = helpers.validateInAppPurchaseState({ purchaseState: 0 });
  assert.deepEqual(state, { ok: true });
});
