import { createAIBalanceHandler } from "./handler.mjs";

// Только для оператора (service_role): остаток ElevenLabs числами, без ключей.
const handler = createAIBalanceHandler({
  serviceRoleKey: String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "")
    .trim(),
  supabaseURL: String(Deno.env.get("SUPABASE_URL") || "").trim(),
  env: (name: string) => Deno.env.get(name) || "",
});

Deno.serve(handler);
