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
    "../../tests/20260720_legacy_subscription_server_notifications_test.sql",
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

Deno.test("legacy paid subscription webhooks reuse the private exact-once Apple transaction ledger", () => {
  const lifecycle = latestFunctionBody(
    "apply_verified_app_store_subscription_lifecycle",
  );
  const legacyPlan = latestFunctionBody(
    "x5_apply_verified_app_store_legacy_plan_lifecycle",
  );
  for (
    const productId of [
      "com.x5studio.app.lite.monthly",
      "com.x5studio.app.pro.monthly",
      "com.x5studio.app.max.monthly",
    ]
  ) {
    assert(lifecycle.includes(productId), `lifecycle RPC omits ${productId}`);
  }
  assert(
    /x5_apply_verified_app_store_legacy_plan_lifecycle/i.test(lifecycle) &&
      /v_notification_type\s+not\s+in\s*\(\s*'SUBSCRIBED'\s*,\s*'DID_RENEW'\s*\)[\s\S]*apply_verified_app_store_transaction/i
        .test(legacyPlan),
    "signed legacy plan grants do not reuse apply_verified_app_store_transaction",
  );
  assert(
    /legacy_plan[\s\S]*unsupported_notification_type/i.test(legacyPlan),
    "legacy plans are not explicitly limited to grant lifecycle events",
  );
  for (
    const token of [
      "resolve_verified_app_store_notification_user",
      "lifecycle_event_id_conflict",
      "app_store_verified_lifecycle_events",
      "legacy_binding_used",
    ]
  ) {
    assert(
      legacyPlan.includes(token),
      `legacy plan grant path is missing ${token}`,
    );
  }
  assert(
    /revoke execute on function[\s\S]*x5_apply_verified_app_store_legacy_plan_lifecycle[\s\S]*from public, anon, authenticated, service_role/i
      .test(sql) &&
      !/grant execute on function\s+(?:public\.)?x5_apply_verified_app_store_legacy_plan_lifecycle/i
        .test(sql),
    "legacy plan helper is directly callable outside its public wrapper",
  );
  assert(
    /revoke execute on function public\.apply_verified_app_store_subscription_lifecycle[\s\S]+?from public, anon, authenticated, service_role/i
      .test(sql) &&
      /grant execute on function public\.apply_verified_app_store_subscription_lifecycle[\s\S]+?to service_role/i
        .test(sql),
    "legacy notification grant RPC is not service-role only",
  );
  for (
    const marker of [
      "legacy_plan_initial_grant_failed",
      "legacy_plan_event_replay_was_not_exact_once",
      "legacy_plan_transaction_replay_was_not_exact_once",
      "legacy_plan_cross_account_grant_was_accepted",
    ]
  ) {
    assert(
      rollbackTest.includes(marker),
      `rollback integration coverage is missing ${marker}`,
    );
  }
});
