import {
  appleOnlineChecksEnabled,
  appleVerificationDiagnosticCode,
  AppleVerificationError,
  createHandler,
  EntitlementApplyError,
  type HandlerDependencies,
} from "./index.ts";
import {
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";

Deno.test("Apple JWS verification skips runtime-incompatible live OCSP in every environment", () => {
  assertEquals(appleOnlineChecksEnabled("Production"), false);
  assertEquals(appleOnlineChecksEnabled("Sandbox"), false);
});

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

function signedTransaction(environment = "Production"): string {
  const payload = btoa(JSON.stringify({ environment }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return `header.${payload}.signature`;
}

const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const verifiedPayload = {
  bundleId: "com.x5studio.app",
  productId: "com.x5studio.app.pro.monthly",
  transactionId: "2000000123456789",
  originalTransactionId: "2000000123400000",
  appAccountToken: userId,
  purchaseDate: Date.UTC(2026, 6, 1),
  expiresDate: Date.UTC(2026, 7, 1),
  signedDate: Date.UTC(2026, 6, 14),
  environment: "Production",
};

const verifiedConsumablePayload = {
  ...verifiedPayload,
  productId: "com.x5studio.app.credits.2000",
  transactionId: "2000000123456790",
  originalTransactionId: "2000000123456790",
  type: "Consumable",
  quantity: 1,
  expiresDate: undefined,
};

const verifiedRevocationPayload = {
  ...verifiedPayload,
  productId: "com.x5studio.app.verified.monthly",
  revocationDate: Date.UTC(2026, 6, 12),
};

const verifiedConsumableRefundPayload = {
  ...verifiedConsumablePayload,
  revocationDate: Date.UTC(2026, 6, 12),
};

function dependencies(
  overrides: Partial<HandlerDependencies> = {},
): HandlerDependencies {
  return {
    now: () => Date.UTC(2026, 6, 14),
    authenticate: () => Promise.resolve(userId),
    verifySignedTransaction: () => Promise.resolve(verifiedPayload),
    applyVerifiedSubscription: () =>
      Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: "2026-08-01T00:00:00.000Z",
        is_verified: false,
      }),
    applyVerifiedConsumable: () =>
      Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: null,
        is_verified: false,
      }),
    applyVerifiedConsumableRefund: () =>
      Promise.resolve({
        status: "applied",
        credits_granted: 0,
        subscription_end_date: null,
        is_verified: false,
      }),
    applyVerifiedSandboxReview: () =>
      Promise.reject(new EntitlementApplyError("rejected", 403)),
    applyVerifiedRevocation: () =>
      Promise.resolve({
        status: "applied",
        credits_granted: 0,
        subscription_end_date: null,
        is_verified: false,
      }),
    logError: () => undefined,
    ...overrides,
  };
}

