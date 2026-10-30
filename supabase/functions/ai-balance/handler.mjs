// Остаток платных ИИ-провайдеров для внутреннего мониторинга (оператор, не приложение).
// Пускает только service_role; в ответе только числа — ключи и сырые ответы провайдеров наружу не идут.
// Остаток по API даёт только ElevenLabs; у MiniMax / OpenAI / Gemini / BytePlus такого
// эндпоинта по API-ключу нет — тревогу по ним считают по ai_provider_health.

const ELEVENLABS_SUBSCRIPTION =
  "https://api.elevenlabs.io/v1/user/subscription";

/** @param {unknown} body @param {number} [status] */
export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

/** Сравнение без утечки по времени. @param {string} a @param {string} b */
export function sameSecret(a, b) {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    diff |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return diff === 0;
}

/** @param {string} key @param {typeof fetch} fetchImpl */
export async function elevenLabsBalance(key, fetchImpl) {
  if (!key) return { configured: false };
  const response = await fetchImpl(ELEVENLABS_SUBSCRIPTION, {
    headers: { "xi-api-key": key },
  }).catch(() => null);
  if (!response) return { configured: true, ok: false, error: "network" };
  if (!response.ok) {
    // 401 = у ключа нет права «User: read» — остаток не виден, но это не ошибка оплаты.
    return { configured: true, ok: false, error: `http_${response.status}` };
  }
  const payload = await response.json().catch(() => null);
  const used = Number(payload?.character_count);
  const limit = Number(payload?.character_limit);
  if (!Number.isFinite(used) || !Number.isFinite(limit)) {
    return { configured: true, ok: false, error: "bad_payload" };
  }
  const reset = Number(payload?.next_character_count_reset_unix);
  return {
    configured: true,
    ok: true,
    tier: typeof payload?.tier === "string" ? payload.tier.slice(0, 40) : null,
    used,
    limit,
    left_pct: limit > 0
      ? Math.max(0, Math.round(((limit - used) / limit) * 1000) / 10)
      : null,
    reset_at: Number.isFinite(reset) && reset > 0
      ? new Date(reset * 1000).toISOString()
      : null,
  };
}

/** role из JWT без проверки подписи — только как быстрый фильтр. @param {string} token */
export function jwtRole(token) {
  try {
    const part = token.split(".")[1] || "";
    const text = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
    return String(JSON.parse(text)?.role || "");
  } catch {
    return "";
  }
}

// Ключ в env функции может быть в другом формате, чем legacy service_role из
// `supabase projects api-keys`, поэтому второй путь: role=service_role и Auth
// подтверждает ключ (admin-эндпоинт пускает только service_role).
/** @param {string} token @param {string} serviceRoleKey @param {string} supabaseURL @param {typeof fetch} fetchImpl */
export async function isServiceRole(
  token,
  serviceRoleKey,
  supabaseURL,
  fetchImpl,
) {
  if (!token) return false;
  if (serviceRoleKey && sameSecret(token, serviceRoleKey)) return true;
  if (!supabaseURL || jwtRole(token) !== "service_role") return false;
  const response = await fetchImpl(
    `${supabaseURL}/auth/v1/admin/users?page=1&per_page=1`,
    { headers: { Authorization: `Bearer ${token}`, apikey: token } },
  ).catch(() => null);
  await response?.body?.cancel().catch(() => null);
  return response?.status === 200;
}

/**
 * @param {{ serviceRoleKey: string, supabaseURL?: string, env: (name: string) => string, fetchImpl?: typeof fetch }} deps
 */
export function createAIBalanceHandler(
  { serviceRoleKey, supabaseURL = "", env, fetchImpl = fetch },
) {
  return async (/** @type {Request} */ req) => {
    if (req.method !== "GET" && req.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    const header = String(req.headers.get("Authorization") || "");
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    if (!(await isServiceRole(token, serviceRoleKey, supabaseURL, fetchImpl))) {
      return json({ error: "forbidden" }, 403);
    }
    const configured = (/** @type {string} */ name) =>
      Boolean(String(env(name) || "").trim());
    return json({
      checked_at: new Date().toISOString(),
      elevenlabs: await elevenLabsBalance(
        String(env("ELEVENLABS_API_KEY") || "").trim(),
        fetchImpl,
      ),
      // Для остальных — только «ключ стоит», остатка по API нет.
      configured: {
        minimax: configured("MINIMAX_API_KEY"),
        openai: configured("OPENAI_API_KEY"),
        gemini: configured("GEMINI_API_KEY"),
        byteplus: configured("ARK_API_KEY"),
        fal: configured("FAL_KEY"),
        bunny: configured("BUNNY_STREAM_API_KEY"),
      },
    });
  };
}
