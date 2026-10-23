import { Buffer } from "node:buffer";
import {
  Environment,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { createClient } from "@supabase/supabase-js";
import { EdgeCompatibleSignedDataVerifier } from "./edge_jws_verifier.ts";
import {
  APP_APPLE_ID,
  APP_BUNDLE_ID,
  AppStoreEnvironment,
  InputError,
  isSubscriptionLifecycleNotificationType,
  OneTimeChargeNotificationEvent,
  parseNotificationRequestBody,
  parseUntrustedNotificationEnvironment,
  pinnedAppleRootCertificates,
  RefundNotificationEvent,
  SubscriptionLifecycleNotificationEvent,
  validateVerifiedOneTimeChargeNotification,
  validateVerifiedRefundNotification,
  validateVerifiedSubscriptionLifecycleNotification,
} from "./validation.ts";

export interface NotificationApplyResult {
  status: "applied" | "already_applied" | "ignored_stale";
}

export interface NotificationHandlerDependencies {
  now(): number;
  verifyNotification(
    signedPayload: string,
    environment: AppStoreEnvironment,
  ): Promise<unknown>;
  verifyTransaction(
    signedTransaction: string,
    environment: AppStoreEnvironment,
  ): Promise<unknown>;
  verifyRenewalInfo(
    signedRenewalInfo: string,
    environment: AppStoreEnvironment,
  ): Promise<unknown>;
  resolveNotificationUser(
    event: RefundNotificationEvent | SubscriptionLifecycleNotificationEvent,
  ): Promise<string>;
  applyNotification(
    event: RefundNotificationEvent,
  ): Promise<NotificationApplyResult>;
  applyOneTimeCharge(
    event: OneTimeChargeNotificationEvent,
  ): Promise<NotificationApplyResult>;
  applyLifecycleNotification(
    event: SubscriptionLifecycleNotificationEvent,
  ): Promise<NotificationApplyResult>;
  logError(error: unknown): void;
  logDiagnostic?(entry: NotificationDiagnostic): void;
}

// Every non-applied outcome is logged with its exact reason. Only verified
// Apple routing fields are included: no transaction ids, tokens or users.
export interface NotificationDiagnostic {
  outcome: "ignored" | "rejected";
  http_status: number;
  code: string;
  reason?: string;
  environment?: AppStoreEnvironment;
  notification_type?: string;
  notification_subtype?: string;
  notification_uuid?: string;
}

type NotificationDiagnosticContext = Pick<
  NotificationDiagnostic,
  | "environment"
  | "notification_type"
  | "notification_subtype"
  | "notification_uuid"
>;

export class AppleVerificationError extends Error {
  constructor(
    readonly retryable: boolean,
    readonly diagnosticCode = "UNKNOWN_VERIFICATION_ERROR",
    readonly phase: "notification" | "transaction" | "renewal" = "notification",
  ) {
    super("apple_verification_failed");
  }
}

export class NotificationApplyError extends Error {
  constructor(
    readonly code: string,
    readonly httpStatus: number,
    readonly reason: string = code,
  ) {
    super(code);
  }
}

class NotificationRpcFailure extends Error {
  constructor(message: string, readonly reason: string) {
    super(message);
  }
}

// Database functions raise bare snake_case reason codes. Anything else is
// reduced to a constraint name or an error code, never row details.
export function safeRpcReason(
  error: { code?: unknown; message?: unknown },
): string {
  const message = typeof error.message === "string" ? error.message.trim() : "";
  if (/^[a-z][a-z0-9_]{0,63}$/.test(message)) return message;
  const constraint = message.match(
    /violates [a-z -]*constraint "([A-Za-z0-9_]{1,63})"/,
  );
  if (constraint) return `constraint_${constraint[1].toLowerCase()}`;
  return typeof error.code === "string" && /^[0-9A-Z]{5,8}$/.test(error.code)
    ? `code_${error.code}`
    : "code_unknown";
}

export function createHandler(
  _dependencies: NotificationHandlerDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "POST") {
      return jsonResponse(
        { status: "rejected", error: "method_not_allowed" },
        405,
        { Allow: "POST" },
      );
    }

    const context: NotificationDiagnosticContext = {};
    const diagnose = (
      outcome: NotificationDiagnostic["outcome"],
      httpStatus: number,
      code: string,
      reason?: string,
    ) => {
      try {
        _dependencies.logDiagnostic?.({
          outcome,
          http_status: httpStatus,
          code,
          ...(reason && reason !== code ? { reason } : {}),
          ...context,
        });
      } catch {
        // Diagnostics must never change the response Apple receives.
      }
    };

    try {
      if (
        !request.headers.get("Content-Type")?.toLowerCase().startsWith(
          "application/json",
        )
      ) {
        throw new InputError("invalid_content_type", 415);
      }

      const rawBody = await readJSONBody(request);
      const signedPayload = parseNotificationRequestBody(rawBody);

      // The unsigned data is used only to choose one of two verifier instances.
      // Bundle, environment, event type and transaction identity remain untrusted
      // until the corresponding Apple JWS verification succeeds below.
      const environment = parseUntrustedNotificationEnvironment(signedPayload);
      const notification = await _dependencies.verifyNotification(
        signedPayload,
        environment,
      );

      if (!isRecord(notification)) {
        throw new InputError("invalid_notification_payload");
      }
      Object.assign(
        context,
        notificationDiagnosticContext(notification, environment),
      );
      const isRefund = notification.notificationType === "REFUND" ||
        notification.notificationType === "REFUND_REVERSED";
      const isOneTimeCharge = notification.notificationType ===
        "ONE_TIME_CHARGE";
      const isLifecycle = isSubscriptionLifecycleNotificationType(
        notification.notificationType,
      );
      if (!isRefund && !isOneTimeCharge && !isLifecycle) {
        diagnose("ignored", 200, "unsupported_notification_type");
        return jsonResponse({ status: "ignored" }, 200);
      }
      if (!isRecord(notification.data)) {
        throw new InputError("invalid_notification_payload");
      }
      const signedTransaction = notification.data.signedTransactionInfo;
      if (
        typeof signedTransaction !== "string" ||
        !signedTransaction.trim() ||
        signedTransaction.length > 128 * 1024
      ) {
        throw new InputError("missing_signed_transaction_info");
      }

      const transaction = await _dependencies.verifyTransaction(
        signedTransaction,
        environment,
      );
      let result: NotificationApplyResult;
      if (isOneTimeCharge) {
        const event = validateVerifiedOneTimeChargeNotification(
          notification,
          transaction,
          environment,
          _dependencies.now(),
        );
        result = await _dependencies.applyOneTimeCharge(event);
      } else if (isRefund) {
        const unresolvedEvent = validateVerifiedRefundNotification(
          notification,
          transaction,
          environment,
          _dependencies.now(),
        );
        const event = await withResolvedNotificationUser(
          unresolvedEvent,
          _dependencies,
        );
        result = await _dependencies.applyNotification(event);
      } else {
        const signedRenewalInfo = notification.data.signedRenewalInfo;
        if (
          typeof signedRenewalInfo !== "string" ||
          !signedRenewalInfo.trim() ||
          signedRenewalInfo.length > 128 * 1024
        ) {
          throw new InputError("missing_signed_renewal_info");
        }
        const renewal = await _dependencies.verifyRenewalInfo(
          signedRenewalInfo,
          environment,
        );
        const unresolvedEvent =
          validateVerifiedSubscriptionLifecycleNotification(
            notification,
            transaction,
            renewal,
            environment,
            _dependencies.now(),
          );
        const event = await withResolvedNotificationUser(
          unresolvedEvent,
          _dependencies,
        );
        result = await _dependencies.applyLifecycleNotification(event);
      }
      return jsonResponse({ status: result.status }, 200);
    } catch (error) {
      if (error instanceof InputError) {
        if (error.status === 200) {
          diagnose("ignored", 200, error.code);
          return jsonResponse(
            { status: "ignored", reason: error.code },
            200,
          );
        }
        diagnose("rejected", error.status, error.code);
        return jsonResponse(
          { status: "rejected", error: error.code },
          error.status,
        );
      }
      if (error instanceof AppleVerificationError) {
        const code = error.retryable
          ? "apple_verification_unavailable"
          : `invalid_apple_${error.phase}_${
            safeAppleVerificationCode(error.diagnosticCode)
          }`;
        const status = error.retryable ? 503 : 400;
        diagnose("rejected", status, code);
        return jsonResponse({ status: "rejected", error: code }, status);
      }
      if (error instanceof NotificationApplyError) {
        diagnose("rejected", error.httpStatus, error.code, error.reason);
        return jsonResponse(
          { status: "rejected", error: error.code },
          error.httpStatus,
        );
      }
      _dependencies.logError(error);
      diagnose(
        "rejected",
        500,
        "server_error",
        error instanceof NotificationRpcFailure ? error.reason : undefined,
      );
      return jsonResponse({ status: "rejected", error: "server_error" }, 500);
    }
  };
}

