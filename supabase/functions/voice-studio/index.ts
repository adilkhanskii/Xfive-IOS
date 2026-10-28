// «Мои голоса» премиум-озвучки: клон (ElevenLabs IVC), голос по описанию
// (Voice Design), каталог стандартных голосов с образцами, удаление.
// Секрет: ELEVENLABS_API_KEY (без него — premium_unavailable, без списаний).
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.

import { verifyAIStudioUser } from "../_shared/ai-studio.mjs";
import { VoiceGenerationBackend } from "../generate-voice/backend.mjs";
import { ElevenLabsVoicesClient } from "./elevenlabs-voices.mjs";
import { createVoiceStudioHandler } from "./handler.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const elevenLabsKey = String(Deno.env.get("ELEVENLABS_API_KEY") || "").trim();
const backend = new VoiceGenerationBackend({ supabaseURL, serviceRoleKey });
const voices = elevenLabsKey
  ? new ElevenLabsVoicesClient({ apiKey: elevenLabsKey })
  : null;

Deno.serve(createVoiceStudioHandler({
  verifyUser: (req: Request) =>
    verifyAIStudioUser(req, { supabaseURL, anonKey }),
  voicesClient: () => voices,
  // Клон голоса (IVC) у ElevenLabs только на платном тарифе Starter+.
  // Пока тариф не куплен — секрет не ставим, клиент видит «нужен тариф Starter».
  cloneEnabled: () =>
    String(Deno.env.get("ELEVENLABS_CLONE_ENABLED") || "").trim() === "true",
  quote: (userID: string) =>
    backend.rpc("voice_studio_quote", { p_user_id: userID }),
  charge: (parameters: Record<string, unknown>) =>
    backend.rpc("voice_studio_charge", parameters),
  listVoices: (userID: string) =>
    backend.rpc("list_user_voices", { p_user_id: userID }),
  ownsVoice: async (
    { userID, voiceID }: { userID: string; voiceID: string },
  ) => {
    const result = await backend.rpc("user_voice_owned", {
      p_user_id: userID,
      p_provider_voice_id: voiceID,
    });
    return result?.owned === true;
  },
  deleteVoiceRow: (parameters: Record<string, unknown>) =>
    backend.rpc("delete_user_voice", parameters),
}));

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
