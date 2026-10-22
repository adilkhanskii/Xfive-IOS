import { createClient } from "@supabase/supabase-js";
import {
  automaticPendingDecision,
  decisionFromModerationResult,
  MODERATION_MODEL,
} from "./decision.mjs";
import {
  BUNNY_FAILED_STATUSES,
  BUNNY_STATUS_FINISHED,
  bunnyFrameCandidates,
  bunnyVideoIdFromMediaUrl,
  buildPolicyRequest,
  parsePolicyResponse,
  POLICY_MODEL_DEFAULT,
  policyRejectReason,
} from "./policy.mjs";
import {
  bunnyDeleteVideo,
  bunnyEnvFromDeno,
  bunnyGetVideo,
  normalizeBunnyConfig,
  playbackURL,
} from "../_shared/bunny-stream.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ||
  "https://afwznqjpshybmqhlewmy.supabase.co";
const OPENAI_MODERATION_URL = "https://api.openai.com/v1/moderations";
const OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions";
const MAX_SWEEP_JOBS = 5;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ModerateBody {
  item_id?: string;
  action?: ModerationAction;
  moderation_revision?: number;
}

type ModerationAction = "moderate" | "retry";
// The project does not yet check in generated Supabase Database types.
// deno-lint-ignore no-explicit-any
type AdminClient = ReturnType<typeof createClient<any>>;

interface PortfolioItem {
  id: string;
  user_id: string;
  type: string;
  title: string | null;
  description: string | null;
  media_url: string | null;
  thumbnail_url: string | null;
  moderation_status: string;
  moderation_revision: number;
}

interface ModerationDecision {
  status: "approved" | "rejected" | "pending";
  reason: string;
  result: Record<string, unknown>;
  model: string | null;
  error: string | null;
}

interface ClaimedJob {
  status: "claimed";
  job_id: string;
  attempt: number;
  item: PortfolioItem;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!anonKey || !serviceKey) {
    return json({ error: "missing_supabase_env" }, 500);
  }

  const admin = createClient(SUPABASE_URL, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const isSweep = new URL(req.url).searchParams.get("sweep") === "1";
  if (isSweep) {
    const authorized = await hasValidSweepSecret(req);
    if (!authorized) return json({ error: "not_authenticated" }, 401);
    return runSweep(admin);
  }

  const accessToken = bearerToken(req);
  if (!accessToken) return json({ error: "not_authenticated" }, 401);
  const authClient = createClient(SUPABASE_URL, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser(
    accessToken,
  );
  if (userError || !userData.user) {
    return json({ error: "not_authenticated" }, 401);
  }

  let body: ModerateBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const itemId = body.item_id?.trim();
  if (!itemId) return json({ error: "missing_item_id" }, 400);
  const action: ModerationAction = body.action ?? "moderate";
  if (!(["moderate", "retry"] as string[]).includes(action)) {
    return json({ error: "invalid_action" }, 400);
  }
  const revision = body.moderation_revision;
  if (!Number.isSafeInteger(revision) || (revision ?? 0) < 1) {
    return json({ error: "invalid_moderation_revision" }, 400);
  }

  const leaseToken = randomLeaseToken();
  const { data: claimData, error: claimError } = await admin.rpc(
    "x5_claim_portfolio_moderation_job",
    {
      p_item_id: itemId,
      p_moderation_revision: revision,
      p_owner_id: userData.user.id,
      p_lease_token: leaseToken,
    },
  );
  if (claimError) {
    return json({ error: "claim_failed", detail: claimError.message }, 500);
  }
  const claim = claimData as Record<string, unknown> | null;
  if (claim?.status !== "claimed") return claimResponse(claim);

  const result = await processClaim(
    admin,
    claim as unknown as ClaimedJob,
    leaseToken,
  );
  return result.response;
});

