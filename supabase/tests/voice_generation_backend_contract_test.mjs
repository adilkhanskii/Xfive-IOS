import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const functionDirectory = path.join(
  root,
  "supabase",
  "functions",
  "generate-voice",
);
const migrationPath = path.join(
  root,
  "supabase",
  "migrations",
  "20260726223000_voice_generation_exact_once.sql",
);
const deletionMigrationPath = path.join(
  root,
  "supabase",
  "migrations",
  "20260726224500_account_deletion_voice_cleanup.sql",
);
const deletionACLHotfixPath = path.join(
  root,
  "supabase",
  "migrations",
  "20260726222900_revoke_account_delete_helper_acl.sql",
);
const deletionWorkerDirectory = path.join(
  root,
  "supabase",
  "functions",
  "account-deletion-cleanup",
);
const sqlIntegrationTestPath = path.join(
  root,
  "supabase",
  "tests",
  "20260726_voice_generation_exact_once_test.sql",
);

test("voice backend and exact-once migration exist", () => {
  assert.equal(fs.existsSync(path.join(functionDirectory, "index.ts")), true);
  assert.equal(fs.existsSync(migrationPath), true);
  assert.equal(fs.existsSync(deletionMigrationPath), true);
  assert.equal(fs.existsSync(deletionACLHotfixPath), true);
  assert.ok(
    path.basename(deletionACLHotfixPath) < path.basename(migrationPath),
    "ACL hotfix must apply before the secret-gated voice/deletion rollout",
  );
  assert.equal(
    fs.existsSync(path.join(deletionWorkerDirectory, "index.ts")),
    true,
  );
  assert.equal(fs.existsSync(sqlIntegrationTestPath), true);
});

test("new voice jobs use official MiniMax only and keep credentials server-side", () => {
  assert.equal(fs.existsSync(path.join(functionDirectory, "index.ts")), true);
  assert.equal(
    fs.existsSync(path.join(functionDirectory, "fal-provider.mjs")),
    true,
  );
  assert.equal(
    fs.existsSync(
      path.join(root, "X5", "Services", "VoiceGenerationService.swift"),
    ),
    true,
  );
  const edge = fs.readFileSync(
    path.join(functionDirectory, "index.ts"),
    "utf8",
  );
  const provider = fs.readFileSync(
    path.join(functionDirectory, "direct-provider.mjs"),
    "utf8",
  );
  const swift = fs.readFileSync(
    path.join(root, "X5", "Services", "VoiceGenerationService.swift"),
    "utf8",
  );

  assert.match(edge, /Deno\.env\.get\("MINIMAX_API_KEY"\)/);
  assert.doesNotMatch(edge, /Deno\.env\.get\("ELEVENLABS_API_KEY"\)/);
  assert.match(provider, /https:\/\/api\.minimax\.io\/v1\/t2a_v2/);
  assert.doesNotMatch(provider, /api\.elevenlabs\.io/i);
  assert.doesNotMatch(
    swift,
    /MINIMAX_API_KEY|ELEVENLABS_API_KEY|api\.minimax\.io|api\.elevenlabs\.io/i,
  );
});

test("direct provider migration accepts new manifests and preserves legacy Fal", () => {
  const sql = fs.readFileSync(
    path.join(
      root,
      "supabase",
      "migrations",
      "20260817173000_direct_voice_providers.sql",
    ),
    "utf8",
  );
  assert.match(sql, /provider' = 'minimax'[\s\S]*model' = 'speech-2\.8-turbo'/);
  assert.match(sql, /provider' = 'elevenlabs'[\s\S]*model' = 'eleven_v3'/);
  assert.match(sql, /fal-ai\/elevenlabs\/tts\/eleven-v3/);
  assert.match(sql, /complete_voice_generation_by_provider/);
});

