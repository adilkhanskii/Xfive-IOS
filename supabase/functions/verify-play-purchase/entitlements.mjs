export const ANDROID_PACKAGE_NAME = "com.x5marketing.mobile";

const productEntitlements = {
  x5_lite_monthly_v2: {
    productId: "x5_lite_monthly_v2",
    purchaseType: "subscription",
    profilePlan: "pro",
    subscriptionType: "lite_monthly",
    credits: 1000,
    verified: false,
    legacy: false,
  },
  x5_pro_monthly_v2: {
    productId: "x5_pro_monthly_v2",
    purchaseType: "subscription",
    profilePlan: "pro",
    subscriptionType: "pro_monthly",
    credits: 2000,
    verified: false,
    legacy: false,
  },
  x5_max_monthly_v2: {
    productId: "x5_max_monthly_v2",
    purchaseType: "subscription",
    profilePlan: "pro",
    subscriptionType: "max_monthly",
    credits: 5000,
    verified: false,
    legacy: false,
  },
  x5_verified_monthly_v2: {
    productId: "x5_verified_monthly_v2",
    purchaseType: "subscription",
    profilePlan: undefined,
    subscriptionType: "verified_monthly",
    credits: 0,
    verified: true,
    legacy: false,
  },
  x5_pro_monthly: {
    productId: "x5_pro_monthly",
    purchaseType: "subscription",
    profilePlan: "pro",
    subscriptionType: "monthly",
    credits: 1000,
    verified: false,
    legacy: true,
  },
  x5_pro_yearly: {
    productId: "x5_pro_yearly",
    purchaseType: "subscription",
    profilePlan: "pro",
    subscriptionType: "yearly",
    credits: 12000,
    verified: false,
    legacy: true,
  },
  x5_credits_1000_v2: {
    productId: "x5_credits_1000_v2",
    purchaseType: "inapp",
    profilePlan: undefined,
    subscriptionType: undefined,
    credits: 1000,
    verified: false,
    legacy: false,
  },
  x5_credits_2000_v2: {
    productId: "x5_credits_2000_v2",
    purchaseType: "inapp",
    profilePlan: undefined,
    subscriptionType: undefined,
    credits: 2000,
    verified: false,
    legacy: false,
  },
  x5_credits_5000_v2: {
    productId: "x5_credits_5000_v2",
    purchaseType: "inapp",
    profilePlan: undefined,
    subscriptionType: undefined,
    credits: 5000,
    verified: false,
    legacy: false,
  },
  x5_verified_monthly: {
    productId: "x5_verified_monthly",
    purchaseType: "subscription",
    profilePlan: undefined,
    subscriptionType: "verified_monthly",
    credits: 0,
    verified: true,
    legacy: true,
  },
};

export function getProductEntitlement(productId) {
  return productEntitlements[productId];
}

// Google never charges a license tester, yet the purchase still reports
// purchaseState 0 and carries a real order id. Products bought outside the
// standard billing flow expose `purchaseType` (0 Test, 1 Promo, 2 Rewarded) and
// subscriptionsv2 reports the same case as a `testPurchase` object. Minting
// credits for those is free money, so they are refused here exactly like the
// Apple sandbox lockdown refuses TestFlight transactions.
export function validateBillablePurchase(purchase) {
  const isTestProduct = purchase?.purchaseType === 0;
  const isTestSubscription = purchase?.testPurchase != null;
  if (!isTestProduct && !isTestSubscription) return { ok: true };

  return {
    ok: false,
    status: 402,
    error: "play_test_not_billable",
  };
}

export function validateInAppPurchaseState(purchase) {
  const billable = validateBillablePurchase(purchase);
  if (!billable.ok) return billable;

  if (purchase?.purchaseState === 0) return { ok: true };

  const state = purchase?.purchaseState ?? "missing";
  return {
    ok: false,
    status: 402,
    error: `product_not_purchased:${state}`,
  };
}

export function validateSubscriptionPurchaseState(purchase) {
  const billable = validateBillablePurchase(purchase);
  if (!billable.ok) return billable;

  const state = purchase?.subscriptionState ?? "missing";
  const activeStates = new Set([
    "SUBSCRIPTION_STATE_ACTIVE",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    // Google keeps a canceled auto-renewing subscription entitled until the
    // paid line-item expiry; extractSubscriptionEntitlement validates that next.
    "SUBSCRIPTION_STATE_CANCELED",
  ]);
  if (activeStates.has(state)) return { ok: true };

  return {
    ok: false,
    status: 402,
    error: `purchase_not_active:${state}`,
  };
}

