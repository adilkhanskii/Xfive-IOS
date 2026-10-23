const migrationsDir = new URL("../../migrations/", import.meta.url);
const migrationName = (await Array.fromAsync(Deno.readDir(migrationsDir)))
  .map((entry) => entry.name)
  .find((name) => name.endsWith("_x5_store_backend_remediation.sql"));

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

assert(migrationName, "x5_store_backend_remediation migration is missing");
const sql = await Deno.readTextFile(new URL(migrationName, migrationsDir));
const sqlTest = await Deno.readTextFile(
  new URL(
    "../../tests/20260716_x5_store_backend_remediation_test.sql",
    import.meta.url,
  ),
);

function functionBody(name: string): string {
  const matches = [...sql.matchAll(
    new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "gi",
    ),
  )];
  assert(matches.length > 0, `${name} replacement is missing`);
  return matches.at(-1)![0];
}

Deno.test("Sandbox is capped and restricted to App Review plus exactly two developer UUIDs", () => {
  for (
    const id of [
      "f3eea23f-0aeb-405b-ab35-2c53173b7a8f",
      "eee55a08-18d1-46e3-a303-1411d1bb9333",
    ]
  ) {
    assert(sql.includes(id), `approved developer ${id} is missing`);
  }
  assert(
    /account_kind\s+text[\s\S]*check\s*\(account_kind\s+in\s*\(\s*'app_review'\s*,\s*'developer'\s*\)\s*\)/i
      .test(sql),
    "Sandbox account kind constraint is missing",
  );
  const grant = functionBody("x5_app_store_sandbox_grant_legacy");
  assert(
    /review\.account_kind\s*=\s*'app_review'[\s\S]*appreview@x5studio\.app/i
      .test(grant),
    "canonical App Review identity is not rechecked",
  );
  assert(
    /review\.account_kind\s*=\s*'developer'[\s\S]*p_user_id\s+in\s*\([\s\S]*f3eea23f[\s\S]*eee55a08/i
      .test(grant),
    "Sandbox developer identity is not an exact UUID allowlist",
  );
  assert(
    /sandbox_review_credit_cap_exceeded/i.test(grant),
    "Sandbox hard credit cap was removed",
  );
});

Deno.test("Apple lifecycle ledger and RPC are private, exact-once and support renew/expiry/revoke", () => {
  assert(
    /create table public\.app_store_verified_lifecycle_events/i.test(sql),
    "lifecycle event ledger is missing",
  );
  assert(
    /alter table public\.app_store_verified_lifecycle_events force row level security/i
      .test(sql),
    "lifecycle event ledger is not force-RLS protected",
  );
  assert(
    /notification_type\s+in\s*\([\s\S]*'SUBSCRIBED'[\s\S]*'DID_RENEW'[\s\S]*'DID_FAIL_TO_RENEW'[\s\S]*'EXPIRED'[\s\S]*'GRACE_PERIOD_EXPIRED'[\s\S]*'REVOKE'/i
      .test(sql),
    "required lifecycle notification types are missing",
  );
  const apply = functionBody("apply_verified_app_store_subscription_lifecycle");
  for (
    const token of [
      "lifecycle_event_id_conflict",
      "apply_verified_app_store_transaction",
      "apply_verified_app_store_sandbox_review_transaction",
      "apply_verified_app_store_verified_revocation",
      "x5_rebuild_app_store_verified_profile",
    ]
  ) {
    assert(apply.includes(token), `lifecycle RPC does not contain ${token}`);
  }
  assert(
    /revoke execute on function public\.apply_verified_app_store_subscription_lifecycle[\s\S]+?from public, anon, authenticated, service_role/i
      .test(sql),
    "lifecycle RPC privileges are not reset",
  );
  assert(
    /grant execute on function public\.apply_verified_app_store_subscription_lifecycle[\s\S]+?to service_role/i
      .test(sql),
    "lifecycle RPC is not service-role only",
  );
  assert(
    sqlTest.includes("revoke_first_lifecycle_failed"),
    "REVOKE as the first verified webhook is not covered",
  );
});

Deno.test("exact legacy Apple tokens work across renewals, lifecycle, refunds and direct revocation", () => {
  const resolver = functionBody("resolve_verified_app_store_notification_user");
  const renewal = functionBody("apply_verified_app_store_transaction");
  const refund = functionBody("apply_verified_app_store_server_notification");
  const directRevoke = functionBody(
    "apply_verified_app_store_verified_revocation",
  );
  const lifecycle = functionBody(
    "apply_verified_app_store_subscription_lifecycle",
  );

  for (
    const product of [
      "com.x5studio.app.lite.monthly",
      "com.x5studio.app.pro.monthly",
      "com.x5studio.app.max.monthly",
      "com.x5studio.app.verified.monthly",
    ]
  ) {
    assert(resolver.includes(product), `legacy resolver omits ${product}`);
  }
  for (
    const token of [
      "app_store_legacy_bindings",
      "for update",
      "bound_at is null",
      "legacy_app_account_token",
      "app_account_token is null",
      "legacy_binding_mismatch",
    ]
  ) {
    assert(
      resolver.toLowerCase().includes(token.toLowerCase()),
      `legacy resolver is missing ${token}`,
    );
  }
  assert(
    /resolve_verified_app_store_notification_user[\s\S]*x5_apply_verified_app_store_transaction_production_internal/i
      .test(renewal),
    "longitudinal legacy renewal does not reuse the exact resolver",
  );
  for (const body of [refund, directRevoke, lifecycle]) {
    assert(
      /resolve_verified_app_store_notification_user/i.test(body),
      "a signed legacy notification path bypasses the exact resolver",
    );
  }
  assert(
    /x5_apply_verified_legacy_subscription_notification/i.test(refund) &&
      /x5_apply_verified_legacy_subscription_notification/i.test(
        directRevoke,
      ) &&
      /lifecycle-legacy-revoke/i.test(lifecycle),
    "refund or revocation can still write the random token to a token=user ledger",
  );
  assert(
    /legacy_binding_original_transaction_id[\s\S]*foreign key[\s\S]*app_store_legacy_bindings/i
      .test(sql),
    "legacy notification ledgers lack an exact binding foreign key",
  );
  assert(
    !sql.includes("x5_app_store_lifecycle_chain_allows_entitlement"),
    "a terminal event can still suppress every period in an Apple chain",
  );
  const periodScope = functionBody(
    "x5_app_store_lifecycle_transaction_allows_entitlement",
  );
  assert(
    /latest\.transaction_id\s*=\s*p_transaction_id/i.test(periodScope) &&
      /'EXPIRED'[\s\S]*'GRACE_PERIOD_EXPIRED'/i.test(periodScope) &&
      !/'REVOKE'/i.test(periodScope),
    "lifecycle expiry is not scoped to one reversible StoreKit period",
  );
  for (
    const marker of [
      "legacy_pro_second_renewal_failed",
      "old_period_expiry_killed_newer_renewal",
      "legacy_bound_grace_was_not_projected",
      "legacy_on_device_revocation_failed",
      "legacy_on_device_reversal_did_not_restore",
      "legacy_revoke_reversal_did_not_restore",
      "legacy_null_last_refund_failed",
      "legacy_null_last_reversal_failed",
      "owner_legacy_notification_resolver_failed",
    ]
  ) {
    assert(sqlTest.includes(marker), `rollback test is missing ${marker}`);
  }
});

Deno.test("billing grace is latest-event, refund-aware and source-bound", () => {
  const rebuild = functionBody("x5_rebuild_app_store_verified_profile");
  const grace = functionBody("x5_active_app_store_grace_period");
  const lifecycle = functionBody(
    "apply_verified_app_store_subscription_lifecycle",
  );

  assert(
    /x5_active_app_store_grace_period/i.test(rebuild),
    "periodic profile reconciliation drops billing grace",
  );
  assert(
    /distinct on[\s\S]*notification_signed_date\s+desc[\s\S]*notification_type\s*=\s*'DID_FAIL_TO_RENEW'[\s\S]*notification_subtype\s*=\s*'GRACE_PERIOD'/i
      .test(grace),
    "grace is not derived from the latest signed lifecycle event",
  );
  assert(
    /x5_app_store_notification_refund_active/i.test(grace),
    "an active refund does not suppress billing grace",
  );
  for (
    const token of [
      "app_store_transactions",
      "app_store_sandbox_review_transactions",
      "app_store_legacy_bindings",
      "lifecycle_grace_source_not_found",
      "sandbox_review_account_not_allowed",
    ]
  ) {
    assert(
      lifecycle.includes(token),
      `billing grace source proof is missing ${token}`,
    );
  }
  for (
    const marker of [
      "billing_grace_was_not_projected",
      "billing_grace_was_lost_during_rebuild",
      "active_refund_did_not_suppress_grace",
      "refund_reversal_did_not_restore_latest_grace",
      "later_expiry_did_not_supersede_grace",
      "stale_grace_extended_after_later_terminal",
      "sandbox_grace_without_allowlisted_source_was_accepted",
    ]
  ) {
    assert(sqlTest.includes(marker), `rollback test is missing ${marker}`);
  }
});

Deno.test("verified and paid-plan reconciliation trusts exact server ledgers and never changes credits", () => {
  const verified = functionBody("x5_rebuild_app_store_verified_profile");
  assert(
    /join public\.app_store_legacy_bindings/i.test(verified),
    "legacy iOS verified source is not bound by exact migration evidence",
  );
  assert(
    /purchase_token_hash\s+is\s+not\s+null[\s\S]*claim_key\s+is\s+not\s+null/i
      .test(verified),
    "Android verified source is not restricted to server claims",
  );
  assert(
    /is distinct from/i.test(verified),
    "verified reconciliation rewrites already-correct profiles",
  );

  const plans = functionBody("x5_reconcile_paid_plan_profile");
  assert(
    /plan\s*=\s*'free'/i.test(plans),
    "expired paid plans are not cleared",
  );
  assert(
    /plan\s*=\s*'black'/i.test(plans),
    "black/permanent plan preservation is missing",
  );
  assert(
    /subscription_end_date\s+is\s+null/i.test(plans),
    "null-end permanent plans are not preserved",
  );
  const permanentNullEndGuard = plans.search(
    /if\s+lower\(coalesce\(v_profile\.plan,\s*'free'\)\)\s+in\s*\(\s*'lite',\s*'pro',\s*'max'\s*\)[\s\S]*?v_profile\.subscription_end_date\s+is\s+null\s+then/i,
  );
  const entitlementLookup = plans.search(/select\s+entitlement\.expires_at/i);
  assert(
    permanentNullEndGuard >= 0 && permanentNullEndGuard < entitlementLookup,
    "an active store row can overwrite a permanent null-end paid plan",
  );
  assert(
    !/\bcredits\s*=/i.test(verified + plans),
    "reconciliation mutates the credit balance",
  );
  assert(
    /cron\.schedule\([\s\S]*x5-reconcile-store-profiles/i.test(sql),
    "periodic reconciliation cron is missing",
  );
  const sweep = functionBody("x5_reconcile_store_profiles");
  assert(
    /x5_store_reconciliation_state/i.test(sql) &&
      /last_profile_id/i.test(sweep) &&
      /for\s+update/i.test(sweep) &&
      /profile\.id\s*>\s*v_last_profile_id/i.test(sweep),
    "periodic reconciliation can starve every profile after the first batch",
  );
  const retention = functionBody("x5_prepare_credit_retention");
  assert(
    /x5\.store_reconciliation_user/i.test(sweep) &&
      /x5\.store_reconciliation_user/i.test(retention) &&
      /new\.credits_expires_at\s*:=\s*old\.credits_expires_at/i.test(
        retention,
      ),
    "badge reconciliation can mutate credit retention metadata",
  );
});

Deno.test("the existing owner legacy plan is trusted only through its complete exact tuple", () => {
  assert(
    sql.includes("2000001163575812") &&
      sql.includes("f3eea23f-0aeb-405b-ab35-2c53173b7a8f"),
    "the existing owner chain is not explicitly bound",
  );
  assert(
    /owner_legacy_chain_tuple_mismatch/i.test(sql),
    "a mismatched owner tuple does not abort the binding",
  );
  for (
    const field of [
      "original_transaction_id",
      "user_id",
      "product_id",
      "platform",
      "created_at",
      "credited_at",
      "credits_granted",
      "subscription_end_date",
      "app_account_token",
      "claim_key",
      "purchase_type",
      "purchase_token_hash",
      "order_id",
      "expires_at",
      "last_transaction_id",
      "legacy_app_account_token",
    ]
  ) {
    assert(
      new RegExp(`legacy\\.${field}`, "i").test(sql),
      `owner binding does not guard ${field}`,
    );
  }
  const plans = functionBody("x5_reconcile_paid_plan_profile");
  assert(
    /coalesce\(\s*legacy_ios\.legacy_app_account_token,\s*legacy_ios\.app_account_token,\s*legacy_ios\.user_id\s*\)/i
      .test(plans),
    "nil-token owner binding cannot participate in reconciliation",
  );
});

Deno.test("successful Apple and Android credit packs clear only credit expiry metadata", () => {
  const retention = functionBody("x5_prepare_credit_retention");
  const expiry = functionBody("x5_expire_old_credits");
  const apple = functionBody("apply_verified_app_store_consumable");
  const sandbox = functionBody(
    "apply_verified_app_store_sandbox_review_transaction",
  );
  const android = functionBody("apply_android_purchase_entitlement");
  const refunds = functionBody(
    "apply_verified_app_store_server_notification",
  );

  assert(
    /add\s+column\s+if\s+not\s+exists\s+permanent_credits/i.test(sql) &&
      /permanent_credit_debt/i.test(retention),
    "profiles do not track the permanent credit floor separately",
  );

  assert(
    /current_setting\(\s*'x5\.permanent_credit_grant_user'/i.test(retention) &&
      /new\.permanent_credits[\s\S]*old\.permanent_credits/i.test(retention),
    "retention trigger does not grow and preserve a trusted permanent floor",
  );
  assert(
    /set\s+credits\s*=\s*permanent_credits[\s\S]*credits_expires_at\s*=\s*null/i
      .test(expiry),
    "subscription expiry can erase the permanent floor",
  );
  assert(
    /x5\.permanent_credit_adjustment_user/i.test(refunds),
    "verified permanent-pack refunds do not adjust the floor",
  );
  for (const [name, body] of [["Apple", apple], ["Sandbox", sandbox]]) {
    assert(
      /set_config\(\s*'x5\.permanent_credit_grant_user'/i.test(body),
      `${name} consumable does not mark the trusted permanent grant`,
    );
    assert(
      /set_config\(\s*'x5\.permanent_credit_adjustment_user'/i.test(body),
      `${name} pending refunds cannot reduce the permanent grant`,
    );
    assert(
      !/\b(?:plan|subscription_type|subscription_date|purchased_course_ids)\s*=/i
        .test(body),
      `${name} consumable changes non-credit entitlement fields`,
    );
  }
  assert(
    /p_purchase_type\s*=\s*'inapp'[\s\S]*set_config\(\s*'x5\.permanent_credit_grant_user'/i
      .test(android),
    "Android in-app credit pack does not mark the trusted permanent grant",
  );
  assert(
    /p_purchase_type\s*=\s*'subscription'[\s\S]*subscription_end_date/i
      .test(android),
    "legacy monthly expiry path was removed from Android",
  );
  assert(
    /elsif\s+permanent_grant\s+or\s+permanent_adjustment\s+then[\s\S]*?debt_reduction\s*:=\s*least\(old_permanent_debt,\s*credit_delta\)/i
      .test(retention),
    "new permanent grants no longer repay fungible refund debt first",
  );
  for (
    const marker of [
      "new_permanent_pack_did_not_repay_fungible_debt",
      "mixed_permanent_floor_was_not_preserved",
      "mixed_subscription_expiry_erased_permanent_floor",
      "permanent_refund_after_spend_left_a_floor",
      "badge_change_expired_permanent_only_balance",
    ]
  ) {
    assert(sqlTest.includes(marker), `rollback test is missing ${marker}`);
  }
});