async function runSweep(admin: AdminClient): Promise<Response> {
  const outcomes: Record<string, number> = {};
  let processed = 0;

  for (let index = 0; index < MAX_SWEEP_JOBS; index += 1) {
    const leaseToken = randomLeaseToken();
    const { data, error } = await admin.rpc(
      "x5_claim_next_portfolio_moderation_job",
      { p_lease_token: leaseToken },
    );
    if (error) {
      return json({ error: "sweep_claim_failed", detail: error.message }, 500);
    }
    const claim = data as Record<string, unknown> | null;
    if (!claim || claim.status === "empty") break;
    if (claim.status !== "claimed") {
      const status = String(claim.status ?? "unknown");
      outcomes[status] = (outcomes[status] ?? 0) + 1;
      continue;
    }

    const result = await processClaim(
      admin,
      claim as unknown as ClaimedJob,
      leaseToken,
    );
    processed += 1;
    outcomes[result.status] = (outcomes[result.status] ?? 0) + 1;
  }

  const cleanup = await cleanupPrivatePortfolioMedia(admin);
  return json({ ok: true, processed, outcomes, cleanup });
}

async function processClaim(
  admin: AdminClient,
  claim: ClaimedJob,
  leaseToken: string,
): Promise<{ status: string; response: Response }> {
  const decision = await moderateItem(admin, claim.item);
  const { data: completionData, error: completionError } = await admin.rpc(
    "x5_complete_portfolio_moderation_job",
    {
      p_job_id: claim.job_id,
      p_lease_token: leaseToken,
      p_status: decision.status,
      p_reason: decision.reason,
      p_result: decision.result,
      p_model: decision.model,
      p_error: decision.error,
    },
  );
  if (completionError) {
    return {
      status: "completion_failed",
      response: json({
        error: "completion_failed",
        detail: completionError.message,
      }, 500),
    };
  }

  const completion = completionData as Record<string, unknown> | null;
  const completionStatus = String(completion?.status ?? "unknown");
  if (
    !["completed", "retry_scheduled", "exhausted"].includes(
      completionStatus,
    )
  ) {
    return {
      status: completionStatus,
      response: json({ error: completionStatus }, 409),
    };
  }

  let cleanupError: string | null = null;
  if (decision.status === "rejected" && completionStatus === "completed") {
    cleanupError = await removeRejectedPortfolioMedia(admin, claim.item);
  }

  const { data: item } = await admin
    .from("portfolio_items")
    .select("*")
    .eq("id", claim.item.id)
    .eq("moderation_revision", claim.item.moderation_revision)
    .maybeSingle();

  return {
    status: completionStatus,
    response: json({
      ok: true,
      status: decision.status,
      queue_status: completionStatus,
      attempt: claim.attempt,
      retry_after: completion?.retry_after ?? null,
      cleanup_pending: cleanupError != null,
      item: item ?? null,
    }, completionStatus === "retry_scheduled" ? 202 : 200),
  };
}

