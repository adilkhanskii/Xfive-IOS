function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

function functionBody(source: string, name: string): string {
  const match = source.match(
    new RegExp(
      `create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${name}\\([\\s\\S]+?as\\s+\\$function\\$([\\s\\S]+?)\\$function\\$;`,
      "i",
    ),
  );
  assert(match, `missing function body for ${name}`);
  return match[1];
}

async function refundMigrationSource(): Promise<string> {
  const migrationsUrl = new URL("../../migrations/", import.meta.url);
  const matches: string[] = [];
  for await (const entry of Deno.readDir(migrationsUrl)) {
    if (
      entry.isFile &&
      entry.name.endsWith("_app_store_consumable_refunds.sql")
    ) {
      matches.push(entry.name);
    }
  }
  assert(
    matches.length === 1,
    `expected one consumable refund migration, found ${matches.length}`,
  );
  return await Deno.readTextFile(new URL(matches[0], migrationsUrl));
}

async function rollbackTestSource(): Promise<string> {
  return await Deno.readTextFile(
    new URL(
      "../../tests/20260716_app_store_consumable_refunds_test.sql",
      import.meta.url,
    ),
  );
}

async function edgeFunctionSource(): Promise<string> {
  return await Deno.readTextFile(new URL("./index.ts", import.meta.url));
}

