import {
  InputError,
  validateVerifiedRefundNotification,
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
const legacyToken = "b6580000-0000-4000-8000-000000000001";
const now = Date.UTC(2026, 6, 21, 1);
const purchaseDate = Date.UTC(2026, 6, 1);
const expiresDate = Date.UTC(2026, 7, 1);
const transactionSignedDate = Date.UTC(2026, 6, 21, 0, 58);
const revocationDate = Date.UTC(2026, 6, 20);
const notificationSignedDate = Date.UTC(2026, 6, 21, 0, 59);
const products = [
  "com.x5studio.app.lite.monthly",
  "com.x5studio.app.pro.monthly",
  "com.x5studio.app.max.monthly",
] as const;

function notification(
  notificationType: "REFUND" | "REFUND_REVERSED",
  environment: "Production" | "Sandbox" = "Production",
) {
  return {
    notificationType,
    notificationUUID: "d7210000-0000-4000-8000-000000000001",
    version: "2.0",
    signedDate: notificationSignedDate,
    data: {
      bundleId: "com.x5studio.app",
      environment,
      signedTransactionInfo: "inner.transaction.signature",
    },
  };
}

function transaction(
  productId: string,
  notificationType: "REFUND" | "REFUND_REVERSED",
  appAccountToken = userId,
  environment: "Production" | "Sandbox" = "Production",
) {
  return {
    bundleId: "com.x5studio.app",
    environment,
    productId,
    transactionId: "2000000123456793",
    originalTransactionId: "2000000123456000",
    appAccountToken,
    type: "Auto-Renewable Subscription",
    quantity: 1,
    purchaseDate,
    expiresDate,
    signedDate: transactionSignedDate,
    revocationDate: notificationType === "REFUND" ? revocationDate : undefined,
    revocationType: notificationType === "REFUND"
      ? "REFUND_PRORATED"
      : undefined,
    revocationPercentage: notificationType === "REFUND" ? 40000 : undefined,
  };
}

Deno.test("Production legacy paid-plan refund and reversal preserve explicit Apple quantity one", () => {
  for (const productId of products) {
    for (const notificationType of ["REFUND", "REFUND_REVERSED"] as const) {
      const event = validateVerifiedRefundNotification(
        notification(notificationType),
        transaction(productId, notificationType),
        "Production",
        now,
      );

      assertEquals(event.productKind, "legacy_subscription");
      assertEquals(event.productId, productId);
      assertEquals(event.environment, "Production");
      assertEquals(event.quantity, 1);
      assertEquals(event.expiresDate, "2026-08-01T00:00:00.000Z");
      assertEquals(
        event.revocationPercentage,
        notificationType === "REFUND" ? 40000 : null,
      );
    }
  }
});

Deno.test("legacy paid-plan refund normalizes Apple's omitted or explicit quantity one", () => {
  for (const quantity of [undefined, null, 1]) {
    const event = validateVerifiedRefundNotification(
      notification("REFUND"),
      { ...transaction(products[0], "REFUND"), quantity },
      "Production",
      now,
    );
    assertEquals(event.quantity, 1);
  }

  for (const quantity of [0, 2]) {
    assertInputError(
      () =>
        validateVerifiedRefundNotification(
          notification("REFUND"),
          { ...transaction(products[0], "REFUND"), quantity },
          "Production",
          now,
        ),
      "invalid_quantity",
    );
  }
});

Deno.test("legacy paid-plan refund preserves Apple's missing account token for exact server resolution", () => {
  const event = validateVerifiedRefundNotification(
    notification("REFUND"),
    {
      ...transaction(products[1], "REFUND"),
      appAccountToken: undefined,
    },
    "Production",
    now,
  );
  assertEquals(event.appAccountToken, null);

  assertInputError(
    () =>
      validateVerifiedRefundNotification(
        notification("REFUND"),
        {
          ...transaction("com.x5studio.app.verified.monthly", "REFUND"),
          appAccountToken: undefined,
        },
        "Production",
        now,
      ),
    "missing_account_token",
  );
});

Deno.test("legacy paid-plan refund is never accepted from Sandbox", () => {
  assertInputError(
    () =>
      validateVerifiedRefundNotification(
        notification("REFUND", "Sandbox"),
        transaction(products[0], "REFUND", userId, "Sandbox"),
        "Sandbox",
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

Deno.test("legacy paid-plan refund resolves its exact signed owner and reaches one apply", async () => {
  const calls: string[] = [];
  const dependencies: NotificationHandlerDependencies = {
    now: () => now,
    verifyNotification: () => {
      calls.push("outer");
      return Promise.resolve(notification("REFUND"));
    },
    verifyTransaction: () => {
      calls.push("transaction");
      return Promise.resolve(transaction(products[1], "REFUND", legacyToken));
    },
    verifyRenewalInfo: () => {
      throw new Error("refund must not verify renewal info");
    },
    resolveNotificationUser: (event) => {
      calls.push(
        `resolve:${event.originalTransactionId}:${event.appAccountToken}`,
      );
      return Promise.resolve(legacyOwner);
    },
    applyNotification: (event) => {
      assertEquals(event.userId, legacyOwner);
      assertEquals(event.appAccountToken, legacyToken);
      assertEquals(event.productKind, "legacy_subscription");
      assertEquals(event.quantity, 1);
      calls.push(`apply:${event.productId}`);
      return Promise.resolve({ status: "applied" });
    },
    applyOneTimeCharge: () => {
      throw new Error("refund must not apply a one-time charge");
    },
    applyLifecycleNotification: () => {
      throw new Error("refund must not apply subscription lifecycle");
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
  assertEquals((await response.json()).status, "applied");
  assertEquals(
    calls.join("|"),
    `outer|transaction|resolve:2000000123456000:${legacyToken}|apply:${
      products[1]
    }`,
  );
});

Deno.test("resolved nil-token legacy refund uses the exact owner sentinel in the ledger", async () => {
  let resolverSawNull = false;
  let applied = false;
  const dependencies: NotificationHandlerDependencies = {
    now: () => now,
    verifyNotification: () => Promise.resolve(notification("REFUND")),
    verifyTransaction: () =>
      Promise.resolve({
        ...transaction(products[1], "REFUND"),
        appAccountToken: undefined,
      }),
    verifyRenewalInfo: () => {
      throw new Error("refund must not verify renewal info");
    },
    resolveNotificationUser: (event) => {
      resolverSawNull = event.appAccountToken === null;
      return Promise.resolve(legacyOwner);
    },
    applyNotification: (event) => {
      assertEquals(event.userId, legacyOwner);
      assertEquals(event.appAccountToken, legacyOwner);
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
    applyOneTimeCharge: () => {
      throw new Error("refund must not apply a one-time charge");
    },
    applyLifecycleNotification: () => {
      throw new Error("refund must not apply subscription lifecycle");
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
