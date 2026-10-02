export type AppStoreEnvironment = "Production" | "Sandbox";

export const APP_BUNDLE_ID = "com.x5studio.app";
export const APP_APPLE_ID = 6764340680;

// Public DER roots downloaded from Apple's PKI directory. Keep the SHA-256
// fingerprints locked by validation_test.ts so deployment secrets cannot
// silently replace the App Store trust anchors.
const PINNED_APPLE_ROOT_CERTIFICATES_BASE64 = [
  "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",
] as const;

export function pinnedAppleRootCertificates(): Uint8Array[] {
  return PINNED_APPLE_ROOT_CERTIFICATES_BASE64.map(decodeCertificateBase64);
}
export const VERIFIED_MONTHLY_PRODUCT_ID = "com.x5studio.app.verified.monthly";
export const LEGACY_PLAN_PRODUCT_IDS = new Set([
  "com.x5studio.app.lite.monthly",
  "com.x5studio.app.pro.monthly",
  "com.x5studio.app.max.monthly",
]);
export const CONSUMABLE_PRODUCT_IDS = new Set([
  "com.x5studio.app.credits.1000",
  "com.x5studio.app.credits.2000",
  "com.x5studio.app.credits.5000",
]);

const MAX_SIGNED_PAYLOAD_LENGTH = 128 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60_000;
// Apple bills an auto-renewal up to 24 hours before the current period ends
// and signs the renewal transaction, renewal info and DID_RENEW notification
// at that moment. The renewal's purchaseDate is the start of the new period,
// so its signatures legitimately precede purchaseDate, and its first delivery
// arrives before purchaseDate, by up to a day. One extra hour absorbs Apple
// batching and clock skew; anything earlier or further ahead is rejected.
export const MAX_RENEWAL_EARLY_SIGNING_MS = 25 * 60 * 60_000;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class InputError extends Error {
  constructor(readonly code: string, readonly status = 400) {
    super(code);
  }
}

export interface RefundNotificationEvent {
  eventId: string;
  notificationType: "REFUND" | "REFUND_REVERSED";
  userId: string;
  productKind: "consumable" | "subscription" | "legacy_subscription";
  productId: string;
  environment: AppStoreEnvironment;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken: string | null;
  purchaseDate: string;
  expiresDate: string | null;
  transactionSignedDate: string;
  notificationSignedDate: string;
  revocationDate: string | null;
  revocationPercentage: number | null;
  quantity: number | null;
}

export interface OneTimeChargeNotificationEvent {
  eventId: string;
  notificationType: "ONE_TIME_CHARGE";
  userId: string;
  productId: string;
  environment: AppStoreEnvironment;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken: string;
  purchaseDate: string;
  transactionSignedDate: string;
  notificationSignedDate: string;
  quantity: 1;
}

export type SubscriptionLifecycleNotificationType =
  | "SUBSCRIBED"
  | "DID_RENEW"
  | "DID_FAIL_TO_RENEW"
  | "EXPIRED"
  | "GRACE_PERIOD_EXPIRED"
  | "REVOKE";

export interface SubscriptionLifecycleNotificationEvent {
  eventId: string;
  notificationType: SubscriptionLifecycleNotificationType;
  notificationSubtype: string | null;
  userId: string;
  productId: string;
  environment: AppStoreEnvironment;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken: string | null;
  purchaseDate: string;
  expiresDate: string;
  transactionSignedDate: string;
  renewalSignedDate: string;
  notificationSignedDate: string;
  revocationDate: string | null;
  gracePeriodExpiresDate: string | null;
  autoRenewStatus: number | null;
}

const SUBSCRIPTION_LIFECYCLE_TYPES = new Set<string>([
  "SUBSCRIBED",
  "DID_RENEW",
  "DID_FAIL_TO_RENEW",
  "EXPIRED",
  "GRACE_PERIOD_EXPIRED",
  "REVOKE",
]);

export function isSubscriptionLifecycleNotificationType(
  value: unknown,
): value is SubscriptionLifecycleNotificationType {
  return typeof value === "string" && SUBSCRIPTION_LIFECYCLE_TYPES.has(value);
}