function notificationDiagnosticContext(
  notification: Record<string, unknown>,
  environment: AppStoreEnvironment,
): NotificationDiagnosticContext {
  const token = (value: unknown, pattern: RegExp) =>
    typeof value === "string" && pattern.test(value) ? value : undefined;
  const context: NotificationDiagnosticContext = { environment };
  const type = token(notification.notificationType, /^[A-Z0-9_]{1,64}$/);
  const subtype = token(notification.subtype, /^[A-Z0-9_]{1,64}$/);
  const uuid = token(
    notification.notificationUUID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
  );
  if (type) context.notification_type = type;
  if (subtype) context.notification_subtype = subtype;
  if (uuid) context.notification_uuid = uuid.toLowerCase();
  return context;
}

function safeAppleVerificationCode(code: string): string {
  switch (code) {
    case "VERIFICATION_FAILURE":
    case "VERIFICATION_FAILURE_NO_CAUSE":
    case "VERIFICATION_FAILURE_INVALID_SIGNATURE":
    case "VERIFICATION_FAILURE_INVALID_JWT":
    case "VERIFICATION_FAILURE_TYPE_ERROR":
    case "VERIFICATION_FAILURE_OTHER_CAUSE":
    case "VERIFICATION_FAILURE_EDGE_SEGMENTS_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_PAYLOAD_DECODE_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_PAYLOAD_VALIDATE_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_HEADER_DECODE_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_EFFECTIVE_DATE_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_CERTIFICATE_CHAIN_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_KEY_CONSTRAINTS_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_SIGNATURE_DECODE_RUNTIME":
    case "VERIFICATION_FAILURE_EDGE_SIGNATURE_VERIFY_RUNTIME":
    case "INVALID_APP_IDENTIFIER":
    case "INVALID_ENVIRONMENT":
    case "INVALID_CHAIN_LENGTH":
    case "INVALID_CERTIFICATE":
    case "FAILURE":
    case "UNKNOWN_VERIFICATION_STATUS":
    case "UNKNOWN_VERIFICATION_ERROR":
      return code.toLowerCase();
    default:
      return "unknown_verification_status";
  }
}

