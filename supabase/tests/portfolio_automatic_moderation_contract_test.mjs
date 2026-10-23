import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../migrations/20260801121000_portfolio_automatic_moderation_enforcement.sql",
    import.meta.url,
  ),
  "utf8",
);
const decision = await readFile(
  new URL("../functions/moderate-portfolio/decision.mjs", import.meta.url),
  "utf8",
);

test("ordinary clients cannot write moderation verdicts", () => {
  const guard = functionBody("x5_guard_portfolio_moderation_fields");
  assert.match(guard, /service_role/i);
  assert.doesNotMatch(guard, /is_x5_developer|manual_review/i);
  assert.match(
    guard,
    /if tg_op = 'INSERT'[\s\S]*new\.moderation_status := 'pending'/i,
  );
  assert.match(
    guard,
    /if v_content_changed then[\s\S]*new\.moderation_status := 'pending'/i,
  );
  assert.match(
    guard,
    /else[\s\S]*new\.moderation_status := old\.moderation_status/i,
  );
});

test("automatic-only status contract fails closed", () => {
  assert.match(
    migration,
    /moderation_status set default 'pending'[\s\S]*moderation_status in \('pending', 'approved', 'rejected'\)/i,
  );
  assert.doesNotMatch(migration, /manual_review|is_x5_developer/i);
  assert.match(decision, /status:\s*"approved"/i);
  assert.match(decision, /status:\s*"rejected"/i);
  assert.match(decision, /status:\s*"pending"/i);
  assert.doesNotMatch(decision, /manual_review/i);
});

test("only approved items are public while owners retain private visibility", () => {
  const publicPolicy = migration.split(
    'create policy "portfolio public read"',
    2,
  )[1].split(";", 1)[0];
  assert.match(publicPolicy, /moderation_status = 'approved'/i);
  assert.match(publicPolicy, /auth\.uid\(\)\) = user_id/i);
  assert.doesNotMatch(publicPolicy, /developer|manual/i);
});

test("automatic moderation has a private bounded retry queue", () => {
  assert.match(
    migration,
    /create table if not exists public\.portfolio_moderation_jobs/i,
  );
  assert.match(migration, /attempt_count between 0 and 5/i);
  assert.match(migration, /force row level security/i);
  assert.match(migration, /for update(?: of item)? skip locked/i);
  assert.match(migration, /lease_token_hash/i);
  assert.match(migration, /pg_catalog\.sha256/i);
  assert.match(migration, /when 1 then interval '1 minute'/i);
  assert.match(migration, /when 2 then interval '5 minutes'/i);
  assert.match(migration, /when 3 then interval '15 minutes'/i);
  assert.match(migration, /else interval '1 hour'/i);
  assert.match(migration, /status = 'exhausted'/i);
  assert.match(migration, /final_attempt_lease_expired/i);
  assert.match(migration, /jsonb_build_object\('retry_exhausted', true\)/i);
});

test("server-owned sweep is signed, scheduled and service-only", () => {
  assert.match(migration, /x5_portfolio_moderation_sweep_secret/i);
  assert.match(
    migration,
    /length\(pg_catalog\.btrim\(v_sweep_secret\)\) < 32/i,
  );
  assert.match(migration, /x5_dispatch_portfolio_moderation_sweep/i);
  assert.match(
    migration,
    /cron\.schedule[\s\S]*x5-portfolio-moderation-sweep/i,
  );
  assert.match(migration, /X-X5-Portfolio-Moderation-Secret/i);
  assert.match(migration, /grant execute[\s\S]*to service_role/i);
});

test("moderation metadata does not bump the content CAS revision", () => {
  const revisionGuard = functionBody("x5_bump_portfolio_moderation_revision");
  assert.match(revisionGuard, /v_content_changed/i);
  assert.match(
    revisionGuard,
    /when v_content_changed then old\.moderation_revision \+ 1/i,
  );
  assert.match(revisionGuard, /else old\.moderation_revision/i);
  assert.doesNotMatch(
    revisionGuard,
    /old\.moderation_revision \+ 1;\s*end if/i,
  );
});

function functionBody(name) {
  const matches = [...migration.matchAll(
    new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "gi",
    ),
  )];
  assert.ok(matches.length > 0, `${name} missing`);
  return matches.at(-1)[0];
}