export function parseNotificationRequestBody(_body: unknown): string {
  if (!isRecord(_body) || Array.isArray(_body)) {
    throw new InputError("invalid_request_body");
  }
  const keys = Object.keys(_body);
  if (keys.length !== 1 || keys[0] !== "signedPayload") {
    throw new InputError("invalid_request_body");
  }
  if (typeof _body.signedPayload !== "string") {
    throw new InputError("invalid_signed_payload");
  }
  const value = _body.signedPayload.trim();
  if (!value || value.length > MAX_SIGNED_PAYLOAD_LENGTH) {
    throw new InputError("invalid_signed_payload");
  }
  return value;
}

export function parseUntrustedNotificationEnvironment(
  _signedPayload: string,
): AppStoreEnvironment {
  const segments = _signedPayload.split(".");
  if (
    segments.length !== 3 || segments.some((segment) => segment.length === 0)
  ) {
    throw new InputError("invalid_signed_payload");
  }

  let payload: unknown;
  try {
    payload = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(segments[1])),
    );
  } catch {
    throw new InputError("invalid_signed_payload");
  }
  if (!isRecord(payload)) {
    throw new InputError("invalid_signed_payload");
  }
  const carriers = [payload.data, payload.summary, payload.appData]
    .filter((value) => isRecord(value));
  if (carriers.length !== 1) {
    throw new InputError("invalid_environment");
  }
  const environment = carriers[0].environment;
  if (environment === "Production" || environment === "Sandbox") {
    return environment;
  }
  throw new InputError("invalid_environment");
}

export function validateVerifiedOneTimeChargeNotification(
  _notification: unknown,
  _transaction: unknown,
  _expectedEnvironment: AppStoreEnvironment,
  _nowMs: number,
): OneTimeChargeNotificationEvent {
  if (!isRecord(_notification) || !isRecord(_notification.data)) {
    throw new InputError("invalid_notification_payload");
  }
  if (!isRecord(_transaction)) {
    throw new InputError("invalid_transaction_payload");
  }
  if (_notification.notificationType !== "ONE_TIME_CHARGE") {
    throw new InputError("unsupported_notification_type", 200);
  }
  if (_notification.subtype !== undefined && _notification.subtype !== null) {
    throw new InputError("invalid_notification_subtype");
  }

  const eventId = requiredUUID(
    _notification.notificationUUID,
    "invalid_notification_uuid",
  );
  const version = requiredString(
    _notification.version,
    "invalid_notification_version",
    16,
  );
  if (!version.startsWith("2.")) {
    throw new InputError("invalid_notification_version");
  }
  if (
    _notification.data.bundleId !== APP_BUNDLE_ID ||
    _transaction.bundleId !== APP_BUNDLE_ID
  ) {
    throw new InputError("invalid_bundle");
  }
  if (
    _notification.data.environment !== _expectedEnvironment ||
    _transaction.environment !== _expectedEnvironment
  ) {
    throw new InputError("invalid_environment");
  }
  requiredString(
    _notification.data.signedTransactionInfo,
    "missing_signed_transaction_info",
    MAX_SIGNED_PAYLOAD_LENGTH,
  );

  const productId = requiredString(
    _transaction.productId,
    "unsupported_product",
  );
  if (!CONSUMABLE_PRODUCT_IDS.has(productId)) {
    throw new InputError("unsupported_product", 200);
  }
  if (_transaction.type !== "Consumable") {
    throw new InputError("invalid_product_type");
  }
  if (
    _transaction.quantity !== undefined &&
    _transaction.quantity !== null &&
    _transaction.quantity !== 1
  ) {
    throw new InputError("invalid_quantity");
  }
  if (
    _transaction.expiresDate !== undefined &&
    _transaction.expiresDate !== null
  ) {
    throw new InputError("invalid_expiration_date");
  }
  if (
    _transaction.revocationDate != null ||
    _transaction.revocationReason != null ||
    _transaction.revocationType != null ||
    _transaction.revocationPercentage != null
  ) {
    throw new InputError("transaction_revoked");
  }

  const transactionId = requiredString(
    _transaction.transactionId,
    "invalid_transaction_id",
    255,
  );
  const originalTransactionId = requiredString(
    _transaction.originalTransactionId,
    "invalid_original_transaction_id",
    255,
  );
  if (originalTransactionId !== transactionId) {
    throw new InputError("invalid_original_transaction_id");
  }
  const appAccountToken = requiredUUID(
    _transaction.appAccountToken,
    _transaction.appAccountToken === undefined ||
      _transaction.appAccountToken === null
      ? "missing_account_token"
      : "invalid_app_account_token",
  ).toLowerCase();

  const purchaseDateMs = requiredTimestamp(
    _transaction.purchaseDate,
    "invalid_purchase_date",
  );
  const transactionSignedDateMs = requiredTimestamp(
    _transaction.signedDate,
    "invalid_signed_date",
  );
  const notificationSignedDateMs = requiredTimestamp(
    _notification.signedDate,
    "invalid_notification_signed_date",
  );
  for (
    const [value, code] of [
      [purchaseDateMs, "invalid_purchase_date"],
      [transactionSignedDateMs, "invalid_signed_date"],
      [notificationSignedDateMs, "invalid_notification_signed_date"],
    ] as const
  ) {
    if (value > _nowMs + MAX_CLOCK_SKEW_MS) throw new InputError(code);
  }
  if (
    transactionSignedDateMs < purchaseDateMs - MAX_CLOCK_SKEW_MS ||
    notificationSignedDateMs < transactionSignedDateMs - MAX_CLOCK_SKEW_MS
  ) {
    throw new InputError("invalid_signed_date");
  }

  return {
    eventId,
    notificationType: "ONE_TIME_CHARGE",
    userId: appAccountToken,
    productId,
    environment: _expectedEnvironment,
    transactionId,
    originalTransactionId,
    appAccountToken,
    purchaseDate: new Date(purchaseDateMs).toISOString(),
    transactionSignedDate: new Date(transactionSignedDateMs).toISOString(),
    notificationSignedDate: new Date(notificationSignedDateMs).toISOString(),
    quantity: 1,
  };
}

