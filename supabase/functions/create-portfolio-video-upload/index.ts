import { handleCreatePortfolioVideoUpload } from "./handler.mjs";
import {
  bunnyEnvFromDeno,
  corsHeaders,
  makeSupabaseDeps,
  withCors,
} from "../_shared/bunny-stream.mjs";

// Видео портфолио → Bunny Stream (TUS). Пользователь проверяется внутри.
const getEnv = (name: string) => Deno.env.get(name);
const supabase = makeSupabaseDeps(getEnv);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const response = await handleCreatePortfolioVideoUpload(request, {
    env: bunnyEnvFromDeno(getEnv),
    now: () => Date.now(),
    verifyUser: supabase.verifyUser,
    rpc: supabase.rpc,
    fetchImpl: fetch,
    logger: console,
  });
  return withCors(response);
});
