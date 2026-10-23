import {
  buildFruitStoryIdentity,
  buildFruitStoryResponsesRequest,
  extractStructuredStory,
  FruitStoryRequestError,
  moderationInput,
  normalizeFruitStoryEdgeRequest,
  normalizeProviderStory,
  shouldHoldFruitStoryOutcome,
} from "./story.mjs";

const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const OPENAI_MODERATIONS_URL = "https://api.openai.com/v1/moderations";
const DEFAULT_MODEL = "gpt-5.6-sol";
const AUTH_TIMEOUT_MS = 6_000;
const RPC_TIMEOUT_MS = 4_000;
const MODERATION_TIMEOUT_MS = 8_000;
const RESPONSES_TIMEOUT_MS = 30_000;
const MAX_MODERATION_RESPONSE_BYTES = 128 * 1024;
const MAX_RESPONSES_RESPONSE_BYTES = 1024 * 1024;
const strictStoryFormat = Object.freeze({
  type: "json_schema",
  strict: true,
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

class FruitStoryProviderError extends Error {
  code: string;
  phase: string;
  providerStatus: number | null;
  reason: string;

  constructor(
    code: string,
    {
      phase = "provider",
      providerStatus = null,
      reason = "provider_failure",
    }: {
      phase?: string;
      providerStatus?: number | null;
      reason?: string;
    } = {},
  ) {
    super(code);
    this.name = "FruitStoryProviderError";
    this.code = code;
    this.phase = phase;
    this.providerStatus = providerStatus;
    this.reason = reason;
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return safeError("method_not_allowed", 405);
  }

  const authorization = request.headers.get("Authorization") || "";
  if (!authorization.startsWith("Bearer ")) {
    return safeError("not_authenticated", 401);
  }
  const user = await verifyUser(authorization);
  if (!user?.id) {
    return safeError("not_authenticated", 401);
  }

  let questionnaire;
  let identity;
  try {
    questionnaire = normalizeFruitStoryEdgeRequest(await request.json());
    identity = await buildFruitStoryIdentity(questionnaire);
  } catch (error) {
    if (error instanceof FruitStoryRequestError) {
      return safeError(error.code, error.status);
    }
    return safeError("invalid_json", 400);
  }

  const openAIKey = (Deno.env.get("OPENAI_API_KEY") || "").trim();
  if (!openAIKey) {
    console.error(JSON.stringify({
      event: "fruit_story_not_configured",
      user_id: user.id,
    }));
    return safeError("story_unavailable", 503);
  }
  const model = (
    Deno.env.get("FRUIT_STORY_MODEL") || DEFAULT_MODEL
  ).trim() || DEFAULT_MODEL;
  const providerIdempotencyKey = `fruit-story-${await sha256Hex(
    `fruit-story\0${user.id}\0${identity.requestID}`,
  )}`;

  const claim = await callUserRPC(
    "claim_fruit_story_request",
    {
      p_request_id: identity.requestID,
      p_request_fingerprint: identity.fingerprint,
    },
    authorization,
  );
  if (!claim) {
    return safeError("story_unavailable", 503);
  }
  if (claim.status === "rate_limited") {
    const retryAfter = boundedRetryAfter(claim.retry_after, 3);
    return safeError("rate_limited", 429, retryAfter);
  }
  if (claim.status === "in_progress") {
    const retryAfter = boundedRetryAfter(claim.retry_after, 3);
    return safeError("in_progress", 425, retryAfter);
  }
  if (claim.status === "ambiguous") {
    return safeError("outcome_unknown", 409, 3);
  }
  if (claim.status === "replay") {
    const replay = safeReplayStory(
      claim.story,
      questionnaire.canonicalHeroFruit,
    );
    if (!replay) {
      return safeError("story_unavailable", 503);
    }
    return json({
      story: replay,
      request_id: identity.requestID,
      replayed: true,
    });
  }
  if (claim.status === "not_authenticated") {
    return safeError("not_authenticated", 401);
  }
  if (
    claim.status === "invalid_request" ||
    claim.status === "idempotency_conflict"
  ) {
    return safeError(String(claim.status), 409);
  }
  if (claim.status !== "claimed") {
    return safeError("story_unavailable", 503);
  }

  const rawLeaseToken = claim.lease_token;
  const leaseToken = typeof rawLeaseToken === "string"
    ? rawLeaseToken.trim().toLowerCase()
    : "";
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(leaseToken)
  ) {
    return safeError("story_unavailable", 503);
  }

  let responsesDispatched = false;
  try {
    const moderation = await safeProviderFetch(
      OPENAI_MODERATIONS_URL,
      {
        method: "POST",
        headers: openAIHeaders(openAIKey),
        body: JSON.stringify({
          model: "omni-moderation-latest",
          input: moderationInput(questionnaire),
        }),
        signal: AbortSignal.timeout(MODERATION_TIMEOUT_MS),
      },
      "moderation",
    );
    const moderationBody = await readProviderJSON(
      moderation,
      MAX_MODERATION_RESPONSE_BYTES,
      "moderation",
    );
    if (!moderation.ok) {
      throw providerUnavailable(
        "moderation",
        moderation.status,
        "http_error",
      );
    }
    const flagged = moderationFlagged(moderationBody);
    if (flagged === null) {
      throw providerUnavailable(
        "moderation",
        moderation.status,
        "invalid_response",
      );
    }
    if (flagged) {
      throw new FruitStoryProviderError("content_rejected", {
        phase: "moderation",
        providerStatus: moderation.status,
        reason: "flagged",
      });
    }

    const providerRequest = buildFruitStoryResponsesRequest(
      questionnaire,
      model,
    );
    providerRequest.text.format = {
      ...providerRequest.text.format,
      ...strictStoryFormat,
    };
    responsesDispatched = true;
    const response = await safeProviderFetch(
      OPENAI_RESPONSES_URL,
      {
        method: "POST",
        headers: {
          ...openAIHeaders(openAIKey),
          "Idempotency-Key": providerIdempotencyKey,
          "X-Client-Request-Id": identity.requestID,
        },
        body: JSON.stringify(providerRequest),
        signal: AbortSignal.timeout(RESPONSES_TIMEOUT_MS),
      },
      "responses",
    );
    const responseBody = await readProviderJSON(
      response,
      MAX_RESPONSES_RESPONSE_BYTES,
      "responses",
    );
    if (!response.ok) {
      throw providerUnavailable(
        "responses",
        response.status,
        "http_error",
      );
    }

    const story = extractStructuredStory(
      responseBody,
      questionnaire.canonicalHeroFruit,
    );
    const completion = await completeFruitStoryClaim(
      identity,
      leaseToken,
      story,
      authorization,
    );
    if (
      !completion ||
      completion.status !== "completed"
    ) {
      const hold = await holdFruitStoryClaim(
        identity,
        leaseToken,
        authorization,
      );
      const replay = hold?.status === "completed"
        ? safeReplayStory(
          hold.story,
          questionnaire.canonicalHeroFruit,
        )
        : null;
      if (replay) {
        return json({
          story: replay,
          request_id: identity.requestID,
          replayed: true,
        });
      }
      return safeError("outcome_unknown", 409);
    }

    const completedStory = safeReplayStory(
      completion.story,
      questionnaire.canonicalHeroFruit,
    );
    if (!completedStory) {
      return safeError("story_unavailable", 503);
    }
    return json({
      story: completedStory,
      request_id: identity.requestID,
      replayed: false,
    });
  } catch (error) {
    const providerError = error instanceof FruitStoryProviderError
      ? error
      : null;
    const ambiguousOutcome = shouldHoldFruitStoryOutcome({
      responsesDispatched,
      isProviderError: providerError !== null,
      providerPhase: providerError?.phase || null,
      providerStatus: providerError?.providerStatus ?? null,
    });
    let claimResult: Record<string, unknown> | null;
    if (ambiguousOutcome) {
      claimResult = await holdFruitStoryClaim(
        identity,
        leaseToken,
        authorization,
      );
    } else {
      claimResult = await releaseFruitStoryClaim(
        identity,
        leaseToken,
        authorization,
      );
    }
    const recoveredStory = claimResult?.status === "completed"
      ? safeReplayStory(
        claimResult.story,
        questionnaire.canonicalHeroFruit,
      )
      : null;
    if (recoveredStory) {
      return json({
        story: recoveredStory,
        request_id: identity.requestID,
        replayed: true,
      });
    }
    console.error(JSON.stringify({
      event: "fruit_story_provider_failed",
      user_id: user.id,
      phase: providerError?.phase || "provider",
      status: providerError?.providerStatus || undefined,
      reason: providerError?.reason ||
        (error instanceof FruitStoryRequestError
          ? error.code
          : "provider_failure"),
    }));
    if (providerError?.code === "content_rejected") {
      return safeError("content_rejected", 422);
    }
    if (ambiguousOutcome) {
      return safeError("outcome_unknown", 409);
    }
    return safeError("story_unavailable", 503);
  }
});

