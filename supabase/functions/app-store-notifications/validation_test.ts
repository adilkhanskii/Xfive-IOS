import {
  APP_APPLE_ID,
  InputError,
  parseAppAppleId,
  parseAppleRootCertificates,
  parseNotificationRequestBody,
  parseUntrustedNotificationEnvironment,
  pinnedAppleRootCertificates,
  validateVerifiedOneTimeChargeNotification,
  validateVerifiedRefundNotification,
  validateVerifiedSubscriptionLifecycleNotification,
} from "./validation.ts";

const OFFICIAL_APPLE_ROOT_SHA256 = [
  "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
  "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
  "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
];

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

async function sha256Hex(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", Uint8Array.from(value));
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

Deno.test("runtime pins the X5 App Store application id", () => {
  assertEquals(APP_APPLE_ID, 6764340680);
});

Deno.test("runtime pins the official Apple root certificates", async () => {
  const fingerprints = await Promise.all(
    pinnedAppleRootCertificates().map(sha256Hex),
  );
  assertEquals(
    JSON.stringify(fingerprints),
    JSON.stringify(OFFICIAL_APPLE_ROOT_SHA256),
  );
});

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

function unsignedJWS(payload: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(payload))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return `header.${encoded}.signature`;
}

const userId = "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4";
const now = Date.UTC(2026, 6, 16, 12);
const outerSignedDate = Date.UTC(2026, 6, 16, 11, 59);
const purchaseDate = Date.UTC(2026, 6, 1);
const transactionSignedDate = Date.UTC(2026, 6, 16, 11, 58);
const revocationDate = Date.UTC(2026, 6, 15);

const refundNotification = {
  notificationType: "REFUND",
  notificationUUID: "8ea875c0-2a6a-4d15-8c98-ab8b28cf8aad",
  version: "2.0",
  signedDate: outerSignedDate,
  data: {
    bundleId: "com.x5studio.app",
    environment: "Production",
    signedTransactionInfo: "inner.header.signature",
  },
};

const creditTransaction = {
  bundleId: "com.x5studio.app",
  environment: "Production",
  productId: "com.x5studio.app.credits.2000",
  transactionId: "2000000123456790",
  originalTransactionId: "2000000123456790",
  appAccountToken: userId,
  type: "Consumable",
  quantity: 1,
  purchaseDate,
  signedDate: transactionSignedDate,
  revocationDate,
  revocationType: "REFUND_FULL",
  revocationPercentage: 100000,
};

const oneTimeChargeNotification = {
  notificationType: "ONE_TIME_CHARGE",
  notificationUUID: "f55c8bb4-e093-4f1e-a7fe-a247d31f79a4",
  version: "2.0",
  signedDate: outerSignedDate,
  data: {
    bundleId: "com.x5studio.app",
    environment: "Production",
    signedTransactionInfo: "inner.header.signature",
  },
};

const oneTimeChargeTransaction = {
  bundleId: "com.x5studio.app",
  environment: "Production",
  productId: "com.x5studio.app.credits.2000",
  transactionId: "2000000123456890",
  originalTransactionId: "2000000123456890",
  appAccountToken: userId,
  type: "Consumable",
  quantity: 1,
  purchaseDate,
  signedDate: transactionSignedDate,
};

const lifecycleNotification = {
  notificationType: "DID_RENEW",
  notificationUUID: "f7de2cdc-d47d-46e7-8c67-6f68b3792bc2",
  version: "2.0",
  signedDate: outerSignedDate,
  data: {
    bundleId: "com.x5studio.app",
    environment: "Production",
    signedTransactionInfo: "inner.transaction.signature",
    signedRenewalInfo: "inner.renewal.signature",
  },
};

const subscriptionTransaction = {
  bundleId: "com.x5studio.app",
  environment: "Production",
  productId: "com.x5studio.app.verified.monthly",
  transactionId: "2000000123456791",
  originalTransactionId: "2000000123456000",
  appAccountToken: userId,
  type: "Auto-Renewable Subscription",
  purchaseDate,
  expiresDate: Date.UTC(2026, 7, 1),
  signedDate: transactionSignedDate,
};

const renewalInfo = {
  environment: "Production",
  originalTransactionId: "2000000123456000",
  productId: "com.x5studio.app.verified.monthly",
  autoRenewProductId: "com.x5studio.app.verified.monthly",
  appAccountToken: userId,
  autoRenewStatus: 1,
  renewalDate: Date.UTC(2026, 7, 1),
  signedDate: transactionSignedDate,
};