function post(body: unknown, token = "access-token"): Request {
  return new Request(
    "https://example.test/functions/v1/verify-app-store-transaction",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

Deno.test("handler authenticates before touching the transaction", async () => {
  let verified = false;
  const handler = createHandler(dependencies({
    authenticate: () => Promise.resolve(null),
    verifySignedTransaction: () => {
      verified = true;
      return Promise.resolve(verifiedPayload);
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(response.status, 401);
  assertEquals(verified, false);
});

Deno.test("handler ignores no client-declared product or transaction fields", async () => {
  let verified = false;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () => {
      verified = true;
      return Promise.resolve(verifiedPayload);
    },
  }));

  const response = await handler(post({
    signed_transaction: signedTransaction(),
    product_id: "forged.product",
  }));
  assertEquals(response.status, 400);
  assertEquals(verified, false);
});

Deno.test("handler routes subscription payloads to the subscription RPC", async () => {
  let applied: Record<string, unknown> | undefined;
  let consumableApplied = false;
  const handler = createHandler(dependencies({
    applyVerifiedSubscription: (authenticatedUserId, transaction) => {
      applied = { authenticatedUserId, ...transaction };
      return Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: transaction.expiresDate,
        is_verified: false,
      });
    },
    applyVerifiedConsumable: () => {
      consumableApplied = true;
      throw new Error("wrong_rpc");
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.status, "applied");
  assertEquals(body.credits_granted, 2000);
  assert(applied);
  assertEquals(applied.authenticatedUserId, userId);
  assertEquals(applied.productId, "com.x5studio.app.pro.monthly");
  assertEquals(applied.productKind, "subscription");
  assertEquals(applied.environment, "Production");
  assertEquals(consumableApplied, false);
});

Deno.test("handler routes consumable payloads to the credit-only RPC", async () => {
  let subscriptionApplied = false;
  let applied: Record<string, unknown> | undefined;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () => Promise.resolve(verifiedConsumablePayload),
    applyVerifiedSubscription: () => {
      subscriptionApplied = true;
      throw new Error("wrong_rpc");
    },
    applyVerifiedConsumable: (authenticatedUserId, transaction) => {
      applied = { authenticatedUserId, ...transaction };
      return Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: null,
        is_verified: false,
      });
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );

  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.status, "applied");
  assertEquals(body.credits_granted, 2000);
  assertEquals(body.subscription_end_date, null);
  assert(applied);
  assertEquals(subscriptionApplied, false);
  assertEquals(applied.authenticatedUserId, userId);
  assertEquals(applied.productId, "com.x5studio.app.credits.2000");
  assertEquals(applied.productKind, "consumable");
  assertEquals(applied.quantity, 1);
  assertEquals(applied.expiresDate, null);
});

Deno.test("handler routes Sandbox transactions only to the review RPC", async () => {
  let verified = false;
  let productionApplied = false;
  let sandboxApplied: Record<string, unknown> | undefined;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () => {
      verified = true;
      return Promise.resolve({
        ...verifiedConsumablePayload,
        environment: "Sandbox",
      });
    },
    applyVerifiedSubscription: () => {
      productionApplied = true;
      return Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: "2026-08-01T00:00:00.000Z",
        is_verified: false,
      });
    },
    applyVerifiedConsumable: () => {
      productionApplied = true;
      return Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: null,
        is_verified: false,
      });
    },
    applyVerifiedSandboxReview: (authenticatedUserId, transaction) => {
      sandboxApplied = { authenticatedUserId, ...transaction };
      return Promise.resolve({
        status: "applied",
        credits_granted: 2000,
        subscription_end_date: null,
        is_verified: false,
      });
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction("Sandbox") }),
  );

  assertEquals(verified, true);
  assertEquals(response.status, 200);
  assertEquals((await response.json()).credits_granted, 2000);
  assertEquals(productionApplied, false);
  assert(sandboxApplied);
  assertEquals(sandboxApplied.authenticatedUserId, userId);
  assertEquals(sandboxApplied.environment, "Sandbox");
});

Deno.test("handler routes signed Production verified revocation only to the revocation RPC", async () => {
  let normalApplied = false;
  let revoked: Record<string, unknown> | undefined;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () => Promise.resolve(verifiedRevocationPayload),
    applyVerifiedSubscription: () => {
      normalApplied = true;
      throw new Error("normal_rpc_must_not_run");
    },
    applyVerifiedRevocation: (authenticatedUserId, transaction) => {
      revoked = { authenticatedUserId, ...transaction };
      return Promise.resolve({
        status: "applied",
        credits_granted: 0,
        subscription_end_date: null,
        is_verified: false,
      });
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );
  const body = await response.json();

  assertEquals(response.status, 200);
  assertEquals(body.credits_granted, 0);
  assertEquals(body.is_verified, false);
  assertEquals(normalApplied, false);
  assert(revoked);
  assertEquals(revoked.authenticatedUserId, userId);
  assertEquals(revoked.environment, "Production");
  assertEquals(revoked.productId, "com.x5studio.app.verified.monthly");
  assertEquals(revoked.revocationDate, "2026-07-12T00:00:00.000Z");
});

Deno.test("handler routes signed Sandbox verified revocation only to the revocation RPC", async () => {
  let sandboxPurchaseApplied = false;
  let revoked: Record<string, unknown> | undefined;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({ ...verifiedRevocationPayload, environment: "Sandbox" }),
    applyVerifiedSandboxReview: () => {
      sandboxPurchaseApplied = true;
      throw new Error("sandbox_purchase_rpc_must_not_run");
    },
    applyVerifiedRevocation: (authenticatedUserId, transaction) => {
      revoked = { authenticatedUserId, ...transaction };
      return Promise.resolve({
        status: "already_applied",
        credits_granted: 0,
        subscription_end_date: null,
        is_verified: false,
      });
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction("Sandbox") }),
  );
  const body = await response.json();

  assertEquals(response.status, 200);
  assertEquals(body.status, "already_applied");
  assertEquals(body.credits_granted, 0);
  assertEquals(sandboxPurchaseApplied, false);
  assert(revoked);
  assertEquals(revoked.environment, "Sandbox");
});

