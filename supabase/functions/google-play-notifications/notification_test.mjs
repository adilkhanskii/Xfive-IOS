import assert from "node:assert/strict";
import test from "node:test";

import {
  authoritativeVoidedAction,
  buildGooglePlayReversalRpcArgs,
  canonicalVoidedEventMaterial,
  decodePubSubNotification,
  mapDeveloperNotification,
  processAuthoritativeVoidedPurchases,
  withSubscriptionSnapshot,
} from "./notification.mjs";

function pubsub(payload, messageId = "message-1") {
  return {
    message: {
      messageId,
      data: Buffer.from(JSON.stringify(payload)).toString("base64"),
    },
  };
}

test("decodes Google PubSub envelope without retaining raw transport data", () => {
  assert.deepEqual(
    decodePubSubNotification(pubsub({
      packageName: "com.x5marketing.mobile",
      eventTimeMillis: "1784246400000",
      voidedPurchaseNotification: {
        purchaseToken: "secret-token",
        orderId: "GPA.1",
        productType: 2,
        refundType: 1,
      },
    })),
    {
      messageId: "message-1",
      notification: {
        packageName: "com.x5marketing.mobile",
        eventTimeMillis: "1784246400000",
        voidedPurchaseNotification: {
          purchaseToken: "secret-token",
          orderId: "GPA.1",
          productType: 2,
          refundType: 1,
        },
      },
    },
  );
});

test("subscription RTDN derives product and successful order only from subscriptionsv2", () => {
  const action = mapDeveloperNotification({
    subscriptionNotification: {
      version: "1.0",
      notificationType: 13,
      purchaseToken: "token",
    },
  });
  assert.deepEqual(action, {
    kind: "subscription_expired",
    purchaseToken: "token",
    notificationType: 13,
    reverseCredits: false,
  });
  assert.deepEqual(
    withSubscriptionSnapshot(action, {
      subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
      lineItems: [
        {
          productId: "x5_pro_monthly_v2",
          latestSuccessfulOrderId: "GPA.current-paid-order",
          expiryTime: "2026-07-31T00:00:00.000Z",
        },
      ],
    }),
    {
      ...action,
      productId: "x5_pro_monthly_v2",
      successfulOrderId: "GPA.current-paid-order",
      snapshotState: "SUBSCRIPTION_STATE_EXPIRED",
      snapshotExpiry: "2026-07-31T00:00:00.000Z",
    },
  );
  assert.throws(
    () => withSubscriptionSnapshot(action, { lineItems: [] }),
    /subscription_successful_order_unavailable/,
  );
});

test("maps positive subscription lifecycle events for exact-order background sync", () => {
  for (const notificationType of [1, 2, 3, 4, 6, 7, 9, 17, 18]) {
    const action = mapDeveloperNotification({
      subscriptionNotification: {
        version: "1.0",
        notificationType,
        purchaseToken: "sub-token",
      },
    });
    assert.equal(action?.kind, "subscription_snapshot_sync");
    assert.equal(action?.notificationType, notificationType);
    assert.equal(action?.purchaseToken, "sub-token");
    assert.equal("productId" in action, false);
  }
});

test("terminal subscription action carries live state and expiry into the RPC", () => {
  const mapped = mapDeveloperNotification({
    subscriptionNotification: {
      version: "1.0",
      notificationType: 12,
      purchaseToken: "sub-token",
    },
  });
  const action = withSubscriptionSnapshot(mapped, {
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    lineItems: [{
      productId: "x5_lite_monthly_v2",
      latestSuccessfulOrderId: "GPA.renewed",
      expiryTime: "2026-09-01T00:00:00.000Z",
    }],
  });
  assert.deepEqual(
    buildGooglePlayReversalRpcArgs(
      action,
      "token-hash",
      "2026-07-01T00:00:00.000Z",
    ),
    {
      p_event_kind: "subscription_revoked",
      p_purchase_token_hash: "token-hash",
      p_successful_order_id: "GPA.renewed",
      p_event_time: "2026-07-01T00:00:00.000Z",
      p_voided_quantity: 0,
      p_reverse_credits: true,
      p_snapshot_subscription_state: "SUBSCRIPTION_STATE_ACTIVE",
      p_snapshot_expiry: "2026-09-01T00:00:00.000Z",
    },
  );
});

