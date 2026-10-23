import {
  aiREST,
  aiStudioCorsHeaders,
  aiStudioError,
  aiStudioJSON,
  requiredAIEnvironment,
  verifyAIStudioUser,
} from "../_shared/ai-studio.mjs";

const supabaseURL = requiredAIEnvironment("SUPABASE_URL");
const anonKey = requiredAIEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredAIEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const uuidPattern = /^[0-9a-f-]{36}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: aiStudioCorsHeaders });
  }
  const user = await verifyAIStudioUser(req, { supabaseURL, anonKey });
  if (!user) return aiStudioError("unauthorized", "Нужен вход в аккаунт.", 401);
  try {
    if (req.method === "GET") {
      const rows = await aiREST({
        supabaseURL,
        serviceRoleKey,
        path:
          `user_ai_presets?select=id,name,tool_id,settings,created_at,updated_at&user_id=eq.${user.id}&order=updated_at.desc`,
      });
      return aiStudioJSON({ presets: rows || [] });
    }
    if (req.method !== "POST") {
      return aiStudioError(
        "method_not_allowed",
        "Метод не поддерживается.",
        405,
      );
    }
    const body = await req.json().catch(() => null);
    const action = String(body?.action || "save");
    if (action === "delete") {
      const id = String(body?.id || "");
      if (!uuidPattern.test(id)) {
        return aiStudioError(
          "invalid_preset_id",
          "Шаблон указан неверно.",
          400,
        );
      }
      await aiREST({
        supabaseURL,
        serviceRoleKey,
        path: `user_ai_presets?id=eq.${id}&user_id=eq.${user.id}`,
        method: "DELETE",
      });
      return aiStudioJSON({ deleted: true });
    }
    const name = String(body?.name || "").trim().replace(/[\r\n]+/g, " ").slice(
      0,
      80,
    );
    const toolID = String(body?.tool_id || "").trim().toLowerCase();
    const settings = body?.settings;
    if (
      !name || !/^[a-z0-9][a-z0-9_-]{1,63}$/.test(toolID) || !settings ||
      typeof settings !== "object" || Array.isArray(settings)
    ) {
      return aiStudioError(
        "invalid_preset",
        "Проверьте название и настройки шаблона.",
        400,
      );
    }
    const rows = await aiREST({
      supabaseURL,
      serviceRoleKey,
      path: "user_ai_presets?on_conflict=user_id,name",
      method: "POST",
      prefer: "resolution=merge-duplicates,return=representation",
      body: {
        user_id: user.id,
        name,
        tool_id: toolID,
        settings,
        updated_at: new Date().toISOString(),
      },
    });
    return aiStudioJSON({ preset: rows?.[0] }, 201);
  } catch {
    return aiStudioError(
      "preset_service_unavailable",
      "Шаблоны временно недоступны.",
      503,
      true,
    );
  }
});
