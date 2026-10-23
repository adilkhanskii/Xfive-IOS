export const aiStudioCorsHeaders = Object.freeze({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
});

/**
 * @param {unknown} body
 * @param {number} [status]
 * @param {Record<string, string>} [headers]
 */
export function aiStudioJSON(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...aiStudioCorsHeaders,
      ...headers,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

/** @param {string} code @param {string} message @param {number} [status] @param {boolean} [retryable] */
export function aiStudioError(code, message, status = 400, retryable = false) {
  return aiStudioJSON({ error: { code, message, retryable } }, status);
}

/** @param {string} name */
export function requiredAIEnvironment(name) {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}

/** @param {Request} req @param {{supabaseURL: string, anonKey: string}} configuration */
export async function verifyAIStudioUser(req, { supabaseURL, anonKey }) {
  const authorization = String(req.headers.get("Authorization") || "");
  if (!authorization.startsWith("Bearer ")) return null;
  const response = await fetch(`${supabaseURL}/auth/v1/user`, {
    headers: {
      "Authorization": authorization,
      "apikey": anonKey,
      "Cache-Control": "no-store",
    },
  }).catch(() => null);
  if (!response?.ok) return null;
  const payload = await response.json().catch(() => null);
  const id = String(payload?.id || "");
  return /^[0-9a-f-]{36}$/i.test(id) ? { id, authorization } : null;
}

/** @param {string} serviceRoleKey @param {boolean} [withJSON] */
export function aiServiceHeaders(serviceRoleKey, withJSON = true) {
  return {
    "apikey": serviceRoleKey,
    "Authorization": `Bearer ${serviceRoleKey}`,
    ...(withJSON ? { "Content-Type": "application/json" } : {}),
    "Cache-Control": "no-store",
  };
}

/** @param {{supabaseURL: string, serviceRoleKey: string, name: string, parameters?: unknown}} options */
export async function aiServiceRPC({
  supabaseURL,
  serviceRoleKey,
  name,
  parameters,
}) {
  const response = await fetch(
    `${supabaseURL}/rest/v1/rpc/${encodeURIComponent(name)}`,
    {
      method: "POST",
      headers: aiServiceHeaders(serviceRoleKey),
      body: JSON.stringify(parameters || {}),
    },
  );
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`ai_rpc_${name}_failed_${response.status}`);
  }
  return payload;
}

/** @param {{supabaseURL: string, serviceRoleKey: string, path: string, method?: string, body?: unknown, prefer?: string}} options */
export async function aiREST({
  supabaseURL,
  serviceRoleKey,
  path,
  method = "GET",
  body,
  prefer,
}) {
  const response = await fetch(`${supabaseURL}/rest/v1/${path}`, {
    method,
    headers: {
      ...aiServiceHeaders(serviceRoleKey),
      ...(prefer ? { "Prefer": prefer } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const payload = response.status === 204
    ? null
    : await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`ai_rest_failed_${response.status}`);
  }
  return payload;
}

/** @param {{supabaseURL: string, serviceRoleKey: string, bucket: string, path: string, expiresIn?: number}} options */
export async function signAIStorageObject({
  supabaseURL,
  serviceRoleKey,
  bucket,
  path,
  expiresIn = 900,
}) {
  const response = await fetch(
    `${supabaseURL}/storage/v1/object/sign/${encodeStoragePath(bucket)}/${
      encodeStoragePath(path)
    }`,
    {
      method: "POST",
      headers: aiServiceHeaders(serviceRoleKey),
      body: JSON.stringify({ expiresIn }),
    },
  );
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`ai_storage_sign_failed_${response.status}`);
  }
  const signedPath = String(payload?.signedURL || payload?.signedUrl || "");
  if (!signedPath) throw new Error("ai_storage_sign_missing_url");
  return {
    signedURL: /^https:\/\//i.test(signedPath) ? signedPath : new URL(
      signedPath.startsWith("/storage/v1/")
        ? signedPath
        : `/storage/v1${signedPath.startsWith("/") ? "" : "/"}${signedPath}`,
      supabaseURL,
    ).toString(),
    expiresAt: new Date(Date.now() + expiresIn * 1_000).toISOString(),
  };
}

/** @param {{supabaseURL: string, serviceRoleKey: string, bucket: string, path: string, maximumBytes: number}} options */
export async function downloadAIStorageObject({
  supabaseURL,
  serviceRoleKey,
  bucket,
  path,
  maximumBytes,
}) {
  const response = await fetch(
    `${supabaseURL}/storage/v1/object/authenticated/${
      encodeStoragePath(bucket)
    }/${encodeStoragePath(path)}`,
    {
      headers: aiServiceHeaders(serviceRoleKey, false),
      redirect: "manual",
    },
  );
  if (!response.ok || !response.body) {
    throw new Error(`ai_storage_download_failed_${response.status}`);
  }
  const declared = Number(response.headers.get("Content-Length") || 0);
  if (declared > maximumBytes) throw new Error("ai_storage_object_too_large");
  return await readBoundedBytes(response, maximumBytes);
}

/** @param {{supabaseURL: string, serviceRoleKey: string, bucket: string, path: string, mimeType: string, bytes: Uint8Array, upsert?: boolean}} options */
export async function uploadAIStorageObject({
  supabaseURL,
  serviceRoleKey,
  bucket,
  path,
  mimeType,
  bytes,
  upsert = false,
}) {
  const response = await fetch(
    `${supabaseURL}/storage/v1/object/${encodeStoragePath(bucket)}/${
      encodeStoragePath(path)
    }`,
    {
      method: "POST",
      headers: {
        ...aiServiceHeaders(serviceRoleKey, false),
        "Content-Type": mimeType,
        "cache-control": "3600",
        "x-upsert": String(upsert),
      },
      body: Uint8Array.from(bytes).buffer,
    },
  );
  if (!response.ok && !(upsert && response.status === 409)) {
    throw new Error(`ai_storage_upload_failed_${response.status}`);
  }
}

/** @param {Response} response @param {number} maximumBytes */
export async function readBoundedBytes(response, maximumBytes) {
  const reader = response.body?.getReader?.();
  if (!reader) throw new Error("ai_response_body_missing");
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = Uint8Array.from(value || []);
      total += chunk.byteLength;
      if (total > maximumBytes) {
        await reader.cancel().catch(() => undefined);
        throw new Error("ai_response_too_large");
      }
      chunks.push(chunk);
    }
  } finally {
    reader.releaseLock();
  }
  const output = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

/** @param {unknown} value @param {number} maximumBytes */
export function decodeBoundedBase64(value, maximumBytes) {
  const encoded = String(value || "")
    .trim()
    .replace(/^data:[^;]+;base64,/i, "")
    .replace(/\s+/g, "");
  if (
    !encoded ||
    encoded.length % 4 === 1 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded) ||
    encoded.length > Math.ceil(maximumBytes / 3) * 4 + 4
  ) {
    throw new Error("invalid_base64");
  }
  const binary = atob(encoded);
  if (!binary.length || binary.length > maximumBytes) {
    throw new Error("input_too_large");
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

/** @param {Uint8Array} bytes */
export async function sha256AIBytes(bytes) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(bytes).buffer,
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** @param {unknown} value */
export async function sha256AIText(value) {
  return await sha256AIBytes(new TextEncoder().encode(String(value)));
}

/** @param {unknown} value */
export function encodeStoragePath(value) {
  return String(value || "").split("/").map(encodeURIComponent).join("/");
}
