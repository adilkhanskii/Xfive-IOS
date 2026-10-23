function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

async function consumableMigrationSource(): Promise<string> {
  const migrationsUrl = new URL("../../migrations/", import.meta.url);
  const matches: string[] = [];
  for await (const entry of Deno.readDir(migrationsUrl)) {
    if (
      entry.isFile &&
      entry.name.endsWith("_apple_consumable_credit_topups.sql")
    ) {
      matches.push(entry.name);
    }
  }
  assert(
    matches.length === 1,
    `expected one Apple consumable migration, found ${matches.length}`,
  );
  return await Deno.readTextFile(new URL(matches[0], migrationsUrl));
}

Deno.test("Apple consumable migration is private, exact-once, and server-priced", async () => {
  const source = await consumableMigrationSource();

  assertMatch(
    source,
    /create table(?: if not exists)? public\.app_store_consumable_transactions/i,
    "missing separate consumable transaction ledger",
  );
  assertMatch(
    source,
    /create or replace function public\.apply_verified_app_store_consumable\s*\(/i,
    "missing consumable entitlement RPC",
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
    "transaction replay must be serialized",
  );
  assert(
    !/v_existing\.signed_date\s*<>\s*p_signed_date/i.test(source),
    "a valid transaction replay must not conflict only because Apple re-signed its JWS",
  );
  assertMatch(
    source,
    /'status',\s*'already_applied'[\s\S]+?'credits_granted',\s*0/i,
    "replays must report zero newly granted credits",
  );
  assertMatch(
    source,
    /com\.x5studio\.app\.credits\.1000[\s\S]+?1000/i,
    "1,000-credit amount must come from the product allowlist",
  );
  assertMatch(
    source,
    /com\.x5studio\.app\.credits\.2000[\s\S]+?2000/i,
    "2,000-credit amount must come from the product allowlist",
  );
  assertMatch(
    source,
    /com\.x5studio\.app\.credits\.5000[\s\S]+?5000/i,
    "5,000-credit amount must come from the product allowlist",
  );
  assert(
    !/\bp_credits\b/i.test(source),
    "the consumable RPC must not accept a client-derived credit amount",
  );
  assertMatch(
    source,
    /alter table public\.app_store_consumable_transactions enable row level security/i,
    "consumable ledger must enable RLS",
  );
  assertMatch(
    source,
    /alter table public\.app_store_consumable_transactions force row level security/i,
    "consumable ledger must force RLS",
  );
  assertMatch(
    source,
    /revoke all privileges on table public\.app_store_consumable_transactions\s+from service_role/i,
    "default Supabase grants must be removed before append-only service-role grants",
  );
  assertMatch(
    source,
    /grant select,\s*insert\s+on table public\.app_store_consumable_transactions\s+to service_role/i,
    "service role needs append-only ledger access",
  );
  assert(
    !/grant[^;]*(?:update|delete)[^;]*on table public\.app_store_consumable_transactions/i
      .test(source),
    "the immutable consumable ledger must not grant update or delete",
  );
  assertMatch(
    source,
    /revoke execute on function public\.apply_verified_app_store_consumable[\s\S]+?from public, anon, authenticated/i,
    "consumable RPC must not be client-callable",
  );
  assertMatch(
    source,
    /grant execute on function public\.apply_verified_app_store_consumable[\s\S]+?to service_role/i,
    "consumable RPC must be service-role-only",
  );

  const profileUpdate = source.match(
    /update public\.profiles[\s\S]+?where id = p_user_id\s*;/i,
  )?.[0];
  assert(profileUpdate, "missing atomic profile credit update");
  assertMatch(
    profileUpdate,
    /set credits\s*=\s*coalesce\(credits,\s*0\)\s*\+\s*v_credits/i,
    "top-up must add the server-derived credit amount",
  );
  assert(
    !/\b(?:plan|subscription_type|subscription_date|subscription_end_date|is_verified|verified_until)\s*=/i
      .test(profileUpdate),
    "top-up must not mutate plan, subscription, or verification fields",
  );
});
