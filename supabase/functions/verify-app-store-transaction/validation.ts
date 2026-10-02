export type AppStoreEnvironment = "Production" | "Sandbox";
export type AppStoreProductKind = "subscription" | "consumable";

export const APP_BUNDLE_ID = "com.x5studio.app";
export const APP_APPLE_ID = 6764340680;
export const VERIFIED_MONTHLY_PRODUCT_ID = "com.x5studio.app.verified.monthly";
export const SUBSCRIPTION_PRODUCT_IDS = new Set([
  "com.x5studio.app.lite.monthly",
  "com.x5studio.app.pro.monthly",
  "com.x5studio.app.max.monthly",
  VERIFIED_MONTHLY_PRODUCT_ID,
]);
export const CONSUMABLE_PRODUCT_IDS = new Set([
  "com.x5studio.app.credits.1000",
  "com.x5studio.app.credits.2000",
  "com.x5studio.app.credits.5000",
]);
export const ALLOWED_PRODUCT_IDS = new Set([
  ...SUBSCRIPTION_PRODUCT_IDS,
  ...CONSUMABLE_PRODUCT_IDS,
]);

// Public DER roots downloaded from Apple's PKI directory. Keep the SHA-256
// fingerprints locked by validation_test.ts so deployment secrets cannot
// silently replace the App Store trust anchors.
const PINNED_APPLE_ROOT_CERTIFICATES_BASE64 = [
  "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",
] as const;

export function pinnedAppleRootCertificates(): Uint8Array[] {
  return PINNED_APPLE_ROOT_CERTIFICATES_BASE64.map(decodeBase64);
}

const MAX_SIGNED_TRANSACTION_LENGTH = 64 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60_000;
// Apple bills an auto-renewal up to 24 hours before the current period ends
// and signs the renewal transaction at that moment. Its purchaseDate is the
// start of the new period, so a renewal from StoreKit may be signed, and sent
// by the app, up to a day before purchaseDate. One extra hour absorbs clock
// skew. Consumables keep the strict clock-skew window.
export const MAX_RENEWAL_EARLY_SIGNING_MS = 25 * 60 * 60_000;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class InputError extends Error {
  constructor(
    readonly code: string,
    readonly status = 400,
  ) {
    super(code);
  }
}

export interface VerifiedTransactionPayload {
  bundleId?: string;
  productId?: string;
  transactionId?: string;
  originalTransactionId?: string;
  appAccountToken?: string;
  purchaseDate?: number;
  expiresDate?: number;
  signedDate?: number;
  revocationDate?: number;
  isUpgraded?: boolean;
  environment?: string;
  type?: string;
  quantity?: number;
}

export interface NormalizedTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  productKind: AppStoreProductKind;
  environment: AppStoreEnvironment;
  appAccountToken: string | null;
  purchaseDate: string;
  expiresDate: string | null;
  signedDate: string;
  revocationDate: string | null;
  quantity: number | null;
}

export function parseVerifyRequestBody(body: unknown): string {
  if (!isRecord(body) || Array.isArray(body)) {
    throw new InputError("invalid_request_body");
  }

  const keys = Object.keys(body);
  if (keys.length !== 1 || keys[0] !== "signed_transaction") {
    throw new InputError("invalid_request_body");
  }

  const signedTransaction = body.signed_transaction;
  if (typeof signedTransaction !== "string") {
    throw new InputError("invalid_signed_transaction");
  }

  const trimmed = signedTransaction.trim();
  if (!trimmed || trimmed.length > MAX_SIGNED_TRANSACTION_LENGTH) {
    throw new InputError("invalid_signed_transaction");
  }
  return trimmed;
}

/**
 * Reads the unsigned payload solely to choose the correct Apple verifier.
 * No value from this function is trusted until SignedDataVerifier succeeds.
 */
export function parseUntrustedTransactionEnvironment(
  signedTransaction: string,
): AppStoreEnvironment {
  const segments = signedTransaction.split(".");
  if (
    segments.length !== 3 || segments.some((segment) => segment.length === 0)
  ) {
    throw new InputError("invalid_signed_transaction");
  }

  let payload: unknown;
  try {
    payload = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(segments[1])),
    );
  } catch {
    throw new InputError("invalid_signed_transaction");
  }

  if (!isRecord(payload)) throw new InputError("invalid_signed_transaction");
  if (
    payload.environment === "Production" || payload.environment === "Sandbox"
  ) {
    return payload.environment;
  }
  throw new InputError("invalid_environment");
}

