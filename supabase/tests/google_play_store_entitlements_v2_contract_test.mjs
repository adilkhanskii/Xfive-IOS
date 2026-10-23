import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  new URL(
    "../migrations/20260717090000_google_play_store_entitlements_v2.sql",
    import.meta.url,
  ),
  "utf8",
);

test("Google Play V2 ledger keys claims to successful orders", () => {
  assert.match(migration, /successful_order_id text/);
  assert.match(migration, /p_successful_order_id text/);
  assert.match(
    migration,
    /p_claim_key\s*<>\s*btrim\(p_product_id\)\s*\|\|\s*':'\s*\|\|\s*btrim\(p_purchase_token_hash\)\s*\|\|\s*':'\s*\|\|\s*btrim\(p_successful_order_id\)/,
  );
});

test("same paid order can refresh expiry without minting credits", () => {
  assert.match(migration, /v_access_refreshed boolean := false/);
  assert.match(migration, /p_expires_at > v_existing_entitlement\.expires_at/);
  assert.match(migration, /'credits_granted', 0/);
  assert.match(migration, /'access_refreshed', v_access_refreshed/);
  assert.match(migration, /greatest\([\s\S]*verified_until[\s\S]*p_expires_at/);
  assert.match(
    migration,
    /greatest\([\s\S]*subscription_end_date[\s\S]*p_expires_at/,
  );
});

test("every inserted paid subscription order grants its mapped credits once", () => {
  assert.match(
    migration,
    /elsif p_purchase_type = 'inapp'[\s\S]*else\s+v_expiry_advances[\s\S]*v_credits_granted := v_expected_credits;/,
  );
  assert.doesNotMatch(
    migration,
    /v_credits_granted := case\s+when v_expiry_advances then v_expected_credits else 0 end/,
  );
});

test("Google projection preserves black and manual null-end paid access", () => {
  assert.match(migration, /v_preserve_permanent_access boolean := false/);
  assert.match(
    migration,
    /v_preserve_permanent_access := v_profile\.plan = 'black'[\s\S]*lower\(coalesce\(v_profile\.plan, 'free'\)\) in \('lite', 'pro', 'max'\)[\s\S]*v_profile\.subscription_end_date is null/,
  );
  assert.match(
    migration,
    /elsif not v_preserve_permanent_access then[\s\S]*update public\.profiles/,
  );
  assert.match(
    migration,
    /v_expiry_advances := not v_preserve_permanent_access/,
  );
});

test("linked replacement tokens close only the old owner's future access", () => {
  assert.match(migration, /add column if not exists revoked_at timestamptz/);
  assert.match(migration, /add column if not exists revocation_reason text/);
  assert.match(
    migration,
    /create or replace function public\.close_android_linked_subscription/,
  );
  assert.match(migration, /replacement_subscription_unavailable/);
  assert.match(migration, /revocation_reason = 'subscription_replaced'/);
  assert.match(
    migration,
    /purchase_token_hash = btrim\(p_linked_purchase_token_hash\)/,
  );
  assert.match(
    migration,
    /revoke execute on function public\.close_android_linked_subscription[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.close_android_linked_subscription[\s\S]*to service_role/,
  );
});

test("V2 ledger validates quantity and remains service-role only", () => {
  assert.match(migration, /purchase_quantity integer not null default 1/);
  assert.match(migration, /refundable_quantity integer not null default 1/);
  assert.match(migration, /credits_revoked integer not null default 0/);
  assert.match(migration, /updated_at timestamptz not null default now\(\)/);
  assert.match(
    migration,
    /validate constraint iap_entitlements_refundable_quantity_valid/,
  );
  assert.match(
    migration,
    /v_credits_granted := v_expected_credits \* p_quantity/,
  );
  assert.match(
    migration,
    /revoke execute on function public\.apply_android_purchase_entitlement_v2\([\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.apply_android_purchase_entitlement_v2\([\s\S]*to service_role/,
  );
});
