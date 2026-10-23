import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  new URL(
    "../migrations/20260726184500_video_openai_provider.sql",
    import.meta.url,
  ),
  "utf8",
);

test("OpenAI corrective migration extends the ledger without rewriting Google webhook binding", () => {
  assert.match(
    migration,
    /provider_name in \('fal', 'google', 'openai'\)/,
  );
  assert.match(
    migration,
    /p_provider_name not in \('fal', 'google', 'openai'\)/,
  );
  assert.doesNotMatch(
    migration,
    /create or replace function public\.bind_google_video_generation_webhook/,
  );
});

test("provider switching is pre-submission, forward-only, and claim-token protected", () => {
  assert.match(
    migration,
    /function public\.switch_video_generation_provider[\s\S]*for update/,
  );
  assert.match(
    migration,
    /provider_request_id is not null[\s\S]*submitted_at is not null[\s\S]*already_submitted/,
  );
  assert.match(
    migration,
    /p_expected_provider_name not in \('fal', 'google'\)/,
  );
  assert.match(
    migration,
    /p_new_provider_name not in \('google', 'openai'\)/,
  );
  assert.match(
    migration,
    /p_expected_provider_name = 'google'[\s\S]*p_new_provider_name <> 'openai'/,
  );
  assert.match(migration, /request\.claim_token_hash/);
  assert.match(migration, /request\.submission_rejected_at is not null/);
});

test("Google and OpenAI share bounded polling reconciliation while ambiguous submissions avoid fast refunds", () => {
  assert.match(
    migration,
    /function public\.claim_video_generation_reconciliation_batch[\s\S]*provider_name in \('google', 'openai'\)[\s\S]*for update skip locked/,
  );
  assert.match(
    migration,
    /function public\.reconcile_stale_video_generation_jobs[\s\S]*provider_name not in \('google', 'openai'\)/,
  );
  assert.match(
    migration,
    /submission_rejected_at is not null[\s\S]*x5_restore_video_generation_credits/,
  );
});

test("replaced security-definer RPCs keep service-only ACLs", () => {
  assert.match(
    migration,
    /revoke execute on function public\.claim_video_generation_job[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.claim_video_generation_job[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.switch_video_generation_provider[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.claim_video_generation_reconciliation_batch[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.reconcile_stale_video_generation_jobs[\s\S]*to postgres/,
  );
});
