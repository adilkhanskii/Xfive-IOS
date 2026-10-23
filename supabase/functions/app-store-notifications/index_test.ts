import {
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import {
  appleVerificationDiagnosticCode,
  AppleVerificationError,
  createHandler,
  NotificationApplyError,
  type NotificationHandlerDependencies,
  oneTimeChargeRPCName,
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

function unsignedNotification(environment = "Production"): string {
  const encoded = btoa(JSON.stringify({ data: { environment } }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return `header.${encoded}.signature`;
}

const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const outer = {
  notificationType: "REFUND",
  notificationUUID: "8ea875c0-2a6a-4d15-8c98-ab8b28cf8aad",
  version: "2.0",
  signedDate: Date.UTC(2026, 6, 16, 11, 59),
  data: {
    bundleId: "com.x5studio.app",
    environment: "Production",
    signedTransactionInfo: "inner.header.signature",
  },
};
const inner = {
  bundleId: "com.x5studio.app",
  environment: "Production",
  productId: "com.x5studio.app.credits.1000",
  transactionId: "2000000123456790",
  originalTransactionId: "2000000123456790",
  appAccountToken: userId,
  type: "Consumable",
  quantity: 1,
  purchaseDate: Date.UTC(2026, 6, 1),
  signedDate: Date.UTC(2026, 6, 16, 11, 58),
  revocationDate: Date.UTC(2026, 6, 15),
  revocationType: "REFUND_FULL",
  revocationPercentage: 100000,
};
const renewal = {
  environment: "Production",
  originalTransactionId: "2000000123456000",
  productId: "com.x5studio.app.verified.monthly",
  autoRenewProductId: "com.x5studio.app.verified.monthly",
  appAccountToken: userId,
  autoRenewStatus: 1,
  renewalDate: Date.UTC(2026, 7, 1),
  signedDate: Date.UTC(2026, 6, 16, 11, 58),
};

function dependencies(
  overrides: Partial<NotificationHandlerDependencies> = {},
): NotificationHandlerDependencies {
  return {
    now: () => Date.UTC(2026, 6, 16, 12),
    verifyNotification: () => Promise.resolve(outer),
    verifyTransaction: () => Promise.resolve(inner),
    verifyRenewalInfo: () => Promise.resolve(renewal),
    resolveNotificationUser: (event) => Promise.resolve(event.userId),
    applyOneTimeCharge: () => Promise.resolve({ status: "applied" }),
    applyNotification: () => Promise.resolve({ status: "applied" }),
    applyLifecycleNotification: () => Promise.resolve({ status: "applied" }),
    logError: () => undefined,
    ...overrides,
  };
}

function post(body: unknown, contentType = "application/json"): Request {
  return new Request(
    "https://example.test/functions/v1/app-store-notifications",
    {
      method: "POST",
      headers: { "Content-Type": contentType },
      body: JSON.stringify(body),
    },
  );
}

Deno.test("public webhook requires strict POST JSON", async () => {
  const handler = createHandler(dependencies());
  const get = await handler(
    new Request("https://example.test", { method: "GET" }),
  );
  assertEquals(get.status, 405);
  assertEquals(get.headers.get("Allow"), "POST");

  const wrongContent = await handler(
    post({ signedPayload: "a.b.c" }, "text/plain"),
  );
  assertEquals(wrongContent.status, 415);

  const wrongShape = await handler(
    post({ signedPayload: "a.b.c", forged: true }),
  );
  assertEquals(wrongShape.status, 400);
});

Deno.test("body limit is enforced before JSON and JWS verification", async () => {
  let verified = false;
  const handler = createHandler(dependencies({
    verifyNotification: () => {
      verified = true;
      return Promise.resolve(outer);
    },
  }));
  const response = await handler(
    post({ signedPayload: "x".repeat(140 * 1024) }),
  );
  assertEquals(response.status, 413);
  assertEquals(verified, false);
});

Deno.test("outer JWS is verified before inner JWS and database apply", async () => {
  const calls: string[] = [];
  const handler = createHandler(dependencies({
    verifyNotification: (_signed, environment) => {
      calls.push(`outer:${environment}`);
      return Promise.resolve(outer);
    },
    verifyTransaction: (_signed, environment) => {
      calls.push(`inner:${environment}`);
      return Promise.resolve(inner);
    },
    applyNotification: (event) => {
      calls.push(`apply:${event.userId}:${event.revocationPercentage}`);
      return Promise.resolve({ status: "applied" });
    },
  }));

  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "applied");
  assertEquals(
    calls.join("|"),
    `outer:Production|inner:Production|apply:${userId}:100000`,
  );
});

Deno.test("ONE_TIME_CHARGE verifies both Apple JWS layers and applies the exact signed account token", async () => {
  for (const environment of ["Production", "Sandbox"] as const) {
    const calls: string[] = [];
    const chargeOuter = {
      ...outer,
      notificationType: "ONE_TIME_CHARGE",
      notificationUUID: environment === "Production"
        ? "f55c8bb4-e093-4f1e-a7fe-a247d31f79a4"
        : "90e85492-e8f1-4cc3-b2d1-867e7020e448",
      data: { ...outer.data, environment },
    };
    const chargeTransaction = {
      ...inner,
      environment,
      revocationDate: undefined,
      revocationType: undefined,
      revocationPercentage: undefined,
    };
    const handler = createHandler(dependencies({
      verifyNotification: (_signed, routedEnvironment) => {
        calls.push(`outer:${routedEnvironment}`);
        return Promise.resolve(chargeOuter);
      },
      verifyTransaction: (_signed, routedEnvironment) => {
        calls.push(`inner:${routedEnvironment}`);
        return Promise.resolve(chargeTransaction);
      },
      resolveNotificationUser: () => {
        throw new Error("ONE_TIME_CHARGE must use its exact appAccountToken");
      },
      applyOneTimeCharge: (event) => {
        calls.push(
          `apply:${event.environment}:${event.userId}:${event.productId}:${event.transactionId}`,
        );
        assertEquals(event.userId, event.appAccountToken);
        return Promise.resolve({ status: "applied" });
      },
      applyNotification: () => {
        throw new Error("refund apply must not be used");
      },
      applyLifecycleNotification: () => {
        throw new Error("lifecycle apply must not be used");
      },
    }));

    const response = await handler(
      post({ signedPayload: unsignedNotification(environment) }),
    );
    assertEquals(response.status, 200);
    assertEquals((await response.json()).status, "applied");
    assertEquals(
      calls.join("|"),
      `outer:${environment}|inner:${environment}|apply:${environment}:${userId}:com.x5studio.app.credits.1000:2000000123456790`,
    );
  }
});

Deno.test("ONE_TIME_CHARGE selects only the production ledger or existing Sandbox allowlist RPC", () => {
  assertEquals(
    oneTimeChargeRPCName("Production"),
    "apply_verified_app_store_consumable",
  );
  assertEquals(
    oneTimeChargeRPCName("Sandbox"),
    "apply_verified_app_store_sandbox_review_transaction",
  );
  for (const value of ["Xcode", "LocalTesting", "", null]) {
    try {
      oneTimeChargeRPCName(value);
    } catch (error) {
      assert(error instanceof Error);
      assertEquals(error.message, "invalid_environment");
      continue;
    }
    throw new Error(`unexpected ONE_TIME_CHARGE environment: ${String(value)}`);
  }
});

Deno.test("subscription lifecycle verifies outer, transaction and renewal JWS before one database apply", async () => {
  const calls: string[] = [];
  const lifecycleOuter = {
    ...outer,
    notificationType: "DID_RENEW",
    data: {
      ...outer.data,
      signedRenewalInfo: "renewal.header.signature",
    },
  };
  const lifecycleTransaction = {
    ...inner,
    productId: "com.x5studio.app.verified.monthly",
    transactionId: "2000000123456791",
    originalTransactionId: "2000000123456000",
    type: "Auto-Renewable Subscription",
    quantity: undefined,
    expiresDate: Date.UTC(2026, 7, 1),
    revocationDate: undefined,
    revocationType: undefined,
    revocationPercentage: undefined,
  };
  const handler = createHandler(dependencies({
    verifyNotification: (_signed, environment) => {
      calls.push(`outer:${environment}`);
      return Promise.resolve(lifecycleOuter);
    },
    verifyTransaction: (_signed, environment) => {
      calls.push(`transaction:${environment}`);
      return Promise.resolve(lifecycleTransaction);
    },
    verifyRenewalInfo: (_signed, environment) => {
      calls.push(`renewal:${environment}`);
      return Promise.resolve(renewal);
    },
    applyNotification: () => {
      throw new Error("refund apply must not be used");
    },
    applyLifecycleNotification: (event) => {
      calls.push(`apply:${event.notificationType}:${event.userId}`);
      return Promise.resolve({ status: "applied" });
    },
  }));

  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "applied");
  assertEquals(
    calls.join("|"),
    `outer:Production|transaction:Production|renewal:Production|apply:DID_RENEW:${userId}`,
  );
});

Deno.test("legacy subscription renewal and expiry resolve the exact bound owner before apply", async () => {
  const legacyOwner = "9ae99a45-91ac-486a-b7ec-e6614b7bc257";
  const legacyToken = "b6580000-0000-4000-8000-000000000001";
  for (const notificationType of ["DID_RENEW", "EXPIRED"] as const) {
    const calls: string[] = [];
    const lifecycleOuter = {
      ...outer,
      notificationType,
      data: {
        ...outer.data,
        signedRenewalInfo: "renewal.header.signature",
      },
    };
    const lifecycleTransaction = {
      ...inner,
      productId: "com.x5studio.app.verified.monthly",
      transactionId: `legacy-${notificationType.toLowerCase()}`,
      originalTransactionId: "2000001190576148",
      appAccountToken: legacyToken,
      type: "Auto-Renewable Subscription",
      quantity: undefined,
      expiresDate: notificationType === "EXPIRED"
        ? Date.UTC(2026, 6, 15)
        : Date.UTC(2026, 7, 1),
      revocationDate: undefined,
      revocationType: undefined,
      revocationPercentage: undefined,
    };
    const legacyRenewal = {
      ...renewal,
      originalTransactionId: "2000001190576148",
      appAccountToken: legacyToken,
    };
    const handler = createHandler(dependencies({
      verifyNotification: () => Promise.resolve(lifecycleOuter),
      verifyTransaction: () => Promise.resolve(lifecycleTransaction),
      verifyRenewalInfo: () => Promise.resolve(legacyRenewal),
      resolveNotificationUser: (event) => {
        calls.push(
          `resolve:${event.environment}:${event.originalTransactionId}:${event.appAccountToken}`,
        );
        return Promise.resolve(legacyOwner);
      },
      applyLifecycleNotification: (event) => {
        calls.push(
          `apply:${event.notificationType}:${event.userId}:${event.appAccountToken}`,
        );
        return Promise.resolve({ status: "applied" });
      },
    }));

    const response = await handler(
      post({ signedPayload: unsignedNotification() }),
    );
    assertEquals(response.status, 200);
    assertEquals(
      calls.join("|"),
      `resolve:Production:2000001190576148:${legacyToken}|apply:${notificationType}:${legacyOwner}:${legacyToken}`,
    );
  }
});

Deno.test("legacy verified refund and reversal resolve owner while preserving the signed token", async () => {
  const legacyOwner = "9ae99a45-91ac-486a-b7ec-e6614b7bc257";
  const legacyToken = "b6580000-0000-4000-8000-000000000001";
  for (const notificationType of ["REFUND", "REFUND_REVERSED"] as const) {
    const refundOuter = {
      ...outer,
      notificationType,
    };
    const refundTransaction = {
      ...inner,
      productId: "com.x5studio.app.verified.monthly",
      transactionId: "legacy-refund-transaction",
      originalTransactionId: "2000001190576148",
      appAccountToken: legacyToken,
      type: "Auto-Renewable Subscription",
      quantity: undefined,
      expiresDate: Date.UTC(2026, 7, 1),
      revocationDate: notificationType === "REFUND"
        ? Date.UTC(2026, 6, 15)
        : undefined,
      revocationType: notificationType === "REFUND" ? "REFUND_FULL" : undefined,
      revocationPercentage: notificationType === "REFUND" ? 100000 : undefined,
    };
    let applied = false;
    const handler = createHandler(dependencies({
      verifyNotification: () => Promise.resolve(refundOuter),
      verifyTransaction: () => Promise.resolve(refundTransaction),
      resolveNotificationUser: (event) => {
        assertEquals(event.appAccountToken, legacyToken);
        return Promise.resolve(legacyOwner);
      },
      applyNotification: (event) => {
        assertEquals(event.userId, legacyOwner);
        assertEquals(event.appAccountToken, legacyToken);
        assertEquals(event.notificationType, notificationType);
        applied = true;
        return Promise.resolve({ status: "applied" });
      },
    }));

    const response = await handler(
      post({ signedPayload: unsignedNotification() }),
    );
    assertEquals(response.status, 200);
    assertEquals(applied, true);
  }
});

Deno.test("DID_FAIL_TO_RENEW grace period is verified, resolved and applied", async () => {
  let applied = false;
  const gracePeriodExpiresDate = Date.UTC(2026, 6, 20);
  const handler = createHandler(dependencies({
    verifyNotification: () =>
      Promise.resolve({
        ...outer,
        notificationType: "DID_FAIL_TO_RENEW",
        subtype: "GRACE_PERIOD",
        data: {
          ...outer.data,
          signedRenewalInfo: "renewal.header.signature",
        },
      }),
    verifyTransaction: () =>
      Promise.resolve({
        ...inner,
        productId: "com.x5studio.app.verified.monthly",
        transactionId: "grace-period-transaction",
        originalTransactionId: "grace-period-chain",
        type: "Auto-Renewable Subscription",
        quantity: undefined,
        expiresDate: Date.UTC(2026, 6, 16, 11),
        revocationDate: undefined,
        revocationType: undefined,
        revocationPercentage: undefined,
      }),
    verifyRenewalInfo: () =>
      Promise.resolve({
        ...renewal,
        originalTransactionId: "grace-period-chain",
        gracePeriodExpiresDate,
      }),
    resolveNotificationUser: (event) => {
      assertEquals(event.appAccountToken, userId);
      return Promise.resolve(userId);
    },
    applyLifecycleNotification: (event) => {
      assertEquals(event.notificationType, "DID_FAIL_TO_RENEW");
      assertEquals(event.notificationSubtype, "GRACE_PERIOD");
      assertEquals(
        event.gracePeriodExpiresDate,
        "2026-07-20T00:00:00.000Z",
      );
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
  }));

  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 200);
  assertEquals(applied, true);
});

Deno.test("lifecycle notification without signed renewal info is rejected before database apply", async () => {
  let applied = false;
  const handler = createHandler(dependencies({
    verifyNotification: () =>
      Promise.resolve({ ...outer, notificationType: "EXPIRED" }),
    applyLifecycleNotification: () => {
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
  }));

  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "missing_signed_renewal_info");
  assertEquals(applied, false);
});

Deno.test("signed but irrelevant notification types are acknowledged without inner verification", async () => {
  let innerVerified = false;
  let applied = false;
  const handler = createHandler(dependencies({
    verifyNotification: () =>
      Promise.resolve({ ...outer, notificationType: "TEST", data: undefined }),
    verifyTransaction: () => {
      innerVerified = true;
      return Promise.resolve(inner);
    },
    applyNotification: () => {
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
  }));
  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "ignored");
  assertEquals(innerVerified, false);
  assertEquals(applied, false);
});

Deno.test("signed unsupported X5 products are acknowledged without state changes", async () => {
  let applied = false;
  const handler = createHandler(dependencies({
    verifyTransaction: () =>
      Promise.resolve({
        ...inner,
        productId: "com.x5studio.app.retired.monthly",
      }),
    applyNotification: () => {
      applied = true;
      return Promise.resolve({ status: "applied" });
    },
  }));
  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).reason, "unsupported_product");
  assertEquals(applied, false);
});

