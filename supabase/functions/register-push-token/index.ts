import { createClient } from "@supabase/supabase-js";
import { createRegisterPushTokenHandler } from "./handler.mjs";

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
const admin = createClient(supabaseURL, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(createRegisterPushTokenHandler({
  loadUserID: async (accessToken: string) => {
    const authClient = createClient(supabaseURL, anonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await authClient.auth.getUser(accessToken);
    if (error) return null;
    return data.user?.id || null;
  },
  saveToken: async (
    userID: string,
    registration: { token: string; platform: "ios" | "android" | "web" },
  ) => {
    const { data, error } = await admin.rpc("x5_register_push_token", {
      p_user_id: userID,
      p_platform: registration.platform,
      p_token: registration.token,
    });
    if (error || data?.status !== "ok" || !data?.updated_at) {
      throw new Error("push_token_upsert_failed");
    }
    return String(data.updated_at);
  },
  deleteToken: async (
    userID: string,
    registration: { token: string; platform: "ios" | "android" | "web" },
  ) => {
    const { data, error } = await admin.rpc("x5_unregister_push_token", {
      p_user_id: userID,
      p_platform: registration.platform,
      p_token: registration.token,
    });
    if (error || data?.status !== "ok") {
      throw new Error("push_token_delete_failed");
    }
    return {
      deleted: data.deleted === true,
      profileCleared: data.profile_cleared === true,
    };
  },
}));

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
