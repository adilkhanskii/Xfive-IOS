import { Buffer } from "node:buffer";
import {
  Environment,
  type JWSTransactionDecodedPayload,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { createClient } from "@supabase/supabase-js";
import { EdgeCompatibleSignedDataVerifier } from "./edge_jws_verifier.ts";
import {
  APP_APPLE_ID,
  APP_BUNDLE_ID,
  type AppStoreEnvironment,
  InputError,
  type NormalizedTransaction,
  parseUntrustedTransactionEnvironment,
  parseVerifyRequestBody,
  pinnedAppleRootCertificates,
  validateVerifiedTransaction,
  VERIFIED_MONTHLY_PRODUCT_ID,
  type VerifiedTransactionPayload,
} from "./validation.ts";

export interface EntitlementResult {
  status: "applied" | "already_applied";
  credits_granted: number;
  subscription_end_date: string | null;
  is_verified: boolean;
}

export interface HandlerDependencies {
  now(): number;
  authenticate(accessToken: string): Promise<string | null>;
  verifySignedTransaction(
    signedTransaction: string,
    environment: AppStoreEnvironment,
  ): Promise<VerifiedTransactionPayload>;
  applyVerifiedSubscription(
    userId: string,
    transaction: NormalizedTransaction,
  ): Promise<EntitlementResult>;
  applyVerifiedConsumable(
    userId: string,
    transaction: NormalizedTransaction,
  ): Promise<EntitlementResult>;
  applyVerifiedConsumableRefund(
    userId: string,
    transaction: NormalizedTransaction,
  ): Promise<EntitlementResult>;
  applyVerifiedSandboxReview(
    userId: string,
    transaction: NormalizedTransaction,
  ): Promise<EntitlementResult>;
  applyVerifiedRevocation(
    userId: string,
    transaction: NormalizedTransaction,
  ): Promise<EntitlementResult>;
  logError(error: unknown): void;
}

export class AppleVerificationError extends Error {
  constructor(
    readonly retryable: boolean,
    readonly diagnosticCode = "apple_verification_failed",
  ) {
    super("apple_verification_failed");
  }
}

export class EntitlementApplyError extends Error {
  constructor(
    readonly statusValue:
      | "owned_by_other"
      | "rejected"
      | "sandbox_test_not_billable",
    readonly httpStatus: number,
    readonly diagnosticCode:
      | "owned_by_other"
      | "rejected"
      | "account_token_mismatch"
      | "sandbox_test_not_billable" = statusValue,
    readonly reason?: string,
  ) {
    super(statusValue);
  }
}

class EntitlementRpcFailure extends Error {
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

type AccountTokenMismatchDiagnostic =
  & (InputError | EntitlementApplyError)
  & {
    transactionId?: string;
    productId?: string;
    environment?: AppStoreEnvironment;
    appAccountToken?: string;
    authenticatedUserId?: string;
  };

function accountTokenMismatchDiagnostic(
  error: unknown,
): AccountTokenMismatchDiagnostic | null {
  const isMismatch = error instanceof InputError
    ? error.code === "account_token_mismatch"
    : error instanceof EntitlementApplyError
    ? error.diagnosticCode === "account_token_mismatch"
    : false;
  return isMismatch ? error as AccountTokenMismatchDiagnostic : null;
}

function retainVerifiedTransactionOwnership(
  error: unknown,
  verifiedPayload: VerifiedTransactionPayload,
  environment: AppStoreEnvironment,
  authenticatedUserId: string,
): void {
  const diagnostic = accountTokenMismatchDiagnostic(error);
  if (!diagnostic) return;

  diagnostic.transactionId = verifiedPayload.transactionId;
  diagnostic.productId = verifiedPayload.productId;
  diagnostic.environment = environment;
  diagnostic.appAccountToken = verifiedPayload.appAccountToken;
  diagnostic.authenticatedUserId = authenticatedUserId;
}

export function createHandler(
  _dependencies: HandlerDependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "POST") {
      return jsonResponse(
        { status: "rejected", error: "method_not_allowed" },
        405,
        { Allow: "POST" },
      );
    }

    try {
      const accessToken = bearerToken(request.headers.get("Authorization"));
      if (!accessToken) {
        return jsonResponse({ status: "rejected", error: "unauthorized" }, 401);
      }

      const userId = await _dependencies.authenticate(accessToken);
      if (!userId) {
        return jsonResponse({ status: "rejected", error: "unauthorized" }, 401);
      }

      if (
        !request.headers.get("Content-Type")?.toLowerCase().startsWith(
          "application/json",
        )
      ) {
        throw new InputError("invalid_content_type", 415);
      }

      let rawBody: unknown;
      try {
        rawBody = await request.json();
      } catch {
        throw new InputError("invalid_request_body");
      }

      const signedTransaction = parseVerifyRequestBody(rawBody);
      const environment = parseUntrustedTransactionEnvironment(
        signedTransaction,
      );
      const verifiedPayload = await _dependencies.verifySignedTransaction(
        signedTransaction,
        environment,
      );
      try {
        const transaction = validateVerifiedTransaction(
          verifiedPayload,
          userId,
          environment,
          _dependencies.now(),
        );
        let result: EntitlementResult;
        if (transaction.revocationDate) {
          result = transaction.productKind === "consumable"
            ? await _dependencies.applyVerifiedConsumableRefund(
              userId,
              transaction,
            )
            : await _dependencies.applyVerifiedRevocation(userId, transaction);
        } else if (transaction.environment === "Sandbox") {
          // Apple signs both TestFlight and App Review purchases as Sandbox.
          // Unlike the legacy production restore path, the isolated review RPC
          // always requires StoreKit's appAccountToken to bind the purchase to
          // the authenticated dedicated review account.
          if (!transaction.appAccountToken) {
            throw new InputError("missing_account_token");
          }
          if (transaction.appAccountToken !== userId.toLowerCase()) {
            throw new InputError("account_token_mismatch");
          }
          result = await _dependencies.applyVerifiedSandboxReview(
            userId,
            transaction,
          );
        } else {
          result = transaction.productKind === "consumable"
            ? await _dependencies.applyVerifiedConsumable(userId, transaction)
            : await _dependencies.applyVerifiedSubscription(
              userId,
              transaction,
            );
        }
        return jsonResponse(result, 200);
      } catch (error) {
        retainVerifiedTransactionOwnership(
          error,
          verifiedPayload,
          environment,
          userId,
        );
        throw error;
      }
    } catch (error) {
      if (error instanceof InputError) {
        _dependencies.logError(error);
        if (error.code === "transaction_owned_by_other") {
          return jsonResponse({ status: "owned_by_other" }, 409);
        }
        return jsonResponse(
          { status: "rejected", error: error.code },
          error.status,
        );
      }
      if (error instanceof AppleVerificationError) {
        _dependencies.logError(error);
        return error.retryable
          ? jsonResponse({
            status: "rejected",
            error: "apple_verification_unavailable",
          }, 503)
          : jsonResponse({
            status: "rejected",
            error: `invalid_apple_transaction_${
              safeAppleVerificationCode(error.diagnosticCode)
            }`,
          }, 400);
      }
      if (error instanceof EntitlementApplyError) {
        _dependencies.logError(error);
        // A plain database rejection carries its exact reason code so the
        // app diagnostics show why. Ownership outcomes keep their exact
        // contracts: the app treats an account_token_mismatch error specially.
        return jsonResponse(
          error.statusValue === "rejected" &&
            error.diagnosticCode === "rejected" && error.reason
            ? { status: error.statusValue, error: error.reason }
            : { status: error.statusValue },
          error.httpStatus,
        );
      }
      _dependencies.logError(error);
      return jsonResponse({ status: "rejected", error: "server_error" }, 500);
    }
  };
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

function bearerToken(authorization: string | null): string | null {
  const match = authorization?.match(/^Bearer\s+([^\s]+)$/i);
  return match?.[1] ?? null;
}

function jsonResponse(
  body: Record<string, unknown> | EntitlementResult,
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

let appleRootCertificates: Buffer[] | undefined;
const appleVerifiers = new Map<AppStoreEnvironment, SignedDataVerifier>();

// The public App Store id and Apple trust anchors are source-pinned and tested
// so stale or malformed deployment secrets cannot break every valid purchase.
function getAppleRootCertificates(): Buffer[] {
  if (appleRootCertificates) return appleRootCertificates;
  const certificates = pinnedAppleRootCertificates();
  appleRootCertificates = certificates.map((certificate) =>
    Buffer.from(certificate)
  );
  return appleRootCertificates;
}

function getAppleVerifier(
  environment: AppStoreEnvironment,
): SignedDataVerifier {
  const cached = appleVerifiers.get(environment);
  if (cached) return cached;

  const verifierEnvironment = environment === "Production"
    ? Environment.PRODUCTION
    : Environment.SANDBOX;
  const appAppleId = environment === "Production" ? APP_APPLE_ID : undefined;

  let verifier: SignedDataVerifier;
  try {
    verifier = new EdgeCompatibleSignedDataVerifier(
      getAppleRootCertificates(),
      appleOnlineChecksEnabled(environment),
      verifierEnvironment,
      APP_BUNDLE_ID,
      appAppleId,
    );
  } catch {
    throw new InputError("invalid_apple_verifier_configuration", 500);
  }
  appleVerifiers.set(environment, verifier);
  return verifier;
}

// Apple's verifier still validates the complete certificate chain, Apple OIDs,
// JWS signature, bundle id and environment when online checks are disabled; it
// uses the signed JWS date for certificate validity and skips only live OCSP.
// Live OCSP in the Node library rejects Apple's responder certificate in the
// Supabase Deno runtime, including for valid Production purchases. Keep the
// cryptographic verification enabled and avoid that runtime-incompatible path.
export function appleOnlineChecksEnabled(
  _environment: AppStoreEnvironment,
): boolean {
  return false;
}

async function verifySignedTransaction(
  signedTransaction: string,
  environment: AppStoreEnvironment,
): Promise<JWSTransactionDecodedPayload> {
  const verifier = getAppleVerifier(environment);
  try {
    return await verifier.verifyAndDecodeTransaction(signedTransaction);
  } catch (error) {
    const retryable = error instanceof VerificationException &&
      error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE;
    const diagnosticCode = appleVerificationDiagnosticCode(error);
    throw new AppleVerificationError(retryable, diagnosticCode);
  }
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

function publicSupabaseKey(): string {
  return Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    requiredEnvironmentVariable("SUPABASE_ANON_KEY");
}

async function authenticate(accessToken: string): Promise<string | null> {
  const client = createClient(
    requiredEnvironmentVariable("SUPABASE_URL"),
    publicSupabaseKey(),
    {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  const { data, error } = await client.auth.getUser(accessToken);
  if (error || !data.user) return null;
  return data.user.id;
}

async function applyVerifiedSubscription(
  userId: string,
  transaction: NormalizedTransaction,
): Promise<EntitlementResult> {
  if (transaction.productKind !== "subscription" || !transaction.expiresDate) {
    throw new Error("invalid_subscription_transaction");
  }
  return await applyVerifiedRpc("apply_verified_app_store_transaction", {
    p_user_id: userId,
    p_transaction_id: transaction.transactionId,
    p_original_transaction_id: transaction.originalTransactionId,
    p_product_id: transaction.productId,
    p_environment: transaction.environment,
    p_app_account_token: transaction.appAccountToken,
    p_purchase_date: transaction.purchaseDate,
    p_expires_date: transaction.expiresDate,
    p_signed_date: transaction.signedDate,
    p_revocation_date: transaction.revocationDate,
  });
}

async function applyVerifiedConsumable(
  userId: string,
  transaction: NormalizedTransaction,
): Promise<EntitlementResult> {
  if (transaction.productKind !== "consumable" || transaction.quantity !== 1) {
    throw new Error("invalid_consumable_transaction");
  }
  return await applyVerifiedRpc("apply_verified_app_store_consumable", {
    p_user_id: userId,
    p_transaction_id: transaction.transactionId,
    p_original_transaction_id: transaction.originalTransactionId,
    p_product_id: transaction.productId,
    p_environment: transaction.environment,
    p_app_account_token: transaction.appAccountToken,
    p_purchase_date: transaction.purchaseDate,
    p_signed_date: transaction.signedDate,
    p_revocation_date: transaction.revocationDate,
    p_quantity: transaction.quantity,
  });
}

async function applyVerifiedConsumableRefund(
  userId: string,
  transaction: NormalizedTransaction,
): Promise<EntitlementResult> {
  if (
    transaction.productKind !== "consumable" ||
    transaction.quantity !== 1 ||
    transaction.expiresDate !== null ||
    !transaction.revocationDate ||
    !transaction.appAccountToken ||
    transaction.appAccountToken !== userId.toLowerCase()
  ) {
    throw new Error("invalid_consumable_refund");
  }
  return await applyVerifiedRpc("apply_verified_app_store_consumable_refund", {
    p_user_id: userId,
    p_transaction_id: transaction.transactionId,
    p_original_transaction_id: transaction.originalTransactionId,
    p_product_id: transaction.productId,
    p_environment: transaction.environment,
    p_app_account_token: transaction.appAccountToken,
    p_purchase_date: transaction.purchaseDate,
    p_signed_date: transaction.signedDate,
    p_revocation_date: transaction.revocationDate,
    p_quantity: transaction.quantity,
  });
}

async function applyVerifiedSandboxReview(
  userId: string,
  transaction: NormalizedTransaction,
): Promise<EntitlementResult> {
  if (
    transaction.environment !== "Sandbox" ||
    !transaction.appAccountToken ||
    transaction.appAccountToken !== userId.toLowerCase()
  ) {
    throw new Error("invalid_sandbox_review_transaction");
  }
  return await applyVerifiedRpc(
    "apply_verified_app_store_sandbox_review_transaction",
    {
      p_user_id: userId,
      p_transaction_id: transaction.transactionId,
      p_original_transaction_id: transaction.originalTransactionId,
      p_product_id: transaction.productId,
      p_environment: transaction.environment,
      p_app_account_token: transaction.appAccountToken,
      p_purchase_date: transaction.purchaseDate,
      p_expires_date: transaction.expiresDate,
      p_signed_date: transaction.signedDate,
      p_revocation_date: transaction.revocationDate,
      p_quantity: transaction.quantity,
    },
  );
}

async function applyVerifiedRevocation(
  userId: string,
  transaction: NormalizedTransaction,
): Promise<EntitlementResult> {
  if (
    transaction.productKind !== "subscription" ||
    transaction.productId !== VERIFIED_MONTHLY_PRODUCT_ID ||
    !transaction.expiresDate ||
    !transaction.revocationDate ||
    !transaction.appAccountToken ||
    transaction.appAccountToken !== userId.toLowerCase()
  ) {
    throw new Error("invalid_verified_revocation");
  }
  return await applyVerifiedRpc(
    "apply_verified_app_store_verified_revocation",
    {
      p_user_id: userId,
      p_transaction_id: transaction.transactionId,
      p_original_transaction_id: transaction.originalTransactionId,
      p_product_id: transaction.productId,
      p_environment: transaction.environment,
      p_app_account_token: transaction.appAccountToken,
      p_purchase_date: transaction.purchaseDate,
      p_expires_date: transaction.expiresDate,
      p_signed_date: transaction.signedDate,
      p_revocation_date: transaction.revocationDate,
    },
  );
}

async function applyVerifiedRpc(
  rpcName:
    | "apply_verified_app_store_transaction"
    | "apply_verified_app_store_consumable"
    | "apply_verified_app_store_consumable_refund"
    | "apply_verified_app_store_sandbox_review_transaction"
    | "apply_verified_app_store_verified_revocation",
  parameters: Record<string, unknown>,
): Promise<EntitlementResult> {
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

  const { data, error } = await admin.rpc(rpcName, parameters);

  if (error) {
    const safeToken = `${error.code ?? ""} ${error.message ?? ""} ${
      error.details ?? ""
    } ${error.hint ?? ""}`
      .toLowerCase();
    const reason = safeRpcReason(error);
    if (
      safeToken.includes("owned_by_other") ||
      safeToken.includes("transaction_id_conflict") ||
      safeToken.includes("consumable_refund_id_conflict")
    ) {
      throw new EntitlementApplyError("owned_by_other", 409);
    }
    if (
      safeToken.includes("sandbox_review_account_not_allowed") ||
      safeToken.includes("sandbox_review_credit_cap_exceeded")
    ) {
      throw new EntitlementApplyError("sandbox_test_not_billable", 403);
    }
    if (safeToken.includes("account_token_mismatch")) {
      throw new EntitlementApplyError(
        "rejected",
        400,
        "account_token_mismatch",
        reason,
      );
    }
    if (
      safeToken.includes("invalid_user_id") ||
      safeToken.includes("profile_not_found") ||
      safeToken.includes("invalid_transaction_id") ||
      safeToken.includes("invalid_original_transaction_id") ||
      safeToken.includes("invalid_environment") ||
      safeToken.includes("sandbox_not_allowed") ||
      safeToken.includes("sandbox_review_environment_required") ||
      safeToken.includes("unknown_product") ||
      safeToken.includes("invalid_quantity") ||
      safeToken.includes("transaction_revoked") ||
      safeToken.includes("missing_transaction_dates") ||
      safeToken.includes("invalid_expiration_date") ||
      safeToken.includes("transaction_expired") ||
      safeToken.includes("invalid_transaction_dates") ||
      safeToken.includes("missing_account_token") ||
      safeToken.includes("revocation_source_not_found") ||
      safeToken.includes("revocation_source_mismatch") ||
      safeToken.includes("revocation_id_conflict") ||
      safeToken.includes("consumable_refund_source_not_found") ||
      safeToken.includes("consumable_refund_source_mismatch") ||
      safeToken.includes("invalid_revocation_date")
    ) {
      throw new EntitlementApplyError("rejected", 400, "rejected", reason);
    }
    throw new EntitlementRpcFailure(`${rpcName}_failed`, reason);
  }

  if (!isEntitlementResult(data)) {
    throw new Error("invalid_entitlement_rpc_response");
  }
  return data;
}

function isEntitlementResult(value: unknown): value is EntitlementResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const result = value as Record<string, unknown>;
  return (result.status === "applied" || result.status === "already_applied") &&
    typeof result.credits_granted === "number" &&
    Number.isSafeInteger(result.credits_granted) &&
    result.credits_granted >= 0 &&
    (typeof result.subscription_end_date === "string" ||
      result.subscription_end_date === null) &&
    typeof result.is_verified === "boolean";
}

function requiredEnvironmentVariable(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new InputError(`missing_${name.toLowerCase()}`, 500);
  return value;
}

const runtimeDependencies: HandlerDependencies = {
  now: () => Date.now(),
  authenticate,
  verifySignedTransaction,
  applyVerifiedSubscription,
  applyVerifiedConsumable,
  applyVerifiedConsumableRefund,
  applyVerifiedSandboxReview,
  applyVerifiedRevocation,
  logError: (error) => {
    const name = error instanceof Error ? error.name : typeof error;
    const code = error instanceof InputError
      ? error.code
      : error instanceof EntitlementApplyError
      ? error.diagnosticCode
      : error instanceof AppleVerificationError
      ? error.diagnosticCode
      : "server_error";
    const ownership = accountTokenMismatchDiagnostic(error);
    const reason = error instanceof EntitlementApplyError ||
        error instanceof EntitlementRpcFailure
      ? error.reason
      : undefined;
    console.error("verify-app-store-transaction failed", {
      name,
      code,
      ...(reason ? { reason } : {}),
      ...(ownership
        ? {
          transaction_id: ownership.transactionId,
          product_id: ownership.productId,
          environment: ownership.environment,
          app_account_token: ownership.appAccountToken,
          authenticated_user_id: ownership.authenticatedUserId,
        }
        : {}),
    });
  },
};

if (import.meta.main) {
  Deno.serve(createHandler(runtimeDependencies));
}
