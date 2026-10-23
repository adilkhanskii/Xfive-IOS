function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(actual: string, expected: RegExp, message: string): void {
  assert(expected.test(actual), message);
}

const migration = await Deno.readTextFile(
  new URL(
    "../../migrations/20260831132000_lock_testflight_sandbox_purchases.sql",
    import.meta.url,
  ),
);

Deno.test("TestFlight Sandbox grants are locked to the dedicated App Review account", () => {
  assertMatch(
    migration,
    /delete from public\.app_store_sandbox_review_accounts[\s\S]+?account_kind\s*=\s*'developer'/i,
    "developer TestFlight allowlist rows must be removed",
  );
  assertMatch(
    migration,
    /where lower\(account\.email\)\s*=\s*'appreview@x5studio\.app'/i,
    "the App Review account must be resolved by exact canonical email",
  );
  assertMatch(
    migration,
    /check\s*\(account_kind\s*=\s*'app_review'\)/i,
    "future developer Sandbox allowlist rows must be rejected",
  );
  assertMatch(
    migration,
    /dedicated_app_review_account_missing/i,
    "deployment must fail closed when the review account is absent",
  );
  assert(
    !/2000000000/.test(migration),
    "the former unbounded developer credit ceiling must not survive",
  );
});
