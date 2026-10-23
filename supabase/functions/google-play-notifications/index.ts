import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { create as jwtCreate, getNumericDate } from "djwt";
import {
  buildGooglePlayReversalRpcArgs,
  canonicalVoidedEventMaterial,
  decodePubSubNotification,
  isCurrentlyEntitledSubscriptionSnapshot,
  mapDeveloperNotification,
  processAuthoritativeVoidedPurchases,
  withSubscriptionSnapshot,
} from "./notification.mjs";

const PACKAGE_NAME = "com.x5marketing.mobile";
const PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ||
  "https://afwznqjpshybmqhlewmy.supabase.co";

type ServiceAccount = {
  client_email: string;
  private_key: string;
  token_uri?: string;
};

type ReversalAction = {
  kind: string;
  purchaseToken: string;
  productId?: string;
  successfulOrderId?: string;
  notificationType?: number;
  voidedQuantity?: number;
  reverseCredits?: boolean;
  refundType?: number;
  voidedTimeMillis?: string;
  snapshotState?: string;
  snapshotExpiry?: string;
};

type SubscriptionEntitlement = {
  credits: number;
  subscriptionType: string;
  profilePlan: string | null;
  verified: boolean;
};

const SUBSCRIPTION_ENTITLEMENTS: Record<string, SubscriptionEntitlement> = {
  x5_lite_monthly_v2: {
    credits: 1000,
    subscriptionType: "lite_monthly",
    profilePlan: "pro",
    verified: false,
  },
  x5_pro_monthly_v2: {
    credits: 2000,
    subscriptionType: "pro_monthly",
    profilePlan: "pro",
    verified: false,
  },
  x5_max_monthly_v2: {
    credits: 5000,
    subscriptionType: "max_monthly",
    profilePlan: "pro",
    verified: false,
  },
  x5_verified_monthly_v2: {
    credits: 0,
    subscriptionType: "verified_monthly",
    profilePlan: null,
    verified: true,
  },
  x5_pro_monthly: {
    credits: 1000,
    subscriptionType: "monthly",
    profilePlan: "pro",
    verified: false,
  },
  x5_pro_yearly: {
    credits: 12000,
    subscriptionType: "yearly",
    profilePlan: "pro",
    verified: false,
  },
  x5_verified_monthly: {
    credits: 0,
    subscriptionType: "verified_monthly",
    profilePlan: null,
    verified: true,
  },
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) return json({ error: "server_unavailable" }, 503);
  const admin = createClient(SUPABASE_URL, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const rawBody = await request.json();
    if (rawBody?.action === "scan_voided_purchases") {
      await verifyScanSecret(request);
      const result = await scanVoidedPurchases(admin, rawBody);
      return json({ ok: true, ...result });
    }

    await verifyPubSubIdentity(request);
    const { messageId, notification } = decodePubSubNotification(rawBody);
    if (notification.packageName !== PACKAGE_NAME) {
      return json({ error: "package_mismatch" }, 400);
    }
    if (notification.testNotification) {
      return new Response(null, { status: 204 });
    }

    const action = mapDeveloperNotification(notification) as
      | ReversalAction
      | null;
    if (!action) return new Response(null, { status: 204 });
    const eventTime = parseEventTime(notification.eventTimeMillis);
    if (action.kind === "voided_authoritative") {
      const eventMillis = Date.parse(eventTime);
      const result = await scanVoidedPurchases(
        admin,
        { start_time_millis: eventMillis - 24 * 60 * 60 * 1000 },
        {
          purchaseToken: action.purchaseToken,
          orderId: action.successfulOrderId || "",
          refundType: action.refundType,
        },
      );
      if (!result.targetProcessed) {
        throw new Error("authoritative_voided_purchase_unavailable");
      }
      return new Response(null, { status: 204 });
    }

    let resolvedAction: ReversalAction = action;
    if (action.kind.startsWith("subscription_")) {
      const accessToken = await googlePlayAccessToken();
      const snapshot = await loadSubscriptionSnapshot(
        action.purchaseToken,
        accessToken,
      );
      resolvedAction = withSubscriptionSnapshot(
        action,
        snapshot,
      ) as ReversalAction;
      if (action.kind === "subscription_snapshot_sync") {
        if (isCurrentlyEntitledSubscriptionSnapshot(resolvedAction)) {
          await applySubscriptionSnapshot(
            admin,
            resolvedAction,
            snapshot,
            accessToken,
          );
        }
        return new Response(null, { status: 204 });
      }
    }
    await applyReversal(admin, `rtdn:${messageId}`, resolvedAction, eventTime);
    return new Response(null, { status: 204 });
  } catch (error) {
    const code = error instanceof Error ? error.message : "unknown_error";
    const clientError = new Set([
      "invalid_pubsub_identity",
      "invalid_pubsub_envelope",
      "invalid_pubsub_payload",
      "invalid_developer_notification",
      "invalid_scan_secret",
      "invalid_event_time",
    ]).has(code);
    console.error("[google-play-notifications] processing failed", code);
    return json(
      { error: clientError ? code : "google_play_notification_retry" },
      clientError ? 401 : 503,
    );
  }
});

