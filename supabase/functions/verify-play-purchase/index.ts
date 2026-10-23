import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { create as jwtCreate, getNumericDate } from "djwt";
import {
  ANDROID_PACKAGE_NAME,
  buildGooglePlayClaimKey,
  canRecoverKnownConsumedPurchase,
  createGooglePlayAccountBinding,
  extractInAppEntitlement,
  extractSubscriptionEntitlement,
  finalizeGooglePlayPurchase,
  getGooglePlayPredecessorPurchaseTokens,
  getProductEntitlement,
  isGooglePlayFinalizationRace,
  isGooglePlayPurchaseGone,
  validateGooglePlayAccountBinding,
} from "./entitlements.mjs";
import { assertGooglePlayPackageAccess } from "./publisherAccess.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ||
  "https://afwznqjpshybmqhlewmy.supabase.co";
const ANDROID_PUBLISHER_SCOPE =
  "https://www.googleapis.com/auth/androidpublisher";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

type VerifyBody = {
  action?: "preflight";
  product_id?: string;
  purchase_token?: string;
  package_name?: string;
  purchase_type?: "subscription" | "inapp";
};

type GoogleServiceAccount = {
  client_email: string;
  private_key: string;
  token_uri?: string;
};

type VerifiedPurchase = {
  ok: true;
  expiry: string | null;
  orderId: string;
  quantity?: number;
  refundableQuantity?: number;
};