export function validateVerifiedRefundNotification(
  _notification: unknown,
  _transaction: unknown,
  _expectedEnvironment: AppStoreEnvironment,
  _nowMs: number,
): RefundNotificationEvent {
  if (!isRecord(_notification) || !isRecord(_notification.data)) {
    throw new InputError("invalid_notification_payload");
  }
  if (!isRecord(_transaction)) {
    throw new InputError("invalid_transaction_payload");
  }

  const notificationType = _notification.notificationType;
  if (
    notificationType !== "REFUND" && notificationType !== "REFUND_REVERSED"
  ) {
    throw new InputError("unsupported_notification_type", 200);
  }
  const eventId = requiredUUID(
    _notification.notificationUUID,
    "invalid_notification_uuid",
  );
  const version = requiredString(
    _notification.version,
    "invalid_notification_version",
    16,
  );
  if (!version.startsWith("2.")) {
    throw new InputError("invalid_notification_version");
  }
  if (
    _notification.data.bundleId !== APP_BUNDLE_ID ||
    _transaction.bundleId !== APP_BUNDLE_ID
  ) {
    throw new InputError("invalid_bundle");
  }
  if (
    _notification.data.environment !== _expectedEnvironment ||
    _transaction.environment !== _expectedEnvironment
  ) {
    throw new InputError("invalid_environment");
  }
  requiredString(
    _notification.data.signedTransactionInfo,
    "missing_signed_transaction_info",
    MAX_SIGNED_PAYLOAD_LENGTH,
  );

  const productId = requiredString(
    _transaction.productId,
    "unsupported_product",
  );
  const productKind = CONSUMABLE_PRODUCT_IDS.has(productId)
    ? "consumable"
    : productId === VERIFIED_MONTHLY_PRODUCT_ID
    ? "subscription"
    : _expectedEnvironment === "Production" &&
        LEGACY_PLAN_PRODUCT_IDS.has(productId)
    ? "legacy_subscription"
    : null;
  if (!productKind) throw new InputError("unsupported_product", 200);

  const transactionId = requiredString(
    _transaction.transactionId,
    "invalid_transaction_id",
    255,
  );
  const originalTransactionId = requiredString(
    _transaction.originalTransactionId,
    "invalid_original_transaction_id",
    255,
  );
  const accountTokenMissing = _transaction.appAccountToken === undefined ||
    _transaction.appAccountToken === null;
  const appAccountToken = accountTokenMissing
    ? productKind === "legacy_subscription" ? null : (() => {
      throw new InputError("missing_account_token");
    })()
    : requiredUUID(
      _transaction.appAccountToken,
      "invalid_app_account_token",
    ).toLowerCase();

  if (productKind === "consumable") {
    if (_transaction.type !== "Consumable") {
      throw new InputError("invalid_product_type");
    }
    if (
      _transaction.quantity !== undefined &&
      _transaction.quantity !== null &&
      _transaction.quantity !== 1
    ) {
      throw new InputError("invalid_quantity");
    }
    if (
      _transaction.expiresDate !== undefined &&
      _transaction.expiresDate !== null
    ) {
      throw new InputError("invalid_expiration_date");
    }
  } else {
    if (_transaction.type !== "Auto-Renewable Subscription") {
      throw new InputError("invalid_product_type");
    }
    if (
      (productKind === "subscription" ||
        productKind === "legacy_subscription") &&
      _transaction.quantity !== undefined &&
      _transaction.quantity !== null &&
      _transaction.quantity !== 1
    ) {
      throw new InputError("invalid_quantity");
    }
  }

  const purchaseDateMs = requiredTimestamp(
    _transaction.purchaseDate,
    "invalid_purchase_date",
  );
  const transactionSignedDateMs = requiredTimestamp(
    _transaction.signedDate,
    "invalid_signed_date",
  );
  const notificationSignedDateMs = requiredTimestamp(
    _notification.signedDate,
    "invalid_notification_signed_date",
  );
  for (
    const [value, code] of [
      [purchaseDateMs, "invalid_purchase_date"],
      [transactionSignedDateMs, "invalid_signed_date"],
      [notificationSignedDateMs, "invalid_notification_signed_date"],
    ] as const
  ) {
    if (value > _nowMs + MAX_CLOCK_SKEW_MS) throw new InputError(code);
  }
  if (
    transactionSignedDateMs < purchaseDateMs - MAX_CLOCK_SKEW_MS ||
    notificationSignedDateMs < transactionSignedDateMs - MAX_CLOCK_SKEW_MS
  ) {
    throw new InputError("invalid_signed_date");
  }

  let expiresDate: string | null = null;
  if (
    productKind === "subscription" || productKind === "legacy_subscription"
  ) {
    const expiresDateMs = requiredTimestamp(
      _transaction.expiresDate,
      "invalid_expiration_date",
    );
    if (expiresDateMs <= purchaseDateMs) {
      throw new InputError("invalid_expiration_date");
    }
    expiresDate = new Date(expiresDateMs).toISOString();
  }

  let normalizedRevocationDate: string | null = null;
  let normalizedRevocationPercentage: number | null = null;
  if (notificationType === "REFUND") {
    const revocationDateMs = requiredTimestamp(
      _transaction.revocationDate,
      "invalid_revocation_date",
    );
    if (
      revocationDateMs < purchaseDateMs ||
      revocationDateMs > _nowMs + MAX_CLOCK_SKEW_MS ||
      transactionSignedDateMs < revocationDateMs - MAX_CLOCK_SKEW_MS
    ) {
      throw new InputError("invalid_revocation_date");
    }
    normalizedRevocationDate = new Date(revocationDateMs).toISOString();
    normalizedRevocationPercentage = normalizeRefundPercentage(
      _transaction.revocationType,
      _transaction.revocationPercentage,
    );
  } else {
    if (
      _transaction.revocationDate !== undefined ||
      _transaction.revocationReason !== undefined ||
      _transaction.revocationType !== undefined ||
      _transaction.revocationPercentage !== undefined
    ) {
      throw new InputError("invalid_refund_reversal");
    }
  }

  return {
    eventId,
    notificationType,
    userId: appAccountToken ?? "",
    productKind,
    productId,
    environment: _expectedEnvironment,
    transactionId,
    originalTransactionId,
    appAccountToken,
    purchaseDate: new Date(purchaseDateMs).toISOString(),
    expiresDate,
    transactionSignedDate: new Date(transactionSignedDateMs).toISOString(),
    notificationSignedDate: new Date(notificationSignedDateMs).toISOString(),
    revocationDate: normalizedRevocationDate,
    revocationPercentage: normalizedRevocationPercentage,
    quantity: productKind === "consumable" ||
        productKind === "legacy_subscription"
      ? 1
      : null,
  };
}