async function completeFruitStoryClaim(
  identity: { requestID: string; fingerprint: string },
  leaseToken: string,
  story: Record<string, unknown>,
  authorization: string,
): Promise<Record<string, unknown> | null> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const completion = await callUserRPC(
      "complete_fruit_story_request",
      {
        p_request_id: identity.requestID,
        p_request_fingerprint: identity.fingerprint,
        p_lease_token: leaseToken,
        p_story: story,
      },
      authorization,
    );
    if (completion) return completion;
    if (attempt < 2) {
      await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
    }
  }
  return null;
}

async function releaseFruitStoryClaim(
  identity: { requestID: string; fingerprint: string },
  leaseToken: string,
  authorization: string,
): Promise<Record<string, unknown> | null> {
  return await callUserRPC(
    "release_fruit_story_request",
    {
      p_request_id: identity.requestID,
      p_request_fingerprint: identity.fingerprint,
      p_lease_token: leaseToken,
    },
    authorization,
  );
}

async function holdFruitStoryClaim(
  identity: { requestID: string; fingerprint: string },
  leaseToken: string,
  authorization: string,
): Promise<Record<string, unknown> | null> {
  return await callUserRPC(
    "hold_fruit_story_request",
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

async function safeProviderFetch(
  url: string,
  init: RequestInit,
  phase: string,
): Promise<Response> {
  try {
    return await fetch(url, init);
  } catch (error) {
    throw providerUnavailable(
      phase,
      null,
      error instanceof DOMException && error.name === "TimeoutError"
        ? "timeout"
        : "network_failure",
    );
  }
}

async function readProviderJSON(
  response: Response,
  maxBytes: number,
  phase: string,
): Promise<unknown> {
  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw providerUnavailable(
      phase,
      response.status,
      "response_too_large",
    );
  }
  if (!response.body) {
    throw providerUnavailable(phase, response.status, "invalid_response");
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => {});
        throw providerUnavailable(
          phase,
          response.status,
          "response_too_large",
        );
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof FruitStoryProviderError) throw error;
    throw providerUnavailable(phase, response.status, "invalid_response");
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
  } catch {
    throw providerUnavailable(phase, response.status, "invalid_response");
  }
}