type PurchaseVerificationFailure = {
  ok: false;
  status: number;
  error: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!serviceKey || !anonKey) {
      return json({ error: "missing_supabase_env" }, 500);
    }

    const accessToken = (req.headers.get("Authorization") || "").replace(
      /^Bearer\s+/i,
      "",
    ).trim();
    if (!accessToken) return json({ error: "missing_token" }, 401);

    const body = await req.json() as VerifyBody;
    const authClient = createClient(SUPABASE_URL, anonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await authClient.auth.getUser(
      accessToken,
    );
    if (userError || !userData.user) {
      return json({ error: "invalid_user" }, 401);
    }

    const bindingSecret = Deno.env.get("GOOGLE_PLAY_ACCOUNT_BINDING_SECRET");
    if (!bindingSecret) {
      return json({ error: "play_account_binding_unavailable" }, 503);
    }
    const userId = userData.user.id;
    const expectedAccountBinding = await createGooglePlayAccountBinding(
      userId,
      bindingSecret,
    );

    if (body.action === "preflight") {
      try {
        const googleAccessToken = await googlePlayAccessToken();
        await assertGooglePlayPackageAccess(
          ANDROID_PACKAGE_NAME,
          googleAccessToken,
        );
        return json({
          ok: true,
          ready: true,
          account_binding: expectedAccountBinding,
        });
      } catch (error) {
        console.error("[verify-play-purchase] readiness failed", error);
        return json({
          ok: false,
          ready: false,
          error: "play_payments_unavailable",
        }, 503);
      }
    }

    const productId = body.product_id?.trim() || "";
    const purchaseToken = body.purchase_token?.trim() || "";
    const packageName = body.package_name?.trim() || ANDROID_PACKAGE_NAME;
    const requestedPurchaseType = body.purchase_type;
    if (!productId || !purchaseToken) {
      return json({ error: "missing_purchase_fields" }, 400);
    }
    if (packageName !== ANDROID_PACKAGE_NAME) {
      return json({ error: "invalid_package" }, 400);
    }

    const entitlement = getProductEntitlement(productId);
    if (!entitlement) return json({ error: "unknown_product" }, 400);
    if (
      requestedPurchaseType &&
      requestedPurchaseType !== entitlement.purchaseType
    ) {
      return json({ error: "purchase_type_mismatch" }, 400);
    }

    const admin = createClient(SUPABASE_URL, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const tokenHash = await sha256(purchaseToken);
    const googleAccessToken = await googlePlayAccessToken();
    let purchase: unknown;
    try {
      purchase = entitlement.purchaseType === "subscription"
        ? await loadGoogleSubscription(
          packageName,
          purchaseToken,
          googleAccessToken,
        )
        : await loadGoogleProduct(
          packageName,
          productId,
          purchaseToken,
          googleAccessToken,
        );
    } catch (error) {
      const recoveredProfile = await recoverKnownConsumedPurchase(admin, {
        error,
        purchaseType: entitlement.purchaseType,
        userId,
        productId,
        tokenHash,
      });
      if (recoveredProfile) {
        return json({
          ok: true,
          store_finalized: true,
          finalization_pending: false,
          entitlement_applied: true,
          product_id: productId,
          entitlement,
          already_claimed: true,
          credits_granted: 0,
          profile: recoveredProfile,
        });
      }
      throw error;
    }
    const verified = (entitlement.purchaseType === "subscription"
      ? extractSubscriptionEntitlement(productId, purchase)
      : extractInAppEntitlement(purchase)) as
        | VerifiedPurchase
        | PurchaseVerificationFailure;
    if (!verified.ok) {
      return json({ error: verified.error }, verified.status);
    }

    let accountBinding = validateGooglePlayAccountBinding({
      purchaseType: entitlement.purchaseType,
      purchase,
      expectedBinding: expectedAccountBinding,
    });
    if (
      !accountBinding.ok &&
      accountBinding.error === "purchase_account_binding_required"
    ) {
      const predecessorTokens = entitlement.purchaseType === "subscription"
        ? getGooglePlayPredecessorPurchaseTokens(purchase)
        : [];
      const allowedTokenHashes = [
        tokenHash,
        ...await Promise.all(predecessorTokens.map((token) =>
          sha256(token)
        )),
      ];
      const ownershipLedgers = await loadGooglePlayOwnershipLedgers(
        admin,
        allowedTokenHashes,
      );
      accountBinding = validateGooglePlayAccountBinding({
        purchaseType: entitlement.purchaseType,
        purchase,
        expectedBinding: expectedAccountBinding,
        userId,
        allowedTokenHashes,
        ownershipLedgers,
      });
    }
    if (!accountBinding.ok) {
      return json({ error: accountBinding.error }, accountBinding.status);
    }

    const expiry = verified.expiry;
    const claimKey = buildGooglePlayClaimKey(
      productId,
      tokenHash,
      verified.orderId,
    );

    const { data: applyResult, error: applyError } = await admin
      .rpc("apply_android_purchase_entitlement_v2", {
        p_user_id: userId,
        p_claim_key: claimKey,
        p_product_id: productId,
        p_purchase_type: entitlement.purchaseType,
        p_purchase_token_hash: tokenHash,
        p_successful_order_id: verified.orderId,
        p_expires_at: expiry || null,
        p_quantity: verified.quantity || 1,
        p_refundable_quantity: verified.refundableQuantity ?? 1,
        p_credits: entitlement.credits,
        p_subscription_type: entitlement.subscriptionType || null,
        p_profile_plan: entitlement.profilePlan || null,
        p_verified: entitlement.verified,
      });
    if (applyError) {
      if (applyError.message?.includes("owned_by_other")) {
        return json({ error: "owned_by_other" }, 409);
      }
      return json({
        error: "entitlement_apply_failed",
      }, 500);
    }

    let responseProfile = applyResult?.profile || null;
    if (
      entitlement.purchaseType === "subscription" &&
      await closeLinkedGoogleSubscription(
        admin,
        userId,
        purchase,
        tokenHash,
      )
    ) {
      const { data: reconciledProfile, error: profileError } = await admin
        .from("profiles")
        .select("*")
        .eq("id", userId)
        .single();
      if (profileError || !reconciledProfile) {
        throw new Error("linked_subscription_profile_failed");
      }
      responseProfile = reconciledProfile;
    }

    let storeFinalized = false;
    try {
      await finalizeGooglePlayPurchase({
        purchaseType: entitlement.purchaseType,
        purchase,
        packageName,
        productId,
        purchaseToken,
        accessToken: googleAccessToken,
      });
      storeFinalized = true;
    } catch (error) {
      if (
        entitlement.purchaseType === "inapp" &&
        isGooglePlayFinalizationRace(error)
      ) {
        try {
          const refreshed = await loadGoogleProduct(
            packageName,
            productId,
            purchaseToken,
            googleAccessToken,
          ) as { consumptionState?: number };
          storeFinalized = refreshed.consumptionState === 1;
        } catch (reloadError) {
          storeFinalized = isGooglePlayPurchaseGone(reloadError);
        }
      }
      if (storeFinalized) {
        return json({
          ok: true,
          store_finalized: true,
          finalization_pending: false,
          entitlement_applied: true,
          product_id: productId,
          entitlement,
          already_claimed: applyResult?.already_claimed === true,
          credits_granted: applyResult?.credits_granted || 0,
          profile: responseProfile,
        });
      }
      console.error(
        "[verify-play-purchase] Google finalization pending",
        error instanceof Error ? error.message : "unknown_error",
      );
      return json({
        ok: true,
        warning: "play_finalization_pending",
        retryable: true,
        store_finalized: false,
        finalization_pending: true,
        entitlement_applied: true,
        already_claimed: applyResult?.already_claimed === true,
        credits_granted: applyResult?.credits_granted || 0,
        profile: responseProfile,
      });
    }

    return json({
      ok: true,
      store_finalized: true,
      finalization_pending: false,
      entitlement_applied: true,
      product_id: productId,
      entitlement,
      already_claimed: applyResult?.already_claimed === true,
      credits_granted: applyResult?.credits_granted || 0,
      profile: responseProfile,
    });
  } catch (error) {
    console.error("[verify-play-purchase] verification failed", error);
    return json({ error: "verify_exception" }, 500);
  }
});

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