export function validateVerifiedSubscriptionLifecycleNotification(
  _notification: unknown,
  _transaction: unknown,
  _renewal: unknown,
  _expectedEnvironment: AppStoreEnvironment,
  _nowMs: number,
): SubscriptionLifecycleNotificationEvent {
  if (!isRecord(_notification) || !isRecord(_notification.data)) {
    throw new InputError("invalid_notification_payload");
  }
  if (!isRecord(_transaction)) {
    throw new InputError("invalid_transaction_payload");
  }
  if (!isRecord(_renewal)) {
    throw new InputError("invalid_renewal_payload");
  }

  const notificationType = _notification.notificationType;
  if (!isSubscriptionLifecycleNotificationType(notificationType)) {
    throw new InputError("unsupported_notification_type", 200);
  }
  const eventId = requiredUUID(
    _notification.notificationUUID,
    "invalid_notification_uuid",
  );
  const version = requiredString(
    _notification.version,
    "invalid_notification_version",
    16,
  );
  if (!version.startsWith("2.")) {
    throw new InputError("invalid_notification_version");
  }
  let notificationSubtype: string | null = null;
  if (_notification.subtype !== undefined && _notification.subtype !== null) {
    notificationSubtype = requiredString(
      _notification.subtype,
      "invalid_notification_subtype",
      64,
    );
  }
  if (
    notificationType === "DID_FAIL_TO_RENEW" &&
    notificationSubtype !== "GRACE_PERIOD"
  ) {
    throw new InputError("unsupported_notification_type", 200);
  }

  if (
    _notification.data.bundleId !== APP_BUNDLE_ID ||
    _transaction.bundleId !== APP_BUNDLE_ID
  ) {
    throw new InputError("invalid_bundle");
  }
  if (
    _notification.data.environment !== _expectedEnvironment ||
    _transaction.environment !== _expectedEnvironment ||
    _renewal.environment !== _expectedEnvironment
  ) {
    throw new InputError("invalid_environment");
  }
  requiredString(
    _notification.data.signedTransactionInfo,
    "missing_signed_transaction_info",
    MAX_SIGNED_PAYLOAD_LENGTH,
  );
  requiredString(
    _notification.data.signedRenewalInfo,
    "missing_signed_renewal_info",
    MAX_SIGNED_PAYLOAD_LENGTH,
  );

  const productId = requiredString(
    _transaction.productId,
    "unsupported_product",
  );
  const isVerifiedSubscription = productId === VERIFIED_MONTHLY_PRODUCT_ID;
  const isLegacyPlan = LEGACY_PLAN_PRODUCT_IDS.has(productId);
  if (!isVerifiedSubscription && !isLegacyPlan) {
    throw new InputError("unsupported_product", 200);
  }
  // The retired paid-plan products need only the signed grant events. Their
  // expiry remains timestamp-driven and refunds use the separate refund JWS
  // path, so accepting terminal lifecycle events here would widen authority
  // without helping a build-179 purchase settle.
  if (
    isLegacyPlan &&
    (_expectedEnvironment !== "Production" ||
      (notificationType !== "SUBSCRIBED" && notificationType !== "DID_RENEW"))
  ) {
    throw new InputError("unsupported_notification_type", 200);
  }
  const renewalProducts = [_renewal.productId, _renewal.autoRenewProductId]
    .filter((value) => value !== undefined && value !== null);
  if (
    renewalProducts.length === 0 ||
    renewalProducts.some((value) => value !== productId)
  ) {
    throw new InputError("unsupported_product", 200);
  }
  if (_transaction.type !== "Auto-Renewable Subscription") {
    throw new InputError("invalid_product_type");
  }
  if (
    _transaction.quantity !== undefined &&
    _transaction.quantity !== null &&
    _transaction.quantity !== 1
  ) {
    throw new InputError("invalid_quantity");
  }

  const transactionId = requiredString(
    _transaction.transactionId,
    "invalid_transaction_id",
    255,
  );
  const originalTransactionId = requiredString(
    _transaction.originalTransactionId,
    "invalid_original_transaction_id",
    255,
  );
  if (
    requiredString(
      _renewal.originalTransactionId,
      "invalid_original_transaction_id",
      255,
    ) !== originalTransactionId
  ) {
    throw new InputError("invalid_original_transaction_id");
  }

  const transactionTokenMissing = _transaction.appAccountToken === undefined ||
    _transaction.appAccountToken === null;
  const renewalTokenMissing = _renewal.appAccountToken === undefined ||
    _renewal.appAccountToken === null;
  const transactionAccountToken = transactionTokenMissing ? null : requiredUUID(
    _transaction.appAccountToken,
    "invalid_app_account_token",
  ).toLowerCase();
  const renewalAccountToken = renewalTokenMissing ? null : requiredUUID(
    _renewal.appAccountToken,
    "invalid_app_account_token",
  ).toLowerCase();
  let appAccountToken: string | null;
  if (transactionTokenMissing || renewalTokenMissing) {
    if (!isLegacyPlan) throw new InputError("missing_account_token");
    if (!transactionTokenMissing || !renewalTokenMissing) {
      throw new InputError("account_token_mismatch");
    }
    appAccountToken = null;
  } else {
    if (renewalAccountToken !== transactionAccountToken) {
      throw new InputError("account_token_mismatch");
    }
    appAccountToken = transactionAccountToken;
  }

  const purchaseDateMs = requiredTimestamp(
    _transaction.purchaseDate,
    "invalid_purchase_date",
  );
  const expiresDateMs = requiredTimestamp(
    _transaction.expiresDate,
    "invalid_expiration_date",
  );
  const transactionSignedDateMs = requiredTimestamp(
    _transaction.signedDate,
    "invalid_signed_date",
  );
  const renewalSignedDateMs = requiredTimestamp(
    _renewal.signedDate,
    "invalid_renewal_signed_date",
  );
  const notificationSignedDateMs = requiredTimestamp(
    _notification.signedDate,
    "invalid_notification_signed_date",
  );

  if (expiresDateMs <= purchaseDateMs) {
    throw new InputError("invalid_expiration_date");
  }
  // Only the period start may lie ahead (an early-billed renewal). Every
  // signature must already exist, and the notification is signed last.
  if (purchaseDateMs > _nowMs + MAX_RENEWAL_EARLY_SIGNING_MS) {
    throw new InputError("invalid_purchase_date");
  }
  for (
    const [value, code] of [
      [transactionSignedDateMs, "invalid_signed_date"],
      [renewalSignedDateMs, "invalid_renewal_signed_date"],
      [notificationSignedDateMs, "invalid_notification_signed_date"],
    ] as const
  ) {
    if (value > _nowMs + MAX_CLOCK_SKEW_MS) throw new InputError(code);
  }
  if (
    transactionSignedDateMs < purchaseDateMs - MAX_RENEWAL_EARLY_SIGNING_MS ||
    renewalSignedDateMs < purchaseDateMs - MAX_RENEWAL_EARLY_SIGNING_MS ||
    notificationSignedDateMs < transactionSignedDateMs - MAX_CLOCK_SKEW_MS ||
    notificationSignedDateMs < renewalSignedDateMs - MAX_CLOCK_SKEW_MS
  ) {
    throw new InputError("invalid_signed_date");
  }

  if (_renewal.renewalDate !== undefined && _renewal.renewalDate !== null) {
    const renewalDateMs = requiredTimestamp(
      _renewal.renewalDate,
      "invalid_renewal_date",
    );
    if (renewalDateMs < purchaseDateMs) {
      throw new InputError("invalid_renewal_date");
    }
  }

  let autoRenewStatus: number | null = null;
  if (
    _renewal.autoRenewStatus !== undefined && _renewal.autoRenewStatus !== null
  ) {
    if (_renewal.autoRenewStatus !== 0 && _renewal.autoRenewStatus !== 1) {
      throw new InputError("invalid_auto_renew_status");
    }
    autoRenewStatus = _renewal.autoRenewStatus;
  }

  let gracePeriodExpiresDate: string | null = null;
  if (
    _renewal.gracePeriodExpiresDate !== undefined &&
    _renewal.gracePeriodExpiresDate !== null
  ) {
    const graceMs = requiredTimestamp(
      _renewal.gracePeriodExpiresDate,
      "invalid_grace_period_expiration_date",
    );
    if (
      ((notificationType === "DID_FAIL_TO_RENEW" ||
        notificationType === "GRACE_PERIOD_EXPIRED") &&
        graceMs < expiresDateMs) ||
      (notificationType === "DID_FAIL_TO_RENEW" && graceMs <= _nowMs) ||
      (notificationType === "GRACE_PERIOD_EXPIRED" &&
        graceMs > notificationSignedDateMs + MAX_CLOCK_SKEW_MS)
    ) {
      throw new InputError("invalid_grace_period_expiration_date");
    }
    gracePeriodExpiresDate = new Date(graceMs).toISOString();
  }

  let normalizedRevocationDate: string | null = null;
  if (notificationType === "REVOKE") {
    const revocationDateMs = requiredTimestamp(
      _transaction.revocationDate,
      "invalid_revocation_date",
    );
    if (
      revocationDateMs < purchaseDateMs ||
      revocationDateMs > _nowMs + MAX_CLOCK_SKEW_MS ||
      transactionSignedDateMs < revocationDateMs - MAX_CLOCK_SKEW_MS
    ) {
      throw new InputError("invalid_revocation_date");
    }
    normalizedRevocationDate = new Date(revocationDateMs).toISOString();
  } else if (
    _transaction.revocationDate !== undefined ||
    _transaction.revocationReason !== undefined
  ) {
    throw new InputError("invalid_revocation_date");
  }

  if (
    (notificationType === "EXPIRED" ||
      notificationType === "GRACE_PERIOD_EXPIRED") &&
    expiresDateMs > notificationSignedDateMs + MAX_CLOCK_SKEW_MS
  ) {
    throw new InputError("invalid_expiration_date");
  }
  if (
    (notificationType === "GRACE_PERIOD_EXPIRED" ||
      notificationType === "DID_FAIL_TO_RENEW") &&
    gracePeriodExpiresDate === null
  ) {
    throw new InputError("invalid_grace_period_expiration_date");
  }

  return {
    eventId,
    notificationType,
    notificationSubtype,
    userId: appAccountToken ?? "",
    productId,
    environment: _expectedEnvironment,
    transactionId,
    originalTransactionId,
    appAccountToken,
    purchaseDate: new Date(purchaseDateMs).toISOString(),
    expiresDate: new Date(expiresDateMs).toISOString(),
    transactionSignedDate: new Date(transactionSignedDateMs).toISOString(),
    renewalSignedDate: new Date(renewalSignedDateMs).toISOString(),
    notificationSignedDate: new Date(notificationSignedDateMs).toISOString(),
    revocationDate: normalizedRevocationDate,
    gracePeriodExpiresDate,
    autoRenewStatus,
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
    for (const match of matches) {
      certificates.push(decodeCertificateBase64(match[1]));
    }
  }

  if (base64?.trim()) {
    let encodedCertificates: unknown;
    try {
      encodedCertificates = JSON.parse(base64);
    } catch {
      throw new InputError("invalid_apple_root_certificates", 500);
    }
    if (
      !Array.isArray(encodedCertificates) ||
      encodedCertificates.length === 0
    ) {
      throw new InputError("invalid_apple_root_certificates", 500);
    }
    for (const encoded of encodedCertificates) {
      if (typeof encoded !== "string") {
        throw new InputError("invalid_apple_root_certificates", 500);
      }
      certificates.push(decodeCertificateBase64(encoded));
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

function normalizeRefundPercentage(
  revocationType: unknown,
  percentage: unknown,
): number {
  if (
    percentage !== undefined &&
    (typeof percentage !== "number" ||
      !Number.isSafeInteger(percentage) ||
      percentage <= 0 ||
      percentage > 100000)
  ) {
    throw new InputError("invalid_revocation_percentage");
  }

  if (revocationType === undefined || revocationType === null) {
    return percentage === undefined ? 100000 : percentage as number;
  }
  if (revocationType === "REFUND_FULL") {
    if (percentage !== undefined && percentage !== 100000) {
      throw new InputError("invalid_revocation_percentage");
    }
    return 100000;
  }
  if (revocationType === "REFUND_PRORATED") {
    if (
      typeof percentage !== "number" || percentage <= 0 || percentage >= 100000
    ) {
      throw new InputError("invalid_revocation_percentage");
    }
    return percentage;
  }
  throw new InputError("invalid_revocation_percentage");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requiredString(value: unknown, code: string, max = 128): string {
  if (typeof value !== "string") throw new InputError(code);
  const normalized = value.trim();
  if (!normalized || normalized.length > max) throw new InputError(code);
  return normalized;
}

function requiredUUID(value: unknown, code: string): string {
  const normalized = requiredString(value, code);
  if (!UUID_PATTERN.test(normalized)) throw new InputError(code);
  return normalized;
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
  const decoded = atob(
    standard.padEnd(Math.ceil(standard.length / 4) * 4, "="),
  );
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function decodeCertificateBase64(value: string): Uint8Array {
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