test("migration provides private exact-once debit, replay, refund, and audio storage", () => {
  assert.equal(fs.existsSync(migrationPath), true);
  const sql = fs.readFileSync(migrationPath, "utf8");

  for (const fragment of [
    "voice_generation_requests",
    "claim_voice_generation_request",
    "complete_voice_generation_request",
    "get_voice_generation_request",
    "fail_voice_generation_request",
    "reconcile_stale_voice_generation_requests",
    "voice-generation-results",
    "insufficient_credits",
    "idempotency_conflict",
    "already_refunded",
    "audio/mpeg",
    "enable row level security",
    "force row level security",
    "service_role",
  ]) {
    assert.match(sql, new RegExp(fragment.replaceAll("-", "\\-"), "i"));
  }
  assert.match(sql, /unique\s*\(\s*user_id\s*,\s*request_key\s*\)/i);
  assert.match(sql, /for update/i);
  assert.match(sql, /status\s*=\s*'refunded'/i);
  assert.match(sql, /interval\s+'4 hours'/i);
  assert.match(sql, /generation_expired/i);
});

test("account deletion is queued, service-only, scheduled, and storage-safe", () => {
  const sql = fs.readFileSync(deletionMigrationPath, "utf8");
  const aclHotfix = fs.readFileSync(deletionACLHotfixPath, "utf8");
  const worker = fs.readFileSync(
    path.join(deletionWorkerDirectory, "index.ts"),
    "utf8",
  );
  const config = fs.readFileSync(
    path.join(root, "supabase", "config.toml"),
    "utf8",
  );
  const enqueueFunction = sql.match(
    /create or replace function public\.delete_own_account\(\)([\s\S]*?)\$function\$;/i,
  )?.[1] || "";

  assert.match(
    sql,
    /revoke all on function public\.x5_delete_eq_if_exists\(text, text, uuid\)\s+from public, anon, authenticated, service_role;/i,
  );
  assert.match(
    aclHotfix,
    /revoke all on function public\.x5_delete_eq_if_exists\(text, text, uuid\)\s+from public, anon, authenticated, service_role;/i,
  );
  assert.match(enqueueFunction, /insert into public\.account_deletion_jobs/i);
  assert.doesNotMatch(enqueueFunction, /delete from auth\.users/i);
  assert.match(sql, /finalize_queued_account_deletion/i);
  assert.match(
    sql,
    /grant execute on function public\.finalize_queued_account_deletion\(uuid, text\)\s+to service_role;/i,
  );
  assert.match(sql, /x5_account_deletion_cleanup_secret/i);
  assert.match(sql, /account_deletion_cleanup_vault_secret_required/i);
  assert.match(sql, /cron\.schedule\(/i);
  assert.match(sql, /x5-account-deletion-cleanup/i);
  assert.match(sql, /\* \* \* \* \*/);
  assert.match(sql, /net\.http_post\(/i);
  assert.match(worker, /\/storage\/v1\/object\/voice-generation-results/);
  assert.match(sql, /list_refunded_voice_orphan_paths/i);
  assert.match(
    sql,
    /split_part\(object\.name,\s*'\/',\s*4\)::integer\s*<\s*ledger\.attempt/i,
  );
  assert.match(worker, /list_refunded_voice_orphan_paths/i);
  assert.doesNotMatch(worker, /delete\s+from\s+storage\.objects/i);
  assert.match(
    config,
    /\[functions\.account-deletion-cleanup\]\s+verify_jwt\s*=\s*false/i,
  );
});

test("SQL integration regression covers replay, lost submit, and deletion races", () => {
  const sqlTest = fs.readFileSync(sqlIntegrationTestPath, "utf8");
  for (const fragment of [
    "duplicate_claim_redebit",
    "bind_voice_generation_webhook",
    "ambiguous_submit_was_blindly_refunded",
    "terminal_rejection_not_reconciled",
    "delete_own_account",
    "account_deletion_tombstone_did_not_block_debit",
    "rollback;",
  ]) {
    assert.match(sqlTest, new RegExp(fragment, "i"));
  }
});