async function moderateItem(
  admin: AdminClient,
  item: PortfolioItem,
): Promise<ModerationDecision> {
  if (hasInvalidPortfolioMediaURL(item)) {
    return {
      status: "rejected",
      reason: "Недопустимая ссылка на медиа портфолио",
      result: { reason: "portfolio_media_url_invalid" },
      model: null,
      error: null,
    };
  }

  const text = [
    item.title ? `Название: ${item.title}` : "",
    item.description ? `Описание: ${item.description}` : "",
  ].filter(Boolean).join("\n").trim();

  // Картинки на проверку: фото кейса / обложка видео из Supabase Storage +
  // для видео из Bunny — кадры самого ролика (не только обложка, Диас 22.10).
  const imageUrls: string[] = [];
  const storageImage = await signedImageURLFor(admin, item);
  if (storageImage) imageUrls.push(storageImage);

  const bunnyVideoId = bunnyVideoIdFromMediaUrl(item.media_url);
  if (bunnyVideoId) {
    const frames = await bunnyFramesFor(admin, item, bunnyVideoId);
    if ("decision" in frames) return frames.decision;
    imageUrls.push(...frames.urls);
  }

  if (item.type === "video" && imageUrls.length === 0) {
    return automaticPendingDecision({
      code: "video_preview_missing",
      result: { reason: "video_preview_missing" },
      model: null,
      error: "video_preview_missing",
    });
  }
  if (!text && imageUrls.length === 0) {
    return automaticPendingDecision({
      code: "empty_content",
      result: { reason: "empty_content" },
      model: null,
      error: "empty_content",
    });
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    return automaticPendingDecision({
      code: "missing_openai_key",
      result: { reason: "missing_openai_key" },
      model: MODERATION_MODEL,
      error: "missing_openai_key",
    });
  }

  // 1) omni-moderation: текст + каждая картинка/лист кадров отдельно
  // (18+, насилие, самоповреждение на картинках; в тексте ещё ненависть, наркотики и др.).
  const omniInputs: unknown[][] = [];
  if (text) omniInputs.push([{ type: "text", text }]);
  for (const url of imageUrls) {
    omniInputs.push([{ type: "image_url", image_url: { url } }]);
  }
  const omniPayloads: Record<string, unknown>[] = [];
  for (const input of omniInputs) {
    const omni = await callOpenAI(OPENAI_MODERATION_URL, apiKey, {
      model: MODERATION_MODEL,
      input,
    });
    if (!omni.ok) {
      return automaticPendingDecision({
        code: "provider_unavailable",
        result: { openai_status: omni.status, payload: omni.payload },
        model: MODERATION_MODEL,
        error: omni.error,
      });
    }
    omniPayloads.push(omni.payload);
    const decision = decisionFromModerationResult(
      (omni.payload as { results?: unknown[] })?.results?.[0],
      omni.payload,
      MODERATION_MODEL,
    );
    if (decision.status !== "approved") {
      return {
        ...decision,
        result: { omni: omniPayloads, checked_images: imageUrls.length },
      };
    }
  }

  // 2) правила X5: наркотики, оружие, экстремизм, мошенничество — и в тексте, и на картинках.
  const policyModel = Deno.env.get("PORTFOLIO_POLICY_MODEL")?.trim() ||
    POLICY_MODEL_DEFAULT;
  const policy = await callOpenAI(
    OPENAI_CHAT_URL,
    apiKey,
    buildPolicyRequest({ text, imageUrls, model: policyModel }),
  );
  const verdict = policy.ok ? parsePolicyResponse(policy.payload) : { ok: false };
  if (!policy.ok || !verdict.ok) {
    return automaticPendingDecision({
      code: "policy_check_unavailable",
      result: { openai_status: policy.status, omni: omniPayloads },
      model: policyModel,
      error: policy.error || "policy_response_invalid",
    });
  }
  const result = {
    omni: omniPayloads,
    policy: verdict,
    checked_images: imageUrls.length,
  };
  if (!verdict.allowed) {
    return {
      status: "rejected",
      reason: policyRejectReason(verdict.violations),
      result,
      model: policyModel,
      error: null,
    };
  }
  return {
    status: "approved",
    reason: "Проверено автоматически",
    result,
    model: `${MODERATION_MODEL}+${policyModel}`,
    error: null,
  };
}

async function callOpenAI(
  url: string,
  apiKey: string,
  body: unknown,
): Promise<
  { ok: boolean; status: number; payload: Record<string, unknown>; error: string | null }
> {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(40_000),
    });
    const payload = await response.json().catch(() => ({}));
    return {
      ok: response.ok,
      status: response.status,
      payload,
      error: response.ok
        ? null
        : (payload?.error?.message || `OpenAI ${response.status}`),
    };
  } catch (error) {
    return { ok: false, status: 0, payload: {}, error: String(error) };
  }
}

