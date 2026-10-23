import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  new URL(
    "../migrations/20260716214926_image_generation_reliability.sql",
    import.meta.url,
  ),
  "utf8",
);
const edge = readFileSync(
  new URL("../functions/generate-image/index.ts", import.meta.url),
  "utf8",
);
const serviceRoleHotfixURL = new URL(
  "../migrations/20260724090000_fix_image_generation_service_role_guard.sql",
  import.meta.url,
);

test("generation ledger is private and stores only hashed request identity", () => {
  assert.match(migration, /create table public\.image_generation_requests/);
  assert.match(migration, /request_key text not null/);
  assert.match(migration, /request_fingerprint text not null/);
  assert.match(migration, /is_legacy boolean not null/);
  assert.match(migration, /claim_token_hash text not null/);
  assert.match(migration, /result_manifest jsonb/);
  assert.match(migration, /permanent_credits_debited integer/);
  assert.match(migration, /permanent_credit_debt_at_claim integer/);
  assert.match(migration, /credits_expires_at_before_debit timestamptz/);
  assert.match(migration, /credits_expires_at_after_debit timestamptz/);
  assert.doesNotMatch(migration, /\bprompt\s+text\b/i);
  assert.match(
    migration,
    /alter table public\.image_generation_requests enable row level security/,
  );
  assert.match(
    migration,
    /alter table public\.image_generation_requests force row level security/,
  );
  assert.match(
    migration,
    /revoke all on table public\.image_generation_requests[\s\S]*from public, anon, authenticated, service_role/,
  );
});

