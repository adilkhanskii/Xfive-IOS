import {
  createHandler,
  NotificationApplyError,
  type NotificationDiagnostic,
  type NotificationHandlerDependencies,
  safeRpcReason,
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

// Production-shaped renewal (2026-09-30 incident): Apple bills the next month
// up to a day before the current period ends. The renewal's purchaseDate is
// the new period start (the previous expiresDate) and every JWS is signed at
// billing time, before purchaseDate. Identifiers are synthetic.
const HOUR = 60 * 60_000;
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

Deno.test("rejections are logged with the exact reason and no identifiers", async () => {
  const diagnostics: NotificationDiagnostic[] = [];
  const sqlRejected = createHandler(
    dependencies(renewalPayloads(billedAt), appleRetryAfterPeriodStart, {
      applyLifecycleNotification: () =>
        Promise.reject(
          new NotificationApplyError(
            "invalid_notification",
            400,
            "invalid_signed_date",
          ),
        ),
      logDiagnostic: (entry) => diagnostics.push(entry),
    }),
  );
  const response = await sqlRejected(post());
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "invalid_notification");

  const tooEarly = createHandler(
    dependencies(
      renewalPayloads(periodStart - 30 * HOUR),
      appleRetryAfterPeriodStart,
      { logDiagnostic: (entry) => diagnostics.push(entry) },
    ),
  );
  assertEquals((await tooEarly(post())).status, 400);

  assertEquals(diagnostics.length, 2);
  assertEquals(diagnostics[0].outcome, "rejected");
  assertEquals(diagnostics[0].http_status, 400);
  assertEquals(diagnostics[0].code, "invalid_notification");
  assertEquals(diagnostics[0].reason, "invalid_signed_date");
  assertEquals(diagnostics[0].notification_type, "DID_RENEW");
  assertEquals(diagnostics[0].environment, "Production");
  assertEquals(diagnostics[0].notification_uuid, notificationUUID);
  assertEquals(diagnostics[1].code, "invalid_signed_date");
  assertEquals(diagnostics[1].reason, undefined);
  const logged = JSON.stringify(diagnostics);
  for (const secret of [userId, transactionId, originalTransactionId]) {
    assert(!logged.includes(secret), `diagnostics leaked ${secret}`);
  }
});

Deno.test("ignored renewal-status and billing notifications are logged, not dropped silently", async () => {
  const diagnostics: NotificationDiagnostic[] = [];
  const payloads = renewalPayloads(billedAt);
  const statusChange = createHandler(
    dependencies(
      {
        ...payloads,
        notification: {
          ...payloads.notification,
          notificationType: "DID_CHANGE_RENEWAL_STATUS",
          subtype: "AUTO_RENEW_DISABLED",
        },
      },
      billedAt + 30_000,
      {
        logDiagnostic: (entry) => diagnostics.push(entry),
      },
    ),
  );
  const ignored = await statusChange(post());
  assertEquals(ignored.status, 200);
  assertEquals((await ignored.json()).status, "ignored");

  const billingRetry = createHandler(
    dependencies(
      {
        ...payloads,
        notification: {
          ...payloads.notification,
          notificationType: "DID_FAIL_TO_RENEW",
        },
      },
      billedAt + 30_000,
      {
        logDiagnostic: (entry) => diagnostics.push(entry),
      },
    ),
  );
  assertEquals((await billingRetry(post())).status, 200);

  assertEquals(diagnostics.length, 2);
  assertEquals(diagnostics[0].outcome, "ignored");
  assertEquals(diagnostics[0].code, "unsupported_notification_type");
  assertEquals(diagnostics[0].notification_type, "DID_CHANGE_RENEWAL_STATUS");
  assertEquals(diagnostics[0].notification_subtype, "AUTO_RENEW_DISABLED");
  assertEquals(diagnostics[1].outcome, "ignored");
  assertEquals(diagnostics[1].notification_type, "DID_FAIL_TO_RENEW");
  assertEquals(diagnostics[1].notification_subtype, undefined);
});

Deno.test("a failing diagnostics sink never changes Apple's response", async () => {
  const handler = createHandler(
    dependencies(renewalPayloads(periodStart - 30 * HOUR), periodStart, {
      logDiagnostic: () => {
        throw new Error("log sink down");
      },
    }),
  );
  const response = await handler(post());
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "invalid_signed_date");
});

Deno.test("database errors are reduced to reason codes without row details", () => {
  assertEquals(
    safeRpcReason({ code: "22023", message: "invalid_signed_date" }),
    "invalid_signed_date",
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
  assertEquals(safeRpcReason({ message: transactionId }), "code_unknown");
});
