import {
  APP_APPLE_ID,
  InputError,
  parseAppAppleId,
  parseAppleRootCertificates,
  parseUntrustedTransactionEnvironment,
  parseVerifyRequestBody,
  pinnedAppleRootCertificates,
  validateVerifiedTransaction,
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
  status?: number,
): void {
  try {
    action();
  } catch (error) {
    assert(
      error instanceof InputError,
      `expected InputError, got ${String(error)}`,
    );
    assertEquals(error.code, code);
    if (status !== undefined) assertEquals(error.status, status);
    return;
  }
  throw new Error(`expected ${code} error`);
}

function unsignedJWS(payload: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(payload))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
  return `eyJhbGciOiJFUzI1NiJ9.${encoded}.signature`;
}

const validTransaction = {
  bundleId: "com.x5studio.app",
  productId: "com.x5studio.app.pro.monthly",
  transactionId: "2000000123456789",
  originalTransactionId: "2000000123400000",
  appAccountToken: "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4",
  purchaseDate: Date.UTC(2026, 6, 1),
  expiresDate: Date.UTC(2026, 7, 1),
  signedDate: Date.UTC(2026, 6, 14),
  environment: "Production",
};

const validConsumable = {
  ...validTransaction,
  productId: "com.x5studio.app.credits.1000",
  transactionId: "2000000123456790",
  originalTransactionId: "2000000123456790",
  type: "Consumable",
  quantity: 1,
  expiresDate: undefined,
};

Deno.test("request accepts only one signed_transaction field", () => {
  assertEquals(
    parseVerifyRequestBody({
      signed_transaction: "  header.payload.signature  ",
    }),
    "header.payload.signature",
  );

  assertInputError(
    () =>
      parseVerifyRequestBody({
        signed_transaction: "a.b.c",
        product_id: "forged",
      }),
    "invalid_request_body",
    400,
  );
  assertInputError(
    () => parseVerifyRequestBody({ signed_transaction: "" }),
    "invalid_signed_transaction",
  );
});

Deno.test("untrusted payload is used only to route supported App Store environments", () => {
  assertEquals(
    parseUntrustedTransactionEnvironment(
      unsignedJWS({ environment: "Production" }),
    ),
    "Production",
  );
  assertEquals(
    parseUntrustedTransactionEnvironment(
      unsignedJWS({ environment: "Sandbox" }),
    ),
    "Sandbox",
  );
  assertInputError(
    () =>
      parseUntrustedTransactionEnvironment(
        unsignedJWS({ environment: "Xcode" }),
      ),
    "invalid_environment",
  );
  assertInputError(
    () => parseUntrustedTransactionEnvironment("not-a-jws"),
    "invalid_signed_transaction",
  );
});

Deno.test("verified transaction is normalized for the service-only RPC", () => {
  const normalized = validateVerifiedTransaction(
    validTransaction,
    "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4",
    "Production",
    Date.UTC(2026, 6, 14),
  );

  assertEquals(normalized.productId, "com.x5studio.app.pro.monthly");
  assertEquals(normalized.productKind, "subscription");
  assertEquals(normalized.environment, "Production");
  assertEquals(normalized.purchaseDate, "2026-07-01T00:00:00.000Z");
  assertEquals(normalized.expiresDate, "2026-08-01T00:00:00.000Z");
  assertEquals(normalized.signedDate, "2026-07-14T00:00:00.000Z");
  assertEquals(
    normalized.appAccountToken,
    "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4",
  );
  assertEquals(normalized.revocationDate, null);
});

Deno.test("signed verified-monthly revocation is normalized even after expiry", () => {
  const now = Date.UTC(2026, 6, 14);
  const revocationDate = Date.UTC(2026, 6, 12);
  const normalized = validateVerifiedTransaction(
    {
      ...validTransaction,
      productId: "com.x5studio.app.verified.monthly",
      expiresDate: Date.UTC(2026, 6, 10),
      revocationDate,
    },
    validTransaction.appAccountToken,
    "Production",
    now,
  );

  assertEquals(normalized.productKind, "subscription");
  assertEquals(normalized.expiresDate, "2026-07-10T00:00:00.000Z");
  assertEquals(normalized.revocationDate, "2026-07-12T00:00:00.000Z");
});

Deno.test("verified-monthly revocation requires the authenticated account token", () => {
  const now = Date.UTC(2026, 6, 14);
  for (
    const appAccountToken of [
      undefined,
      "ed0fe39b-a7cd-4e64-a443-0266125ff3ea",
    ]
  ) {
    assertInputError(
      () =>
        validateVerifiedTransaction(
          {
            ...validTransaction,
            productId: "com.x5studio.app.verified.monthly",
            appAccountToken,
            revocationDate: Date.UTC(2026, 6, 12),
          },
          validTransaction.appAccountToken,
          "Production",
          now,
        ),
      appAccountToken === undefined
        ? "missing_account_token"
        : "account_token_mismatch",
    );
  }
});

Deno.test("revocation date must be signed, chronological, and not in the future", () => {
  const now = Date.UTC(2026, 6, 14);
  for (
    const revocationDate of [
      Date.UTC(2026, 5, 30),
      now + 6 * 60_000,
    ]
  ) {
    assertInputError(
      () =>
        validateVerifiedTransaction(
          {
            ...validTransaction,
            productId: "com.x5studio.app.verified.monthly",
            revocationDate,
          },
          validTransaction.appAccountToken,
          "Production",
          now,
        ),
      "invalid_revocation_date",
    );
  }
});