function moderationFlagged(payload: unknown): boolean | null {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return null;
  }
  const results = (payload as { results?: unknown }).results;
  if (!Array.isArray(results) || results.length !== 1) return null;
  return typeof results[0]?.flagged === "boolean" ? results[0].flagged : null;
}

function safeReplayStory(
  value: unknown,
  canonicalHeroFruit: string,
): Record<string, unknown> | null {
  try {
    return normalizeProviderStory(
      value,
      canonicalHeroFruit,
    ) as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function providerUnavailable(
  phase: string,
  providerStatus: number | null,
  reason: string,
): FruitStoryProviderError {
  return new FruitStoryProviderError("story_unavailable", {
    phase,
    providerStatus: Number.isInteger(providerStatus) &&
        Number(providerStatus) > 0
      ? Number(providerStatus)
      : null,
    reason,
  });
}

function openAIHeaders(key: string): Record<string, string> {
  return {
    "Authorization": `Bearer ${key}`,
    "Content-Type": "application/json",
  };
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
  const message = code === "content_rejected"
    ? "Запрос не прошёл проверку безопасности. Измените описание."
    : code === "story_unavailable"
    ? "Сервис историй временно недоступен. Попробуйте позже."
    : code === "rate_limited"
    ? "Слишком много запросов. Попробуйте немного позже."
    : code === "in_progress"
    ? "История ещё создаётся. Повторите через несколько секунд."
    : code === "outcome_unknown"
    ? "Запрос можно безопасно продолжить тем же идентификатором без повторного списания."
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
