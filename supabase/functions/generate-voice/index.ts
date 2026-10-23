// Authenticated client entrypoint for official MiniMax voice jobs.
// Required provider env: MINIMAX_API_KEY.
// FAL_KEY is read only to let already-bound legacy queue jobs finish.
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY.

import { VoiceGenerationBackend } from "./backend.mjs";
import { FalVoiceQueueProvider } from "./fal-provider.mjs";
import { DirectVoiceProvider } from "./direct-provider.mjs";
import { createGenerateVoiceHandler } from "./handler.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const falKey = Deno.env.get("FAL_KEY") || "";
const minimaxKey = Deno.env.get("MINIMAX_API_KEY") || "";
const backend = new VoiceGenerationBackend({
  supabaseURL,
  serviceRoleKey,
});
const provider = falKey.trim()
  ? new FalVoiceQueueProvider({ apiKey: falKey })
  : null;
const directProvider = minimaxKey.trim()
  ? new DirectVoiceProvider({ minimaxKey })
  : null;

Deno.serve(createGenerateVoiceHandler({
  verifyUser,
  providerConfigured: () => directProvider !== null,
  directProviderConfigured: () => directProvider !== null,
  generateDirect: (parameters: { input: Record<string, unknown> }) =>
    directProvider!.generate(parameters),
  lookupGeneration: (parameters: Record<string, unknown>) =>
    backend.rpc("lookup_voice_generation_request", parameters),
  claimGeneration: (parameters: Record<string, unknown>) =>
    backend.rpc("claim_voice_generation_request", parameters),
  buildWebhookURL: ({
    claimToken,
    attempt,
  }: {
    claimToken: string;
    attempt: number;
  }) => {
    const url = new URL(
      `${supabaseURL}/functions/v1/voice-generation-webhook`,
    );
    url.searchParams.set("claim", claimToken);
    url.searchParams.set("attempt", String(attempt));
    return url.toString();
  },
  submitGeneration: (
    parameters: { input: Record<string, unknown>; webhookURL: string },
  ) => provider!.submit(parameters),
  bindProvider: (parameters: Record<string, unknown>) =>
    backend.rpc("bind_voice_generation_provider_request", parameters),
  markSubmissionAmbiguous: (parameters: Record<string, unknown>) =>
    backend.rpc("mark_voice_generation_submission_ambiguous", parameters),
  markSubmissionRejected: (parameters: Record<string, unknown>) =>
    backend.rpc("mark_voice_generation_submission_rejected", parameters),
  getProviderStatus: (parameters: { requestID: string }) =>
    provider!.status(parameters),
  getProviderResult: (parameters: { requestID: string }) =>
    provider!.result(parameters),
  storeAudio: (
    parameters: {
      audioURL: string;
      userID: string;
      requestKey: string;
      attempt: number;
    },
  ) => backend.storeAudio(parameters),
  completeByProvider: (parameters: Record<string, unknown>) =>
    backend.rpc("complete_voice_generation_by_provider", parameters),
  getByProvider: (parameters: Record<string, unknown>) =>
    backend.rpc("get_voice_generation_by_provider", parameters),
  failByProvider: (parameters: Record<string, unknown>) =>
    backend.rpc("fail_voice_generation_by_provider", parameters),
  failGeneration: (parameters: Record<string, unknown>) =>
    backend.rpc("fail_voice_generation_request", parameters),
  deleteAudio: (path: string) => backend.deleteAudio(path),
  signAudio: (path: string) => backend.signAudio(path),
  assetForObject: (_userID: string, path: string) =>
    backend.rpc("generated_asset_by_object_service", {
      p_bucket_id: "voice-generation-results",
      p_object_path: path,
    }),
  recordProviderHealth: (
    success: boolean,
    errorCode: string | null = null,
  ) =>
    backend.rpc("record_ai_provider_health", {
      p_provider: "minimax",
      p_capability: "voice",
      p_success: success,
      p_model: "speech-2.8-turbo",
      p_error_code: errorCode,
    }),
}));

async function verifyUser(
  authorization: string,
): Promise<{ id: string } | null> {
  const response = await fetch(`${supabaseURL}/auth/v1/user`, {
    headers: {
      "Authorization": authorization,
      "apikey": anonKey,
      "Cache-Control": "no-store",
    },
  }).catch(() => null);
  if (!response?.ok) return null;
  const payload: unknown = await response.json().catch(() => null);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  const id = String((payload as { id?: unknown }).id || "");
  return /^[0-9a-f-]{36}$/i.test(id) ? { id } : null;
}

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