Deno.test("request body accepts exactly one camel-case signedPayload", () => {
  assertEquals(
    parseNotificationRequestBody({ signedPayload: "  a.b.c  " }),
    "a.b.c",
  );
  assertInputError(
    () =>
      parseNotificationRequestBody({
        signedPayload: "a.b.c",
        transactionId: "forged",
      }),
    "invalid_request_body",
  );
  assertInputError(
    () => parseNotificationRequestBody({ signed_payload: "a.b.c" }),
    "invalid_request_body",
  );
});

Deno.test("only the unsigned outer environment is used for verifier routing", () => {
  assertEquals(
    parseUntrustedNotificationEnvironment(unsignedJWS({
      notificationType: "forged",
      data: { environment: "Production", bundleId: "attacker.app" },
    })),
    "Production",
  );
  assertEquals(
    parseUntrustedNotificationEnvironment(unsignedJWS({
      data: { environment: "Sandbox" },
    })),
    "Sandbox",
  );
  assertInputError(
    () =>
      parseUntrustedNotificationEnvironment(unsignedJWS({
        data: { environment: "Xcode" },
      })),
    "invalid_environment",
  );
});

Deno.test("summary and appData notifications are routed only for outer verification", () => {
  assertEquals(
    parseUntrustedNotificationEnvironment(unsignedJWS({
      notificationType: "RENEWAL_EXTENSION",
      summary: { environment: "Production", bundleId: "forged" },
    })),
    "Production",
  );
  assertEquals(
    parseUntrustedNotificationEnvironment(unsignedJWS({
      notificationType: "RESCIND_CONSENT",
      appData: { environment: "Sandbox", bundleId: "forged" },
    })),
    "Sandbox",
  );
});

Deno.test("unsigned notification routing rejects missing or conflicting environments", () => {
  for (
    const payload of [
      { notificationType: "TEST" },
      {
        data: { environment: "Production" },
        summary: { environment: "Sandbox" },
      },
      {
        data: { environment: "Production" },
        appData: { environment: "Production" },
      },
    ]
  ) {
    assertInputError(
      () => parseUntrustedNotificationEnvironment(unsignedJWS(payload)),
      "invalid_environment",
    );
  }
});

Deno.test("full credit refund is normalized from two verified JWS payloads", () => {
  const event = validateVerifiedRefundNotification(
    refundNotification,
    creditTransaction,
    "Production",
    now,
  );

  assertEquals(event.eventId, refundNotification.notificationUUID);
  assertEquals(event.notificationType, "REFUND");
  assertEquals(event.userId, userId);
  assertEquals(event.productKind, "consumable");
  assertEquals(event.productId, "com.x5studio.app.credits.2000");
  assertEquals(event.environment, "Production");
  assertEquals(event.quantity, 1);
  assertEquals(event.revocationPercentage, 100000);
  assertEquals(event.revocationDate, "2026-07-15T00:00:00.000Z");
  assertEquals(event.notificationSignedDate, "2026-07-16T11:59:00.000Z");
});

Deno.test("refunds accept Apple's omitted or explicit quantity one", () => {
  const consumable = validateVerifiedRefundNotification(
    refundNotification,
    { ...creditTransaction, quantity: undefined },
    "Production",
    now,
  );
  assertEquals(consumable.quantity, 1);

  const subscription = validateVerifiedRefundNotification(
    refundNotification,
    {
      ...creditTransaction,
      productId: "com.x5studio.app.verified.monthly",
      type: "Auto-Renewable Subscription",
      quantity: 1,
      expiresDate: Date.UTC(2026, 7, 1),
    },
    "Production",
    now,
  );
  assertEquals(subscription.quantity, null);
});

Deno.test("verified ONE_TIME_CHARGE normalizes an exact consumable credit grant", () => {
  const event = validateVerifiedOneTimeChargeNotification(
    oneTimeChargeNotification,
    oneTimeChargeTransaction,
    "Production",
    now,
  );

  assertEquals(event.eventId, oneTimeChargeNotification.notificationUUID);
  assertEquals(event.notificationType, "ONE_TIME_CHARGE");
  assertEquals(event.userId, userId);
  assertEquals(event.appAccountToken, userId);
  assertEquals(event.productId, "com.x5studio.app.credits.2000");
  assertEquals(event.environment, "Production");
  assertEquals(event.transactionId, oneTimeChargeTransaction.transactionId);
  assertEquals(
    event.originalTransactionId,
    oneTimeChargeTransaction.originalTransactionId,
  );
  assertEquals(event.quantity, 1);
  assertEquals(event.purchaseDate, "2026-07-01T00:00:00.000Z");
  assertEquals(event.transactionSignedDate, "2026-07-16T11:58:00.000Z");
  assertEquals(event.notificationSignedDate, "2026-07-16T11:59:00.000Z");
});

