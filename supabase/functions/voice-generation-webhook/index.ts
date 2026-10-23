// Public gateway endpoint for fal callbacks. The handler verifies fal's
// Ed25519 signature over the raw body before any ledger or Storage access.

import { VoiceGenerationBackend } from "../generate-voice/backend.mjs";
import { createVoiceWebhookHandler } from "./handler.mjs";
import { getFalJwks, verifyFalWebhookSignature } from "./webhook-signature.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const backend = new VoiceGenerationBackend({
  supabaseURL,
  serviceRoleKey,
});

Deno.serve(createVoiceWebhookHandler({
  verifyWebhook: async ({
    headers,
    rawBody,
  }: {
    headers: Headers;
    rawBody: Uint8Array;
  }) =>
    await verifyFalWebhookSignature({
      headers,
      rawBody,
      jwks: await getFalJwks(),
    }),
  bindWebhook: (parameters: Record<string, unknown>) =>
    backend.rpc("bind_voice_generation_webhook", parameters),
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
  deleteAudio: (path: string) => backend.deleteAudio(path),
}));

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
