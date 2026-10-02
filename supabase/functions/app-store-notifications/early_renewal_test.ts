import {
  createHandler,
  type NotificationHandlerDependencies,
} from "./index.ts";
import {
  InputError,
  MAX_RENEWAL_EARLY_SIGNING_MS,
  validateVerifiedOneTimeChargeNotification,
  validateVerifiedSubscriptionLifecycleNotification,
} from "./validation.ts";

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

function assertInputError(action: () => unknown, code: string): void {
  try {
    action();
  } catch (error) {
    assert(error instanceof InputError, `expected InputError: ${error}`);
    assertEquals(error.code, code);
    assertEquals(error.status, 400);
    return;
  }
  throw new Error(`expected ${code}`);
}

// Production-shaped renewal (2026-09-30 incident): Apple bills the next month
// up to a day before the current period ends. The renewal's purchaseDate is
// the new period start (the previous expiresDate) and every JWS is signed at
// billing time, before purchaseDate. Identifiers are synthetic.
const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;
const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const transactionId = "2000000900000002";
const originalTransactionId = "2000000900000001";
const notificationUUID = "3f1d2c4b-5a69-4e7f-8a9b-0c1d2e3f4a5b";
const periodStart = Date.UTC(2026, 8, 30, 10, 39, 6);
const periodEnd = Date.UTC(2026, 9, 30, 10, 39, 6);
const billedAt = periodStart - 23 * HOUR;
const appleRetryAfterPeriodStart = Date.UTC(2026, 9, 3, 12);

function renewalPayloads(
  signedAt: number,
  purchaseDate = periodStart,
  expiresDate = periodEnd,
) {
  return {
    notification: {
      notificationType: "DID_RENEW",
      notificationUUID,
      version: "2.0",
      signedDate: signedAt + 1_000,
      data: {
        bundleId: "com.x5studio.app",
        environment: "Production",
        signedTransactionInfo: "inner.transaction.signature",
        signedRenewalInfo: "inner.renewal.signature",
      },
    } as Record<string, unknown>,
    transaction: {
      bundleId: "com.x5studio.app",
      environment: "Production",
      productId: "com.x5studio.app.verified.monthly",
      transactionId,
      originalTransactionId,
      appAccountToken: userId,
      type: "Auto-Renewable Subscription",
      purchaseDate,
      expiresDate,
      signedDate: signedAt,
    } as Record<string, unknown>,
    renewal: {
      environment: "Production",
      originalTransactionId,
      productId: "com.x5studio.app.verified.monthly",
      autoRenewProductId: "com.x5studio.app.verified.monthly",
      appAccountToken: userId,
      autoRenewStatus: 1,
      renewalDate: expiresDate,
      signedDate: signedAt,
    } as Record<string, unknown>,
  };
}

function validate(
  payloads: ReturnType<typeof renewalPayloads>,
  nowMs: number,
) {
  return validateVerifiedSubscriptionLifecycleNotification(
    payloads.notification,
    payloads.transaction,
    payloads.renewal,
    "Production",
    nowMs,
  );
}

Deno.test("early renewal window is Apple's 24 hours plus one hour of margin", () => {
  assertEquals(MAX_RENEWAL_EARLY_SIGNING_MS, 25 * HOUR);
});

Deno.test("DID_RENEW billed 23h before its period start is accepted on first delivery", () => {
  const event = validate(renewalPayloads(billedAt), billedAt + 30_000);
  assertEquals(event.notificationType, "DID_RENEW");
  assertEquals(event.userId, userId);
  assertEquals(event.transactionId, transactionId);
  assertEquals(event.purchaseDate, "2026-09-30T10:39:06.000Z");
  assertEquals(event.expiresDate, "2026-10-30T10:39:06.000Z");
  assertEquals(event.transactionSignedDate, "2026-09-29T11:39:06.000Z");
  assertEquals(event.renewalSignedDate, "2026-09-29T11:39:06.000Z");
});

Deno.test("the same early-signed DID_RENEW is accepted on Apple's later retries", () => {
  const payloads = renewalPayloads(billedAt);
  for (
    const nowMs of [
      periodStart - HOUR,
      periodStart + 5 * 60_000,
      appleRetryAfterPeriodStart,
    ]
  ) {
    const event = validate(payloads, nowMs);
    assertEquals(event.purchaseDate, "2026-09-30T10:39:06.000Z");
  }
});

Deno.test("a renewal signed 30h before its period start is rejected", () => {
  const signedAt = periodStart - 30 * HOUR;
  const payloads = renewalPayloads(signedAt);
  assertInputError(
    () => validate(payloads, signedAt + 30_000),
    "invalid_purchase_date",
  );
  assertInputError(
    () => validate(payloads, periodStart + HOUR),
    "invalid_signed_date",
  );
});