export function buildProfileUpdate({
  productId,
  currentProfile = {},
  now,
  expiry,
  skipCreditGrant = false,
}) {
  const entitlement = getProductEntitlement(productId);
  if (!entitlement) throw new Error(`unknown product: ${productId}`);

  if (entitlement.verified) {
    return {
      is_verified: true,
      verified_until: expiry,
    };
  }

  const currentCredits = Number(currentProfile?.credits || 0);
  if (entitlement.purchaseType === "inapp") {
    return {
      credits: currentCredits + (skipCreditGrant ? 0 : entitlement.credits),
    };
  }

  const currentExpiry = Date.parse(currentProfile?.subscription_end_date || "");
  const newExpiry = Date.parse(expiry || "");
  const expiryAdvances = Number.isNaN(currentExpiry) ||
    newExpiry > currentExpiry;
  const creditsToGrant = !skipCreditGrant && expiryAdvances
    ? entitlement.credits
    : 0;

  return {
    plan: entitlement.profilePlan,
    credits: currentCredits + creditsToGrant,
    subscription_type: entitlement.subscriptionType,
    subscription_date: now,
    subscription_end_date: expiry,
  };
}
export function extractSubscriptionEntitlement(
  requestedProductId,
  purchase,
  nowMs = Date.now(),
) {
  const stateValidation = validateSubscriptionPurchaseState(purchase);
  if (!stateValidation.ok) return stateValidation;

  const lineItems = Array.isArray(purchase?.lineItems)
    ? purchase.lineItems
    : [];
  const matching = lineItems.find((item) =>
    item?.productId === requestedProductId
  );
  if (!matching) {
    return { ok: false, status: 400, error: "product_mismatch" };
  }
  if (!matching.latestSuccessfulOrderId) {
    return {
      ok: false,
      status: 402,
      error: "subscription_item_not_owned",
    };
  }
  if (!matching.expiryTime) {
    return { ok: false, status: 402, error: "purchase_not_active" };
  }
  const expiryMs = Date.parse(matching.expiryTime);
  if (!Number.isFinite(expiryMs) || expiryMs <= nowMs) {
    return { ok: false, status: 402, error: "purchase_expired" };
  }

  return {
    ok: true,
    expiry: matching.expiryTime,
    orderId: matching.latestSuccessfulOrderId,
    acknowledgementState: purchase?.acknowledgementState,
  };
}

export function extractInAppEntitlement(purchase) {
  const stateValidation = validateInAppPurchaseState(purchase);
  if (!stateValidation.ok) return stateValidation;
  if (!purchase?.orderId) {
    return { ok: false, status: 402, error: "purchase_order_missing" };
  }
  const quantity = Number.isInteger(purchase.quantity) && purchase.quantity > 0
    ? purchase.quantity
    : 1;
  const refundableQuantity = Number.isInteger(purchase.refundableQuantity)
    ? Math.max(0, Math.min(quantity, purchase.refundableQuantity))
    : quantity;
  return {
    ok: true,
    expiry: null,
    orderId: purchase.orderId,
    quantity,
    refundableQuantity,
    consumptionState: purchase.consumptionState,
  };
}

export function buildGooglePlayClaimKey(
  productId,
  tokenHash,
  successfulOrderId,
) {
  return `${productId}:${tokenHash}:${successfulOrderId}`;
}

/**
 * @param {{
 *   purchaseType: string,
 *   purchase: any,
 *   expectedBinding: string,
 *   userId?: string,
 *   allowedTokenHashes?: string[],
 *   ownershipLedgers?: Array<{
 *     user_id?: string,
 *     app_account_token?: string,
 *     purchase_token_hash?: string
 *   }>
 * }} options
 */
