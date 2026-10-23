function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

async function correctiveMigrationSource(): Promise<string> {
  const migrationsUrl = new URL("../../migrations/", import.meta.url);
  const matches: string[] = [];
  for await (const entry of Deno.readDir(migrationsUrl)) {
    if (
      entry.isFile &&
      entry.name.endsWith(
        "_accept_resigned_app_store_subscription_replays.sql",
      )
    ) {
      matches.push(entry.name);
    }
  }
  assert(
    matches.length === 1,
    `expected one re-signed subscription replay migration, found ${matches.length}`,
  );
  return await Deno.readTextFile(new URL(matches[0], migrationsUrl));
}

async function rollbackSqlTestSource(): Promise<string> {
  return await Deno.readTextFile(
    new URL(
      "../../tests/20260714_entitlement_hardening_test.sql",
      import.meta.url,
    ),
  );
}

Deno.test("production subscription replay ignores only a fresh Apple signed_date", async () => {
  const source = await correctiveMigrationSource();

  assertMatch(
    source,
    /create function public\.x5_apply_verified_app_store_transaction_production_internal\s*\(/i,
    "the production internal RPC must be replaced behind its stable name",
  );
  assertMatch(source, /security definer/i, "RPC must be security definer");
  assertMatch(
    source,
    /set search_path\s*=\s*''/i,
    "RPC must pin an empty search_path",
  );
  assertMatch(
    source,
    /message_text[\s\S]+?transaction_id_conflict/i,
    "the compatibility wrapper must handle only the legacy replay conflict",
  );
  assert(
    !/v_existing\.signed_date\s*(?:<>|is distinct from)\s*p_signed_date/i.test(
      source,
    ),
    "a freshly signed JWS must not conflict solely on signed_date",
  );

  const immutablePredicates = [
    /v_existing\.user_id\s*<>\s*p_user_id/i,
    /v_existing\.original_transaction_id\s*<>\s*v_original_transaction_id/i,
    /v_existing\.product_id\s*<>\s*v_product_id/i,
    /v_existing\.environment\s*<>\s*v_environment/i,
    /v_existing\.app_account_token\s+is distinct from\s+p_app_account_token/i,
    /v_existing\.purchase_date\s*<>\s*p_purchase_date/i,
    /v_existing\.expires_date\s*<>\s*p_expires_date/i,
  ];
  for (const predicate of immutablePredicates) {
    assertMatch(
      source,
      predicate,
      `missing immutable replay predicate ${predicate}`,
    );
  }
  assertMatch(
    source,
    /raise exception using errcode = '22023', message = 'transaction_id_conflict'/i,
    "immutable replay mismatches must remain conflicts",
  );
  assertMatch(
    source,
    /'status',\s*'already_applied'[\s\S]+?'credits_granted',\s*v_existing\.credits_granted/i,
    "an exact re-signed replay must return the existing immutable grant",
  );
  assertMatch(
    source,
    /revoke execute on function public\.x5_apply_verified_app_store_transaction_production_internal[\s\S]+?from public, anon, authenticated, service_role/i,
    "the internal RPC must not be directly callable by API roles",
  );
});

Deno.test("production Apple ledgers are append-only for service_role", async () => {
  const source = await correctiveMigrationSource();
  const tables = [
    "app_store_transactions",
    "app_store_entitlement_owners",
    "app_store_legacy_bindings",
  ];

  for (const table of tables) {
    assertMatch(
      source,
      new RegExp(
        `revoke all privileges on table public\\.${table}\\s+from service_role`,
        "i",
      ),
      `${table} must drop broad default service-role privileges`,
    );
    assertMatch(
      source,
      new RegExp(
        `grant select,\\s*insert\\s+on table public\\.${table}\\s+to service_role`,
        "i",
      ),
      `${table} must expose only append-only service-role access`,
    );
    assert(
      !new RegExp(
        `grant[^;]*(?:update|delete|truncate)[^;]*on table public\\.${table}`,
        "i",
      ).test(source),
      `${table} must not regrant mutable service-role privileges`,
    );
  }
});

Deno.test("rollback SQL covers re-signed verified and legacy replays plus immutable conflicts", async () => {
  const source = await rollbackSqlTestSource();

  assertMatch(
    source,
    /verified_badge_resigned_replay_was_not_idempotent/i,
    "missing verified badge re-signed replay assertion",
  );
  assertMatch(
    source,
    /legacy_resigned_replay_was_not_idempotent/i,
    "missing legacy-chain re-signed replay assertion",
  );
  for (
    const marker of [
      "resigned_replay_original_id_mismatch_was_accepted",
      "resigned_replay_user_mismatch_was_accepted",
      "resigned_replay_product_mismatch_was_accepted",
      "resigned_replay_account_token_mismatch_was_accepted",
    ]
  ) {
    assertMatch(
      source,
      new RegExp(marker, "i"),
      `missing rollback mismatch assertion ${marker}`,
    );
  }
  for (
    const table of [
      "app_store_transactions",
      "app_store_entitlement_owners",
      "app_store_legacy_bindings",
    ]
  ) {
    for (const privilege of ["update", "delete", "truncate"]) {
      assertMatch(
        source,
        new RegExp(
          `has_table_privilege\\(\\s*'service_role',\\s*'public\\.${table}',\\s*'${privilege}'\\s*\\)`,
          "i",
        ),
        `rollback SQL must reject ${privilege} on ${table}`,
      );
    }
  }
  assertMatch(
    source,
    /service_role_owns_a_production_app_store_ledger/i,
    "rollback SQL must ensure service_role does not own an append-only ledger",
  );
  assertMatch(
    source,
    /rollback;[\s\S]+entitlement_and_verified_app_store_ledger_validated_with_rollback/i,
    "privilege and replay probes must be transactionally rolled back",
  );
});