export function validateVerifiedTransaction(
  payload: VerifiedTransactionPayload,
  userId: string,
  expectedEnvironment: AppStoreEnvironment,
  nowMs: number,
): NormalizedTransaction {
  if (!UUID_PATTERN.test(userId)) throw new InputError("invalid_user_id", 401);
  if (payload.bundleId !== APP_BUNDLE_ID) {
    throw new InputError("invalid_bundle");
  }
  if (payload.environment !== expectedEnvironment) {
    throw new InputError("invalid_environment");
  }

  const productId = requiredString(payload.productId, "unknown_product");
  if (!ALLOWED_PRODUCT_IDS.has(productId)) {
    throw new InputError("unknown_product");
  }
  const productKind: AppStoreProductKind = CONSUMABLE_PRODUCT_IDS.has(productId)
    ? "consumable"
    : "subscription";
  if (productKind === "consumable") {
    if (payload.type !== "Consumable") {
      throw new InputError("invalid_product_type");
    }
    // Apple's decoded transaction model marks quantity as optional. StoreKit
    // may omit the implicit single unit, but any explicit value other than one
    // must still be rejected so a signed claim can never multiply credits.
    if (payload.quantity !== undefined && payload.quantity !== 1) {
      throw new InputError("invalid_quantity");
    }
  }

  const transactionId = requiredString(
    payload.transactionId,
    "invalid_transaction_id",
  );
  const originalTransactionId = requiredString(
    payload.originalTransactionId,
    "invalid_original_transaction_id",
  );

  let appAccountToken: string | null = null;
  if (
    payload.appAccountToken !== undefined && payload.appAccountToken !== null
  ) {
    if (
      typeof payload.appAccountToken !== "string" ||
      !UUID_PATTERN.test(payload.appAccountToken)
    ) {
      throw new InputError("invalid_app_account_token");
    }
    appAccountToken = payload.appAccountToken.toLowerCase();
    // Ownership is decided by the service-only RPC after Apple verification.
    // Normal purchases still require token == authenticated user, while two
    // explicitly grandfathered legacy chains can bind an older random token
    // only when original transaction, user, product, and token all match the
    // closed server-side allowlist.
  }
  if (productKind === "consumable") {
    if (appAccountToken === null) {
      throw new InputError("missing_account_token");
    }
    if (appAccountToken !== userId.toLowerCase()) {
      throw new InputError("account_token_mismatch");
    }
  }

  const isRevocation = payload.revocationDate !== undefined &&
    payload.revocationDate !== null;
  if (isRevocation) {
    if (
      productKind === "subscription" &&
      productId !== VERIFIED_MONTHLY_PRODUCT_ID
    ) {
      throw new InputError("transaction_revoked", 402);
    }
    if (appAccountToken === null) {
      throw new InputError("missing_account_token");
    }
    if (appAccountToken !== userId.toLowerCase()) {
      throw new InputError("account_token_mismatch");
    }
  }
  if (payload.isUpgraded === true) {
    throw new InputError("transaction_superseded", 402);
  }

  const purchaseDateMs = requiredTimestamp(
    payload.purchaseDate,
    "invalid_purchase_date",
  );
  const signedDateMs = requiredTimestamp(
    payload.signedDate,
    "invalid_signed_date",
  );
  const maxPurchaseLeadMs = productKind === "subscription"
    ? MAX_RENEWAL_EARLY_SIGNING_MS
    : MAX_CLOCK_SKEW_MS;
  if (purchaseDateMs > nowMs + maxPurchaseLeadMs) {
    throw new InputError("invalid_purchase_date");
  }
  if (signedDateMs > nowMs + MAX_CLOCK_SKEW_MS) {
    throw new InputError("invalid_signed_date");
  }
  if (
    productKind === "subscription" &&
    signedDateMs < purchaseDateMs - MAX_RENEWAL_EARLY_SIGNING_MS
  ) {
    throw new InputError("invalid_signed_date");
  }

  let revocationDate: string | null = null;
  if (isRevocation) {
    const revocationDateMs = requiredTimestamp(
      payload.revocationDate,
      "invalid_revocation_date",
    );
    if (
      revocationDateMs < purchaseDateMs ||
      revocationDateMs > nowMs + MAX_CLOCK_SKEW_MS ||
      revocationDateMs > signedDateMs + MAX_CLOCK_SKEW_MS
    ) {
      throw new InputError("invalid_revocation_date");
    }
    revocationDate = new Date(revocationDateMs).toISOString();
  }

  let expiresDate: string | null = null;
  if (productKind === "subscription") {
    const expiresDateMs = requiredTimestamp(
      payload.expiresDate,
      "invalid_expiration_date",
    );
    if (expiresDateMs <= nowMs && !isRevocation) {
      throw new InputError("transaction_expired", 402);
    }
    if (expiresDateMs <= purchaseDateMs) {
      throw new InputError("invalid_expiration_date");
    }
    expiresDate = new Date(expiresDateMs).toISOString();
  }

  return {
    transactionId,
    originalTransactionId,
    productId,
    productKind,
    environment: expectedEnvironment,
    appAccountToken,
    purchaseDate: new Date(purchaseDateMs).toISOString(),
    expiresDate,
    signedDate: new Date(signedDateMs).toISOString(),
    revocationDate,
    quantity: productKind === "consumable" ? 1 : null,
  };
}