test("voided RTDN waits for authoritative quantity and scan identity is canonical", () => {
  assert.deepEqual(
    mapDeveloperNotification({
      packageName: "com.x5marketing.mobile",
      voidedPurchaseNotification: {
        purchaseToken: "token",
        orderId: "GPA.1",
        productType: 1,
        refundType: 1,
      },
    }),
    {
      kind: "voided_authoritative",
      purchaseToken: "token",
      successfulOrderId: "GPA.1",
      refundType: 1,
    },
  );

  const authoritative = authoritativeVoidedAction({
    purchaseToken: "token",
    orderId: "GPA.1",
    voidedTimeMillis: "1784246400000",
    voidedQuantity: 2,
  });
  assert.deepEqual(authoritative, {
    kind: "voided_partial",
    purchaseToken: "token",
    successfulOrderId: "GPA.1",
    voidedTimeMillis: "1784246400000",
    voidedQuantity: 2,
    reverseCredits: true,
  });
  assert.equal(
    canonicalVoidedEventMaterial(authoritative),
    "voided:token:GPA.1:1784246400000:2",
  );
  assert.throws(
    () =>
      authoritativeVoidedAction({
        purchaseToken: "token",
        orderId: "GPA.1",
        voidedTimeMillis: "1784246400000",
        voidedQuantity: 0,
      }, 2),
    /authoritative_voided_quantity_unavailable/,
  );
});

test("maps terminal subscription events and one-time cancellation", () => {
  for (
    const [notificationType, kind, reverseCredits] of [
      [5, "subscription_on_hold", false],
      [10, "subscription_paused", false],
      [12, "subscription_revoked", true],
      [13, "subscription_expired", false],
    ]
  ) {
    const action = mapDeveloperNotification({
      subscriptionNotification: {
        version: "1.0",
        notificationType,
        purchaseToken: "sub-token",
      },
    });
    assert.deepEqual(action, {
      kind,
      purchaseToken: "sub-token",
      notificationType,
      reverseCredits,
    });
  }

  assert.equal(
    mapDeveloperNotification({
      subscriptionNotification: {
        notificationType: 8,
        purchaseToken: "price-only-event",
      },
    }),
    null,
  );
  assert.equal(
    mapDeveloperNotification({
      oneTimeProductNotification: {
        notificationType: 2,
        purchaseToken: "pack-token",
        sku: "x5_credits_1000_v2",
      },
    })?.kind,
    "one_time_canceled",
  );
});

test("authoritative scan skips an unknown ledger and continues to a known refund", async () => {
  const seen = [];
  const result = await processAuthoritativeVoidedPurchases([
    {
      purchaseToken: "unknown",
      orderId: "GPA.unknown",
      voidedTimeMillis: "1784246400000",
    },
    {
      purchaseToken: "known",
      orderId: "GPA.known",
      voidedTimeMillis: "1784246401000",
      voidedQuantity: 2,
    },
  ], (action) => {
    seen.push(action.successfulOrderId);
    return action.successfulOrderId === "GPA.unknown"
      ? { status: "source_not_found" }
      : { status: "applied" };
  });
  assert.deepEqual(seen, ["GPA.unknown", "GPA.known"]);
  assert.deepEqual(result, { processed: 1, skippedNoEntitlement: 1 });
});

test("targeted full refund continues past an earlier partial for the same order", async () => {
  const seen = [];
  const result = await processAuthoritativeVoidedPurchases(
    [
      {
        purchaseToken: "shared-token",
        orderId: "GPA.shared",
        voidedTimeMillis: "1784246400000",
        voidedQuantity: 1,
      },
      {
        purchaseToken: "shared-token",
        orderId: "GPA.shared",
        voidedTimeMillis: "1784246401000",
      },
    ],
    (action) => {
      seen.push(action.kind);
      return { status: "applied" };
    },
    {
      purchaseToken: "shared-token",
      orderId: "GPA.shared",
      refundType: 1,
    },
  );

  assert.deepEqual(seen, ["voided_partial", "voided_full"]);
  assert.deepEqual(result, {
    processed: 2,
    skippedNoEntitlement: 0,
    targetProcessed: true,
  });
});