async function recoverKnownConsumedPurchase(
  admin: SupabaseClient,
  {
    error,
    purchaseType,
    userId,
    productId,
    tokenHash,
  }: {
    error: unknown;
    purchaseType: string;
    userId: string;
    productId: string;
    tokenHash: string;
  },
): Promise<Record<string, unknown> | null> {
  if (!isGooglePlayPurchaseGone(error) || purchaseType !== "inapp") return null;
  const { data: ledger, error: ledgerError } = await admin
    .from("iap_entitlements")
    .select(
      "user_id,app_account_token,product_id,purchase_type,purchase_token_hash,successful_order_id",
    )
    .eq("platform", "android")
    .eq("user_id", userId)
    .eq("product_id", productId)
    .eq("purchase_token_hash", tokenHash)
    .maybeSingle();
  if (ledgerError) throw new Error("known_purchase_lookup_failed");
  if (
    !canRecoverKnownConsumedPurchase({
      purchaseType,
      googleStatus: (error as { status?: number })?.status,
      ledger,
      userId,
      productId,
      tokenHash,
    })
  ) return null;

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("*")
    .eq("id", userId)
    .single();
  if (profileError || !profile) {
    throw new Error("known_purchase_profile_failed");
  }
  return profile as Record<string, unknown>;
}

async function loadGooglePlayOwnershipLedgers(
  admin: SupabaseClient,
  tokenHashes: string[],
): Promise<Array<Record<string, unknown>>> {
  const uniqueHashes = [...new Set(tokenHashes.filter(Boolean))];
  if (uniqueHashes.length === 0) return [];
  const { data, error } = await admin
    .from("iap_entitlements")
    .select("user_id,app_account_token,purchase_token_hash")
    .eq("platform", "android")
    .in("purchase_token_hash", uniqueHashes);
  if (error) throw new Error("purchase_owner_lookup_failed");
  return (data || []) as Array<Record<string, unknown>>;
}

async function closeLinkedGoogleSubscription(
  admin: SupabaseClient,
  userId: string,
  purchase: unknown,
  replacementTokenHash: string,
): Promise<boolean> {
  const typed = purchase as {
    linkedPurchaseToken?: unknown;
    startTime?: unknown;
  };
  if (
    typeof typed.linkedPurchaseToken !== "string" ||
    typed.linkedPurchaseToken.length === 0
  ) {
    return false;
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
  return true;
}

class GooglePlayApiError extends Error {
  constructor(readonly status: number) {
    super(`google_play_api_failed:${status}`);
  }
}

async function loadGoogleSubscription(
  packageName: string,
  purchaseToken: string,
  accessToken: string,
): Promise<unknown> {
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
      encodeURIComponent(packageName)
    }/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  const text = await response.text();
  if (!response.ok) {
    void text;
    throw new GooglePlayApiError(response.status);
  }
  return JSON.parse(text);
}

async function loadGoogleProduct(
  packageName: string,
  productId: string,
  purchaseToken: string,
  accessToken: string,
): Promise<unknown> {
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
      encodeURIComponent(packageName)
    }/purchases/products/${encodeURIComponent(productId)}/tokens/${
      encodeURIComponent(purchaseToken)
    }`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  const text = await response.text();
  if (!response.ok) {
    void text;
    throw new GooglePlayApiError(response.status);
  }
  return JSON.parse(text);
}

async function googlePlayAccessToken(): Promise<string> {
  const raw = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("missing GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");
  const account = JSON.parse(raw) as GoogleServiceAccount;
  const tokenUri = account.token_uri || "https://oauth2.googleapis.com/token";
  const assertion = await serviceAccountJwt(account, tokenUri);
  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const data = await response.json();
  if (!response.ok || !data.access_token) {
    throw new Error(
      `Google token error ${response.status}: ${JSON.stringify(data)}`,
    );
  }
  return data.access_token as string;
}

async function serviceAccountJwt(
  account: GoogleServiceAccount,
  audience: string,
): Promise<string> {
  const key = await importRS256(account.private_key);
  return await jwtCreate(
    { alg: "RS256", typ: "JWT" },
    {
      iss: account.client_email,
      scope: ANDROID_PUBLISHER_SCOPE,
      aud: audience,
      iat: getNumericDate(0),
      exp: getNumericDate(3600),
    },
    key,
  );
}

async function importRS256(pem: string): Promise<CryptoKey> {
  const cleaned = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(cleaned), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash)).map((b) =>
    b.toString(16).padStart(2, "0")
  ).join("");
}