async function withResolvedNotificationUser<
  T extends RefundNotificationEvent | SubscriptionLifecycleNotificationEvent,
>(event: T, dependencies: NotificationHandlerDependencies): Promise<T> {
  const resolvedUserId = await dependencies.resolveNotificationUser(event);
  if (
    typeof resolvedUserId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(resolvedUserId)
  ) {
    throw new Error("invalid_notification_user_resolution");
  }
  const canonicalUserId = resolvedUserId.toLowerCase();
  return {
    ...event,
    userId: canonicalUserId,
    appAccountToken: event.appAccountToken ?? canonicalUserId,
  };
}

const MAX_BODY_BYTES = 132 * 1024;

async function readJSONBody(request: Request): Promise<unknown> {
  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength !== null) {
    const parsed = Number(declaredLength);
    if (Number.isFinite(parsed) && parsed > MAX_BODY_BYTES) {
      throw new InputError("request_too_large", 413);
    }
  }

  const reader = request.body?.getReader();
  if (!reader) throw new InputError("invalid_request_body");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new InputError("request_too_large", 413);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new InputError("invalid_request_body");
  }
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  headers: HeadersInit = {},
): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...Object.fromEntries(new Headers(headers).entries()),
    },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

let appleRootCertificates: Buffer[] | undefined;
const appleVerifiers = new Map<AppStoreEnvironment, SignedDataVerifier>();