Deno.test("the early-signing boundary is exactly 25 hours", () => {
  const nowMs = periodStart + HOUR;
  validate(renewalPayloads(periodStart - 25 * HOUR), nowMs);
  assertInputError(
    () => validate(renewalPayloads(periodStart - 25 * HOUR - 1), nowMs),
    "invalid_signed_date",
  );
  const firstDeliveryAt = periodStart - 25 * HOUR;
  validate(renewalPayloads(firstDeliveryAt), firstDeliveryAt + 30_000);
});

Deno.test("far-future-dated renewals are rejected", () => {
  const nowMs = billedAt;
  assertInputError(
    () =>
      validate(
        renewalPayloads(nowMs, nowMs + 30 * DAY, nowMs + 60 * DAY),
        nowMs,
      ),
    "invalid_purchase_date",
  );
  assertInputError(
    () =>
      validate(
        renewalPayloads(nowMs, nowMs + 26 * HOUR, nowMs + 31 * DAY),
        nowMs,
      ),
    "invalid_purchase_date",
  );
});

Deno.test("the window covers only the period start, never future signatures", () => {
  const payloads = renewalPayloads(billedAt);
  assertInputError(
    () => validate(payloads, billedAt - 10 * 60_000),
    "invalid_signed_date",
  );

  const lateRenewalInfo = renewalPayloads(billedAt);
  lateRenewalInfo.renewal.signedDate = periodStart - 30 * HOUR;
  assertInputError(
    () => validate(lateRenewalInfo, periodStart + HOUR),
    "invalid_signed_date",
  );

  const notificationBeforeTransaction = renewalPayloads(billedAt);
  notificationBeforeTransaction.notification.signedDate = billedAt -
    10 * 60_000;
  assertInputError(
    () => validate(notificationBeforeTransaction, periodStart + HOUR),
    "invalid_signed_date",
  );

  const expiresBeforeStart = renewalPayloads(
    billedAt,
    periodStart,
    periodStart,
  );
  assertInputError(
    () => validate(expiresBeforeStart, periodStart + HOUR),
    "invalid_expiration_date",
  );
});

Deno.test("consumable charges keep the strict clock-skew window", () => {
  const nowMs = Date.UTC(2026, 9, 2, 12);
  const notification = {
    notificationType: "ONE_TIME_CHARGE",
    notificationUUID: "f55c8bb4-e093-4f1e-a7fe-a247d31f79a4",
    version: "2.0",
    signedDate: nowMs,
    data: {
      bundleId: "com.x5studio.app",
      environment: "Production",
      signedTransactionInfo: "inner.header.signature",
    },
  };
  const transaction = {
    bundleId: "com.x5studio.app",
    environment: "Production",
    productId: "com.x5studio.app.credits.2000",
    transactionId: "2000000900000090",
    originalTransactionId: "2000000900000090",
    appAccountToken: userId,
    type: "Consumable",
    quantity: 1,
    purchaseDate: nowMs + HOUR,
    signedDate: nowMs,
  };
  assertInputError(
    () =>
      validateVerifiedOneTimeChargeNotification(
        notification,
        transaction,
        "Production",
        nowMs,
      ),
    "invalid_purchase_date",
  );
  assertInputError(
    () =>
      validateVerifiedOneTimeChargeNotification(
        notification,
        { ...transaction, purchaseDate: nowMs + 10 * 60_000 },
        "Production",
        nowMs + 10 * 60_000,
      ),
    "invalid_signed_date",
  );
});

function post(): Request {
  const encoded = btoa(JSON.stringify({ data: { environment: "Production" } }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return new Request(
    "https://example.test/functions/v1/app-store-notifications",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ signedPayload: `header.${encoded}.signature` }),
    },
  );
}

function dependencies(
  payloads: ReturnType<typeof renewalPayloads>,
  nowMs: number,
  overrides: Partial<NotificationHandlerDependencies> = {},
): NotificationHandlerDependencies {
  return {
    now: () => nowMs,
    verifyNotification: () => Promise.resolve(payloads.notification),
    verifyTransaction: () => Promise.resolve(payloads.transaction),
    verifyRenewalInfo: () => Promise.resolve(payloads.renewal),
    resolveNotificationUser: (event) => Promise.resolve(event.userId),
    applyOneTimeCharge: () => Promise.reject(new Error("unexpected")),
    applyNotification: () => Promise.reject(new Error("unexpected")),
    applyLifecycleNotification: () => Promise.resolve({ status: "applied" }),
    logError: () => undefined,
    ...overrides,
  };
}

Deno.test("an early-billed DID_RENEW reaches the lifecycle RPC on first delivery", async () => {
  const applied: string[] = [];
  const handler = createHandler(
    dependencies(renewalPayloads(billedAt), billedAt + 30_000, {
      applyLifecycleNotification: (event) => {
        applied.push(
          `${event.notificationType}|${event.purchaseDate}|${event.expiresDate}|${event.transactionSignedDate}`,
        );
        return Promise.resolve({ status: "applied" });
      },
    }),
  );
  const response = await handler(post());
  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "applied");
  assertEquals(
    applied.join(","),
    "DID_RENEW|2026-09-30T10:39:06.000Z|2026-10-30T10:39:06.000Z|2026-09-29T11:39:06.000Z",
  );
});
