import { handleCourseVideoLegacyImport } from "./handler.mjs";
import { bunnyEnvFromDeno, withCors } from "../_shared/bunny-stream.mjs";

// verify_jwt = false (config.toml): вызывает только оператор с
// X-X5-Reconcile-Secret (COURSE_VIDEO_CRON_SECRET), проверка в handler.
// Крона нет намеренно: каждый курс переносится по явной команде.
const getEnv = (name: string) => Deno.env.get(name);
const serviceKey = () => getEnv("SUPABASE_SERVICE_ROLE_KEY") || "";
const supabaseURL = () => (getEnv("SUPABASE_URL") || "").replace(/\/+$/, "");

async function callRPC(name: string, parameters: Record<string, unknown>) {
  try {
    const response = await fetch(`${supabaseURL()}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: serviceKey(),
        Authorization: `Bearer ${serviceKey()}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(parameters),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return null;
    return await response.json().catch(() => null);
  } catch {
    return null;
  }
}

Deno.serve(async (request) => {
  const response = await handleCourseVideoLegacyImport(request, {
    env: { ...bunnyEnvFromDeno(getEnv), SUPABASE_URL: supabaseURL() },
    now: () => Date.now(),
    fetchImpl: fetch,
    rpc: callRPC,
    rpcRows: async (name: string, parameters: Record<string, unknown>) => {
      const rows = await callRPC(name, parameters);
      return Array.isArray(rows) ? rows : null;
    },
    serviceHeaders: () => ({
      apikey: serviceKey(),
      Authorization: `Bearer ${serviceKey()}`,
    }),
  });
  return withCors(response);
});
