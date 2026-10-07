import { handleCourseVideoPlayback } from "./handler.mjs";
import {
  bunnyEnvFromDeno,
  corsHeaders,
  makeSupabaseDeps,
  withCors,
} from "../_shared/bunny-stream.mjs";

// verify_jwt = false (config.toml): guests may open free lessons with the anon
// key; user tokens are verified inside the handler via Supabase Auth.
const getEnv = (name: string) => Deno.env.get(name);
const supabase = makeSupabaseDeps(getEnv);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const response = await handleCourseVideoPlayback(request, {
    env: bunnyEnvFromDeno(getEnv),
    anonKey: getEnv("SUPABASE_ANON_KEY") || "",
    now: () => Date.now(),
    verifyUser: supabase.verifyUser,
    rpc: supabase.rpc,
    logger: console,
  });
  return withCors(response);
});