export function parseAppleRootCertificates(
  pem: string | undefined,
  base64: string | undefined,
): Uint8Array[] {
  const certificates: Uint8Array[] = [];

  if (pem?.trim()) {
    const matches = [
      ...pem.matchAll(
        /-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/g,
      ),
    ];
    if (matches.length === 0) {
      throw new InputError("invalid_apple_root_certificates", 500);
    }
    for (const match of matches) certificates.push(decodeBase64(match[1]));
  }

  if (base64?.trim()) {
    let encodedCertificates: unknown;
    try {
      encodedCertificates = JSON.parse(base64);
    } catch {
      encodedCertificates = base64.split(/[\n,;]/).map((value) => value.trim())
        .filter(Boolean);
    }
    if (
      !Array.isArray(encodedCertificates) || encodedCertificates.length === 0
    ) {
      throw new InputError("invalid_apple_root_certificates", 500);
    }
    for (const encoded of encodedCertificates) {
      if (typeof encoded !== "string") {
        throw new InputError("invalid_apple_root_certificates", 500);
      }
      certificates.push(decodeBase64(encoded));
    }
  }

  if (certificates.length === 0) {
    throw new InputError("missing_apple_root_certificates", 500);
  }
  if (certificates.length > 10) {
    throw new InputError("invalid_apple_root_certificates", 500);
  }
  return certificates;
}

export function parseAppAppleId(raw: string | undefined): number {
  if (!raw?.trim()) throw new InputError("missing_apple_app_id", 500);
  if (!/^\d+$/.test(raw.trim())) {
    throw new InputError("invalid_apple_app_id", 500);
  }
  const parsed = Number(raw.trim());
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new InputError("invalid_apple_app_id", 500);
  }
  return parsed;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requiredString(value: unknown, code: string): string {
  if (typeof value !== "string") throw new InputError(code);
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 128) throw new InputError(code);
  return trimmed;
}

function requiredTimestamp(value: unknown, code: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new InputError(code);
  }
  return value;
}

function decodeBase64URL(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid base64url");
  const standard = value.replaceAll("-", "+").replaceAll("_", "/");
  return decodeBase64(standard.padEnd(Math.ceil(standard.length / 4) * 4, "="));
}

function decodeBase64(value: string): Uint8Array {
  const compact = value.replace(/\s+/g, "");
  if (
    !compact || compact.length % 4 === 1 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(compact)
  ) {
    throw new InputError("invalid_apple_root_certificates", 500);
  }
  try {
    const decoded = atob(compact);
    if (!decoded) throw new Error("empty certificate");
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch (error) {
    if (error instanceof InputError) throw error;
    throw new InputError("invalid_apple_root_certificates", 500);
  }
}
