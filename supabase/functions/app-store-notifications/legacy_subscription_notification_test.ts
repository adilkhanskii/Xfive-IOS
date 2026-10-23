import {
  InputError,
  validateVerifiedSubscriptionLifecycleNotification,
} from "./validation.ts";
import {
  createHandler,
  type NotificationHandlerDependencies,
} from "./index.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

function assertInputError(
  action: () => unknown,
  code: string,
  status = 400,
): void {
  try {
    action();
  } catch (error) {
    assert(
      error instanceof InputError,
      `expected InputError: ${String(error)}`,
    );
    assertEquals(error.code, code);
    assertEquals(error.status, status);
    return;
  }
  throw new Error(`expected ${code}`);
}

const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const legacyOwner = "9ae99a45-91ac-486a-b7ec-e6614b7bc257";
const now = Date.UTC(2026, 6, 16, 12);
const purchaseDate = Date.UTC(2026, 6, 1);
const signedDate = Date.UTC(2026, 6, 16, 11, 58);
const expiresDate = Date.UTC(2026, 7, 1);
const products = [
  "com.x5studio.app.lite.monthly",
  "com.x5studio.app.pro.monthly",
  "com.x5studio.app.max.monthly",
] as const;

function notification(
  notificationType: "SUBSCRIBED" | "DID_RENEW" | "EXPIRED",
) {
  return {
    notificationType,
    subtype: notificationType === "SUBSCRIBED" ? "INITIAL_BUY" : undefined,
    notificationUUID: "f7de2cdc-d47d-46e7-8c67-6f68b3792bc2",
    version: "2.0",
    signedDate: Date.UTC(2026, 6, 16, 11, 59),
    data: {
      bundleId: "com.x5studio.app",
      environment: "Production",
      signedTransactionInfo: "inner.transaction.signature",
      signedRenewalInfo: "inner.renewal.signature",
    },
  };
}

function transaction(productId: string) {
  return {
    bundleId: "com.x5studio.app",
    environment: "Production",
    productId,
    transactionId: "2000000123456791",
    originalTransactionId: "2000000123456000",
    appAccountToken: userId,
    type: "Auto-Renewable Subscription",
    purchaseDate,
    expiresDate,
    signedDate,
  };
}

function renewal(productId: string) {
  return {
    environment: "Production",
    originalTransactionId: "2000000123456000",
    productId,
    autoRenewProductId: productId,
    appAccountToken: userId,
    autoRenewStatus: 1,
    renewalDate: expiresDate,
    signedDate,
  };
}

Deno.test("signed legacy plan initial buys and renewals preserve the Apple product", () => {
  for (const productId of products) {
    for (const notificationType of ["SUBSCRIBED", "DID_RENEW"] as const) {
      const event = validateVerifiedSubscriptionLifecycleNotification(
        notification(notificationType),
        transaction(productId),
        renewal(productId),
        "Production",
        now,
      );

      assertEquals(String(event.productId), productId);
      assertEquals(event.notificationType, notificationType);
      assertEquals(event.userId, userId);
    }
  }
});

Deno.test("signed legacy plan accepts Apple's explicit subscription quantity one", () => {
  const productId = products[1];
  const event = validateVerifiedSubscriptionLifecycleNotification(
    notification("SUBSCRIBED"),
    { ...transaction(productId), quantity: 1 },
    renewal(productId),
    "Production",
    now,
  );

  assertEquals(String(event.productId), productId);
  assertEquals(event.notificationType, "SUBSCRIBED");

  assertInputError(
    () =>
      validateVerifiedSubscriptionLifecycleNotification(
        notification("SUBSCRIBED"),
        { ...transaction(productId), quantity: 2 },
        renewal(productId),
        "Production",
        now,
      ),
    "invalid_quantity",
  );
});