Deno.test("all Apple credit packs accept only signed consumable quantity-one claims", () => {
  for (
    const productId of [
      "com.x5studio.app.credits.1000",
      "com.x5studio.app.credits.2000",
      "com.x5studio.app.credits.5000",
    ]
  ) {
    const normalized = validateVerifiedTransaction(
      { ...validConsumable, productId },
      validConsumable.appAccountToken,
      "Production",
      Date.UTC(2026, 6, 14),
    );

    assertEquals(normalized.productId, productId);
    assertEquals(normalized.productKind, "consumable");
    assertEquals(normalized.quantity, 1);
    assertEquals(normalized.expiresDate, null);
  }

  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validConsumable, type: "Non-Consumable" },
        validConsumable.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "invalid_product_type",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validConsumable, quantity: 2 },
        validConsumable.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "invalid_quantity",
  );
  const implicitSingleQuantity = validateVerifiedTransaction(
    { ...validConsumable, quantity: undefined },
    validConsumable.appAccountToken,
    "Production",
    Date.UTC(2026, 6, 14),
  );
  assertEquals(implicitSingleQuantity.quantity, 1);
});

Deno.test("signed Apple credit-pack refunds preserve exact consumable identity", () => {
  const now = Date.UTC(2026, 6, 14);
  const revocationDate = Date.UTC(2026, 6, 12);

  for (
    const productId of [
      "com.x5studio.app.credits.1000",
      "com.x5studio.app.credits.2000",
      "com.x5studio.app.credits.5000",
    ]
  ) {
    const normalized = validateVerifiedTransaction(
      { ...validConsumable, productId, revocationDate },
      validConsumable.appAccountToken,
      "Production",
      now,
    );

    assertEquals(normalized.productKind, "consumable");
    assertEquals(normalized.productId, productId);
    assertEquals(normalized.quantity, 1);
    assertEquals(normalized.expiresDate, null);
    assertEquals(normalized.revocationDate, "2026-07-12T00:00:00.000Z");
  }
});

Deno.test("Apple consumables preserve account, bundle, and refund date checks", () => {
  const now = Date.UTC(2026, 6, 14);
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validConsumable, appAccountToken: undefined },
        validConsumable.appAccountToken,
        "Production",
        now,
      ),
    "missing_account_token",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        {
          ...validConsumable,
          appAccountToken: "ed0fe39b-a7cd-4e64-a443-0266125ff3ea",
        },
        validConsumable.appAccountToken,
        "Production",
        now,
      ),
    "account_token_mismatch",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validConsumable, bundleId: "attacker.app" },
        validConsumable.appAccountToken,
        "Production",
        now,
      ),
    "invalid_bundle",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        {
          ...validConsumable,
          revocationDate: validConsumable.purchaseDate - 1,
        },
        validConsumable.appAccountToken,
        "Production",
        now,
      ),
    "invalid_revocation_date",
  );
});

Deno.test("missing expiration is rejected for subscriptions", () => {
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, expiresDate: undefined },
        validTransaction.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "invalid_expiration_date",
  );
});

Deno.test("legacy nil appAccountToken is deferred to the ownership-aware RPC", () => {
  const normalized = validateVerifiedTransaction(
    { ...validTransaction, appAccountToken: undefined },
    "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4",
    "Production",
    Date.UTC(2026, 6, 14),
  );
  assertEquals(normalized.appAccountToken, null);
});

Deno.test("legacy mismatched appAccountToken is deferred to the ownership-aware RPC", () => {
  const normalized = validateVerifiedTransaction(
    validTransaction,
    "ed0fe39b-a7cd-4e64-a443-0266125ff3ea",
    "Production",
    Date.UTC(2026, 6, 14),
  );
  assertEquals(
    normalized.appAccountToken,
    "7b5a5cb8-239a-4cd1-b5d8-968cc1d437f4",
  );
});

Deno.test("verified transaction rejects wrong product, bundle, or environment", () => {
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, productId: "forged.product" },
        validTransaction.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "unknown_product",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, productId: "x5_pro_monthly" },
        validTransaction.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "unknown_product",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, bundleId: "attacker.app" },
        validTransaction.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "invalid_bundle",
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, environment: "Sandbox" },
        validTransaction.appAccountToken,
        "Production",
        Date.UTC(2026, 6, 14),
      ),
    "invalid_environment",
  );
});

Deno.test("verified transaction rejects revoked, upgraded, expired, or future-signed claims", () => {
  const now = Date.UTC(2026, 6, 14);
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, revocationDate: now - 1 },
        validTransaction.appAccountToken,
        "Production",
        now,
      ),
    "transaction_revoked",
    402,
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, isUpgraded: true },
        validTransaction.appAccountToken,
        "Production",
        now,
      ),
    "transaction_superseded",
    402,
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, expiresDate: now },
        validTransaction.appAccountToken,
        "Production",
        now,
      ),
    "transaction_expired",
    402,
  );
  assertInputError(
    () =>
      validateVerifiedTransaction(
        { ...validTransaction, signedDate: now + 6 * 60_000 },
        validTransaction.appAccountToken,
        "Production",
        now,
      ),
    "invalid_signed_date",
  );
});

Deno.test("Apple configuration parsers accept PEM or base64 DER and require a production app id", () => {
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
  assertInputError(() => parseAppAppleId("12.5"), "invalid_apple_app_id", 500);
});
