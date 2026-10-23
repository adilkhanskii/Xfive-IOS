import {
  aiREST,
  aiStudioCorsHeaders,
  aiStudioError,
  aiStudioJSON,
  decodeBoundedBase64,
  requiredAIEnvironment,
  sha256AIBytes,
  signAIStorageObject,
  uploadAIStorageObject,
  verifyAIStudioUser,
} from "../_shared/ai-studio.mjs";

const supabaseURL = requiredAIEnvironment("SUPABASE_URL");
const anonKey = requiredAIEnvironment("SUPABASE_ANON_KEY");
const serviceRoleKey = requiredAIEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const INPUT_BUCKET = "ai-studio-inputs";
const MAXIMUM_UPLOAD_BYTES = 8 * 1024 * 1024;

type AssetFormat = { type: "image" | "audio" | "video"; extension: string };
const formats: Readonly<Record<string, AssetFormat>> = Object.freeze({
  "image/jpeg": { type: "image", extension: "jpg" },
  "image/png": { type: "image", extension: "png" },
  "image/webp": { type: "image", extension: "webp" },
  "audio/mpeg": { type: "audio", extension: "mp3" },
  "audio/wav": { type: "audio", extension: "wav" },
  "audio/mp4": { type: "audio", extension: "m4a" },
  "video/mp4": { type: "video", extension: "mp4" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: aiStudioCorsHeaders });
  }
  const user = await verifyAIStudioUser(req, { supabaseURL, anonKey });
  if (!user) return aiStudioError("unauthorized", "Нужен вход в аккаунт.", 401);

  try {
    if (req.method === "GET") return await listAssets(req, user.id);
    if (req.method === "POST") return await uploadAsset(req, user.id);
    return aiStudioError("method_not_allowed", "Метод не поддерживается.", 405);
  } catch (error) {
    console.error(JSON.stringify({
      event: "ai_assets_failed",
      reason: String(error instanceof Error ? error.message : "unknown").slice(
        0,
        120,
      ),
    }));
    return aiStudioError(
      "asset_service_unavailable",
      "Галерея временно недоступна. Повторите позже.",
      503,
      true,
    );
  }
});

async function listAssets(req: Request, userID: string) {
  const url = new URL(req.url);
  const requestedType = String(url.searchParams.get("asset_type") || "");
  const type = ["image", "audio", "video"].includes(requestedType)
    ? requestedType
    : "";
  const rawLimit = Number(url.searchParams.get("limit") || 40);
  const limit = Math.max(
    1,
    Math.min(80, Number.isInteger(rawLimit) ? rawLimit : 40),
  );
  const filters = [
    "select=id,asset_type,status,bucket_id,object_path,mime_type,source_kind,source_id,category,title,provider,model,width,height,duration_seconds,metadata,created_at,updated_at",
    `user_id=eq.${encodeURIComponent(userID)}`,
    "status=eq.ready",
    ...(type ? [`asset_type=eq.${type}`] : []),
    "order=created_at.desc",
    `limit=${limit}`,
  ].join("&");
  const rows = await aiREST({
    supabaseURL,
    serviceRoleKey,
    path: `generated_assets?${filters}`,
  });
  const assets = await Promise.all((Array.isArray(rows) ? rows : []).map(
    async (row) => {
      const signed = await signAIStorageObject({
        supabaseURL,
        serviceRoleKey,
        bucket: row.bucket_id,
        path: row.object_path,
      });
      const { bucket_id: _bucket, object_path: _path, ...publicRow } = row;
      return {
        ...publicRow,
        url: signed.signedURL,
        url_expires_at: signed.expiresAt,
      };
    },
  ));
  return aiStudioJSON({ assets });
}

async function uploadAsset(req: Request, userID: string) {
  const body = await req.json().catch(() => null);
  const mimeType = String(body?.mime_type || "").trim().toLowerCase();
  const format = formats[mimeType];
  if (!format) {
    return aiStudioError(
      "unsupported_media",
      "Этот формат не поддерживается.",
      400,
    );
  }
  const declaredType = String(body?.asset_type || format.type);
  if (declaredType !== format.type) {
    return aiStudioError(
      "media_type_mismatch",
      "Тип файла указан неверно.",
      400,
    );
  }
  let bytes;
  try {
    bytes = decodeBoundedBase64(body?.data_base64, MAXIMUM_UPLOAD_BYTES);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "invalid_base64";
    return aiStudioError(
      reason === "input_too_large" ? "media_too_large" : "invalid_media",
      "Не удалось прочитать файл. Максимальный размер — 8 МБ.",
      reason === "input_too_large" ? 413 : 400,
    );
  }
  if (!matchesFormat(mimeType, bytes)) {
    return aiStudioError(
      "media_format_mismatch",
      "Формат файла не совпадает.",
      400,
    );
  }

  const assetID = crypto.randomUUID();
  const objectPath = `${userID}/${assetID}/source.${format.extension}`;
  await uploadAIStorageObject({
    supabaseURL,
    serviceRoleKey,
    bucket: INPUT_BUCKET,
    path: objectPath,
    mimeType,
    bytes,
  });
  const title = String(body?.title || "Загруженный файл")
    .trim().replace(/[\r\n]+/g, " ").slice(0, 120) || "Загруженный файл";
  const sha256 = await sha256AIBytes(bytes);
  let rows;
  try {
    rows = await aiREST({
      supabaseURL,
      serviceRoleKey,
      path: "generated_assets",
      method: "POST",
      prefer: "return=representation",
      body: {
        id: assetID,
        user_id: userID,
        asset_type: format.type,
        status: "ready",
        bucket_id: INPUT_BUCKET,
        object_path: objectPath,
        mime_type: mimeType,
        source_kind: "user_upload",
        title,
        metadata: { sha256, original_size_bytes: bytes.byteLength },
      },
    });
  } catch (error) {
    await fetch(
      `${supabaseURL}/storage/v1/object/${INPUT_BUCKET}/${
        objectPath.split("/").map(encodeURIComponent).join("/")
      }`,
      {
        method: "DELETE",
        headers: {
          "apikey": serviceRoleKey,
          "Authorization": `Bearer ${serviceRoleKey}`,
        },
      },
    ).catch(() => null);
    throw error;
  }
  const row = Array.isArray(rows) ? rows[0] : null;
  const signed = await signAIStorageObject({
    supabaseURL,
    serviceRoleKey,
    bucket: INPUT_BUCKET,
    path: objectPath,
  });
  return aiStudioJSON({
    asset: {
      id: row?.id || assetID,
      asset_type: format.type,
      mime_type: mimeType,
      title,
      url: signed.signedURL,
      url_expires_at: signed.expiresAt,
      created_at: row?.created_at || new Date().toISOString(),
    },
  }, 201);
}

function matchesFormat(mimeType: string, bytes: Uint8Array) {
  const ascii = (start: number, end: number) =>
    String.fromCharCode(...bytes.slice(start, end));
  if (mimeType === "image/jpeg") {
    return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  }
  if (mimeType === "image/png") {
    return bytes[0] === 0x89 && ascii(1, 4) === "PNG";
  }
  if (mimeType === "image/webp") {
    return ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP";
  }
  if (mimeType === "audio/mpeg") {
    return ascii(0, 3) === "ID3" ||
      (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0);
  }
  if (mimeType === "audio/wav") {
    return ascii(0, 4) === "RIFF" && ascii(8, 12) === "WAVE";
  }
  if (mimeType === "audio/mp4" || mimeType === "video/mp4") {
    return ascii(4, 8) === "ftyp";
  }
  return false;
}