// Видео из Bunny: ролик должен принадлежать автору кейса и докодироваться;
// тогда отдаём подписанные ссылки на реальные кадры (только те, что есть).
async function bunnyFramesFor(
  admin: AdminClient,
  item: PortfolioItem,
  videoId: string,
): Promise<{ urls: string[] } | { decision: ModerationDecision }> {
  const reject = (code: string, reason: string) => ({
    decision: {
      status: "rejected" as const,
      reason,
      result: { reason: code },
      model: null,
      error: null,
    },
  });
  if (item.type !== "video") {
    return reject("bunny_media_on_non_video", "Недопустимая ссылка на медиа портфолио");
  }
  const { data: owner } = await admin.rpc("portfolio_video_owner", {
    p_video_id: videoId,
  });
  if (owner?.status !== "found" || owner?.user_id !== item.user_id) {
    return reject("bunny_video_not_owned", "Недопустимая ссылка на медиа портфолио");
  }
  const config = normalizeBunnyConfig(bunnyEnvFromDeno((n: string) => Deno.env.get(n)), {
    requireApiKey: true,
    requireTokenKey: true,
  });
  if (!config) {
    return {
      decision: automaticPendingDecision({
        code: "bunny_not_configured",
        result: { reason: "bunny_not_configured" },
        model: null,
        error: "bunny_not_configured",
      }),
    };
  }
  const info = await bunnyGetVideo(fetch, config, videoId);
  if (!info.ok) {
    if (info.notFound) return reject("bunny_video_missing", "Видео не найдено");
    return {
      decision: automaticPendingDecision({
        code: "bunny_unavailable",
        result: { reason: "bunny_unavailable" },
        model: null,
        error: "bunny_unavailable",
      }),
    };
  }
  if ((BUNNY_FAILED_STATUSES as readonly number[]).includes(Number(info.video.providerStatus))) {
    return reject("bunny_video_failed", "Видео не удалось обработать");
  }
  if (info.video.providerStatus !== BUNNY_STATUS_FINISHED) {
    // Bunny ещё кодирует — кадров нет; очередь проверит снова (1, 5, 15 мин…).
    return {
      decision: automaticPendingDecision({
        code: "video_processing",
        result: { reason: "video_processing", encode_progress: info.video.encodeProgress },
        model: null,
        error: "video_processing",
      }),
    };
  }
  const expires = Math.floor(Date.now() / 1000) + 900;
  const urls: string[] = [];
  for (const file of bunnyFrameCandidates()) {
    const url = await playbackURL(config, videoId, file, expires);
    const probe = await fetch(url, {
      headers: { Range: "bytes=0-0" },
      signal: AbortSignal.timeout(8_000),
    }).catch(() => null);
    await probe?.body?.cancel().catch(() => {});
    if (probe && (probe.status === 200 || probe.status === 206) &&
      (probe.headers.get("content-type") || "").startsWith("image/")) {
      urls.push(url);
    }
  }
  if (urls.length === 0) {
    return {
      decision: automaticPendingDecision({
        code: "video_frames_missing",
        result: { reason: "video_frames_missing" },
        model: null,
        error: "video_frames_missing",
      }),
    };
  }
  return { urls };
}

async function signedImageURLFor(
  admin: AdminClient,
  item: PortfolioItem,
): Promise<string | null> {
  const candidate = item.thumbnail_url?.trim() ||
    (item.type === "image" ? item.media_url?.trim() : null);
  if (!candidate) return null;
  const path = portfolioObjectPath(candidate, item.user_id);
  if (!path) return null;
  const { data, error } = await admin.storage
    .from("portfolio")
    .createSignedUrl(path, 300);
  if (error || !data?.signedUrl) return null;
  return data.signedUrl;
}

async function removeRejectedPortfolioMedia(
  admin: AdminClient,
  item: PortfolioItem,
): Promise<string | null> {
  // Запрещённое видео не храним: удаляем ролик из Bunny и помечаем в учёте.
  const bunnyVideoId = bunnyVideoIdFromMediaUrl(item.media_url);
  let bunnyError: string | null = null;
  if (bunnyVideoId) {
    const { data: owner } = await admin.rpc("portfolio_video_owner", {
      p_video_id: bunnyVideoId,
    });
    const config = normalizeBunnyConfig(
      bunnyEnvFromDeno((n: string) => Deno.env.get(n)),
    );
    if (owner?.status === "found" && owner?.user_id === item.user_id && config) {
      const deleted = await bunnyDeleteVideo(fetch, config, bunnyVideoId);
      if (deleted) {
        await admin.rpc("portfolio_video_mark_deleted", { p_video_id: bunnyVideoId });
      } else {
        bunnyError = "bunny_delete_failed";
      }
    }
  }
  const resolvedPaths = [bunnyVideoId ? null : item.media_url, item.thumbnail_url]
    .map((value) => value?.trim() || "")
    .filter(Boolean)
    .map((value) => portfolioObjectPath(value, item.user_id));
  if (resolvedPaths.some((value) => value == null)) {
    return "portfolio_media_path_invalid";
  }
  const paths = Array.from(
    new Set(resolvedPaths.filter((value): value is string => value != null)),
  );
  if (paths.length === 0) return bunnyError;
  const { error } = await admin.storage.from("portfolio").remove(paths);
  return error?.message ?? bunnyError;
}