async function verifyPubSubIdentity(request: Request): Promise<void> {
  const audience = Deno.env.get("GOOGLE_PLAY_PUBSUB_AUDIENCE");
  const allowedEmail = Deno.env.get("GOOGLE_PLAY_PUBSUB_SERVICE_ACCOUNT_EMAIL");
  const bearer = (request.headers.get("authorization") || "")
    .replace(/^Bearer\s+/i, "").trim();
  if (!audience || !allowedEmail || !bearer) {
    throw new Error("invalid_pubsub_identity");
  }
  const response = await fetch(
    `https://oauth2.googleapis.com/tokeninfo?id_token=${
      encodeURIComponent(bearer)
    }`,
  );
  if (!response.ok) throw new Error("invalid_pubsub_identity");
  const identity = await response.json();
  if (
    identity.aud !== audience ||
    identity.email !== allowedEmail ||
    ![true, "true"].includes(identity.email_verified) ||
    !["accounts.google.com", "https://accounts.google.com"].includes(
      identity.iss,
    )
  ) {
    throw new Error("invalid_pubsub_identity");
  }
}

function verifyScanSecret(request: Request): void {
  const expected = Deno.env.get("GOOGLE_PLAY_VOIDED_SCAN_SECRET") || "";
  const actual = request.headers.get("x-google-play-scan-secret") || "";
  if (!expected || !constantTimeEqual(actual, expected)) {
    throw new Error("invalid_scan_secret");
  }
}

async function applyReversal(
  admin: SupabaseClient,
  eventId: string,
  action: ReversalAction,
  eventTime: string,
): Promise<unknown> {
  const tokenHash = await sha256(action.purchaseToken);
  const rpcArgs = buildGooglePlayReversalRpcArgs(
    action,
    tokenHash,
    eventTime,
  );
  const { data, error } = await admin.rpc("apply_google_play_reversal", {
    p_event_id: eventId,
    ...rpcArgs,
  });
  if (error) throw new Error("google_play_reversal_apply_failed");
  return data;
}

async function applySubscriptionSnapshot(
  admin: SupabaseClient,
  action: ReversalAction,
  snapshot: unknown,
  accessToken: string,
): Promise<void> {
  if (
    !action.productId || !action.successfulOrderId || !action.snapshotExpiry
  ) {
    throw new Error("subscription_snapshot_incomplete");
  }
  const entitlement = SUBSCRIPTION_ENTITLEMENTS[action.productId];
  if (!entitlement) throw new Error("subscription_product_unsupported");
  const tokenHash = await sha256(action.purchaseToken);
  const owner = await resolveSubscriptionOwner(
    admin,
    action.purchaseToken,
    snapshot,
  );
  const claimKey =
    `${action.productId}:${tokenHash}:${action.successfulOrderId}`;
  const { error } = await admin.rpc("apply_android_purchase_entitlement_v2", {
    p_user_id: owner.userId,
    p_claim_key: claimKey,
    p_product_id: action.productId,
    p_purchase_type: "subscription",
    p_purchase_token_hash: tokenHash,
    p_successful_order_id: action.successfulOrderId,
    p_expires_at: action.snapshotExpiry,
    p_quantity: 1,
    p_refundable_quantity: 1,
    p_credits: entitlement.credits,
    p_subscription_type: entitlement.subscriptionType,
    p_profile_plan: entitlement.profilePlan,
    p_verified: entitlement.verified,
  });
  if (error) {
    if (error.message?.includes("owned_by_other")) {
      throw new Error("subscription_owner_conflict");
    }
    throw new Error("subscription_snapshot_apply_failed");
  }
  await closeLinkedSubscription(
    admin,
    owner.userId,
    snapshot,
    tokenHash,
  );
  await acknowledgeSubscriptionIfNeeded(
    action,
    snapshot,
    accessToken,
  );
}

