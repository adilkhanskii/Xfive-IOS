import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  new URL(
    "../migrations/20260717093000_google_play_store_reconciliation.sql",
    import.meta.url,
  ),
  "utf8",
);
const edge = readFileSync(
  new URL("../functions/google-play-notifications/index.ts", import.meta.url),
  "utf8",
);
const notificationHelper = readFileSync(
  new URL(
    "../functions/google-play-notifications/notification.mjs",
    import.meta.url,
  ),
  "utf8",
);
const edgeSurface = `${edge}\n${notificationHelper}`;
const functionConfig = readFileSync(
  new URL("../config.toml", import.meta.url),
  "utf8",
);
const recoveryWorkflow = readFileSync(
  new URL(
    "../../.github/workflows/google-play-voided-reconciliation.yml",
    import.meta.url,
  ),
  "utf8",
);

test("Google reconciliation has a private exact-once event ledger", () => {
  assert.match(
    migration,
    /create table public\.google_play_reconciliation_events/,
  );
  assert.match(migration, /event_id text primary key/);
  assert.match(migration, /credits_reversed integer not null default 0/);
  assert.match(migration, /force row level security/);
  assert.match(migration, /revoke all privileges[\s\S]*service_role/);
});

test("reversal RPC locks the purchase, applies quantity once, and reconciles access", () => {
  assert.match(
    migration,
    /create or replace function public\.apply_google_play_reversal/,
  );
  assert.match(migration, /for update/);
  assert.match(
    migration,
    /refundable_quantity = refundable_quantity - v_quantity/,
  );
  assert.match(migration, /credits_revoked = credits_revoked \+ v_credits/);
  assert.match(migration, /x5\.permanent_credit_adjustment_user/);
  assert.match(migration, /x5_rebuild_app_store_verified_profile/);
  assert.match(migration, /x5_reconcile_paid_plan_profile/);
  assert.match(migration, /v_newer_claim_exists boolean := false/);
  assert.match(
    migration,
    /coalesce\(newer\.expires_at, newer\.subscription_end_date\) >\s+clock_timestamp\(\)/,
  );
  assert.match(migration, /p_snapshot_subscription_state text/);
  assert.match(migration, /p_snapshot_expiry timestamptz/);
  assert.match(migration, /SUBSCRIPTION_STATE_ACTIVE/);
  assert.match(migration, /subscription_paused/);
  assert.match(migration, /SUBSCRIPTION_STATE_PAUSED/);
  assert.match(
    migration,
    /coalesce\(v_source\.credited_at, v_source\.created_at\)[\s\S]*p_event_time \+ interval '5 minutes'/,
  );
  assert.match(migration, /'status', 'ignored_stale'/);
  assert.match(migration, /'status', 'source_not_found'/);
  assert.match(migration, /event_id not like 'rtdn:%'/);
  assert.match(migration, /from public, anon, authenticated, service_role/);
  assert.match(migration, /to service_role/);
});

test("Edge worker verifies PubSub identity and supports RTDN plus voided recovery", () => {
  assert.match(edge, /GOOGLE_PLAY_PUBSUB_AUDIENCE/);
  assert.match(edge, /GOOGLE_PLAY_PUBSUB_SERVICE_ACCOUNT_EMAIL/);
  assert.match(edge, /verifyPubSubIdentity/);
  assert.match(edgeSurface, /voidedPurchaseNotification/);
  assert.match(edgeSurface, /subscriptionNotification/);
  assert.match(edgeSurface, /oneTimeProductNotification/);
  assert.match(edge, /purchases\/voidedpurchases/);
  assert.match(edge, /purchases\/subscriptionsv2\/tokens/);
  assert.match(edge, /withSubscriptionSnapshot/);
  assert.match(edge, /apply_android_purchase_entitlement_v2/);
  assert.match(edge, /includeQuantityBasedPartialRefund:\s*"true"/);
  assert.match(edge, /type:\s*"1"/);
  assert.match(edge, /canonicalVoidedEventMaterial/);
  assert.match(edgeSurface, /source_not_found/);
  assert.match(edge, /close_android_linked_subscription/);
  assert.doesNotMatch(edgeSurface, /subscriptionId/);
  assert.doesNotMatch(
    edgeSurface,
    /positiveInteger\([^\n]*voidedQuantity[^\n]*,\s*1\)/,
  );
  assert.match(
    functionConfig,
    /\[functions\.google-play-notifications\][\s\S]*verify_jwt\s*=\s*false/,
  );
  assert.match(recoveryWorkflow, /schedule:/);
  assert.match(recoveryWorkflow, /workflow_dispatch:/);
  assert.match(recoveryWorkflow, /GOOGLE_PLAY_VOIDED_SCAN_SECRET/);
  assert.match(recoveryWorkflow, /scan_voided_purchases/);
  assert.doesNotMatch(edge, /purchase_token:\s*purchaseToken/);
});