Deno.test("ONE_TIME_CHARGE treats Apple's omitted consumable quantity as one", () => {
  const event = validateVerifiedOneTimeChargeNotification(
    oneTimeChargeNotification,
    { ...oneTimeChargeTransaction, quantity: undefined },
    "Production",
    now,
  );

  assertEquals(event.quantity, 1);
});

Deno.test("ONE_TIME_CHARGE rejects any unsigned semantic mismatch before crediting", () => {
  const cases: Array<[unknown, unknown, string]> = [
    [
      { ...oneTimeChargeNotification, notificationType: "REFUND" },
      oneTimeChargeTransaction,
      "unsupported_notification_type",
    ],
    [
      { ...oneTimeChargeNotification, subtype: "INITIAL_BUY" },
      oneTimeChargeTransaction,
      "invalid_notification_subtype",
    ],
    [
      {
        ...oneTimeChargeNotification,
        data: { ...oneTimeChargeNotification.data, bundleId: "attacker.app" },
      },
      oneTimeChargeTransaction,
      "invalid_bundle",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, environment: "Sandbox" },
      "invalid_environment",
    ],
    [
      oneTimeChargeNotification,
      {
        ...oneTimeChargeTransaction,
        productId: "com.x5studio.app.credits.9999",
      },
      "unsupported_product",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, type: "Non-Consumable" },
      "invalid_product_type",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, quantity: 2 },
      "invalid_quantity",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, appAccountToken: undefined },
      "missing_account_token",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, appAccountToken: "not-a-uuid" },
      "invalid_app_account_token",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, originalTransactionId: "different" },
      "invalid_original_transaction_id",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, expiresDate: Date.UTC(2026, 7, 1) },
      "invalid_expiration_date",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, revocationDate },
      "transaction_revoked",
    ],
    [
      oneTimeChargeNotification,
      { ...oneTimeChargeTransaction, signedDate: purchaseDate - 10 * 60_000 },
      "invalid_signed_date",
    ],
  ];

  for (const [notification, transaction, code] of cases) {
    assertInputError(
      () =>
        validateVerifiedOneTimeChargeNotification(
          notification,
          transaction,
          "Production",
          now,
        ),
      code,
      code === "unsupported_notification_type" || code === "unsupported_product"
        ? 200
        : 400,
    );
  }
});

Deno.test("verified Sandbox ONE_TIME_CHARGE remains explicitly identified for allowlist routing", () => {
  const event = validateVerifiedOneTimeChargeNotification(
    {
      ...oneTimeChargeNotification,
      data: { ...oneTimeChargeNotification.data, environment: "Sandbox" },
    },
    { ...oneTimeChargeTransaction, environment: "Sandbox" },
    "Sandbox",
    now,
  );
  assertEquals(event.environment, "Sandbox");
  assertEquals(event.userId, userId);
});

Deno.test("prorated credit refund preserves Apple's milliunit percentage", () => {
  const event = validateVerifiedRefundNotification(
    refundNotification,
    {
      ...creditTransaction,
      revocationType: "REFUND_PRORATED",
      revocationPercentage: 67932,
    },
    "Production",
    now,
  );
  assertEquals(event.revocationPercentage, 67932);
});

Deno.test("partial refund fields must be internally consistent", () => {
  for (
    const transaction of [
      {
        ...creditTransaction,
        revocationType: "REFUND_PRORATED",
        revocationPercentage: 100000,
      },
      {
        ...creditTransaction,
        revocationType: "REFUND_PRORATED",
        revocationPercentage: 0,
      },
      {
        ...creditTransaction,
        revocationType: "REFUND_FULL",
        revocationPercentage: 50000,
      },
      {
        ...creditTransaction,
        revocationType: "FAMILY_REVOKE",
        revocationPercentage: 100000,
      },
      { ...creditTransaction, revocationPercentage: 100001 },
    ]
  ) {
    assertInputError(
      () =>
        validateVerifiedRefundNotification(
          refundNotification,
          transaction,
          "Production",
          now,
        ),
      "invalid_revocation_percentage",
    );
  }
});