Deno.test("handler routes Production and Sandbox credit refunds only to the refund RPC", async () => {
  for (const environment of ["Production", "Sandbox"] as const) {
    let purchaseApplied = false;
    let verificationRevocationApplied = false;
    let refunded: Record<string, unknown> | undefined;
    const handler = createHandler(dependencies({
      verifySignedTransaction: () =>
        Promise.resolve({
          ...verifiedConsumableRefundPayload,
          environment,
        }),
      applyVerifiedConsumable: () => {
        purchaseApplied = true;
        throw new Error("consumable_grant_must_not_run");
      },
      applyVerifiedSandboxReview: () => {
        purchaseApplied = true;
        throw new Error("sandbox_grant_must_not_run");
      },
      applyVerifiedRevocation: () => {
        verificationRevocationApplied = true;
        throw new Error("verified_revocation_must_not_run");
      },
      applyVerifiedConsumableRefund: (authenticatedUserId, transaction) => {
        refunded = { authenticatedUserId, ...transaction };
        return Promise.resolve({
          status: "applied",
          credits_granted: 0,
          subscription_end_date: null,
          is_verified: false,
        });
      },
    }));

    const response = await handler(
      post({ signed_transaction: signedTransaction(environment) }),
    );
    const body = await response.json();

    assertEquals(response.status, 200);
    assertEquals(body.status, "applied");
    assertEquals(body.credits_granted, 0);
    assertEquals(purchaseApplied, false);
    assertEquals(verificationRevocationApplied, false);
    assert(refunded);
    assertEquals(refunded.authenticatedUserId, userId);
    assertEquals(refunded.environment, environment);
    assertEquals(refunded.productKind, "consumable");
    assertEquals(refunded.productId, "com.x5studio.app.credits.2000");
    assertEquals(refunded.quantity, 1);
    assertEquals(refunded.revocationDate, "2026-07-12T00:00:00.000Z");
  }
});

Deno.test("handler rejects Sandbox users outside the server allowlist", async () => {
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({ ...verifiedPayload, environment: "Sandbox" }),
    applyVerifiedSandboxReview: () =>
      Promise.reject(
        new EntitlementApplyError("sandbox_test_not_billable", 403),
      ),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction("Sandbox") }),
  );

  assertEquals(response.status, 403);
  assertEquals(
    (await response.json()).status,
    "sandbox_test_not_billable",
  );
});

Deno.test("handler requires the authenticated account token for Sandbox subscriptions", async () => {
  let sandboxApplied = false;
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({
        ...verifiedPayload,
        productId: "com.x5studio.app.verified.monthly",
        environment: "Sandbox",
        appAccountToken: undefined,
      }),
    applyVerifiedSandboxReview: () => {
      sandboxApplied = true;
      throw new Error("sandbox_rpc_must_not_run");
    },
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction("Sandbox") }),
  );

  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "missing_account_token");
  assertEquals(sandboxApplied, false);
});

Deno.test("Sandbox subscription account mismatches retain verified ownership only in diagnostics", async () => {
  let sandboxApplied = false;
  const logged: unknown[] = [];
  const ownerToken = "f76bc6fd-481e-4a02-aebc-a7a771f00ca2";
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({
        ...verifiedPayload,
        productId: "com.x5studio.app.verified.monthly",
        environment: "Sandbox",
        appAccountToken: ownerToken,
      }),
    applyVerifiedSandboxReview: () => {
      sandboxApplied = true;
      throw new Error("sandbox_rpc_must_not_run");
    },
    logError: (error) => logged.push(error),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction("Sandbox") }),
  );

  assertEquals(response.status, 400);
  const body = await response.json();
  assertEquals(body.status, "rejected");
  assertEquals(body.error, "account_token_mismatch");
  assertEquals("transactionId" in body, false);
  assertEquals("appAccountToken" in body, false);
  assertEquals(sandboxApplied, false);
  assertEquals(logged.length, 1);
  const diagnostic = logged[0] as Record<string, unknown>;
  assertEquals(diagnostic["transactionId"], verifiedPayload.transactionId);
  assertEquals(
    diagnostic["productId"],
    "com.x5studio.app.verified.monthly",
  );
  assertEquals(diagnostic["environment"], "Sandbox");
  assertEquals(diagnostic["appAccountToken"], ownerToken);
  assertEquals(diagnostic["authenticatedUserId"], userId);
});

Deno.test("Production subscription account mismatches retain verified ownership only in diagnostics", async () => {
  const logged: unknown[] = [];
  const ownerToken = "f76bc6fd-481e-4a02-aebc-a7a771f00ca2";
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({
        ...verifiedPayload,
        appAccountToken: ownerToken,
      }),
    applyVerifiedSubscription: () =>
      Promise.reject(
        new EntitlementApplyError(
          "rejected",
          400,
          "account_token_mismatch",
        ),
      ),
    logError: (error) => logged.push(error),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );

  assertEquals(response.status, 400);
  const body = await response.json();
  assertEquals(body.status, "rejected");
  assertEquals("error" in body, false);
  assertEquals("transactionId" in body, false);
  assertEquals("appAccountToken" in body, false);
  assertEquals(logged.length, 1);
  const diagnostic = logged[0] as Record<string, unknown>;
  assertEquals(diagnostic["transactionId"], verifiedPayload.transactionId);
  assertEquals(diagnostic["productId"], verifiedPayload.productId);
  assertEquals(diagnostic["environment"], "Production");
  assertEquals(diagnostic["appAccountToken"], ownerToken);
  assertEquals(diagnostic["authenticatedUserId"], userId);
});