test("claim, completion, failure, lookup, and reconciliation stay privileged", () => {
  for (const functionName of [
    "claim_image_generation_request",
    "complete_image_generation_request",
    "fail_image_generation_request",
    "get_image_generation_request",
    "reconcile_stale_image_generation_requests",
    "x5_restore_image_generation_credits",
  ]) {
    assert.match(migration, new RegExp(`function public\\.${functionName}`));
  }
  assert.match(migration, /security definer/g);
  assert.match(migration, /set search_path = ''/g);
  assert.match(
    migration,
    /revoke execute on function public\.claim_image_generation_request\([\s\S]*uuid, text, text, boolean, integer, text[\s\S]*\)[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.claim_image_generation_request[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.reconcile_stale_image_generation_requests\([\s\S]*interval[\s\S]*\) to postgres/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.reconcile_stale_image_generation_requests\([\s\S]*interval[\s\S]*\) to service_role/,
  );
  assert.match(
    migration,
    /revoke execute on function public\.x5_restore_image_generation_credits\(uuid\)[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.x5_restore_image_generation_credits/,
  );
});

test("service RPC guards read the current JWT claims object", () => {
  assert.doesNotMatch(migration, /request\.jwt\.claim\.role/);
  assert.equal(
    (
      migration.match(
        /coalesce\(auth\.jwt\(\)\s*->>\s*'role',\s*''\)\s*<>\s*'service_role'/g,
      ) || []
    ).length,
    4,
  );
});

test("production receives an idempotent service-role guard hotfix", () => {
  assert.equal(existsSync(serviceRoleHotfixURL), true);
  const hotfix = readFileSync(serviceRoleHotfixURL, "utf8");
  for (const functionName of [
    "claim_image_generation_request",
    "complete_image_generation_request",
    "get_image_generation_request",
    "fail_image_generation_request",
  ]) {
    assert.match(hotfix, new RegExp(functionName));
  }
  assert.match(hotfix, /auth\.jwt\(\)\s*->>\s*''role''/);
  assert.match(hotfix, /unexpected_generation_service_role_guard/);
});

test("ledger debits once, replays completion, and refunds once", () => {
  assert.match(migration, /status = 'succeeded'[\s\S]*'replay'/);
  assert.match(migration, /status = 'processing'[\s\S]*'in_progress'/);
  assert.match(
    migration,
    /unique \(user_id, request_key\)[\s\S]*on conflict \(user_id, request_key\) do nothing/,
  );
  assert.match(
    migration,
    /from public\.profiles as profile[\s\S]*where profile\.id = p_user_id[\s\S]*for update;[\s\S]*if v_credits < p_cost_credits/,
  );
  assert.match(migration, /attempt = request\.attempt \+ 1/);
  assert.match(
    migration,
    /if request\.status = 'refunded'[\s\S]*v_credits := public\.x5_restore_image_generation_credits\(request\.id\)/,
  );
  assert.match(
    migration,
    /where ledger\.status = 'processing'[\s\S]*for update skip locked[\s\S]*perform public\.x5_restore_image_generation_credits\(request\.id\)/,
  );
  assert.match(migration, /completed_at >= now\(\) - interval '2 minutes'/);
});

test("claim translates a missing profile FK into profile_not_found", () => {
  assert.match(
    migration,
    /exception\s+when foreign_key_violation then[\s\S]*'status', 'profile_not_found'/,
  );
});

test("terminal RPCs are bound to the exact claim attempt and opaque token", () => {
  for (const terminalFunction of [
    "complete_image_generation_request",
    "get_image_generation_request",
    "fail_image_generation_request",
  ]) {
    const start = migration.indexOf(`function public.${terminalFunction}`);
    assert.notEqual(start, -1);
    const body = migration.slice(start, start + 9000);
    assert.match(body, /p_attempt integer/);
    assert.match(body, /p_claim_token text/);
    assert.match(body, /request\.attempt <> p_attempt/);
    assert.match(body, /request\.claim_token_hash <>[\s\S]*sha256/);
    assert.match(body, /'status', 'stale_attempt'/);
  }
});

test("manifest validation rejects missing keys and non-string object fields", () => {
  assert.match(
    migration,
    /not \(p_result_manifest \?& array\[[\s\S]*?'version',[\s\S]*?'provider',[\s\S]*?'model',[\s\S]*?'objects'/,
  );
  assert.match(
    migration,
    /coalesce\(jsonb_typeof\(p_result_manifest -> 'objects'\), ''\) <>\s*'array'/,
  );
  assert.match(
    migration,
    /not \(item\.value \?& array\['path', 'mimeType', 'sha256'\]/,
  );
});

test("refund restores timed/permanent classification and the prior expiry", () => {
  assert.match(
    migration,
    /v_new_debt_since_claim[\s\S]*request\.permanent_credit_debt_at_claim/,
  );
  assert.match(
    migration,
    /v_permanent_restored :=[\s\S]*request\.permanent_credits_debited - v_debt_repaid/,
  );
  assert.match(
    migration,
    /old\.credits_expires_at is not distinct from[\s\S]*request\.credits_expires_at_after_debit[\s\S]*new\.credits_expires_at := request\.credits_expires_at_before_debit/,
  );
  assert.match(
    migration,
    /create trigger zz_x5_restore_image_generation_credits[\s\S]*execute function public\.x5_apply_image_generation_credit_restoration/,
  );
  assert.match(
    migration,
    /current_user <> 'postgres'[\s\S]*x5\.image_generation_restore_request/,
  );
});

test("stale reconciliation and private replay storage are provisioned", () => {
  assert.match(migration, /id, name, public, file_size_limit/);
  assert.match(migration, /'image-generation-results'/);
  assert.match(migration, /false/);
  assert.match(migration, /cron\.schedule/);
  assert.match(migration, /interval '15 minutes'/);
});

test("edge uses the ledger around provider execution and storage replay", () => {
  assert.match(edge, /createClaimToken/);
  assert.match(edge, /buildGenerationIdentity/);
  assert.match(edge, /claim_image_generation_request/);
  assert.match(edge, /complete_image_generation_request/);
  assert.match(edge, /fail_image_generation_request/);
  assert.match(edge, /image-generation-results/);
  assert.match(edge, /readGenerationResult/);
  assert.match(edge, /buildPriorAttemptCleanupCandidates/);
  assert.match(edge, /p_attempt: claimAttempt/);
  assert.match(edge, /p_claim_token: claimToken/);
  assert.match(edge, /waitForClaimResolution/);
  assert.match(edge, /generation_in_progress[\s\S]*425/);
  assert.doesNotMatch(edge, /generation_in_progress[\s\S]{0,240}\b202\b/);
});

test("Google requests opt out of provider-side request and response storage", () => {
  assert.equal((edge.match(/store:\s*false/g) || []).length, 2);
});

test("ambiguous completion keeps durable artifacts until a retry can resolve state", () => {
  assert.match(edge, /class GenerationCompletionUncertainError/);
  assert.match(edge, /completeGenerationDurably/);
  assert.match(
    edge,
    /catch \(error\) \{\s+if \(error instanceof GenerationCompletionUncertainError\)[\s\S]*generation_status_pending[\s\S]*425/,
  );
  const uncertainBranch = edge.indexOf(
    "if (error instanceof GenerationCompletionUncertainError)",
  );
  const refund = edge.indexOf(
    'const refund = await callServiceRpc("fail_image_generation_request"',
    uncertainBranch,
  );
  assert.ok(uncertainBranch >= 0);
  assert.ok(refund > uncertainBranch);
});
