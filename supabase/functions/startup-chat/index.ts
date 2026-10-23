import {
  buildStartupChatIdentity,
  normalizeStartupChatRequest,
  StartupChatRequestError,
} from "./contract.mjs";
import {
  createOpenAIStartupChatProvider,
  StartupChatProviderError,
} from "./provider.mjs";

const DEFAULT_MODEL = "gpt-5.6-sol";
const AUTH_TIMEOUT_MS = 6_000;
const RPC_TIMEOUT_MS = 4_000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return safeError("method_not_allowed", 405);
  }

  const authorization = req.headers.get("Authorization") || "";
  if (!authorization.startsWith("Bearer ")) {
    return safeError("not_authenticated", 401);
  }

  const user = await verifyUser(authorization);
  if (!user?.id) {
    return safeError("not_authenticated", 401);
  }

  let normalized;
  let identity;
  try {
    normalized = normalizeStartupChatRequest(await req.json());
    identity = await buildStartupChatIdentity(normalized);
  } catch (error) {
    if (error instanceof StartupChatRequestError) {
      return safeError(error.code, error.status);
    }
    return safeError("invalid_json", 400);
  }

  const openAIKey = (Deno.env.get("OPENAI_API_KEY") || "").trim();
  if (!openAIKey) {
    console.error(JSON.stringify({
      event: "startup_chat_not_configured",
      user_id: user.id,
    }));
    return safeError("assistant_unavailable", 503);
  }

  const model = (
    Deno.env.get("STARTUP_CHAT_MODEL") || DEFAULT_MODEL
  ).trim() || DEFAULT_MODEL;
  const generateReply = createOpenAIStartupChatProvider({
    apiKey: openAIKey,
  });

  const claim = await callUserRPC(
    "claim_startup_chat_request",
    {
      p_request_id: identity.requestID,
      p_request_fingerprint: identity.fingerprint,
    },
    authorization,
  );
  if (!claim) {
    return safeError("assistant_unavailable", 503);
  }
  if (claim.status === "rate_limited") {
    const retryAfter = boundedRetryAfter(claim.retry_after, 3);
    return safeError("rate_limited", 429, retryAfter);
  }
  if (claim.status === "in_progress") {
    const retryAfter = boundedRetryAfter(claim.retry_after, 3);
    return safeError("in_progress", 425, retryAfter);
  }
  if (claim.status === "replay") {
    const replay = typeof claim.reply === "string" ? claim.reply.trim() : "";
    if (!replay || replay.length > 8_000) {
      return safeError("assistant_unavailable", 503);
    }
    return json({
      reply: replay,
      model: "startup-advisor",
      request_id: identity.requestID,
      replayed: true,
    });
  }
  if (claim.status === "not_authenticated") {
    return safeError("not_authenticated", 401);
  }
  if (
    claim.status === "invalid_request" ||
    claim.status === "idempotency_conflict" ||
    claim.status === "replay_expired"
  ) {
    return safeError(String(claim.status), 409);
  }
  if (claim.status !== "claimed") {
    return safeError("assistant_unavailable", 503);
  }
  const rawLeaseToken = claim.lease_token;
  const leaseToken = typeof rawLeaseToken === "string"
    ? rawLeaseToken.trim().toLowerCase()
    : "";
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(leaseToken)
  ) {
    return safeError("assistant_unavailable", 503);
  }

  try {
    const reply = await generateReply({
      messages: normalized.messages,
      model,
      requestID: identity.requestID,
    });

    const completion = await callUserRPC(
      "complete_startup_chat_request",
      {
        p_request_id: identity.requestID,
        p_request_fingerprint: identity.fingerprint,
        p_lease_token: leaseToken,
        p_reply: reply,
      },
      authorization,
    );
    if (
      !completion ||
      completion.status !== "completed" ||
      typeof completion.reply !== "string"
    ) {
      const release = await releaseStartupChatClaim(
        identity,
        leaseToken,
        authorization,
      );
      if (
        release?.status === "completed" &&
        typeof release.reply === "string" &&
        release.reply.trim()
      ) {
        return json({
          reply: release.reply,
          model: "startup-advisor",
          request_id: identity.requestID,
          replayed: true,
        });
      }
      return safeError("assistant_unavailable", 503);
    }

    return json({
      reply: completion.reply,
      model: "startup-advisor",
      request_id: identity.requestID,
      replayed: false,
    });
  } catch (error) {
    await releaseStartupChatClaim(identity, leaseToken, authorization);
    const providerError = error instanceof StartupChatProviderError
      ? error
      : null;
    console.error(JSON.stringify({
      event: "startup_chat_provider_failed",
      user_id: user.id,
      phase: providerError?.phase || "provider",
      status: providerError?.providerStatus || undefined,
      reason: providerError?.reason || "provider_failure",
    }));
    if (providerError?.code === "content_rejected") {
      return safeError("content_rejected", 422);
    }
    return safeError("assistant_unavailable", 503);
  }
});

async function releaseStartupChatClaim(
  identity: { requestID: string; fingerprint: string },
  leaseToken: string,
  authorization: string,
): Promise<Record<string, unknown> | null> {
  return await callUserRPC(
    "release_startup_chat_request",
    {
      p_request_id: identity.requestID,
      p_request_fingerprint: identity.fingerprint,
      p_lease_token: leaseToken,
    },
    authorization,
  );
}

async function verifyUser(
  authorization: string,
): Promise<{ id?: string } | null> {
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseURL || !anonKey) return null;

  try {
    const response = await fetch(`${supabaseURL}/auth/v1/user`, {
      headers: {
        "apikey": anonKey,
        "Authorization": authorization,
      },
      signal: AbortSignal.timeout(AUTH_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    const payload: unknown = await response.json().catch(() => null);
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return null;
    }
    return payload as { id?: string };
  } catch {
    return null;
  }
}

async function callUserRPC(
  name: string,
  parameters: Record<string, unknown>,
  authorization: string,
): Promise<Record<string, unknown> | null> {
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseURL || !anonKey) return null;

  try {
    const response = await fetch(
      `${supabaseURL}/rest/v1/rpc/${encodeURIComponent(name)}`,
      {
        method: "POST",
        headers: {
          "apikey": anonKey,
          "Authorization": authorization,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(parameters),
        signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
      },
    );
    if (!response.ok) return null;
    const payload: unknown = await response.json().catch(() => null);
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return null;
    }
    return payload as Record<string, unknown>;
  } catch {
    return null;
  }
}

function boundedRetryAfter(value: unknown, fallback: number): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(86_400, Math.max(1, Math.ceil(parsed)));
}

function safeError(
  code: string,
  status: number,
  retryAfter?: number,
): Response {
  const message = code === "assistant_unavailable"
    ? "Стартап-помощник временно недоступен. Попробуйте ещё раз."
    : code === "content_rejected"
    ? "Запрос не прошёл автоматическую проверку безопасности. Измените формулировку."
    : code === "rate_limited"
    ? "Слишком много запросов. Попробуйте немного позже."
    : code === "in_progress"
    ? "Ответ ещё формируется. Повторите через несколько секунд."
    : undefined;
  return json(
    {
      error: {
        code,
        ...(message ? { message } : {}),
        ...(retryAfter ? { retry_after: retryAfter } : {}),
      },
    },
    status,
    retryAfter ? { "Retry-After": String(retryAfter) } : {},
  );
}

function json(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}
