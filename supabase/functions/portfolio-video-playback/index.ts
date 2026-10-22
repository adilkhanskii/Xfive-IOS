import { handlePortfolioVideoPlayback } from "./handler.mjs";
import {
  bunnyEnvFromDeno,
  corsHeaders,
  makeSupabaseDeps,
  withCors,
} from "../_shared/bunny-stream.mjs";

// verify_jwt = false (config.toml): гости смотрят одобренные кейсы с anon-ключом;
// токен пользователя проверяется внутри.
const getEnv = (name: string) => Deno.env.get(name);
const supabase = makeSupabaseDeps(getEnv);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const response = await handlePortfolioVideoPlayback(request, {
    env: bunnyEnvFromDeno(getEnv),
    anonKey: getEnv("SUPABASE_ANON_KEY") || "",
    now: () => Date.now(),
    verifyUser: supabase.verifyUser,
    rpc: supabase.rpc,
    fetchImpl: fetch,
    logger: console,
  });
  return withCors(response);
});