Deno.test("account mismatch diagnostics retain verified transaction ownership", async () => {
  const logged: unknown[] = [];
  const ownerToken = "f76bc6fd-481e-4a02-aebc-a7a771f00ca2";
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({
        ...verifiedConsumablePayload,
        appAccountToken: ownerToken,
      }),
    logError: (error) => logged.push(error),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );

  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "account_token_mismatch");
  assertEquals(logged.length, 1);
  const diagnostic = logged[0] as Record<string, unknown>;
  assertEquals(
    diagnostic["transactionId"],
    verifiedConsumablePayload.transactionId,
  );
  assertEquals(diagnostic["productId"], verifiedConsumablePayload.productId);
  assertEquals(diagnostic["environment"], "Production");
  assertEquals(diagnostic["appAccountToken"], ownerToken);
  assertEquals(diagnostic["authenticatedUserId"], userId);
});

Deno.test("handler returns exact already_applied and owned_by_other status contracts", async () => {
  const alreadyHandler = createHandler(dependencies({
    applyVerifiedSubscription: () =>
      Promise.resolve({
        status: "already_applied",
        credits_granted: 0,
        subscription_end_date: "2026-08-01T00:00:00.000Z",
        is_verified: false,
      }),
  }));
  const already = await alreadyHandler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(already.status, 200);
  assertEquals((await already.json()).status, "already_applied");

  const ownedHandler = createHandler(dependencies({
    applyVerifiedSubscription: () =>
      Promise.reject(new EntitlementApplyError("owned_by_other", 409)),
  }));
  const owned = await ownedHandler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(owned.status, 409);
  assertEquals((await owned.json()).status, "owned_by_other");
});

Deno.test("handler distinguishes retryable Apple verification failures", async () => {
  const retryableHandler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.reject(new AppleVerificationError(true)),
  }));
  const retryable = await retryableHandler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(retryable.status, 503);
  assertEquals(
    (await retryable.json()).error,
    "apple_verification_unavailable",
  );

  const invalidHandler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.reject(new AppleVerificationError(false)),
  }));
  const invalid = await invalidHandler(
    post({ signed_transaction: signedTransaction() }),
  );
  assertEquals(invalid.status, 400);
  assertEquals(
    (await invalid.json()).error,
    "invalid_apple_transaction_unknown_verification_status",
  );
});

Deno.test("Apple verification failures retain only the safe status code", async () => {
  const logged: unknown[] = [];
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.reject(
        new AppleVerificationError(false, "INVALID_APP_IDENTIFIER"),
      ),
    logError: (error) => logged.push(error),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );

  assertEquals(response.status, 400);
  assertEquals(logged.length, 1);
  assert(logged[0] instanceof AppleVerificationError);
  assertEquals(
    (logged[0] as AppleVerificationError).diagnosticCode,
    "INVALID_APP_IDENTIFIER",
  );
  assertEquals(
    (await response.clone().json()).error,
    "invalid_apple_transaction_invalid_app_identifier",
  );
});

Deno.test("Apple verification diagnostics distinguish trust-chain failures", () => {
  assertEquals(
    appleVerificationDiagnosticCode(
      new VerificationException(VerificationStatus.VERIFICATION_FAILURE),
    ),
    "VERIFICATION_FAILURE_NO_CAUSE",
  );
  assertEquals(
    appleVerificationDiagnosticCode(
      new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error("invalid signature"),
      ),
    ),
    "VERIFICATION_FAILURE_INVALID_SIGNATURE",
  );
  assertEquals(
    appleVerificationDiagnosticCode(
      new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error("edge_jws_certificate_chain_runtime"),
      ),
    ),
    "VERIFICATION_FAILURE_EDGE_CERTIFICATE_CHAIN_RUNTIME",
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

Deno.test("handler reports the safe rejection code for production diagnostics", async () => {
  const logged: unknown[] = [];
  const handler = createHandler(dependencies({
    verifySignedTransaction: () =>
      Promise.resolve({
        ...verifiedConsumablePayload,
        quantity: 2,
      }),
    logError: (error) => logged.push(error),
  }));

  const response = await handler(
    post({ signed_transaction: signedTransaction() }),
  );

  assertEquals(response.status, 400);
  assertEquals((await response.json()).error, "invalid_quantity");
  assertEquals(logged.length, 1);
  assert(logged[0] instanceof Error);
  assertEquals((logged[0] as Error).message, "invalid_quantity");
});
