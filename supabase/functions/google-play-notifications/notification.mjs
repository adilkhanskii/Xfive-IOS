export function decodePubSubNotification(body) {
  const message = body?.message;
  if (
    !message || typeof message.messageId !== "string" ||
    typeof message.data !== "string"
  ) {
    throw new Error("invalid_pubsub_envelope");
  }
  let notification;
  try {
    const bytes = Uint8Array.from(
      atob(message.data),
      (char) => char.charCodeAt(0),
    );
    notification = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new Error("invalid_pubsub_payload");
  }
  if (!notification || typeof notification !== "object") {
    throw new Error("invalid_developer_notification");
  }
  return { messageId: message.messageId, notification };
}

export function mapDeveloperNotification(notification) {
  const voided = notification?.voidedPurchaseNotification;
  if (voided?.purchaseToken) {
    return {
      kind: "voided_authoritative",
      purchaseToken: voided.purchaseToken,
      successfulOrderId: voided.orderId,
      refundType: voided.refundType,
    };
  }

  const subscription = notification?.subscriptionNotification;
  if (subscription?.purchaseToken) {
    const mapping = {
      5: ["subscription_on_hold", false],
      10: ["subscription_paused", false],
      12: ["subscription_revoked", true],
      13: ["subscription_expired", false],
    }[subscription.notificationType];
    if (mapping) {
      return {
        kind: mapping[0],
        purchaseToken: subscription.purchaseToken,
        notificationType: subscription.notificationType,
        reverseCredits: mapping[1],
      };
    }
    if (
      POSITIVE_SUBSCRIPTION_NOTIFICATION_TYPES.has(
        subscription.notificationType,
      )
    ) {
      return {
        kind: "subscription_snapshot_sync",
        purchaseToken: subscription.purchaseToken,
        notificationType: subscription.notificationType,
        reverseCredits: false,
      };
    }
    return null;
  }

  const oneTime = notification?.oneTimeProductNotification;
  if (oneTime?.notificationType === 2 && oneTime.purchaseToken) {
    return {
      kind: "one_time_canceled",
      purchaseToken: oneTime.purchaseToken,
      productId: oneTime.sku,
      voidedQuantity: 1,
      reverseCredits: true,
    };
  }

  return null;
}

export function withSuccessfulSubscriptionOrder(action, purchase) {
  return withSubscriptionSnapshot(action, purchase);
}

export function withSubscriptionSnapshot(action, purchase) {
  const lineItems =
    (Array.isArray(purchase?.lineItems) ? purchase.lineItems : []).filter((
      item,
    ) => SUPPORTED_SUBSCRIPTION_PRODUCTS.has(item?.productId));
  const owned = lineItems.filter((item) =>
    typeof item?.latestSuccessfulOrderId === "string" &&
    item.latestSuccessfulOrderId.length > 0 &&
    typeof item?.expiryTime === "string" && item.expiryTime.length > 0
  );
  if (owned.length === 0) {
    throw new Error("subscription_successful_order_unavailable");
  }
  if (owned.length !== 1 || typeof purchase?.subscriptionState !== "string") {
    throw new Error("subscription_snapshot_ambiguous");
  }
  const matching = owned[0];
  return {
    ...action,
    productId: matching.productId,
    successfulOrderId: matching.latestSuccessfulOrderId,
    snapshotState: purchase.subscriptionState,
    snapshotExpiry: matching.expiryTime,
  };
}

export function authoritativeVoidedAction(purchase, expectedRefundType) {
  if (
    typeof purchase?.purchaseToken !== "string" ||
    typeof purchase?.orderId !== "string" ||
    typeof purchase?.voidedTimeMillis !== "string"
  ) {
    throw new Error("authoritative_voided_purchase_invalid");
  }
  const quantity = positiveInteger(purchase.voidedQuantity);
  if (expectedRefundType === 2 && quantity === 0) {
    throw new Error("authoritative_voided_quantity_unavailable");
  }
  if (expectedRefundType === 1 && quantity > 0) {
    throw new Error("authoritative_voided_refund_mismatch");
  }
  return {
    kind: quantity > 0 ? "voided_partial" : "voided_full",
    purchaseToken: purchase.purchaseToken,
    successfulOrderId: purchase.orderId,
    voidedTimeMillis: purchase.voidedTimeMillis,
    voidedQuantity: quantity,
    reverseCredits: true,
  };
}

export function voidedActionMatchesTarget(action, target) {
  if (
    !target ||
    action?.purchaseToken !== target.purchaseToken ||
    action?.successfulOrderId !== target.orderId
  ) {
    return false;
  }
  if (target.refundType === 1) return action.kind === "voided_full";
  if (target.refundType === 2) return action.kind === "voided_partial";
  return false;
}

export function canonicalVoidedEventMaterial(action) {
  if (
    !action?.purchaseToken || !action?.successfulOrderId ||
    !action?.voidedTimeMillis || !Number.isInteger(action?.voidedQuantity)
  ) {
    throw new Error("canonical_voided_event_invalid");
  }
  return `voided:${action.purchaseToken}:${action.successfulOrderId}:${action.voidedTimeMillis}:${action.voidedQuantity}`;
}

export function buildGooglePlayReversalRpcArgs(action, tokenHash, eventTime) {
  return {
    p_event_kind: action.kind,
    p_purchase_token_hash: tokenHash,
    p_successful_order_id: action.successfulOrderId || null,
    p_event_time: eventTime,
    p_voided_quantity: action.voidedQuantity || 0,
    p_reverse_credits: action.reverseCredits,
    p_snapshot_subscription_state: action.snapshotState || null,
    p_snapshot_expiry: action.snapshotExpiry || null,
  };
}

export function isCurrentlyEntitledSubscriptionSnapshot(
  action,
  nowMs = Date.now(),
) {
  const state = action?.snapshotState;
  const expiryMs = Date.parse(action?.snapshotExpiry || "");
  return CURRENTLY_ENTITLED_SUBSCRIPTION_STATES.has(state) &&
    Number.isFinite(expiryMs) && expiryMs > nowMs;
}

export async function processAuthoritativeVoidedPurchases(
  purchases,
  applyPurchase,
  target,
) {
  let processed = 0;
  let skippedNoEntitlement = 0;
  let targetProcessed = false;
  for (const purchase of purchases || []) {
    let action;
    try {
      action = authoritativeVoidedAction(purchase);
    } catch {
      continue;
    }
    const matchesTarget = voidedActionMatchesTarget(action, target);
    const result = await applyPurchase(action);
    if (result?.status === "source_not_found") {
      skippedNoEntitlement += 1;
      continue;
    }
    processed += 1;
    if (matchesTarget) targetProcessed = true;
  }
  return {
    processed,
    skippedNoEntitlement,
    ...(target ? { targetProcessed } : {}),
  };
}

export function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : 0;
}

const POSITIVE_SUBSCRIPTION_NOTIFICATION_TYPES = new Set([
  1, // recovered
  2, // renewed
  3, // canceled but still entitled until paid expiry
  4, // purchased
  6, // grace period
  7, // restarted
  9, // deferred
  17, // item changed
  18, // cancellation scheduled
]);

const CURRENTLY_ENTITLED_SUBSCRIPTION_STATES = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
  "SUBSCRIPTION_STATE_CANCELED",
]);

const SUPPORTED_SUBSCRIPTION_PRODUCTS = new Set([
  "x5_lite_monthly_v2",
  "x5_pro_monthly_v2",
  "x5_max_monthly_v2",
  "x5_verified_monthly_v2",
  "x5_pro_monthly",
  "x5_pro_yearly",
  "x5_verified_monthly",
]);
