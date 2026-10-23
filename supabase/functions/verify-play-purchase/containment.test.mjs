import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(
  new URL("./index.ts", import.meta.url),
  "utf8",
);
const entitlements = readFileSync(
  new URL("./entitlements.mjs", import.meta.url),
  "utf8",
);

test("production Google Play verification mints through the exact-once owner ledger", () => {
  assert.doesNotMatch(
    source,
    /PLAY_PURCHASES_ENABLED\s*=\s*false/,
    "the deployed Google Play verifier must not be replaced by the old disabled stub",
  );

  const googleVerification = Math.min(
    ...[
      source.indexOf("loadGoogleSubscription("),
      source.indexOf("loadGoogleProduct("),
    ].filter((index) => index >= 0),
  );
  const ledgerMutation = source.indexOf(
    '.rpc("apply_android_purchase_entitlement_v2"',
  );

  assert.ok(googleVerification >= 0, "missing Google Play API verification");
  assert.ok(
    ledgerMutation > googleVerification,
    "ledger must run after Google verification",
  );
  assert.doesNotMatch(
    source,
    /\.from\(["\']profiles["\']\)[\s\S]{0,160}\.update\(/,
    "the verifier must not mutate profile balances directly",
  );
  assert.match(source, /buildGooglePlayClaimKey/);
  assert.match(source, /p_successful_order_id: verified\.orderId/);
});

test("deployed package and every current store product stay represented", () => {
  assert.match(
    entitlements,
    /ANDROID_PACKAGE_NAME = "com\.x5marketing\.mobile"/,
  );

  for (
    const productId of [
      "x5_lite_monthly_v2",
      "x5_pro_monthly_v2",
      "x5_max_monthly_v2",
      "x5_verified_monthly_v2",
      "x5_credits_1000_v2",
      "x5_credits_2000_v2",
      "x5_credits_5000_v2",
    ]
  ) {
    assert.match(entitlements, new RegExp(`\\b${productId}\\b`));
  }
});

test("verifier binds Google orders to the authenticated account and successful order ledger", () => {
  assert.match(source, /createGooglePlayAccountBinding/);
  assert.match(source, /validateGooglePlayAccountBinding/);
  assert.match(source, /buildGooglePlayClaimKey/);
  assert.match(source, /GOOGLE_PLAY_ACCOUNT_BINDING_SECRET/);
  assert.match(source, /account_binding: expectedAccountBinding/);
  assert.match(source, /getGooglePlayPredecessorPurchaseTokens/);
  assert.match(source, /loadGooglePlayOwnershipLedgers/);
  assert.match(source, /\.in\("purchase_token_hash", uniqueHashes\)/);
  assert.match(source, /\.rpc\("apply_android_purchase_entitlement_v2"/);
  assert.match(source, /\.rpc\("close_android_linked_subscription"/);
  assert.doesNotMatch(source, /typedPurchase\.latestOrderId/);
  assert.doesNotMatch(source, /expiry \|\| "one-time"/);
});

test("verifier finalizes Google Play only after the exact-once ledger", () => {
  const ledger = source.indexOf('.rpc("apply_android_purchase_entitlement_v2"');
  const linkedClosure = source.indexOf(
    "await closeLinkedGoogleSubscription(",
  );
  const finalization = source.indexOf("finalizeGooglePlayPurchase({");
  assert.ok(ledger >= 0, "missing V2 exact-once ledger");
  assert.ok(
    linkedClosure > ledger,
    "linked predecessor closes after the grant",
  );
  assert.ok(
    finalization > linkedClosure,
    "Google finalization must follow grant and linked-token reconciliation",
  );
  assert.match(source, /play_finalization_pending/);
  assert.match(source, /retryable: true/);
  assert.match(source, /entitlement_applied: true/);
  assert.match(
    source,
    /ok:\s*true,[\s\S]*warning:\s*"play_finalization_pending"/,
  );
  assert.match(source, /store_finalized:\s*false/);
  assert.match(source, /finalization_pending:\s*true/);
  assert.doesNotMatch(
    source,
    /warning:\s*"play_finalization_pending"[\s\S]{0,400}\},\s*503\)/,
  );
  assert.match(source, /recoverKnownConsumedPurchase/);
  assert.match(source, /isGooglePlayFinalizationRace/);
  assert.match(source, /isGooglePlayPurchaseGone/);
});

test("license-tester purchases can never be billed as real Google orders", () => {
  assert.match(entitlements, /export function validateBillablePurchase/);
  assert.match(entitlements, /purchase\?\.purchaseType === 0/);
  assert.match(entitlements, /purchase\?\.testPurchase != null/);
  assert.match(entitlements, /play_test_not_billable/);

  for (
    const validator of [
      "validateInAppPurchaseState",
      "validateSubscriptionPurchaseState",
    ]
  ) {
    const body = entitlements.slice(
      entitlements.indexOf(`export function ${validator}(`),
    );
    assert.match(
      body.slice(0, 200),
      /validateBillablePurchase\(purchase\)/,
      `${validator} must refuse test purchases before granting anything`,
    );
  }
});