export function validateGooglePlayAccountBinding({
  purchaseType,
  purchase,
  expectedBinding,
  userId,
  allowedTokenHashes = [],
  ownershipLedgers = [],
}) {
  const currentBinding = purchaseType === "subscription"
    ? purchase?.externalAccountIdentifiers?.obfuscatedExternalAccountId
    : purchase?.obfuscatedExternalAccountId;
  if (currentBinding) {
    return secureEqual(currentBinding, expectedBinding) ? { ok: true } : {
      ok: false,
      status: 403,
      error: "purchase_account_mismatch",
    };
  }

  const expiredBinding = purchaseType === "subscription"
    ? purchase?.outOfAppPurchaseContext?.expiredExternalAccountIdentifiers
      ?.obfuscatedExternalAccountId
    : undefined;
  if (expiredBinding) {
    return secureEqual(expiredBinding, expectedBinding) ? { ok: true } : {
      ok: false,
      status: 403,
      error: "purchase_account_mismatch",
    };
  }

  const allowed = new Set(
    allowedTokenHashes.filter((value) =>
      typeof value === "string" && value.length > 0
    ),
  );
  const matchingLedgers = ownershipLedgers.filter((ledger) =>
    allowed.has(ledger?.purchase_token_hash)
  );
  if (userId && matchingLedgers.length > 0) {
    const sameOwner = matchingLedgers.every((ledger) =>
      ledger?.user_id === userId && ledger?.app_account_token === userId
    );
    if (sameOwner) return { ok: true, grandfathered: true };
    return {
      ok: false,
      status: 403,
      error: "purchase_account_mismatch",
    };
  }

  return {
    ok: false,
    status: 409,
    error: "purchase_account_binding_required",
  };
}

export function getGooglePlayPredecessorPurchaseTokens(purchase) {
  const tokens = [
    purchase?.outOfAppPurchaseContext?.expiredPurchaseToken,
    purchase?.linkedPurchaseToken,
  ].filter((value) => typeof value === "string" && value.length > 0);
  return [...new Set(tokens)];
}

export async function createGooglePlayAccountBinding(userId, secret) {
  if (!userId || !secret) {
    throw new Error("missing_google_play_account_binding");
  }
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
  return bytesToHex(new Uint8Array(signature));
}

export async function finalizeGooglePlayPurchase({
  purchaseType,
  purchase,
  packageName,
  productId,
  purchaseToken,
  accessToken,
  fetchImpl = fetch,
}) {
  let action;
  let url;
  if (purchaseType === "inapp") {
    if (purchase?.consumptionState === 1) {
      return { ok: true, action: "already_finalized" };
    }
    if (purchase?.consumptionState !== 0) {
      throw new Error("google_play_finalization_state_invalid");
    }
    action = "consumed";
    url =
      `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
        encodeURIComponent(packageName)
      }/purchases/products/${encodeURIComponent(productId)}/tokens/${
        encodeURIComponent(purchaseToken)
      }:consume`;
  } else {
    const state = purchase?.acknowledgementState;
    if (state === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED") {
      return { ok: true, action: "already_finalized" };
    }
    if (state !== "ACKNOWLEDGEMENT_STATE_PENDING") {
      throw new Error("google_play_finalization_state_invalid");
    }
    action = "acknowledged";
    url =
      `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
        encodeURIComponent(packageName)
      }/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${
        encodeURIComponent(purchaseToken)
      }:acknowledge`;
  }

  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) {
    throw new Error(`google_play_finalization_failed:${response.status}`);
  }
  return { ok: true, action };
}

export function isGooglePlayFinalizationRace(error) {
  return /google_play_finalization_failed:(409|410)\b/.test(
    String(error?.message || error || ""),
  );
}

export function isGooglePlayPurchaseGone(error) {
  return error?.status === 404 || error?.status === 410;
}

export function canRecoverKnownConsumedPurchase({
  purchaseType,
  googleStatus,
  ledger,
  userId,
  productId,
  tokenHash,
}) {
  return purchaseType === "inapp" &&
    (googleStatus === 404 || googleStatus === 410) &&
    ledger?.user_id === userId &&
    ledger?.app_account_token === userId &&
    ledger?.product_id === productId &&
    ledger?.purchase_type === "inapp" &&
    ledger?.purchase_token_hash === tokenHash &&
    typeof ledger?.successful_order_id === "string" &&
    ledger.successful_order_id.length > 0;
}

function secureEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string") return false;
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  if (leftBytes.length !== rightBytes.length) return false;
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

function bytesToHex(bytes) {
  return Array.from(bytes).map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
