import { createHandler, type HandlerDependencies } from "./index.ts";
import {
  InputError,
  MAX_RENEWAL_EARLY_SIGNING_MS,
  validateVerifiedTransaction,
  type VerifiedTransactionPayload,
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

// Production-shaped renewal (2026-09-30 incident): StoreKit hands the app the
// renewal Apple billed and signed up to a day before the new period starts.
// purchaseDate is the period start; signedDate is the billing time.
const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;
const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const periodStart = Date.UTC(2026, 8, 30, 10, 39, 6);
const periodEnd = Date.UTC(2026, 9, 30, 10, 39, 6);
const billedAt = periodStart - 23 * HOUR;
const appReopenedAt = Date.UTC(2026, 9, 1, 10, 29, 39);

function renewal(
  signedDate: number,
  purchaseDate = periodStart,
  expiresDate = periodEnd,
): VerifiedTransactionPayload {
  return {
    bundleId: "com.x5studio.app",
    productId: "com.x5studio.app.verified.monthly",
    transactionId: "2000000900000002",
    originalTransactionId: "2000000900000001",
    appAccountToken: userId,
    purchaseDate,
    expiresDate,
    signedDate,
    environment: "Production",
    type: "Auto-Renewable Subscription",
  };
}

function validate(payload: VerifiedTransactionPayload, nowMs: number) {
  return validateVerifiedTransaction(payload, userId, "Production", nowMs);
}

Deno.test("early renewal window is Apple's 24 hours plus one hour of margin", () => {
  assertEquals(MAX_RENEWAL_EARLY_SIGNING_MS, 25 * HOUR);
});

Deno.test("a renewal billed 23h early is accepted before and after its period starts", () => {
  for (const nowMs of [billedAt + 60_000, periodStart - HOUR, appReopenedAt]) {
    const transaction = validate(renewal(billedAt), nowMs);
    assertEquals(transaction.productKind, "subscription");
    assertEquals(transaction.purchaseDate, "2026-09-30T10:39:06.000Z");
    assertEquals(transaction.expiresDate, "2026-10-30T10:39:06.000Z");
    assertEquals(transaction.signedDate, "2026-09-29T11:39:06.000Z");
  }
});

Deno.test("a renewal signed 30h before its period start is rejected", () => {
  const signedAt = periodStart - 30 * HOUR;
  assertInputError(
    () => validate(renewal(signedAt), signedAt + 60_000),
    "invalid_purchase_date",
  );
  assertInputError(
    () => validate(renewal(signedAt), appReopenedAt),
    "invalid_signed_date",
  );
  validate(renewal(periodStart - 25 * HOUR), appReopenedAt);
  assertInputError(
    () => validate(renewal(periodStart - 25 * HOUR - 1), appReopenedAt),
    "invalid_signed_date",
  );
});

Deno.test("far-future-dated subscriptions and future signatures are rejected", () => {
  const nowMs = billedAt;
  assertInputError(
    () => validate(renewal(nowMs, nowMs + 30 * DAY, nowMs + 60 * DAY), nowMs),
    "invalid_purchase_date",
  );
  assertInputError(
    () => validate(renewal(nowMs, nowMs + 26 * HOUR, nowMs + 31 * DAY), nowMs),
    "invalid_purchase_date",
  );
  assertInputError(
    () => validate(renewal(billedAt), billedAt - 10 * 60_000),
    "invalid_signed_date",
  );
});

Deno.test("consumables keep the strict clock-skew purchase window", () => {
  const nowMs = Date.UTC(2026, 9, 2, 12);
  assertInputError(
    () =>
      validate({
        ...renewal(nowMs, nowMs + HOUR),
        productId: "com.x5studio.app.credits.2000",
        transactionId: "2000000900000090",
        originalTransactionId: "2000000900000090",
        type: "Consumable",
        quantity: 1,
        expiresDate: undefined,
      }, nowMs),
    "invalid_purchase_date",
  );
});

function post(): Request {
  const encoded = btoa(JSON.stringify({ environment: "Production" }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return new Request(
    "https://example.test/functions/v1/verify-app-store-transaction",
    {
      method: "POST",
      headers: {
        Authorization: "Bearer access-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        signed_transaction: `header.${encoded}.signature`,
      }),
    },
  );
}

function dependencies(
  overrides: Partial<HandlerDependencies> = {},
): HandlerDependencies {
  const unexpected = () => Promise.reject(new Error("unexpected"));
  return {
    now: () => appReopenedAt,
    authenticate: () => Promise.resolve(userId),
    verifySignedTransaction: () => Promise.resolve(renewal(billedAt)),
    applyVerifiedSubscription: () =>
      Promise.resolve({
        status: "applied",
        credits_granted: 0,
        subscription_end_date: "2026-10-30T10:39:06.000Z",
        is_verified: true,
      }),
    applyVerifiedConsumable: unexpected,
    applyVerifiedConsumableRefund: unexpected,
    applyVerifiedSandboxReview: unexpected,
    applyVerifiedRevocation: unexpected,
    logError: () => undefined,
    ...overrides,
  };
}

Deno.test("the app's early-billed renewal reaches the subscription RPC", async () => {
  const applied: string[] = [];
  const handler = createHandler(dependencies({
    now: () => billedAt + 60_000,
    applyVerifiedSubscription: (_userId, transaction) => {
      applied.push(
        `${transaction.purchaseDate}|${transaction.expiresDate}|${transaction.signedDate}`,
      );
      return Promise.resolve({
        status: "applied",
        credits_granted: 0,
        subscription_end_date: transaction.expiresDate,
        is_verified: true,
      });
    },
  }));
  const response = await handler(post());
  assertEquals(response.status, 200);
  assertEquals((await response.json()).is_verified, true);
  assertEquals(
    applied.join(","),
    "2026-09-30T10:39:06.000Z|2026-10-30T10:39:06.000Z|2026-09-29T11:39:06.000Z",
  );
});