Deno.test("legacy lifecycle accepts only a pair of absent Apple account tokens", () => {
  const productId = products[1];
  const event = validateVerifiedSubscriptionLifecycleNotification(
    notification("DID_RENEW"),
    { ...transaction(productId), appAccountToken: undefined },
    { ...renewal(productId), appAccountToken: undefined },
    "Production",
    now,
  );
  assertEquals(event.appAccountToken, null);

  for (
    const [transactionToken, renewalToken] of [
      [undefined, userId],
      [userId, undefined],
    ] as const
  ) {
    assertInputError(
      () =>
        validateVerifiedSubscriptionLifecycleNotification(
          notification("DID_RENEW"),
          { ...transaction(productId), appAccountToken: transactionToken },
          { ...renewal(productId), appAccountToken: renewalToken },
          "Production",
          now,
        ),
      "account_token_mismatch",
    );
  }
});

Deno.test("legacy plan webhook grant scope excludes terminal lifecycle events", () => {
  for (const productId of products) {
    assertInputError(
      () =>
        validateVerifiedSubscriptionLifecycleNotification(
          notification("EXPIRED"),
          { ...transaction(productId), expiresDate: Date.UTC(2026, 6, 15) },
          renewal(productId),
          "Production",
          now,
        ),
      "unsupported_notification_type",
      200,
    );
  }
});

Deno.test("legacy plan renewal JWS cannot switch the paid product", () => {
  assertInputError(
    () =>
      validateVerifiedSubscriptionLifecycleNotification(
        notification("DID_RENEW"),
        transaction(products[0]),
        renewal(products[1]),
        "Production",
        now,
      ),
    "unsupported_product",
    200,
  );
});

function unsignedNotification(): string {
  const encoded = btoa(JSON.stringify({ data: { environment: "Production" } }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return `header.${encoded}.signature`;
}

Deno.test("legacy initial buy reaches one exact server apply after all Apple JWS checks", async () => {
  const productId = products[0];
  const calls: string[] = [];
  const dependencies: NotificationHandlerDependencies = {
    now: () => now,
    verifyNotification: () => {
      calls.push("outer");
      return Promise.resolve(notification("SUBSCRIBED"));
    },
    verifyTransaction: () => {
      calls.push("transaction");
      return Promise.resolve(transaction(productId));
    },
    verifyRenewalInfo: () => {
      calls.push("renewal");
      return Promise.resolve(renewal(productId));
    },
    resolveNotificationUser: (event) => Promise.resolve(event.userId),
    applyNotification: () => {
      throw new Error("refund apply must not be used");
    },
    applyOneTimeCharge: () => {
      throw new Error("one-time charge apply must not be used");
    },
    applyLifecycleNotification: (event) => {
      calls.push(`apply:${event.productId}`);
      return Promise.resolve({ status: "applied" });
    },
    logError: () => undefined,
  };
  const handler = createHandler(dependencies);
  const response = await handler(
    new Request("https://example.test", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ signedPayload: unsignedNotification() }),
    }),
  );

  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "applied");
  assertEquals(
    calls.join("|"),
    `outer|transaction|renewal|apply:${productId}`,
  );
});

Deno.test("resolved nil-token legacy renewal uses the exact owner sentinel in the ledger", async () => {
  const productId = products[1];
  let resolverSawNull = false;
  let applied = false;
  const dependencies: NotificationHandlerDependencies = {
    now: () => now,
    verifyNotification: () => Promise.resolve(notification("DID_RENEW")),
    verifyTransaction: () =>
      Promise.resolve({
        ...transaction(productId),
        appAccountToken: undefined,
      }),
    verifyRenewalInfo: () =>
      Promise.resolve({ ...renewal(productId), appAccountToken: undefined }),
    resolveNotificationUser: (event) => {
      resolverSawNull = event.appAccountToken === null;
      return Promise.resolve(legacyOwner);
    },
    applyNotification: () => {
      throw new Error("lifecycle must not apply refund");
    },
    applyOneTimeCharge: () => {
      throw new Error("lifecycle must not apply one-time charge");
    },
    applyLifecycleNotification: (event) => {
      assertEquals(event.userId, legacyOwner);
      assertEquals(event.appAccountToken, legacyOwner);
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
    logError: () => undefined,
  };
  const response = await createHandler(dependencies)(
    new Request("https://example.test", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ signedPayload: unsignedNotification() }),
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(resolverSawNull, true);
  assertEquals(applied, true);
});
