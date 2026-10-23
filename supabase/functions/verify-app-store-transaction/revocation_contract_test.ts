function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

async function revocationMigrationSource(): Promise<string> {
  const migrationsUrl = new URL("../../migrations/", import.meta.url);
  const matches: string[] = [];
  for await (const entry of Deno.readDir(migrationsUrl)) {
    if (
      entry.isFile &&
      entry.name.endsWith("_app_store_verified_revocations.sql")
    ) {
      matches.push(entry.name);
    }
  }
  assert(
    matches.length === 1,
    `expected one verified revocation migration, found ${matches.length}`,
  );
  return await Deno.readTextFile(new URL(matches[0], migrationsUrl));
}

Deno.test("verified revocation is append-only, owner-bound, and credit-neutral", async () => {
  const source = await revocationMigrationSource();

  assertMatch(
    source,
    /create table(?: if not exists)? public\.app_store_verified_revocations/i,
    "missing immutable verified-revocation ledger",
  );
  assertMatch(
    source,
    /create or replace function public\.apply_verified_app_store_verified_revocation\s*\(/i,
    "missing verified-revocation RPC",
  );
  assertMatch(source, /security definer/i, "RPC must be security definer");
  assertMatch(
    source,
    /set search_path\s*=\s*''/i,
    "RPC must pin an empty search_path",
  );
  assertMatch(
    source,
    /pg_advisory_xact_lock/i,
    "revocation replay must be serialized",
  );
  assertMatch(
    source,
    /v_product_id\s*<>\s*'com\.x5studio\.app\.verified\.monthly'/i,
    "only the verified-monthly product may use the revocation path",
  );
  assertMatch(
    source,
    /p_app_account_token\s*<>\s*p_user_id/i,
    "revocation must be bound to the authenticated account",
  );
  assertMatch(
    source,
    /from public\.app_store_transactions/i,
    "Production revocation must match the immutable Apple ledger",
  );
  assertMatch(
    source,
    /from public\.app_store_entitlement_owners/i,
    "Production revocation must match the immutable entitlement owner",
  );
  assertMatch(
    source,
    /from public\.app_store_sandbox_review_transactions/i,
    "Sandbox revocation must match its isolated review ledger",
  );
  assertMatch(
    source,
    /revocation_source_not_found/i,
    "unrecorded or forged transactions must be rejected",
  );
  assertMatch(
    source,
    /'status',\s*'already_applied'[\s\S]+?'credits_granted',\s*0/i,
    "replayed revocations must be credit-neutral",
  );
  assert(
    !/\bp_credits\b/i.test(source),
    "revocation RPC must not accept a credit amount",
  );

  assertMatch(
    source,
    /alter table public\.app_store_verified_revocations enable row level security/i,
    "revocation ledger must enable RLS",
  );
  assertMatch(
    source,
    /alter table public\.app_store_verified_revocations force row level security/i,
    "revocation ledger must force RLS",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_verified_revocations[\s\S]+?from service_role/i,
    "service role must not have broad direct ledger access",
  );
  assert(
    !/grant[^;]*(?:update|delete)[^;]*on table public\.app_store_verified_revocations/i
      .test(source),
    "immutable revocations must never grant update or delete",
  );
  assertMatch(
    source,
    /revoke execute on function public\.apply_verified_app_store_verified_revocation[\s\S]+?from public, anon, authenticated/i,
    "revocation RPC must not be client-callable",
  );
  assertMatch(
    source,
    /grant execute on function public\.apply_verified_app_store_verified_revocation[\s\S]+?to service_role/i,
    "revocation RPC must be service-role-only",
  );
});

Deno.test("Apple revocation preserves active Android and other Apple verification", async () => {
  const source = await revocationMigrationSource();

  assertMatch(
    source,
    /from public\.iap_entitlements[\s\S]+?platform[^;]+?'android'/i,
    "active Android verification must participate in reconciliation",
  );
  assertMatch(
    source,
    /x5_verified_monthly_v2/i,
    "current Android verified product must be preserved",
  );
  assertMatch(
    source,
    /from public\.app_store_transactions[\s\S]+?not exists[\s\S]+?app_store_verified_revocations/i,
    "other active Production Apple periods must be preserved",
  );
  assertMatch(
    source,
    /from public\.app_store_sandbox_review_transactions[\s\S]+?not exists[\s\S]+?app_store_verified_revocations/i,
    "other active Sandbox Apple periods must be preserved",
  );

  const profileUpdate = source.match(
    /update public\.profiles[\s\S]+?where id = p_user_id\s*;/i,
  )?.[0];
  assert(profileUpdate, "missing atomic verified-state reconciliation");
  assertMatch(
    profileUpdate,
    /is_verified\s*=/i,
    "verified flag is not reconciled",
  );
  assertMatch(
    profileUpdate,
    /verified_until\s*=/i,
    "verified expiry is not reconciled",
  );
  assert(
    !/\b(?:credits|plan|subscription_type|subscription_date|subscription_end_date)\s*=/i
      .test(profileUpdate),
    "revocation must not mutate credits, plan, or paid subscription fields",
  );
});

Deno.test("revocation RPC conflicts are returned as safe client rejections", async () => {
  const handlerSource = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );

  for (
    const errorCode of [
      "revocation_source_not_found",
      "revocation_source_mismatch",
      "revocation_id_conflict",
      "invalid_revocation_date",
    ]
  ) {
    assert(
      handlerSource.includes(errorCode),
      `handler does not safely map ${errorCode}`,
    );
  }
});
