// «Мои голоса» премиум-озвучки: клон (ElevenLabs IVC), голос по описанию
// (Voice Design), каталог стандартных голосов с образцами, удаление.
// Секрет: ELEVENLABS_API_KEY (без него — premium_unavailable, без списаний).
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.

import { verifyAIStudioUser } from "../_shared/ai-studio.mjs";
import { VoiceGenerationBackend } from "../generate-voice/backend.mjs";
import { ElevenLabsVoicesClient } from "./elevenlabs-voices.mjs";
import { createVoiceStudioHandler } from "./handler.mjs";
import {
  captureVoiceSample,
  createVoiceSleeper,
  voiceSamplePath,
  VoiceSampleStorage,
} from "../_shared/voice-sleep.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const elevenLabsKey = String(Deno.env.get("ELEVENLABS_API_KEY") || "").trim();
const backend = new VoiceGenerationBackend({ supabaseURL, serviceRoleKey });
const voices = elevenLabsKey
  ? new ElevenLabsVoicesClient({ apiKey: elevenLabsKey })
  : null;
const samples = new VoiceSampleStorage({ supabaseURL, serviceRoleKey });
// «Голос спит»: места у ElevenLabs освобождаем усыплением старых голосов X5.
const sleeper = voices
  ? createVoiceSleeper({
    rpc: (name: string, params: Record<string, unknown>) =>
      backend.rpc(name, params),
    voices,
    storage: samples,
    capture: (voiceID: string) =>
      captureVoiceSample({ apiKey: elevenLabsKey, voiceID }),
    log: (...parts: unknown[]) => console.log(...parts),
  })
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
  withRoom: <T>(create: () => Promise<T>) =>
    sleeper ? sleeper.withRoom(create, null) : create(),
  voiceState: ({ userID, voiceID }: { userID: string; voiceID: string }) =>
    backend.rpc("user_voice_state", {
      p_user_id: userID,
      p_provider_voice_id: voiceID,
    }),
  saveSample: async (
    { userID, voiceID, file, type }: {
      userID: string;
      voiceID: string;
      file: Blob;
      type: string;
    },
  ) => {
    const path = voiceSamplePath(userID, voiceID, type);
    await samples.upload(path, new Uint8Array(await file.arrayBuffer()), type);
    await backend.rpc("set_user_voice_sample", {
      p_provider_voice_id: voiceID,
      p_sample_path: path,
    });
  },
  removeSample: (path: string) => samples.remove(path),
}));

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
