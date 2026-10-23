import { handleCreateCourseVideoUpload } from "./handler.mjs";
import {
  bunnyEnvFromDeno,
  corsHeaders,
  makeSupabaseDeps,
  withCors,
} from "../_shared/bunny-stream.mjs";

// Enablement is a runtime switch: public.app_feature_flags
// key 'bunny_course_video_upload' (enforced inside course_video_claim_upload).
const getEnv = (name: string) => Deno.env.get(name);
const supabase = makeSupabaseDeps(getEnv);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  const response = await handleCreateCourseVideoUpload(request, {
    env: bunnyEnvFromDeno(getEnv),
    now: () => Date.now(),
    verifyUser: supabase.verifyUser,
    rpc: supabase.rpc,
    fetchImpl: fetch,
    randomUUID: () => crypto.randomUUID(),
    logger: console,
  });
  return withCors(response);
});
