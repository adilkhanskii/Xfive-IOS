const migrationsDir = new URL("../../migrations/", import.meta.url);
const migrations = (await Array.fromAsync(Deno.readDir(migrationsDir)))
  .filter((entry) => entry.isFile && entry.name.endsWith(".sql"))
  .sort((a, b) => a.name.localeCompare(b.name));

let sql = "";
for (const migration of migrations) {
  sql += `\n${await Deno.readTextFile(new URL(migration.name, migrationsDir))}`;
}
const rollbackTest = await Deno.readTextFile(
  new URL(
    "../../tests/20260720_legacy_subscription_refunds_test.sql",
    import.meta.url,
  ),
);

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function latestFunctionBody(name: string): string {
  const matches = [...sql.matchAll(
    new RegExp(
      `create(?:\\s+or\\s+replace)?\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "gi",
    ),
  )];
  assert(matches.length > 0, `${name} is missing`);
  return matches.at(-1)![0];
}

Deno.test("legacy paid-plan refunds have a private Production-only exact-once engine", () => {
  const helper = latestFunctionBody(
    "x5_apply_verified_app_store_legacy_plan_refund",
  );
  const router = latestFunctionBody(
    "apply_verified_app_store_server_notification",
  );
  for (
    const productId of [
      "com.x5studio.app.lite.monthly",
      "com.x5studio.app.pro.monthly",
      "com.x5studio.app.max.monthly",
    ]
  ) {
    assert(helper.includes(productId), `refund helper omits ${productId}`);
    assert(router.includes(productId), `refund router omits ${productId}`);
  }
  for (
    const marker of [
      "v_environment is distinct from 'Production'",
      "app_store_transactions",
      "notification_event_id_conflict",
      "notification_source_mismatch",
      "pending_credits_withheld",
      "revocation_percentage",
      "x5_reconcile_paid_plan_profile",
      "legacy_binding_used",
      "legacy_credits_granted",
    ]
  ) {
    assert(helper.includes(marker), `refund helper is missing ${marker}`);
  }
  assert(
    /revoke execute on function[\s\S]*x5_apply_verified_app_store_legacy_plan_refund[\s\S]*from public, anon, authenticated, service_role/i
      .test(sql) &&
      !/grant execute on function\s+(?:public\.)?x5_apply_verified_app_store_legacy_plan_refund/i
        .test(sql),
    "legacy refund helper is directly callable",
  );
});

Deno.test("refund-before-grant converts pending economics against the exact inserted ledger row", () => {
  const grant = latestFunctionBody("apply_verified_app_store_transaction");
  for (
    const marker of [
      "app_store_server_notification_state",
      "pending_credits_withheld",
      "app_store_server_notification_grant_adjustments",
      "credits_granted",
      "x5_reconcile_paid_plan_profile",
      "x5_app_store_legacy_plan_grant_pre_refund",
      "coalesce(p_app_account_token, p_user_id)",
    ]
  ) {
    assert(grant.includes(marker), `legacy grant bridge is missing ${marker}`);
  }
  const bindingLock = grant.indexOf(
    "resolve_verified_app_store_notification_user",
  );
  const profileLock = grant.indexOf("from public.profiles");
  assert(bindingLock >= 0, "legacy grant bridge does not lock its binding");
  assert(
    profileLock > bindingLock,
    "legacy grant bridge locks profile before its grandfather binding",
  );
});

Deno.test("nil-token compatibility is limited to an immutable grandfather binding", () => {
  const resolver = latestFunctionBody(
    "resolve_verified_app_store_notification_user",
  );
  for (
    const marker of [
      "p_app_account_token is null",
      "binding.app_account_token = binding.user_id",
      "legacy.app_account_token is null",
      "legacy.legacy_app_account_token is null",
      "legacy.credits_granted is not distinct from",
      "binding.legacy_credits_granted",
    ]
  ) {
    assert(
      resolver.includes(marker),
      `nil-token resolver is missing ${marker}`,
    );
  }
  assert(
    /add column legacy_credits_granted integer/i.test(sql) &&
      /legacy_credit_economics/i.test(sql),
    "legacy credit economics are not frozen on the binding",
  );
});

Deno.test("active refunds suppress the exact grandfather paid-plan source", () => {
  const reconcile = latestFunctionBody("x5_reconcile_paid_plan_profile");
  for (
    const marker of [
      "refund_state.user_id = legacy_ios.user_id",
      "refund_state.product_id = legacy_ios.product_id",
      "refund_state.original_transaction_id =",
      "legacy_ios.original_transaction_id",
      "refund_state.active",
    ]
  ) {
    assert(
      reconcile.includes(marker),
      `paid-plan reconciler does not suppress grandfather source by ${marker}`,
    );
  }
});

Deno.test("legacy refund rollback test covers replay ownership economics reversal and plan reconciliation", () => {
  for (
    const marker of [
      "legacy_plan_partial_refund_failed",
      "legacy_plan_refund_replay_was_not_exact_once",
      "legacy_plan_full_refund_failed",
      "legacy_plan_refund_reversal_failed",
      "legacy_plan_refund_source_mismatch_was_accepted",
      "legacy_plan_refund_cross_account_was_accepted",
      "legacy_plan_refund_before_grant_pending_failed",
      "legacy_plan_refund_before_grant_withholding_failed",
      "legacy_plan_refund_before_grant_reversal_failed",
      "legacy_plan_refund_did_not_reconcile_plan",
      "legacy_plan_refund_reversal_did_not_restore_plan",
      "legacy_plan_grandfather_refund_did_not_reconcile_plan",
      "legacy_plan_grandfather_reversal_did_not_restore_plan",
      "legacy_plan_grandfather_refund_did_not_withhold_credits",
      "legacy_plan_grandfather_late_grant_double_deducted",
      "legacy_plan_zero_ledger_refund_did_not_use_frozen_credits",
      "legacy_plan_nil_token_direct_grant_failed",
      "legacy_plan_later_period_refund_used_grandfather_credits",
      "legacy_plan_nil_token_bound_grant_failed",
      "legacy_plan_nil_token_second_renewal_failed",
      "legacy_plan_nil_token_renewal_replay_failed",
      "legacy_plan_nil_token_refund_failed",
    ]
  ) {
    assert(
      rollbackTest.includes(marker),
      `rollback integration coverage is missing ${marker}`,
    );
  }
});
