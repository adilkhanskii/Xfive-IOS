const migrationsDir = new URL("../../migrations/", import.meta.url);
const migrationName = (await Array.fromAsync(Deno.readDir(migrationsDir)))
  .map((entry) => entry.name)
  .find((name) => name.endsWith("_app_store_server_notifications.sql"));

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

assert(migrationName, "app_store_server_notifications migration is missing");
const sql = await Deno.readTextFile(new URL(migrationName, migrationsDir));

Deno.test("notification ledger is private, append-only, and records exact economics", () => {
  assert(
    /create table public\.app_store_server_notification_events/i.test(sql),
    "notification event ledger is missing",
  );
  for (
    const column of [
      "notification_type",
      "notification_signed_date",
      "transaction_signed_date",
      "revocation_percentage",
      "credits_affected",
      "pending_credits_affected",
      "credits_delta",
    ]
  ) {
    assert(
      new RegExp(`\\b${column}\\b`, "i").test(sql),
      `${column} is missing`,
    );
  }
  assert(
    /alter table public\.app_store_server_notification_events force row level security/i
      .test(sql),
    "ledger is not force-RLS protected",
  );
  assert(
    /revoke all privileges on table public\.app_store_server_notification_events[\s\S]+?from service_role/i
      .test(sql),
    "service role has direct ledger access",
  );
  assert(
    !/grant[^;]*(?:update|delete)[^;]*on table public\.app_store_server_notification_events/i
      .test(sql),
    "append-only ledger grants mutation privileges",
  );
});

Deno.test("service-only RPC owns all notification state transitions", () => {
  assert(
    /create (?:or replace )?function public\.apply_verified_app_store_server_notification\s*\(/i
      .test(sql),
    "notification RPC is missing",
  );
  assert(
    /revoke execute on function public\.apply_verified_app_store_server_notification[\s\S]+?from public, anon, authenticated, service_role/i
      .test(sql),
    "notification RPC execute privileges are not reset",
  );
  assert(
    /grant execute on function public\.apply_verified_app_store_server_notification[\s\S]+?to service_role/i
      .test(sql),
    "notification RPC is not service-role callable",
  );
  assert(
    /notification_event_id_conflict/i.test(sql),
    "event-id conflicts are not rejected",
  );
});

Deno.test("refund and grant paths share locks and active refund triggers", () => {
  for (
    const lockPrefix of [
      "app-store-consumable:",
      "app-store-transaction:",
      "app-store-sandbox-review:",
    ]
  ) {
    assert(sql.includes(lockPrefix), `${lockPrefix} lock is missing`);
  }
  assert(
    /create trigger[\s\S]+?app_store_consumable_transactions/i.test(sql),
    "Production consumable grant guard is missing",
  );
  assert(
    /create trigger[\s\S]+?app_store_transactions/i.test(sql),
    "Production subscription grant guard is missing",
  );
  assert(
    /create trigger[\s\S]+?app_store_sandbox_review_transactions/i.test(sql),
    "Sandbox grant guard is missing",
  );
  assert(
    /app_store_notification_refund_active/i.test(sql),
    "active refund does not block a later grant",
  );
});

Deno.test("prorated refund uses ceiling and reversal restores recorded amount", () => {
  assert(
    /ceil\s*\([\s\S]+?revocation_percentage[\s\S]+?100000/i.test(sql),
    "milliunit refund is not rounded safely",
  );
  assert(
    /credits_affected[\s\S]+?credits_delta/i.test(sql),
    "exact applied amount is not persisted",
  );
  assert(
    /REFUND_REVERSED[\s\S]+?v_prior_credits_affected/i.test(sql),
    "refund reversal does not restore prior exact credits",
  );
  assert(
    /v_source_found[\s\S]+?v_target_pending_credits/i.test(sql),
    "refund-before-grant is not held pending",
  );
  assert(
    /app_store_server_notification_grant_adjustments/i.test(sql),
    "late-grant hold adjustment ledger is missing",
  );
});

Deno.test("authenticated client refund RPCs remain compatible with canonical state", () => {
  assert(
    /create or replace function public\.apply_verified_app_store_consumable_refund\s*\(/i
      .test(sql),
    "consumable client refund bridge is missing",
  );
  assert(
    /create or replace function public\.apply_verified_app_store_verified_revocation\s*\(/i
      .test(sql),
    "verified subscription client refund bridge is missing",
  );
  assert(
    /app_store_consumable_refunds/i.test(sql),
    "legacy consumable deduction baseline is not reconciled",
  );
  assert(
    /app_store_verified_revocations/i.test(sql),
    "legacy subscription revocation baseline is not reconciled",
  );
});

Deno.test("rollback integration test covers ordering and exact restoration", async () => {
  const testSQL = await Deno.readTextFile(
    new URL(
      "../../tests/20260716_app_store_server_notifications_test.sql",
      import.meta.url,
    ),
  );
  for (
    const token of [
      "refund_before_grant",
      "reversal_before_refund",
      "prorated_refund",
      "duplicate_notification",
      "partial_refund_before_grant_was_not_pending",
      "server_percentage_did_not_correct_device_refund",
      "pending_refund_grant_adjustment_was_not_recorded",
      "rollback",
      "app_store_server_notifications_validated_with_rollback",
    ]
  ) {
    assert(testSQL.toLowerCase().includes(token), `${token} test is missing`);
  }
});