function getAppleRootCertificates(): Buffer[] {
  if (appleRootCertificates) return appleRootCertificates;
  appleRootCertificates = pinnedAppleRootCertificates().map((certificate) =>
    Buffer.from(certificate)
  );
  return appleRootCertificates;
}

function getAppleVerifier(
  environment: AppStoreEnvironment,
): SignedDataVerifier {
  const cached = appleVerifiers.get(environment);
  if (cached) return cached;
  // The Apple library keeps certificate-chain, Apple OID, JWS signature,
  // bundle, environment, and signed-date checks when online checks are false.
  // Its live OCSP responder validation is incompatible with Supabase Deno.
  const verifier = new EdgeCompatibleSignedDataVerifier(
    getAppleRootCertificates(),
    false,
    environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
    APP_BUNDLE_ID,
    environment === "Production" ? APP_APPLE_ID : undefined,
  );
  appleVerifiers.set(environment, verifier);
  return verifier;
}

function appleVerificationError(
  error: unknown,
  phase: "notification" | "transaction" | "renewal",
): AppleVerificationError {
  return new AppleVerificationError(
    error instanceof VerificationException &&
      error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
    appleVerificationDiagnosticCode(error),
    phase,
  );
}

export function appleVerificationDiagnosticCode(error: unknown): string {
  if (!(error instanceof VerificationException)) {
    return "UNKNOWN_VERIFICATION_ERROR";
  }

  const cause = error.cause;
  const causeRecord = typeof cause === "object" && cause !== null
    ? cause as unknown as Record<string, unknown>
    : undefined;
  const message = typeof causeRecord?.message === "string"
    ? causeRecord.message.toLowerCase()
    : "";
  const edgeRuntimeStage: Record<string, string> = {
    edge_jws_segments_runtime: "EDGE_SEGMENTS_RUNTIME",
    edge_jws_payload_decode_runtime: "EDGE_PAYLOAD_DECODE_RUNTIME",
    edge_jws_payload_validate_runtime: "EDGE_PAYLOAD_VALIDATE_RUNTIME",
    edge_jws_header_decode_runtime: "EDGE_HEADER_DECODE_RUNTIME",
    edge_jws_effective_date_runtime: "EDGE_EFFECTIVE_DATE_RUNTIME",
    edge_jws_certificate_chain_runtime: "EDGE_CERTIFICATE_CHAIN_RUNTIME",
    edge_jws_key_constraints_runtime: "EDGE_KEY_CONSTRAINTS_RUNTIME",
    edge_jws_signature_decode_runtime: "EDGE_SIGNATURE_DECODE_RUNTIME",
    edge_jws_signature_verify_runtime: "EDGE_SIGNATURE_VERIFY_RUNTIME",
    edge_x509_leaf_parse_runtime: "EDGE_X509_LEAF_PARSE_RUNTIME",
    edge_x509_intermediate_parse_runtime:
      "EDGE_X509_INTERMEDIATE_PARSE_RUNTIME",
    edge_x509_root_parse_runtime: "EDGE_X509_ROOT_PARSE_RUNTIME",
    edge_x509_root_signature_runtime: "EDGE_X509_ROOT_SIGNATURE_RUNTIME",
    edge_x509_intermediate_constraints_runtime:
      "EDGE_X509_INTERMEDIATE_CONSTRAINTS_RUNTIME",
    edge_x509_chain_validation_runtime: "EDGE_X509_CHAIN_VALIDATION_RUNTIME",
    edge_x509_certificate_dates_runtime: "EDGE_X509_CERTIFICATE_DATES_RUNTIME",
    edge_x509_leaf_public_key_runtime: "EDGE_X509_LEAF_PUBLIC_KEY_RUNTIME",
  };
  const safeEdgeRuntimeStage = edgeRuntimeStage[message];
  if (safeEdgeRuntimeStage) {
    return `VERIFICATION_FAILURE_${safeEdgeRuntimeStage}`;
  }

  const status = VerificationStatus[error.status] ??
    "UNKNOWN_VERIFICATION_STATUS";
  if (error.status !== VerificationStatus.VERIFICATION_FAILURE) return status;
  if (!message) return `${status}_NO_CAUSE`;

  if (message.includes("invalid signature")) {
    return `${status}_INVALID_SIGNATURE`;
  }
  if (
    message.includes("jwt malformed") ||
    message.includes("invalid token") ||
    message.includes("invalid algorithm")
  ) {
    return `${status}_INVALID_JWT`;
  }
  if (causeRecord?.name === "TypeError") return `${status}_TYPE_ERROR`;
  return `${status}_OTHER_CAUSE`;
}