Deno.test("consumable refund RPC is source-bound, debt-safe, and exact once", async () => {
  const source = await refundMigrationSource();

  assertMatch(
    source,
    /create table public\.app_store_consumable_refunds/i,
    "missing append-only consumable refund ledger",
  );
  assertMatch(
    source,
    /primary key\s*\(environment,\s*transaction_id\)/i,
    "refund identity must include App Store environment",
  );
  for (
    const [product, credits] of [["1000", 1000], ["2000", 2000], [
      "5000",
      5000,
    ]] as const
  ) {
    assertMatch(
      source,
      new RegExp(
        `product_id\\s*=\\s*'com\\.x5studio\\.app\\.credits\\.${product}'\\s+and\\s+credits_reversed\\s+in\\s*\\(0,\\s*${credits}\\)`,
        "i",
      ),
      `zero-credit tombstones must remain bound to the ${product} pack`,
    );
  }
  assertMatch(
    source,
    /create (?:or replace )?function public\.apply_verified_app_store_consumable_refund/i,
    "missing service-only consumable refund RPC",
  );
  assertMatch(
    source,
    /security definer/i,
    "refund RPC must be security definer",
  );
  assertMatch(
    source,
    /set search_path\s*=\s*''/i,
    "refund RPC must pin an empty search_path",
  );
  assertMatch(
    source,
    /from public\.app_store_consumable_transactions/i,
    "Production refunds must bind to the immutable Production purchase row",
  );
  assertMatch(
    source,
    /from public\.app_store_sandbox_review_transactions/i,
    "Sandbox refunds must bind to the isolated Sandbox purchase row",
  );
  for (
    const predicate of [
      /source\.user_id\s*<>\s*p_user_id/i,
      /source\.original_transaction_id\s*<>\s*v_original_transaction_id/i,
      /source\.product_id\s*<>\s*v_product_id/i,
      /source\.environment\s*<>\s*v_environment/i,
      /source\.app_account_token\s*<>\s*p_app_account_token/i,
      /source\.purchase_date\s*<>\s*p_purchase_date/i,
      /source\.quantity\s*<>\s*p_quantity/i,
    ]
  ) {
    assertMatch(
      source,
      predicate,
      `missing strict source predicate ${predicate}`,
    );
  }
  assertMatch(
    source,
    /v_credits_reversed\s*:=\s*source\.credits_granted/i,
    "deduction must come only from the recorded grant",
  );
  assertMatch(
    source,
    /set credits\s*=\s*coalesce\(credits,\s*0\)\s*-\s*v_credits_reversed/i,
    "refund must subtract the recorded grant and permit debt",
  );
  assert(
    !/set credits\s*=\s*greatest\s*\(/i.test(source),
    "refund balance must not be clamped to zero",
  );
  assertMatch(
    source,
    /'status',\s*'already_applied'[\s\S]+?'credits_granted',\s*0/i,
    "re-signed replay must be exact once and never grant credits",
  );
  assert(
    !/existing\.signed_date\s*(?:<>|is distinct from)\s*p_signed_date/i.test(
      source,
    ),
    "a valid re-signed refund must not conflict only on signed_date",
  );
});

Deno.test("consumable refund ledger is immutable to every API role", async () => {
  const source = await refundMigrationSource();
  assertMatch(
    source,
    /alter table public\.app_store_consumable_refunds owner to postgres/i,
    "postgres must own the refund ledger",
  );
  assertMatch(
    source,
    /alter table public\.app_store_consumable_refunds force row level security/i,
    "refund ledger must force RLS",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_consumable_refunds\s+from public, anon, authenticated/i,
    "client roles must have no refund ledger privileges",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_consumable_refunds\s+from service_role/i,
    "service_role must not mutate the refund ledger directly",
  );
  assertMatch(
    source,
    /grant execute on function public\.apply_verified_app_store_consumable_refund[\s\S]+?to service_role/i,
    "service_role needs only the narrow refund RPC",
  );
});

Deno.test("refund-before-grant creates an atomic tombstone for Production and Sandbox", async () => {
  const source = await refundMigrationSource();
  const refund = functionBody(
    source,
    "apply_verified_app_store_consumable_refund",
  );
  const productionGrant = functionBody(
    source,
    "apply_verified_app_store_consumable",
  );
  const sandboxGrant = functionBody(
    source,
    "apply_verified_app_store_sandbox_review_transaction",
  );

  assert(
    !/consumable_refund_source_not_found/i.test(refund),
    "a verified refund without a purchase row must create a tombstone",
  );
  assertMatch(
    refund,
    /insert into public\.app_store_consumable_refunds[\s\S]+?credits_reversed[\s\S]+?values[\s\S]+?v_credits_reversed/i,
    "refund RPC must persist the zero-or-recorded server reversal",
  );
  assertMatch(
    refund,
    /if not v_source_found then[\s\S]+?v_credits_reversed\s*:=\s*0/i,
    "a missing source must become a zero-credit immutable tombstone",
  );

  for (
    const [name, body] of [
      ["refund", refund],
      ["Production grant", productionGrant],
    ] as const
  ) {
    assertMatch(
      body,
      /pg_advisory_xact_lock[\s\S]+?'app-store-consumable:'\s*\|\|\s*v_environment\s*\|\|\s*':'\s*\|\|\s*v_transaction_id/i,
      `${name} must use the shared environment-scoped transaction lock`,
    );
  }
  const subscriptionLockOffset = sandboxGrant.indexOf(
    "'app-store-sandbox-review:' || v_transaction_id",
  );
  const consumableLockOffset = sandboxGrant.indexOf(
    "'app-store-consumable:' || v_environment || ':' || v_transaction_id",
  );
  const lockConditionOffset = sandboxGrant.lastIndexOf(
    "if v_is_verified_product then",
    subscriptionLockOffset,
  );
  const lockElseOffset = sandboxGrant.indexOf("else", subscriptionLockOffset);
  const lockEndOffset = sandboxGrant.indexOf("end if;", consumableLockOffset);
  assert(
    lockConditionOffset >= 0 && subscriptionLockOffset > lockConditionOffset &&
      lockElseOffset > subscriptionLockOffset &&
      consumableLockOffset > lockElseOffset &&
      lockEndOffset > consumableLockOffset,
    "Sandbox subscriptions must retain their revocation lock while consumables use the refund lock",
  );

  for (
    const [name, body] of [
      ["Production", productionGrant],
      ["Sandbox", sandboxGrant],
    ] as const
  ) {
    assertMatch(
      body,
      /from public\.app_store_consumable_refunds/i,
      `${name} grants must consult the refund tombstone ledger`,
    );
    for (
      const predicate of [
        /refund\.user_id\s*<>\s*p_user_id/i,
        /refund\.original_transaction_id\s*<>\s*v_original_transaction_id/i,
        /refund\.product_id\s*<>\s*v_product_id/i,
        /refund\.app_account_token\s*<>\s*p_app_account_token/i,
        /refund\.purchase_date\s*<>\s*p_purchase_date/i,
        /refund\.quantity\s*<>\s*p_quantity/i,
      ]
    ) {
      assertMatch(
        body,
        predicate,
        `${name} tombstone check is missing ${predicate}`,
      );
    }
    const lockOffset = body.search(/pg_advisory_xact_lock/i);
    const tombstoneOffset = body.search(
      /from public\.app_store_consumable_refunds/i,
    );
    const grantOffset = body.search(
      /insert into public\.app_store_(?:consumable|sandbox_review)_transactions/i,
    );
    assert(
      lockOffset >= 0 && tombstoneOffset > lockOffset &&
        grantOffset > tombstoneOffset,
      `${name} must lock and reject an exact tombstone before any grant insert`,
    );
  }
});

Deno.test("rollback SQL probes Production, Sandbox, replay, debt, and identity conflicts", async () => {
  const source = await rollbackTestSource();
  for (
    const marker of [
      "production_consumable_refund_failed",
      "sandbox_consumable_refund_failed",
      "consumable_refund_replay_was_not_exact_once",
      "consumable_refund_did_not_create_debt",
      "consumable_refund_debt_was_reused",
      "consumable_refund_identity_mismatch_was_accepted",
      "production_refund_before_grant_was_credited",
      "sandbox_refund_before_grant_was_credited",
      "refund_before_grant_identity_conflict_was_accepted",
      "refund_before_grant_cross_account_was_accepted",
      "consumable_refund_rpc_is_client_callable",
      "consumable_refund_ledger_is_not_private",
    ]
  ) {
    assertMatch(
      source,
      new RegExp(marker, "i"),
      `missing rollback marker ${marker}`,
    );
  }
  assertMatch(
    source,
    /rollback;[\s\S]+app_store_consumable_refunds_validated_with_rollback/i,
    "refund probes must be transactionally rolled back",
  );
});

Deno.test("refund tombstone identity conflicts use the opaque 409 contract", async () => {
  const source = await edgeFunctionSource();
  assertMatch(
    source,
    /safeToken\.includes\("owned_by_other"\)[\s\S]+?safeToken\.includes\("transaction_id_conflict"\)[\s\S]+?safeToken\.includes\("consumable_refund_id_conflict"\)[\s\S]+?EntitlementApplyError\("owned_by_other",\s*409\)/i,
    "refund identity conflicts must not leak details or look retryable",
  );
});
