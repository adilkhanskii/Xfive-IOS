import {
  createHandler,
  EntitlementApplyError,
  type HandlerDependencies,
  safeRpcReason,
} from "./index.ts";
import { type VerifiedTransactionPayload } from "./validation.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

// Production-shaped renewal (2026-09-30 incident): StoreKit hands the app the
// renewal Apple billed and signed up to a day before the new period starts.
// purchaseDate is the period start; signedDate is the billing time.
const HOUR = 60 * 60_000;
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

Deno.test("a database rejection returns and logs its exact safe reason", async () => {
  const logged: unknown[] = [];
  const handler = createHandler(dependencies({
    applyVerifiedSubscription: () =>
      Promise.reject(
        new EntitlementApplyError(
          "rejected",
          400,
          "rejected",
          "invalid_transaction_dates",
        ),
      ),
    logError: (error) => logged.push(error),
  }));
  const response = await handler(post());
  assertEquals(response.status, 400);
  const body = await response.json();
  assertEquals(body.status, "rejected");
  assertEquals(body.error, "invalid_transaction_dates");
  assertEquals(logged.length, 1);
  assertEquals(
    (logged[0] as EntitlementApplyError).reason,
    "invalid_transaction_dates",
  );
});

Deno.test("ownership rejections keep their exact response contract", async () => {
  const handler = createHandler(dependencies({
    applyVerifiedSubscription: () =>
      Promise.reject(
        new EntitlementApplyError(
          "rejected",
          400,
          "account_token_mismatch",
          "account_token_mismatch",
        ),
      ),
  }));
  const response = await handler(post());
  assertEquals(response.status, 400);
  const body = await response.json();
  assertEquals(body.status, "rejected");
  assertEquals("error" in body, false);
});

Deno.test("database errors are reduced to reason codes without row details", () => {
  assertEquals(
    safeRpcReason({ code: "22023", message: "invalid_transaction_dates" }),
    "invalid_transaction_dates",
  );
  assertEquals(
    safeRpcReason({
      code: "23514",
      message:
        'new row for relation "app_store_transactions" violates check constraint "app_store_transactions_dates_valid"',
    }),
    "constraint_app_store_transactions_dates_valid",
  );
  assertEquals(
    safeRpcReason({ code: "P0001", message: `user ${userId} not allowed` }),
    "code_P0001",
  );
  assertEquals(safeRpcReason({ message: "2000000900000002" }), "code_unknown");
});