async function verifyNotification(
  signedPayload: string,
  environment: AppStoreEnvironment,
): Promise<ResponseBodyV2DecodedPayload> {
  try {
    return await getAppleVerifier(environment).verifyAndDecodeNotification(
      signedPayload,
    );
  } catch (error) {
    throw appleVerificationError(error, "notification");
  }
}

async function verifyTransaction(
  signedTransaction: string,
  environment: AppStoreEnvironment,
): Promise<JWSTransactionDecodedPayload> {
  try {
    return await getAppleVerifier(environment).verifyAndDecodeTransaction(
      signedTransaction,
    );
  } catch (error) {
    throw appleVerificationError(error, "transaction");
  }
}

async function verifyRenewalInfo(
  signedRenewalInfo: string,
  environment: AppStoreEnvironment,
): Promise<JWSRenewalInfoDecodedPayload> {
  try {
    return await getAppleVerifier(environment).verifyAndDecodeRenewalInfo(
      signedRenewalInfo,
    );
  } catch (error) {
    throw appleVerificationError(error, "renewal");
  }
}

async function applyNotification(
  event: RefundNotificationEvent,
): Promise<NotificationApplyResult> {
  const admin = createClient(
    requiredEnvironmentVariable("SUPABASE_URL"),
    requiredEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  const { data, error } = await admin.rpc(
    "apply_verified_app_store_server_notification",
    {
      p_event_id: event.eventId,
      p_notification_type: event.notificationType,
      p_notification_signed_date: event.notificationSignedDate,
      p_user_id: event.userId,
      p_transaction_id: event.transactionId,
      p_original_transaction_id: event.originalTransactionId,
      p_product_id: event.productId,
      p_environment: event.environment,
      p_app_account_token: event.appAccountToken,
      p_purchase_date: event.purchaseDate,
      p_expires_date: event.expiresDate,
      p_transaction_signed_date: event.transactionSignedDate,
      p_revocation_date: event.revocationDate,
      p_revocation_percentage: event.revocationPercentage,
      p_quantity: event.quantity,
    },
  );
  if (error) {
    const token = `${error.code ?? ""} ${error.message ?? ""} ${
      error.details ?? ""
    } ${error.hint ?? ""}`.toLowerCase();
    if (
      token.includes("owned_by_other") ||
      token.includes("notification_event_id_conflict") ||
      token.includes("notification_source_mismatch")
    ) {
      throw new NotificationApplyError("conflict", 409, safeRpcReason(error));
    }
    if (
      token.includes("invalid_") || token.includes("unknown_product") ||
      token.includes("missing_") || token.includes("profile_not_found")
    ) {
      throw new NotificationApplyError(
        "invalid_notification",
        400,
        safeRpcReason(error),
      );
    }
    throw new NotificationRpcFailure(
      "apply_app_store_notification_failed",
      safeRpcReason(error),
    );
  }
  if (!isNotificationApplyResult(data)) {
    throw new Error("invalid_notification_rpc_response");
  }
  return data;
}

async function applyOneTimeCharge(
  event: OneTimeChargeNotificationEvent,
): Promise<NotificationApplyResult> {
  const admin = createClient(
    requiredEnvironmentVariable("SUPABASE_URL"),
    requiredEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  const rpcName = oneTimeChargeRPCName(event.environment);
  const isProduction = rpcName === "apply_verified_app_store_consumable";
  const { data, error } = await admin.rpc(
    rpcName,
    isProduction
      ? {
        p_user_id: event.userId,
        p_transaction_id: event.transactionId,
        p_original_transaction_id: event.originalTransactionId,
        p_product_id: event.productId,
        p_environment: event.environment,
        p_app_account_token: event.appAccountToken,
        p_purchase_date: event.purchaseDate,
        p_signed_date: event.transactionSignedDate,
        p_revocation_date: null,
        p_quantity: event.quantity,
      }
      : {
        p_user_id: event.userId,
        p_transaction_id: event.transactionId,
        p_original_transaction_id: event.originalTransactionId,
        p_product_id: event.productId,
        p_environment: event.environment,
        p_app_account_token: event.appAccountToken,
        p_purchase_date: event.purchaseDate,
        p_expires_date: null,
        p_signed_date: event.transactionSignedDate,
        p_revocation_date: null,
        p_quantity: event.quantity,
      },
  );
  if (error) {
    const token = `${error.code ?? ""} ${error.message ?? ""} ${
      error.details ?? ""
    } ${error.hint ?? ""}`.toLowerCase();
    if (
      token.includes("owned_by_other") ||
      token.includes("transaction_id_conflict")
    ) {
      throw new NotificationApplyError("conflict", 409, safeRpcReason(error));
    }
    if (
      token.includes("invalid_") || token.includes("unknown_product") ||
      token.includes("missing_") || token.includes("profile_not_found") ||
      token.includes("sandbox_review_account_not_allowed") ||
      token.includes("sandbox_review_credit_cap_exceeded")
    ) {
      throw new NotificationApplyError(
        "invalid_notification",
        400,
        safeRpcReason(error),
      );
    }
    throw new NotificationRpcFailure(
      "apply_app_store_one_time_charge_failed",
      safeRpcReason(error),
    );
  }
  if (!isNotificationApplyResult(data)) {
    throw new Error("invalid_one_time_charge_rpc_response");
  }
  return data;
}

export function oneTimeChargeRPCName(
  environment: unknown,
):
  | "apply_verified_app_store_consumable"
  | "apply_verified_app_store_sandbox_review_transaction" {
  if (environment === "Production") {
    return "apply_verified_app_store_consumable";
  }
  if (environment === "Sandbox") {
    return "apply_verified_app_store_sandbox_review_transaction";
  }
  throw new InputError("invalid_environment");
}

async function resolveNotificationUser(
  event: RefundNotificationEvent | SubscriptionLifecycleNotificationEvent,
): Promise<string> {
  const admin = createClient(
    requiredEnvironmentVariable("SUPABASE_URL"),
    requiredEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  const { data, error } = await admin.rpc(
    "resolve_verified_app_store_notification_user",
    {
      p_environment: event.environment,
      p_original_transaction_id: event.originalTransactionId,
      p_product_id: event.productId,
      p_app_account_token: event.appAccountToken,
    },
  );
  if (error) {
    const token = `${error.code ?? ""} ${error.message ?? ""} ${
      error.details ?? ""
    } ${error.hint ?? ""}`.toLowerCase();
    if (
      token.includes("account_token_mismatch") ||
      token.includes("legacy_binding_mismatch") ||
      token.includes("profile_not_found") || token.includes("invalid_") ||
      token.includes("unknown_product")
    ) {
      throw new NotificationApplyError(
        "invalid_notification",
        400,
        safeRpcReason(error),
      );
    }
    throw new NotificationRpcFailure(
      "resolve_app_store_notification_user_failed",
      safeRpcReason(error),
    );
  }
  if (typeof data !== "string") {
    throw new Error("invalid_notification_user_resolution");
  }
  return data;
}

async function applyLifecycleNotification(
  event: SubscriptionLifecycleNotificationEvent,
): Promise<NotificationApplyResult> {
  const admin = createClient(
    requiredEnvironmentVariable("SUPABASE_URL"),
    requiredEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  const { data, error } = await admin.rpc(
    "apply_verified_app_store_subscription_lifecycle",
    {
      p_event_id: event.eventId,
      p_notification_type: event.notificationType,
      p_notification_subtype: event.notificationSubtype,
      p_notification_signed_date: event.notificationSignedDate,
      p_user_id: event.userId,
      p_transaction_id: event.transactionId,
      p_original_transaction_id: event.originalTransactionId,
      p_product_id: event.productId,
      p_environment: event.environment,
      p_app_account_token: event.appAccountToken,
      p_purchase_date: event.purchaseDate,
      p_expires_date: event.expiresDate,
      p_transaction_signed_date: event.transactionSignedDate,
      p_renewal_signed_date: event.renewalSignedDate,
      p_revocation_date: event.revocationDate,
      p_grace_period_expires_date: event.gracePeriodExpiresDate,
      p_auto_renew_status: event.autoRenewStatus,
    },
  );
  if (error) {
    const token = `${error.code ?? ""} ${error.message ?? ""} ${
      error.details ?? ""
    } ${error.hint ?? ""}`.toLowerCase();
    if (
      token.includes("owned_by_other") ||
      token.includes("lifecycle_event_id_conflict") ||
      token.includes("lifecycle_source_mismatch")
    ) {
      throw new NotificationApplyError("conflict", 409, safeRpcReason(error));
    }
    if (
      token.includes("invalid_") || token.includes("unknown_product") ||
      token.includes("missing_") || token.includes("profile_not_found") ||
      token.includes("sandbox_review_account_not_allowed")
    ) {
      throw new NotificationApplyError(
        "invalid_notification",
        400,
        safeRpcReason(error),
      );
    }
    throw new NotificationRpcFailure(
      "apply_app_store_lifecycle_failed",
      safeRpcReason(error),
    );
  }
  if (!isNotificationApplyResult(data)) {
    throw new Error("invalid_lifecycle_rpc_response");
  }
  return data;
}

function isNotificationApplyResult(
  value: unknown,
): value is NotificationApplyResult {
  return isRecord(value) &&
    (value.status === "applied" || value.status === "already_applied" ||
      value.status === "ignored_stale");
}

function requiredEnvironmentVariable(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new InputError(`missing_${name.toLowerCase()}`, 500);
  return value;
}

const runtimeDependencies: NotificationHandlerDependencies = {
  now: () => Date.now(),
  verifyNotification,
  verifyTransaction,
  verifyRenewalInfo,
  resolveNotificationUser,
  applyOneTimeCharge,
  applyNotification,
  applyLifecycleNotification,
  logError: (error) => {
    const name = error instanceof Error ? error.name : typeof error;
    console.error("app-store-notifications failed", { name });
  },
  logDiagnostic: (entry) => {
    if (entry.outcome === "ignored") {
      console.info("app-store-notifications ignored", entry);
    } else {
      console.warn("app-store-notifications rejected", entry);
    }
  },
};

if (import.meta.main) {
  Deno.serve(createHandler(runtimeDependencies));
}