async function cleanupPrivatePortfolioMedia(
  admin: AdminClient,
): Promise<{ removed: number; error?: string }> {
  const { data, error } = await admin.rpc("x5_list_portfolio_cleanup_paths", {
    p_limit: 100,
  });
  if (error) {
    // The cleanup RPC arrives in the immediately following private-storage
    // migration. A retry sweep will self-heal during a staged release.
    return { removed: 0, error: "cleanup_rpc_unavailable" };
  }
  const paths = Array.isArray(data?.paths)
    ? data.paths.filter((value: unknown): value is string =>
      typeof value === "string" && value.length > 0
    )
    : [];
  if (paths.length === 0) return { removed: 0 };
  const result = await admin.storage.from("portfolio").remove(paths);
  if (result.error) return { removed: 0, error: result.error.message };
  return { removed: paths.length };
}

function portfolioObjectPath(
  value: string,
  expectedOwnerId: string,
): string | null {
  const markers = [
    "/storage/v1/object/public/portfolio/",
    "/storage/v1/object/portfolio/",
  ];
  try {
    const parsed = new URL(value);
    if (parsed.origin !== new URL(SUPABASE_URL).origin) return null;
    if (parsed.username || parsed.password || parsed.search || parsed.hash) {
      return null;
    }
    const marker = markers.find((candidate) =>
      parsed.pathname.startsWith(candidate)
    );
    if (!marker) return null;
    const encodedPath = parsed.pathname.slice(marker.length);
    if (!encodedPath) return null;
    const decodedPath = decodeURIComponent(encodedPath);
    if (decodedPath.includes("\\")) return null;
    const segments = decodedPath.split("/");
    if (
      segments.length < 2 ||
      segments[0] !== expectedOwnerId ||
      segments.some((segment) =>
        !segment || segment === "." || segment === ".." ||
        segment.includes("\0")
      )
    ) {
      return null;
    }
    return segments.join("/");
  } catch {
    return null;
  }
}

function hasInvalidPortfolioMediaURL(item: PortfolioItem): boolean {
  // bunny-stream:<id> проверяется отдельно (владелец ролика — bunnyFramesFor).
  const bunnyMedia = item.type === "video" &&
    bunnyVideoIdFromMediaUrl(item.media_url) != null;
  return [bunnyMedia ? "" : item.media_url, item.thumbnail_url]
    .map((value) => value?.trim() || "")
    .filter(Boolean)
    .some((value) => portfolioObjectPath(value, item.user_id) == null);
}

function claimResponse(claim: Record<string, unknown> | null): Response {
  const status = String(claim?.status ?? "claim_failed");
  const retryAfter = Number(claim?.retry_after ?? 0);
  if (["in_progress", "not_due"].includes(status)) {
    const headers = Number.isFinite(retryAfter) && retryAfter > 0
      ? { "Retry-After": String(Math.ceil(retryAfter)) }
      : undefined;
    return json(
      { ok: true, queue_status: status, retry_after: retryAfter },
      202,
      headers,
    );
  }
  if (status === "not_found") return json({ error: status }, 404);
  if (status === "forbidden") return json({ error: status }, 403);
  if (
    ["stale_item", "completed", "already_completed", "exhausted", "superseded"]
      .includes(status)
  ) {
    return json({ error: status }, 409);
  }
  return json({ error: status }, 500);
}

async function hasValidSweepSecret(req: Request): Promise<boolean> {
  const expected =
    Deno.env.get("X5_PORTFOLIO_MODERATION_SWEEP_SECRET")?.trim() || "";
  const supplied =
    req.headers.get("X-X5-Portfolio-Moderation-Secret")?.trim() || "";
  if (expected.length < 32 || supplied.length < 32) return false;
  const encoder = new TextEncoder();
  const [expectedDigest, suppliedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
  ]);
  const left = new Uint8Array(expectedDigest);
  const right = new Uint8Array(suppliedDigest);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function bearerToken(req: Request): string {
  return (req.headers.get("Authorization") || "")
    .replace(/^Bearer\s+/i, "")
    .trim();
}

function randomLeaseToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

function json(
  payload: unknown,
  status = 200,
  extraHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}
