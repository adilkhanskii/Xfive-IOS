import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const migrationsDirectory = new URL("../migrations/", import.meta.url);
const names = readdirSync(migrationsDirectory)
  .filter((name) => name.endsWith("_startup_chat_idempotency.sql"));
const migration = names.length === 1
  ? readFileSync(new URL(`../migrations/${names[0]}`, import.meta.url), "utf8")
  : "";
const edgeURL = new URL("../functions/startup-chat/index.ts", import.meta.url);
const controlFlowTestURL = new URL(
  "./20260725_startup_chat_rate_limit_test.sql",
  import.meta.url,
);

test("startup chat has exactly one private authenticated idempotency migration", () => {
  assert.equal(names.length, 1);
  assert.match(migration, /create table public\.startup_chat_requests/);
  assert.match(migration, /unique \(user_id, request_id\)/);
  assert.match(migration, /request_fingerprint ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(migration, /enable row level security/);
  assert.match(
    migration,
    /alter table public\.startup_chat_request_attempts enable row level security/,
  );
  assert.match(
    migration,
    /alter table public\.startup_chat_request_attempts force row level security/,
  );
  assert.match(
    migration,
    /revoke all on table public\.startup_chat_request_attempts[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /revoke all on table public\.startup_chat_requests[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.doesNotMatch(migration, /create policy[\s\S]*startup_chat_requests/i);
});

test("claim RPC is auth-owned, rate limited, burst safe, and replay aware", () => {
  assert.match(
    migration,
    /function public\.claim_startup_chat_request\(p_request_id uuid, p_request_fingerprint text\)/,
  );
  assert.match(migration, /security definer/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /count\(\*\)[\s\S]*>= 50/);
  assert.match(migration, /interval '3 seconds'/);
  assert.match(migration, /'status', 'rate_limited'/);
  assert.match(migration, /'status', 'in_progress'/);
  assert.match(migration, /'status', 'replay'/);
  assert.match(migration, /'status', 'idempotency_conflict'/);
});

test("claims use an unguessable rotating ownership token and bounded lease", () => {
  assert.match(migration, /lease_token uuid/);
  assert.match(migration, /lease_generation bigint/);
  assert.match(migration, /lease_expires_at timestamptz/);
  assert.match(migration, /gen_random_uuid\(\)/);
  assert.match(
    migration,
    /lease_expires_at = now\(\) \+ interval '75 seconds'/,
    "the lease must outlive auth, moderation, Responses, and completion deadlines",
  );
  assert.match(migration, /'lease_token', v_lease_token/);
  assert.match(migration, /'lease_generation', v_lease_generation/);
  assert.match(
    migration,
    /request\.lease_expires_at > now\(\)[\s\S]*'status', 'in_progress'/,
  );
  assert.match(
    migration,
    /request\.status = 'retryable'[\s\S]*request\.lease_expires_at <= now\(\)[\s\S]*lease_token = v_lease_token[\s\S]*lease_generation = v_lease_generation[\s\S]*'status', 'claimed'/,
  );
});

test("release preserves rate-limit evidence and allows the same request to retry", () => {
  assert.match(
    migration,
    /function public\.release_startup_chat_request\(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid\)/,
  );
  assert.match(
    migration,
    /release_startup_chat_request[\s\S]*auth\.uid\(\)/,
  );
  assert.match(
    migration,
    /if request\.status = 'completed' then[\s\S]*'status', 'completed'/,
  );
  assert.match(
    migration,
    /release_startup_chat_request[\s\S]*set status = 'retryable'/,
  );
  const releaseFunction = migration.match(
    /create or replace function public\.release_startup_chat_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";
  assert.doesNotMatch(
    releaseFunction,
    /delete from public\.startup_chat_requests/,
    "release must retain the daily and burst ledger row",
  );
  assert.match(
    migration,
    /request\.status = 'retryable'[\s\S]*set status = 'processing'/,
  );
  assert.match(
    migration,
    /select count\(\*\), max\(attempt\.attempted_at\)[\s\S]*attempt\.attempted_at >= v_utc_day_start/,
  );
  assert.doesNotMatch(
    releaseFunction,
    /delete from public\.startup_chat_request_attempts/,
    "release must retain the provider-attempt evidence",
  );
  assert.match(
    migration,
    /grant execute on function public\.release_startup_chat_request[\s\S]*to authenticated/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.release_startup_chat_request[\s\S]*to service_role/,
  );
});

test("every provider attempt is recorded and rate checked before a retry lease rotates", () => {
  const claimFunction = migration.match(
    /create or replace function public\.claim_startup_chat_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";
  const retryEligibility = claimFunction.indexOf("v_reclaim_existing := true");
  const attemptRateRead = claimFunction.indexOf(
    "from public.startup_chat_request_attempts",
  );
  const retryLeaseRotation = claimFunction.indexOf(
    "v_lease_generation := request.lease_generation + 1",
  );
  const attemptWrite = claimFunction.indexOf(
    "insert into public.startup_chat_request_attempts",
  );

  assert.match(
    migration,
    /create table public\.startup_chat_request_attempts/,
  );
  assert.ok(
    retryEligibility >= 0,
    "retry eligibility must enter the common claim path",
  );
  assert.ok(
    attemptRateRead > retryEligibility,
    "attempt rate limits must run after retry eligibility is established",
  );
  assert.ok(
    retryLeaseRotation > attemptRateRead,
    "a retry lease must not rotate before attempt limits pass",
  );
  assert.ok(
    attemptWrite > retryLeaseRotation,
    "the granted retry must be recorded before the transaction returns",
  );
});

test("transactional SQL test exercises burst and daily limits on retry RPCs", () => {
  assert.equal(existsSync(controlFlowTestURL), true);
  const sqlTest = readFileSync(controlFlowTestURL, "utf8");

  assert.match(sqlTest, /claim_startup_chat_request/);
  assert.match(sqlTest, /release_startup_chat_request/);
  assert.match(
    sqlTest,
    /active_lease_allowed_duplicate_provider_attempt/,
  );
  assert.match(sqlTest, /retry_burst_limit_was_bypassed/);
  assert.match(sqlTest, /retry_daily_limit_was_bypassed/);
  assert.match(
    sqlTest,
    /startup_chat_attempt_ledger_is_directly_readable/,
  );
  assert.match(sqlTest, /rollback;/);
});

test("cleanup retains request rows that recorded a recent retry attempt", () => {
  const cleanupFunction = migration.match(
    /create or replace function public\.cleanup_startup_chat_requests[\s\S]*?\$function\$;/,
  )?.[0] ?? "";

  assert.match(
    cleanupFunction,
    /ledger\.updated_at < now\(\) - interval '2 days'/,
  );
  assert.doesNotMatch(
    cleanupFunction,
    /ledger\.created_at < now\(\) - interval '2 days'/,
  );
});

test("stale lease generations cannot complete or release a reclaimed request", () => {
  const completeFunction = migration.match(
    /create or replace function public\.complete_startup_chat_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";
  const releaseFunction = migration.match(
    /create or replace function public\.release_startup_chat_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";
  assert.match(
    migration,
    /function public\.complete_startup_chat_request\(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid, p_reply text\)/,
  );
  assert.match(
    migration,
    /complete_startup_chat_request[\s\S]*request\.lease_token <> p_lease_token[\s\S]*'status', 'lease_conflict'/,
  );
  assert.match(
    migration,
    /complete_startup_chat_request[\s\S]*ledger\.status = 'processing'[\s\S]*ledger\.lease_token = p_lease_token/,
  );
  assert.match(
    migration,
    /release_startup_chat_request[\s\S]*request\.lease_token <> p_lease_token[\s\S]*'status', 'lease_conflict'/,
  );
  assert.match(
    migration,
    /release_startup_chat_request[\s\S]*ledger\.status = 'processing'[\s\S]*ledger\.lease_token = p_lease_token/,
  );
  assert.match(
    completeFunction,
    /request\.lease_token <> p_lease_token[\s\S]*if request\.status = 'completed' then[\s\S]*'reply', request\.reply/,
    "a stale completion token must not be accepted after a newer generation completed",
  );
  assert.match(
    releaseFunction,
    /request\.lease_token <> p_lease_token[\s\S]*if request\.status = 'completed' then[\s\S]*'reply', request\.reply/,
    "a stale release token must not observe success for a newer generation",
  );
  assert.doesNotMatch(
    completeFunction,
    /set status = 'completed',[\s\S]*?lease_token = null/,
  );
  assert.match(
    migration,
    /status = 'completed'[\s\S]*lease_token is not null/,
  );
});

test("completion is bounded, authenticated-only, and cleanup uses pg cron", () => {
  assert.match(migration, /char_length\(p_reply\) > 8000/);
  assert.match(migration, /replay_until = now\(\) \+ interval '15 minutes'/);
  assert.match(
    migration,
    /grant execute on function public\.claim_startup_chat_request[\s\S]*to authenticated/,
  );
  assert.match(
    migration,
    /grant execute on function public\.complete_startup_chat_request[\s\S]*to authenticated/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.(claim|complete)_startup_chat_request[\s\S]*to service_role/,
  );
  assert.match(migration, /cron\.schedule\(/);
  assert.match(migration, /x5-cleanup-startup-chat-requests/);
});

test("edge claims with the user token and never requires a service role secret", () => {
  assert.equal(existsSync(edgeURL), true);
  const edge = readFileSync(edgeURL, "utf8");
  assert.match(edge, /claim_startup_chat_request/);
  assert.match(edge, /complete_startup_chat_request/);
  assert.match(edge, /buildStartupChatIdentity/);
  assert.match(edge, /p_request_id/);
  assert.match(edge, /p_request_fingerprint/);
  assert.match(edge, /p_lease_token/);
  assert.match(edge, /claim\.lease_token/);
  assert.match(edge, /status === "rate_limited"/);
  assert.match(edge, /status === "in_progress"/);
  assert.match(edge, /status === "replay"/);
  assert.match(edge, /"Retry-After"/);
  assert.doesNotMatch(edge, /SUPABASE_SERVICE_ROLE_KEY/);
});

test("server deadlines remain below the fifty-five-second client timeout", () => {
  const edge = readFileSync(edgeURL, "utf8");
  const provider = readFileSync(
    new URL("../functions/startup-chat/provider.mjs", import.meta.url),
    "utf8",
  );
  assert.match(edge, /AUTH_TIMEOUT_MS = 6_000/);
  assert.match(edge, /RPC_TIMEOUT_MS = 4_000/);
  assert.match(provider, /moderationTimeoutMs = 8_000/);
  assert.match(provider, /responseTimeoutMs = 30_000/);
});
