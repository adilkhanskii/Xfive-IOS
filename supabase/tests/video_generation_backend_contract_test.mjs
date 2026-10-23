import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const migrationsDirectory = new URL("../migrations/", import.meta.url);
const migrationNames = readdirSync(migrationsDirectory)
  .filter((name) => name.endsWith("_video_generation_jobs.sql"));

test("video generation migration is present exactly once", () => {
  assert.equal(migrationNames.length, 1);
});

const migration = migrationNames.length === 1
  ? readFileSync(
    new URL(`../migrations/${migrationNames[0]}`, import.meta.url),
    "utf8",
  )
  : "";
const cronSecretMigrationNames = readdirSync(migrationsDirectory)
  .filter((name) => name.endsWith("_video_reconciliation_cron_secret.sql"));
const cronSecretMigration = cronSecretMigrationNames.length === 1
  ? readFileSync(
    new URL(`../migrations/${cronSecretMigrationNames[0]}`, import.meta.url),
    "utf8",
  )
  : "";
const bytePlusMigration = readFileSync(
  new URL(
    "../migrations/20260817150000_direct_byteplus_seedance.sql",
    import.meta.url,
  ),
  "utf8",
);
const edgeUrl = new URL(
  "../functions/generate-video/index.ts",
  import.meta.url,
);
const deploymentUrl = new URL(
  "../functions/generate-video/DEPLOYMENT.md",
  import.meta.url,
);
const nativeVideoSources = [
  "../../X5/Views/Home/VideoGeneratorView.swift",
  "../../X5/Services/VideoGenerationService.swift",
].map((path) => readFileSync(new URL(path, import.meta.url), "utf8")).join(
  "\n",
);