Deno.test("invalid Apple signatures are rejected and retryable OCSP failures get 503", async () => {
  for (
    const [retryable, expectedStatus] of [[false, 400], [true, 503]] as const
  ) {
    const handler = createHandler(dependencies({
      verifyNotification: () =>
        Promise.reject(new AppleVerificationError(retryable)),
    }));
    const response = await handler(
      post({ signedPayload: unsignedNotification() }),
    );
    assertEquals(response.status, expectedStatus);
  }
});

Deno.test("Apple verification rejection exposes only phase and safe diagnostic code", async () => {
  const handler = createHandler(dependencies({
    verifyNotification: () =>
      Promise.reject(
        new AppleVerificationError(
          false,
          "VERIFICATION_FAILURE_TYPE_ERROR",
          "notification",
        ),
      ),
  }));
  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 400);
  assertEquals(
    (await response.json()).error,
    "invalid_apple_notification_verification_failure_type_error",
  );
});

Deno.test("Apple verification diagnostics expose only an allowlisted Edge stage", () => {
  assertEquals(
    appleVerificationDiagnosticCode(
      new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error("edge_jws_signature_verify_runtime"),
      ),
    ),
    "VERIFICATION_FAILURE_EDGE_SIGNATURE_VERIFY_RUNTIME",
  );
  assertEquals(
    appleVerificationDiagnosticCode(
      new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error("edge_x509_leaf_public_key_runtime"),
      ),
    ),
    "VERIFICATION_FAILURE_EDGE_X509_LEAF_PUBLIC_KEY_RUNTIME",
  );
  const distortedStatus = new VerificationException(
    VerificationStatus.VERIFICATION_FAILURE,
    new Error("edge_x509_leaf_parse_runtime"),
  );
  distortedStatus.status = 999 as VerificationStatus;
  assertEquals(
    appleVerificationDiagnosticCode(distortedStatus),
    "VERIFICATION_FAILURE_EDGE_X509_LEAF_PARSE_RUNTIME",
  );
  distortedStatus.cause = {
    message: "edge_x509_leaf_public_key_runtime",
  } as Error;
  assertEquals(
    appleVerificationDiagnosticCode(distortedStatus),
    "VERIFICATION_FAILURE_EDGE_X509_LEAF_PUBLIC_KEY_RUNTIME",
  );
});

Deno.test("database conflicts are not acknowledged as successful Apple delivery", async () => {
  const handler = createHandler(dependencies({
    applyNotification: () =>
      Promise.reject(new NotificationApplyError("conflict", 409)),
  }));
  const response = await handler(
    post({ signedPayload: unsignedNotification() }),
  );
  assertEquals(response.status, 409);
  assertEquals((await response.json()).status, "rejected");
});

Deno.test("responses are never cached and errors do not leak signed payloads", async () => {
  const secret = unsignedNotification();
  const handler = createHandler(dependencies({
    verifyNotification: () => Promise.reject(new Error(secret)),
  }));
  const response = await handler(post({ signedPayload: secret }));
  assertEquals(response.status, 500);
  assertEquals(response.headers.get("Cache-Control"), "no-store");
  assert(!(await response.text()).includes(secret));
});