async function closeLinkedSubscription(
  admin: SupabaseClient,
  userId: string,
  snapshot: unknown,
  replacementTokenHash: string,
): Promise<void> {
  const typed = snapshot as {
    linkedPurchaseToken?: unknown;
    startTime?: unknown;
  };
  if (
    typeof typed.linkedPurchaseToken !== "string" ||
    typed.linkedPurchaseToken.length === 0
  ) {
    return;
  }
  const linkedTokenHash = await sha256(typed.linkedPurchaseToken);
  const parsedStart = typeof typed.startTime === "string"
    ? Date.parse(typed.startTime)
    : Number.NaN;
  const effectiveTime = Number.isFinite(parsedStart)
    ? new Date(parsedStart).toISOString()
    : new Date().toISOString();
  const { error } = await admin.rpc("close_android_linked_subscription", {
    p_user_id: userId,
    p_linked_purchase_token_hash: linkedTokenHash,
    p_replacement_purchase_token_hash: replacementTokenHash,
    p_effective_time: effectiveTime,
  });
  if (error) throw new Error("linked_subscription_close_failed");
}

async function resolveSubscriptionOwner(
  admin: SupabaseClient,
  purchaseToken: string,
  snapshot: unknown,
): Promise<{ userId: string }> {
  const typed = snapshot as {
    linkedPurchaseToken?: string;
    externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string };
    outOfAppPurchaseContext?: {
      expiredPurchaseToken?: string;
      expiredExternalAccountIdentifiers?: {
        obfuscatedExternalAccountId?: string;
      };
    };
  };
  const ownerTokens = [
    purchaseToken,
    typed.outOfAppPurchaseContext?.expiredPurchaseToken,
    typed.linkedPurchaseToken,
  ].filter((value): value is string =>
    typeof value === "string" && value.length > 0
  );
  const tokenHashes = await Promise.all([...new Set(ownerTokens)].map(sha256));
  const { data, error } = await admin
    .from("iap_entitlements")
    .select("user_id,app_account_token,purchase_token_hash")
    .eq("platform", "android")
    .in("purchase_token_hash", tokenHashes);
  if (error) throw new Error("subscription_owner_lookup_failed");
  const ledgers = data || [];
  if (ledgers.length === 0) throw new Error("subscription_owner_unavailable");
  const ownerIds = new Set(ledgers.map((ledger) => ledger.user_id));
  const ownerId = ledgers[0]?.user_id;
  if (
    ownerIds.size !== 1 || typeof ownerId !== "string" ||
    ledgers.some((ledger) => ledger.app_account_token !== ownerId)
  ) {
    throw new Error("subscription_owner_conflict");
  }

  const currentBinding = typed.externalAccountIdentifiers
    ?.obfuscatedExternalAccountId;
  const expiredBinding = typed.outOfAppPurchaseContext
    ?.expiredExternalAccountIdentifiers?.obfuscatedExternalAccountId;
  const suppliedBinding = currentBinding || expiredBinding;
  if (suppliedBinding) {
    const secret = Deno.env.get("GOOGLE_PLAY_ACCOUNT_BINDING_SECRET");
    if (!secret) throw new Error("subscription_binding_unavailable");
    const expected = await googlePlayAccountBinding(ownerId, secret);
    if (!constantTimeEqual(suppliedBinding, expected)) {
      throw new Error("subscription_owner_conflict");
    }
  }
  return { userId: ownerId };
}