Deno.test("verified subscription refund remains atomic even when price refund is prorated", () => {
  const event = validateVerifiedRefundNotification(
    refundNotification,
    {
      ...creditTransaction,
      productId: "com.x5studio.app.verified.monthly",
      type: "Auto-Renewable Subscription",
      quantity: undefined,
      expiresDate: Date.UTC(2026, 7, 1),
      revocationType: "REFUND_PRORATED",
      revocationPercentage: 50000,
    },
    "Production",
    now,
  );
  assertEquals(event.productKind, "subscription");
  assertEquals(event.quantity, null);
  assertEquals(event.revocationPercentage, 50000);
  assertEquals(event.expiresDate, "2026-08-01T00:00:00.000Z");
});

Deno.test("verified subscription renewal is normalized only after all three Apple JWS payloads agree", () => {
  const event = validateVerifiedSubscriptionLifecycleNotification(
    lifecycleNotification,
    subscriptionTransaction,
    renewalInfo,
    "Production",
    now,
  );

  assertEquals(event.eventId, lifecycleNotification.notificationUUID);
  assertEquals(event.notificationType, "DID_RENEW");
  assertEquals(event.userId, userId);
  assertEquals(event.productId, "com.x5studio.app.verified.monthly");
  assertEquals(event.originalTransactionId, "2000000123456000");
  assertEquals(event.expiresDate, "2026-08-01T00:00:00.000Z");
  assertEquals(event.renewalSignedDate, "2026-07-16T11:58:00.000Z");
  assertEquals(event.gracePeriodExpiresDate, null);
  assertEquals(event.revocationDate, null);
});

Deno.test("renewal identity, product, environment and account token must match the transaction", () => {
  for (
    const [renewal, code] of [
      [
        { ...renewalInfo, originalTransactionId: "different" },
        "invalid_original_transaction_id",
      ],
      [
        { ...renewalInfo, productId: "com.x5studio.app.pro.monthly" },
        "unsupported_product",
      ],
      [{ ...renewalInfo, environment: "Sandbox" }, "invalid_environment"],
      [{
        ...renewalInfo,
        appAccountToken: "56ea681b-f6c2-4a48-8d53-ea8e678ec5e5",
      }, "account_token_mismatch"],
    ] as const
  ) {
    assertInputError(
      () =>
        validateVerifiedSubscriptionLifecycleNotification(
          lifecycleNotification,
          subscriptionTransaction,
          renewal,
          "Production",
          now,
        ),
      code,
      code === "unsupported_product" ? 200 : 400,
    );
  }
});

Deno.test("billing recovery renewal accepts a completed grace period before the new paid expiry", () => {
  const event = validateVerifiedSubscriptionLifecycleNotification(
    lifecycleNotification,
    subscriptionTransaction,
    {
      ...renewalInfo,
      gracePeriodExpiresDate: Date.UTC(2026, 6, 15),
    },
    "Production",
    now,
  );
  assertEquals(event.notificationType, "DID_RENEW");
  assertEquals(
    event.gracePeriodExpiresDate,
    "2026-07-15T00:00:00.000Z",
  );
});

Deno.test("billing recovery renewal accepts a still-future grace date carried by Apple", () => {
  const event = validateVerifiedSubscriptionLifecycleNotification(
    lifecycleNotification,
    subscriptionTransaction,
    {
      ...renewalInfo,
      gracePeriodExpiresDate: Date.UTC(2026, 6, 18),
    },
    "Production",
    now,
  );
  assertEquals(event.notificationType, "DID_RENEW");
  assertEquals(
    event.gracePeriodExpiresDate,
    "2026-07-18T00:00:00.000Z",
  );
});

Deno.test("billing failure grace period preserves the signed future service deadline", () => {
  const gracePeriodExpiresDate = Date.UTC(2026, 6, 20);
  const event = validateVerifiedSubscriptionLifecycleNotification(
    {
      ...lifecycleNotification,
      notificationType: "DID_FAIL_TO_RENEW",
      subtype: "GRACE_PERIOD",
    },
    {
      ...subscriptionTransaction,
      expiresDate: Date.UTC(2026, 6, 16, 11),
    },
    {
      ...renewalInfo,
      gracePeriodExpiresDate,
    },
    "Production",
    now,
  );
  assertEquals(event.notificationType, "DID_FAIL_TO_RENEW");
  assertEquals(event.notificationSubtype, "GRACE_PERIOD");
  assertEquals(
    event.gracePeriodExpiresDate,
    "2026-07-20T00:00:00.000Z",
  );

  assertInputError(
    () =>
      validateVerifiedSubscriptionLifecycleNotification(
        { ...lifecycleNotification, notificationType: "DID_FAIL_TO_RENEW" },
        subscriptionTransaction,
        renewalInfo,
        "Production",
        now,
      ),
    "unsupported_notification_type",
    200,
  );
});

