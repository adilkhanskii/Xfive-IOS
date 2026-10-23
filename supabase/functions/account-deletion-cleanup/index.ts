import { VoiceGenerationBackend } from "../generate-voice/backend.mjs";
import { createAccountDeletionCleanupHandler } from "./handler.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const cronSecret = requiredEnvironment("ACCOUNT_DELETION_CLEANUP_SECRET");
const backend = new VoiceGenerationBackend({
  supabaseURL,
  serviceRoleKey,
});

Deno.serve(createAccountDeletionCleanupHandler({
  cronSecret,
  claimJob: (parameters: Record<string, unknown>) =>
    backend.rpc("claim_account_deletion_job", parameters),
  listPaths: (parameters: Record<string, unknown>) =>
    backend.rpc("list_account_deletion_voice_paths", parameters),
  listRefundedVoicePaths: (parameters: Record<string, unknown>) =>
    backend.rpc("list_refunded_voice_orphan_paths", parameters),
  finalizeAccount: (parameters: Record<string, unknown>) =>
    backend.rpc("finalize_queued_account_deletion", parameters),
  recordCleanupPass: (parameters: Record<string, unknown>) =>
    backend.rpc("record_account_deletion_cleanup_pass", parameters),
  releaseJob: (parameters: Record<string, unknown>) =>
    backend.rpc("release_account_deletion_job", parameters),
  deletePaths,
}));

async function deletePaths(paths: string[]): Promise<void> {
  const response = await fetch(
    `${supabaseURL}/storage/v1/object/voice-generation-results`,
    {
      method: "DELETE",
      headers: {
        "apikey": serviceRoleKey,
        "Authorization": `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prefixes: paths }),
    },
  );
  if (!response.ok) {
    throw new Error(`account_deletion_storage_failed_${response.status}`);
  }
}

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