test("video jobs are owned, RLS protected, and expose no prompts or provider URLs", () => {
  assert.match(migration, /create table public\.video_generation_jobs/);
  assert.match(migration, /user_id uuid not null references public\.profiles/);
  assert.match(migration, /unique \(user_id, request_key\)/);
  assert.match(
    migration,
    /status in \('queued', 'rendering', 'completed', 'failed'\)/,
  );
  assert.match(migration, /provider_name text not null/);
  assert.match(migration, /provider_name in \('fal', 'google'\)/);
  assert.match(
    bytePlusMigration,
    /provider_name in \('byteplus', 'fal', 'google', 'openai'\)/,
  );
  assert.match(
    migration,
    /alter table public\.video_generation_jobs enable row level security/,
  );
  assert.match(
    migration,
    /create policy[\s\S]*for select[\s\S]*to authenticated[\s\S]*\(select auth\.uid\(\)\) = user_id/,
  );
  assert.match(
    migration,
    /revoke all on table public\.video_generation_jobs[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.doesNotMatch(
    migration,
    /grant (select|insert|update|delete)[\s\S]*video_generation_jobs[\s\S]*to (anon|authenticated)/,
  );
  assert.doesNotMatch(migration, /\bprompt\s+text\b/i);
  assert.doesNotMatch(migration, /provider_result_url|result_url\s+text/i);
});

test("private input and result buckets are created with bounded media types", () => {
  assert.match(migration, /'video-generation-inputs'/);
  assert.match(migration, /'video-generation-results'/);
  assert.match(migration, /false/);
  assert.match(migration, /image\/jpeg/);
  assert.match(migration, /image\/png/);
  assert.match(migration, /video\/mp4/);
  assert.match(migration, /8388608/);
});

test("credit reservation and refund are atomic, idempotent, and service-only", () => {
  for (
    const name of [
      "claim_video_generation_job",
      "switch_video_generation_provider",
      "record_video_generation_input",
      "mark_video_generation_submitted",
      "bind_google_video_generation_webhook",
      "mark_video_generation_rendering",
      "complete_video_generation_job",
      "fail_video_generation_job",
      "mark_video_generation_submission_rejected",
      "get_video_generation_job_service",
      "reconcile_stale_video_generation_jobs",
      "claim_video_generation_reconciliation_batch",
    ]
  ) {
    assert.match(migration, new RegExp(`function public\\.${name}`));
  }
  assert.match(migration, /where profile\.id = p_user_id[\s\S]*for update/);
  assert.match(migration, /on conflict \(user_id, request_key\) do nothing/);
  assert.match(
    migration,
    /function public\.switch_video_generation_provider[\s\S]*provider_request_id is not null[\s\S]*p_expected_provider_name[\s\S]*p_new_provider_name/,
  );
  assert.match(
    migration,
    /function public\.record_video_generation_input[\s\S]*'already_recorded'[\s\S]*input_object_path = p_input_object_path/,
  );
  assert.match(
    migration,
    /function public\.mark_video_generation_submitted[\s\S]*input_object_path = coalesce\(\s*ledger\.input_object_path,\s*p_input_object_path\s*\)/,
  );
  assert.match(
    migration,
    /function public\.bind_google_video_generation_webhook[\s\S]*claim_token_hash/,
  );
  assert.match(
    migration,
    /function public\.bind_google_video_generation_webhook[\s\S]*provider_name <> 'google'/,
  );
  assert.match(
    migration,
    /function public\.bind_google_video_generation_webhook[\s\S]*already_bound/,
  );
  assert.match(
    migration,
    /function public\.bind_google_video_generation_webhook[\s\S]*submission_conflict/,
  );
  assert.match(
    migration,
    /function public\.claim_video_generation_reconciliation_batch[\s\S]*p_limit[\s\S]*p_max_age[\s\S]*for update skip locked[\s\S]*reconcile_attempted_at/,
  );
  assert.match(migration, /if request\.refunded_at is not null/);
  assert.match(
    migration,
    /request\.provider_request_id is not null[\s\S]*request\.provider_request_id is distinct from p_provider_request_id[\s\S]*provider_request_id = coalesce\(\s*ledger\.provider_request_id,\s*p_provider_request_id\s*\)/,
  );
  assert.match(migration, /status = 'failed'[\s\S]*refunded_at = now\(\)/);
  assert.match(migration, /submission_rejected_at timestamptz/);
  assert.match(migration, /submission_rejection_code text/);
  assert.match(
    migration,
    /function public\.mark_video_generation_submission_rejected[\s\S]*claim_token_hash[\s\S]*provider_request_id is not null[\s\S]*submission_rejected_at/,
  );
  assert.match(
    migration,
    /function public\.reconcile_stale_video_generation_jobs[\s\S]*submission_rejected_at is not null[\s\S]*x5_restore_video_generation_credits[\s\S]*submission_rejection_code/,
  );
  assert.match(
    migration,
    /cron\.schedule\([\s\S]*x5-reconcile-orphaned-video-generations[\s\S]*'\*\/5 \* \* \* \*'/,
  );
  assert.match(
    migration,
    /coalesce\(auth\.jwt\(\) ->> 'role', ''\) <> 'service_role'/,
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
    /grant execute on function public\.bind_google_video_generation_webhook[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.claim_video_generation_reconciliation_batch[\s\S]*to service_role/,
  );
  assert.match(
    migration,
    /grant execute on function public\.mark_video_generation_submission_rejected[\s\S]*to service_role/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.(claim|switch|mark|complete|fail|get)_video_generation[\s\S]*to authenticated/,
  );
});

test("edge contract authenticates users and keeps provider credentials server-side", () => {
  assert.equal(existsSync(edgeUrl), true);
  const edgeEntry = readFileSync(edgeUrl, "utf8");
  const edge = [
    "../functions/generate-video/index.ts",
    "../functions/generate-video/handler.mjs",
    "../functions/generate-video/lifecycle.mjs",
    "../functions/generate-video/storage.mjs",
    "../functions/generate-video/fal-provider.mjs",
    "../functions/generate-video/byteplus-provider.mjs",
    "../functions/generate-video/google-provider.mjs",
    "../functions/generate-video/openai-provider.mjs",
    "../functions/generate-video/video-provider.mjs",
    "../functions/generate-video/moderation.mjs",
    "../functions/generate-video/webhook.mjs",
  ].map((path) => readFileSync(new URL(path, import.meta.url), "utf8")).join(
    "\n",
  );
  assert.match(edge, /Deno\.env\.get\("FAL_KEY"\)/);
  assert.match(edge, /Deno\.env\.get\("ARK_API_KEY"\)/);
  assert.match(edge, /Deno\.env\.get\("(GOOGLE_API_KEY|GEMINI_API_KEY)"\)/);
  assert.match(edge, /verifyUser/);
  assert.match(edge, /req\.method === "GET"/);
  assert.match(edge, /req\.method === "POST"/);
  assert.match(edge, /claim_video_generation_job/);
  assert.match(edge, /switch_video_generation_provider/);
  assert.match(edge, /FalKlingProvider/);
  assert.match(edge, /BytePlusSeedanceProvider/);
  assert.match(edge, /GoogleGeminiVideoProvider/);
  assert.match(edge, /OpenAIVideoProvider/);
  assert.match(edge, /selectVideoProvider/);
  assert.match(edge, /createSignedVideoUrl/);
  assert.match(edge, /verifyFalWebhookSignature/);
  assert.match(edge, /X-Fal-Webhook-Signature/i);
  assert.match(edge, /video-generation-inputs/);
  assert.match(edge, /video-generation-results/);
  assert.match(edgeEntry, /handleFalTerminalWebhook/);
  assert.match(edgeEntry, /finalizeVideoGenerationResult/);
  assert.match(edgeEntry, /record_video_generation_input/);
  assert.match(edgeEntry, /bind_google_video_generation_webhook/);
  assert.match(edgeEntry, /createGoogleWebhookHandler/);
  assert.match(edgeEntry, /createVideoReconcileHandler/);
  assert.doesNotMatch(
    edgeEntry,
    /webhookStatus[\s\S]*mark_video_generation_rendering/,
  );
  assert.doesNotMatch(edge, /job\.(provider_request_id|result_object_path)/);
});

test("server cron reads exactly one named Vault secret and invokes bounded Google reconciliation", () => {
  assert.match(migration, /create extension if not exists pg_net/);
  assert.match(
    migration,
    /create extension if not exists supabase_vault with schema vault/,
  );
  assert.match(
    migration,
    /function public\.enqueue_video_generation_reconciliation[\s\S]*net\.http_post/,
  );
  assert.match(
    migration,
    /cron\.schedule\([\s\S]*x5-reconcile-google-video-generations[\s\S]*enqueue_video_generation_reconciliation/,
  );
  assert.match(
    migration,
    /from vault\.decrypted_secrets[\s\S]*name\s*=\s*'x5_video_reconcile_service_role_key'/,
  );
  assert.match(migration, /v_secret_count\s*<>\s*1/);
  assert.match(
    migration,
    /v_service_role_key\s+is\s+null[\s\S]*btrim\(v_service_role_key\)[\s\S]*<\s*32/,
  );
  assert.doesNotMatch(migration, /app\.settings\.service_role_key/);
  assert.match(
    migration,
    /generate-video\?reconcile=google/,
  );
});

test("server cron uses a dedicated rotatable secret instead of transmitting service role", () => {
  const edge = readFileSync(edgeUrl, "utf8");
  const reconcile = readFileSync(
    new URL("../functions/generate-video/reconcile.mjs", import.meta.url),
    "utf8",
  );
  assert.equal(cronSecretMigrationNames.length, 1);
  assert.match(
    cronSecretMigration,
    /name\s*=\s*'x5_video_reconcile_cron_secret'/,
  );
  assert.match(
    cronSecretMigration,
    /'X-X5-Reconcile-Secret',\s*v_reconcile_secret/,
  );
  assert.doesNotMatch(
    cronSecretMigration,
    /'Authorization'|'apikey'|x5_video_reconcile_service_role_key/,
  );
  assert.match(
    edge,
    /requiredEnvironment\(\s*"VIDEO_RECONCILE_CRON_SECRET"/,
  );
  assert.match(reconcile, /"X-X5-Reconcile-Secret"/);
});

test("safety runs before credit claim and private inputs are cleaned after terminal jobs", () => {
  const handler = readFileSync(
    new URL("../functions/generate-video/handler.mjs", import.meta.url),
    "utf8",
  );
  const edge = readFileSync(edgeUrl, "utf8");
  const storage = readFileSync(
    new URL("../functions/generate-video/storage.mjs", import.meta.url),
    "utf8",
  );
  const moderation = readFileSync(
    new URL("../functions/generate-video/moderation.mjs", import.meta.url),
    "utf8",
  );

  assert.match(edge, /Deno\.env\.get\("OPENAI_API_KEY"\)/);
  assert.match(edge, /createBytePlusVideoModerator/);
  assert.match(moderation, /seed-2-0-lite-260428/);
  assert.match(moderation, /video_moderation_unavailable/);
  assert.doesNotMatch(moderation, /BASELINE_BLOCK_PATTERNS/);
  assert.match(
    handler,
    /moderateRequest\(normalized\)[\s\S]*claimJob\(/,
  );
  assert.match(handler, /content_rejected/);
  assert.match(handler, /deleteStartImage/);
  assert.match(edge, /storage\.deleteStartImage/);
  assert.match(storage, /isAllowedProviderHost/);
  assert.match(storage, /redirect: "manual"/);
  assert.match(
    migration,
    /'input_object_path', request\.input_object_path/,
  );
});

test("deployment notes require no-JWT gateway mode because the handler verifies both callers", () => {
  assert.equal(existsSync(deploymentUrl), true);
  const deployment = readFileSync(deploymentUrl, "utf8");
  assert.match(deployment, /--no-verify-jwt/);
  assert.match(deployment, /ARK_API_KEY/);
  assert.match(deployment, /FAL_KEY/);
  assert.match(deployment, /OPENAI_API_KEY/);
  assert.match(deployment, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(deployment, /do not deploy|review/i);
});

test("native and server video contracts expose only provider-compatible ratios", () => {
  const contract = readFileSync(
    new URL("../functions/generate-video/contract.mjs", import.meta.url),
    "utf8",
  );
  const google = readFileSync(
    new URL("../functions/generate-video/google-provider.mjs", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(contract, /"1:1"/);
  assert.doesNotMatch(google, /aspectRatio === "1:1"/);
  assert.doesNotMatch(nativeVideoSources, /"1:1"/);
});