Deno.test("expiry, grace-period expiry and revoke lifecycle events have strict signed shapes", () => {
  const expiredTransaction = {
    ...subscriptionTransaction,
    expiresDate: Date.UTC(2026, 6, 15),
  };

  for (const notificationType of ["EXPIRED", "GRACE_PERIOD_EXPIRED"] as const) {
    const event = validateVerifiedSubscriptionLifecycleNotification(
      { ...lifecycleNotification, notificationType },
      expiredTransaction,
      notificationType === "GRACE_PERIOD_EXPIRED"
        ? { ...renewalInfo, gracePeriodExpiresDate: Date.UTC(2026, 6, 15) }
        : renewalInfo,
      "Production",
      now,
    );
    assertEquals(event.notificationType, notificationType);
  }

  const revoked = validateVerifiedSubscriptionLifecycleNotification(
    { ...lifecycleNotification, notificationType: "REVOKE" },
    {
      ...subscriptionTransaction,
      revocationDate,
      revocationReason: 1,
    },
    renewalInfo,
    "Production",
    now,
  );
  assertEquals(revoked.revocationDate, "2026-07-15T00:00:00.000Z");

  assertInputError(
    () =>
      validateVerifiedSubscriptionLifecycleNotification(
        { ...lifecycleNotification, notificationType: "REVOKE" },
        subscriptionTransaction,
        renewalInfo,
        "Production",
        now,
      ),
    "invalid_revocation_date",
  );
});

Deno.test("refund reversal requires Apple to omit every revocation field", () => {
  const reversed = validateVerifiedRefundNotification(
    { ...refundNotification, notificationType: "REFUND_REVERSED" },
    {
      ...creditTransaction,
      revocationDate: undefined,
      revocationType: undefined,
      revocationPercentage: undefined,
    },
    "Production",
    now,
  );
  assertEquals(reversed.notificationType, "REFUND_REVERSED");
  assertEquals(reversed.revocationDate, null);
  assertEquals(reversed.revocationPercentage, null);

  assertInputError(
    () =>
      validateVerifiedRefundNotification(
        { ...refundNotification, notificationType: "REFUND_REVERSED" },
        creditTransaction,
        "Production",
        now,
      ),
    "invalid_refund_reversal",
  );
});

Deno.test("outer and inner signed identity must agree with X5", () => {
  for (
    const [outer, inner, code] of [
      [
        {
          ...refundNotification,
          data: { ...refundNotification.data, bundleId: "attacker.app" },
        },
        creditTransaction,
        "invalid_bundle",
      ],
      [
        refundNotification,
        { ...creditTransaction, bundleId: "attacker.app" },
        "invalid_bundle",
      ],
      [
        refundNotification,
        { ...creditTransaction, environment: "Sandbox" },
        "invalid_environment",
      ],
      [
        refundNotification,
        { ...creditTransaction, appAccountToken: undefined },
        "missing_account_token",
      ],
      [refundNotification, {
        ...creditTransaction,
        appAccountToken: "not-a-uuid",
      }, "invalid_app_account_token"],
    ] as const
  ) {
    assertInputError(
      () =>
        validateVerifiedRefundNotification(
          outer,
          inner,
          "Production",
          now,
        ),
      code,
    );
  }
});

Deno.test("unsupported signed products are acknowledged separately from invalid data", () => {
  assertInputError(
    () =>
      validateVerifiedRefundNotification(
        refundNotification,
        { ...creditTransaction, productId: "com.x5studio.app.retired.monthly" },
        "Production",
        now,
      ),
    "unsupported_product",
    200,
  );
});

Deno.test("Apple verifier configuration accepts local certificate formats", () => {
  const pem = "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----";
  const fromPem = parseAppleRootCertificates(pem, undefined);
  assertEquals(fromPem.length, 1);
  assertEquals(Array.from(fromPem[0]).join(","), "1,2,3");

  const fromBase64 = parseAppleRootCertificates(
    undefined,
    JSON.stringify(["AQID", "BAUG"]),
  );
  assertEquals(fromBase64.length, 2);
  assertEquals(Array.from(fromBase64[1]).join(","), "4,5,6");
  assertEquals(parseAppAppleId("1234567890"), 1234567890);

  assertInputError(
    () => parseAppleRootCertificates(undefined, undefined),
    "missing_apple_root_certificates",
    500,
  );
  assertInputError(
    () => parseAppAppleId(undefined),
    "missing_apple_app_id",
    500,
  );
});
