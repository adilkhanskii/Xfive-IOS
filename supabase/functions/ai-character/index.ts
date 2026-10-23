// deno-lint-ignore-file no-explicit-any
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
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const voiceIDs = new Set([
  "Russian_BrightHeroine",
  "Russian_AmbitiousWoman",
  "Russian_CrazyQueen",
  "Russian_PessimisticGirl",
  "Russian_ReliableMan",
  "Russian_AttractiveGuy",
  "Russian_Bad-temperedBoy",
  "Russian_HandsomeChildhoodFriend",
]);
type JSONRecord = Record<string, any>;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: aiStudioCorsHeaders });
  }
  const user = await verifyAIStudioUser(req, { supabaseURL, anonKey });
  if (!user) return aiStudioError("unauthorized", "Нужен вход в аккаунт.", 401);

  try {
    if (req.method === "GET") return await listCharacters(req, user.id);
    if (req.method === "POST") return await mutateCharacter(req, user.id);
    return aiStudioError("method_not_allowed", "Метод не поддерживается.", 405);
  } catch (error) {
    console.error(JSON.stringify({
      event: "ai_character_failed",
      reason: String(error instanceof Error ? error.message : "unknown").slice(
        0,
        120,
      ),
    }));
    return aiStudioError(
      "character_service_unavailable",
      "Персонаж временно недоступен. Повторите позже.",
      503,
      true,
    );
  }
});

async function listCharacters(req: Request, userID: string) {
  const requestedID = String(new URL(req.url).searchParams.get("id") || "");
  if (requestedID && !uuidPattern.test(requestedID)) {
    return aiStudioError(
      "invalid_character_id",
      "Персонаж указан неверно.",
      400,
    );
  }
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: [
      "ai_characters?select=*",
      `user_id=eq.${encodeURIComponent(userID)}`,
      ...(requestedID ? [`id=eq.${encodeURIComponent(requestedID)}`] : []),
      "order=updated_at.desc",
    ].join("&"),
  });
  return aiStudioJSON({ characters: Array.isArray(rows) ? rows : [] });
}

async function mutateCharacter(req: Request, userID: string) {
  const body = await req.json().catch(() => null);
  const action = String(body?.action || "create");
  if (action === "create") {
    const record = normalizeCharacterFields(body?.character || body, false);
    const rows = await aiREST({
      supabaseURL,
      serviceRoleKey,
      path: "ai_characters",
      method: "POST",
      prefer: "return=representation",
      body: { ...record, user_id: userID, status: "draft" },
    });
    return aiStudioJSON({ character: rows?.[0] }, 201);
  }

  const characterID = String(body?.character_id || "");
  if (!uuidPattern.test(characterID)) {
    return aiStudioError(
      "invalid_character_id",
      "Персонаж указан неверно.",
      400,
    );
  }
  const current = await ownedCharacter(characterID, userID);
  if (!current) {
    return aiStudioError("character_not_found", "Персонаж не найден.", 404);
  }

  let changes: JSONRecord = {};
  if (action === "update") {
    changes = normalizeCharacterFields(body?.character || body, true);
  } else if (action === "approve_image") {
    const assetID = String(body?.asset_id || "");
    if (!await ownsAsset(assetID, userID, "image")) {
      return aiStudioError("image_not_found", "Изображение не найдено.", 404);
    }
    changes = {
      approved_image_asset_id: assetID,
      approved_voice_asset_id: null,
      status: "image_approved",
    };
  } else if (action === "approve_voice") {
    if (!current.approved_image_asset_id) {
      return aiStudioError(
        "image_not_approved",
        "Сначала подтвердите изображение персонажа.",
        409,
      );
    }
    const assetID = String(body?.asset_id || "");
    const voiceID = String(body?.voice_id || "");
    const language = String(body?.language || "ru").toLowerCase();
    const speed = Number(body?.speed ?? 1);
    if (
      !await ownsAsset(assetID, userID, "audio") ||
      !voiceIDs.has(voiceID) ||
      !["ru", "kk", "en"].includes(language) ||
      !Number.isFinite(speed) || speed < 0.7 || speed > 1.2
    ) {
      return aiStudioError("invalid_voice", "Проверьте выбранный голос.", 400);
    }
    changes = {
      approved_voice_asset_id: assetID,
      voice_id: voiceID,
      voice_language: language,
      voice_speed: Math.round(speed * 10) / 10,
      status: "voice_approved",
    };
  } else {
    return aiStudioError(
      "unsupported_action",
      "Действие не поддерживается.",
      400,
    );
  }

  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: `ai_characters?id=eq.${encodeURIComponent(characterID)}&user_id=eq.${
      encodeURIComponent(userID)
    }`,
    method: "PATCH",
    prefer: "return=representation",
    body: { ...changes, updated_at: new Date().toISOString() },
  });
  return aiStudioJSON({ character: rows?.[0] });
}

function normalizeCharacterFields(
  raw: JSONRecord,
  partial: boolean,
): JSONRecord {
  const kind = String(raw?.character_kind || "human");
  if (!partial && !["human", "creature", "hybrid"].includes(kind)) {
    throw new Error("invalid_character_kind");
  }
  const output: JSONRecord = {};
  const stringFields: Array<[string, number]> = [
    ["name", 80],
    ["gender", 40],
    ["origin", 100],
    ["face_description", 400],
    ["body_description", 400],
    ["skin_description", 300],
    ["hair_description", 300],
    ["outfit_description", 400],
    ["accessories_description", 300],
    ["extra_description", 600],
  ];
  for (const [field, maximum] of stringFields) {
    if (raw?.[field] === undefined && partial) continue;
    const value = String(raw?.[field] || "").trim().replace(/[\r\n]+/g, " ");
    if (field === "name" && !partial && !value) throw new Error("invalid_name");
    output[field] = value ? value.slice(0, maximum) : null;
  }
  if (raw?.character_kind !== undefined || !partial) {
    output.character_kind = kind;
  }
  if (raw?.age !== undefined || !partial) {
    const age = Number(raw?.age ?? 25);
    if (!Number.isInteger(age) || age < 18 || age > 100) {
      throw new Error("invalid_age");
    }
    output.age = age;
  }
  if (raw?.image_model !== undefined || !partial) {
    const model = String(raw?.image_model || "gpt-image-2");
    if (!["gpt-image-2", "gemini-3.1-flash-image"].includes(model)) {
      throw new Error("invalid_image_model");
    }
    output.image_model = model;
  }
  return output;
}

async function ownedCharacter(
  id: string,
  userID: string,
): Promise<JSONRecord | null> {
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: `ai_characters?select=*&id=eq.${encodeURIComponent(id)}&user_id=eq.${
      encodeURIComponent(userID)
    }&limit=1`,
  });
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function ownsAsset(id: string, userID: string, assetType: string) {
  if (!uuidPattern.test(id)) return false;
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: `generated_assets?select=id&id=eq.${
      encodeURIComponent(id)
    }&user_id=eq.${
      encodeURIComponent(userID)
    }&asset_type=eq.${assetType}&status=eq.ready&limit=1`,
  });
  return Array.isArray(rows) && rows.length === 1;
}