async function acknowledgeSubscriptionIfNeeded(
  action: ReversalAction,
  snapshot: unknown,
  accessToken: string,
): Promise<void> {
  const acknowledgementState = (snapshot as { acknowledgementState?: string })
    ?.acknowledgementState;
  if (acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED") return;
  if (acknowledgementState !== "ACKNOWLEDGEMENT_STATE_PENDING") {
    throw new Error("subscription_acknowledgement_state_invalid");
  }
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}/purchases/subscriptions/${
      encodeURIComponent(action.productId || "")
    }/tokens/${encodeURIComponent(action.purchaseToken)}:acknowledge`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok && ![409, 410].includes(response.status)) {
    throw new Error("subscription_acknowledgement_failed");
  }
}

async function scanVoidedPurchases(
  admin: SupabaseClient,
  body: { start_time_millis?: unknown },
  target?: { purchaseToken: string; orderId: string; refundType?: number },
): Promise<{
  processed: number;
  skippedNoEntitlement: number;
  targetProcessed?: boolean;
}> {
  const accessToken = await googlePlayAccessToken();
  const parsedStart = Number(body.start_time_millis);
  const earliest = Date.now() - 30 * 24 * 60 * 60 * 1000;
  const startTime = Number.isFinite(parsedStart)
    ? Math.max(parsedStart, earliest)
    : earliest;
  let pageToken = "";
  let processed = 0;
  let skippedNoEntitlement = 0;
  let targetProcessed = false;

  do {
    const query = new URLSearchParams({
      startTime: String(Math.trunc(startTime)),
      maxResults: "1000",
      type: "1",
      includeQuantityBasedPartialRefund: "true",
    });
    if (pageToken) query.set("token", pageToken);
    const url =
      `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}/purchases/voidedpurchases?${query}`;
    const response = await fetch(url, {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) throw new Error("voided_purchases_api_failed");
    const page = await response.json();
    const pageResult = await processAuthoritativeVoidedPurchases(
      page.voidedPurchases || [],
      async (rawAction: unknown) => {
        const action = rawAction as ReversalAction;
        const eventId = await sha256(
          canonicalVoidedEventMaterial(action),
        );
        return await applyReversal(
          admin,
          `voided:${eventId}`,
          action,
          parseEventTime(action.voidedTimeMillis),
        ) as { status?: string } | null;
      },
      target,
    );
    processed += pageResult.processed;
    skippedNoEntitlement += pageResult.skippedNoEntitlement;
    targetProcessed = targetProcessed || Boolean(pageResult.targetProcessed);
    pageToken = page.tokenPagination?.nextPageToken || "";
  } while (pageToken);

  return {
    processed,
    skippedNoEntitlement,
    ...(target ? { targetProcessed } : {}),
  };
}

async function loadSubscriptionSnapshot(
  purchaseToken: string,
  accessToken: string,
): Promise<unknown> {
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}/purchases/subscriptionsv2/tokens/${
      encodeURIComponent(purchaseToken)
    }`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) throw new Error("subscription_snapshot_unavailable");
  return await response.json();
}

function parseEventTime(value: unknown): string {
  const milliseconds = Number(value);
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) {
    throw new Error("invalid_event_time");
  }
  return new Date(milliseconds).toISOString();
}

async function googlePlayAccessToken(): Promise<string> {
  const raw = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("publisher_credentials_unavailable");
  const account = JSON.parse(raw) as ServiceAccount;
  const tokenUri = account.token_uri || "https://oauth2.googleapis.com/token";
  const key = await importRS256(account.private_key);
  const assertion = await jwtCreate(
    { alg: "RS256", typ: "JWT" },
    {
      iss: account.client_email,
      scope: PUBLISHER_SCOPE,
      aud: tokenUri,
      iat: getNumericDate(0),
      exp: getNumericDate(3600),
    },
    key,
  );
  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok || !result.access_token) {
    throw new Error("publisher_token_failed");
  }
  return result.access_token;
}

async function importRS256(pem: string): Promise<CryptoKey> {
  const cleaned = pem.replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "").replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(cleaned), (char) => char.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    bytes.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function googlePlayAccountBinding(
  userId: string,
  secret: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(userId),
  );
  return Array.from(new Uint8Array(signature)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
