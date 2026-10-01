import { handleCourseVideoStatus } from "./handler.mjs";
import {
  bunnyEnvFromDeno,
  corsHeaders,
  makeSupabaseDeps,
  withCors,
} from "../_shared/bunny-stream.mjs";

// verify_jwt = false (config.toml): Bunny webhooks and the pg_cron reconciler
// carry no Supabase JWT. Each caller type is authenticated in the handler.
const getEnv = (name: string) => Deno.env.get(name);
const supabase = makeSupabaseDeps(getEnv);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const response = await handleCourseVideoStatus(request, {
    env: bunnyEnvFromDeno(getEnv),
    now: () => Date.now(),
    verifyUser: supabase.verifyUser,
    rpc: supabase.rpc,
    fetchImpl: fetch,
    logger: console,
  });
  return withCors(response);
});
