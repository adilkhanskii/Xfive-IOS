function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

async function sandboxReviewMigrationSource(): Promise<string> {
  const migrationsUrl = new URL("../../migrations/", import.meta.url);
  const matches: string[] = [];
  for await (const entry of Deno.readDir(migrationsUrl)) {
    if (
      entry.isFile &&
      entry.name.endsWith("_app_store_sandbox_review_allowlist.sql")
    ) {
      matches.push(entry.name);
    }
  }
  assert(
    matches.length === 1,
    `expected one sandbox review migration, found ${matches.length}`,
  );
  return await Deno.readTextFile(new URL(matches[0], migrationsUrl));
}

Deno.test("Sandbox App Review is isolated behind a private exact allowlist", async () => {
  const source = await sandboxReviewMigrationSource();

  assertMatch(
    source,
    /create table public\.app_store_sandbox_review_accounts/i,
    "missing private Sandbox review account allowlist",
  );
  assertMatch(
    source,
    /where lower\(email\) = 'appreview@x5studio\.app'/i,
    "the dedicated App Review account must be selected by canonical email",
  );
  assertMatch(
    source,
    /create table public\.app_store_sandbox_review_transactions/i,
    "missing separate Sandbox review transaction ledger",
  );
  assertMatch(
    source,
    /create or replace function public\.apply_verified_app_store_sandbox_review_transaction\s*\(/i,
    "missing Sandbox review RPC",
  );
  assertMatch(source, /security definer/i, "RPC must be security definer");
  assertMatch(
    source,
    /set search_path\s*=\s*''/i,
    "RPC must pin an empty search_path",
  );
  assertMatch(
    source,
    /environment = 'Sandbox'/i,
    "Sandbox ledger must reject Production transactions",
  );
  assertMatch(
    source,
    /sandbox_review_account_not_allowed/i,
    "RPC must reject users outside the review allowlist",
  );
  assertMatch(
    source,
    /max_credit_balance/i,
    "Sandbox credit grants must have a hard balance cap",
  );
  assertMatch(
    source,
    /app_account_token = user_id/i,
    "Sandbox transaction must be bound to the authenticated account",
  );
  assert(
    !/v_existing\.signed_date\s*<>\s*p_signed_date/i.test(source),
    "a valid Sandbox transaction replay must tolerate a freshly signed JWS",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_sandbox_review_accounts\s+from service_role/i,
    "default service-role grants must be removed from the review allowlist",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_sandbox_review_transactions\s+from service_role/i,
    "default service-role grants must be removed from the Sandbox ledger",
  );
  assertMatch(
    source,
    /revoke execute on function public\.apply_verified_app_store_sandbox_review_transaction[\s\S]+?from public, anon, authenticated/i,
    "Sandbox review RPC must not be client-callable",
  );
  assertMatch(
    source,
    /grant execute on function public\.apply_verified_app_store_sandbox_review_transaction[\s\S]+?to service_role/i,
    "Sandbox review RPC must be service-role-only",
  );
});
