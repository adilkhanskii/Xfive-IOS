import { Buffer } from "node:buffer";
import {
  Environment,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { EdgeCompatibleSignedDataVerifier } from "../supabase/functions/app-store-notifications/edge_jws_verifier.ts";
import {
  APP_APPLE_ID,
  pinnedAppleRootCertificates,
} from "../supabase/functions/app-store-notifications/validation.ts";

const BUNDLE_ID = "com.x5studio.app";

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
}

function safeMessage(error: Error): string {
  return error.message
    .replace(
      /[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/g,
      "[redacted-jws]",
    )
    .replace(
      /-----BEGIN[^-]+-----[\s\S]*?-----END[^-]+-----/g,
      "[redacted-pem]",
    )
    .replace(/[A-Za-z0-9+/=]{160,}/g, "[redacted-data]")
    .replace(/[\r\n\t]+/g, " ")
    .slice(0, 400);
}

function report(error: unknown): never {
  if (error instanceof VerificationException) {
    console.log(
      `verification_status=${VerificationStatus[error.status] ?? error.status}`,
    );
    if (error.cause instanceof Error) {
      console.log(`cause_name=${error.cause.name || "Error"}`);
      console.log(`cause_message=${safeMessage(error.cause) || "-"}`);
    } else {
      console.log("cause_name=-");
      console.log("cause_message=-");
    }
  } else if (error instanceof Error) {
    console.log(`verification_status=NON_VERIFICATION_EXCEPTION`);
    console.log(`cause_name=${error.name || "Error"}`);
    console.log(`cause_message=${safeMessage(error) || "-"}`);
  } else {
    console.log("verification_status=UNKNOWN_THROWN_VALUE");
    console.log("cause_name=-");
    console.log("cause_message=-");
  }
  Deno.exit(2);
}

const signedPayload = (await Deno.readTextFile(required("SIGNED_PAYLOAD_PATH")))
  .trim();
const roots = pinnedAppleRootCertificates().map((certificate) =>
  Buffer.from(certificate)
);
const verifier = new EdgeCompatibleSignedDataVerifier(
  roots,
  false,
  Environment.PRODUCTION,
  BUNDLE_ID,
  APP_APPLE_ID,
);

try {
  if (Deno.env.get("PAYLOAD_KIND") === "transaction") {
    const payload = await verifier.verifyAndDecodeTransaction(signedPayload);
    console.log(
      `verified=transaction bundle_match=${
        payload.bundleId === BUNDLE_ID
      } environment=${payload.environment ?? "-"}`,
    );
  } else if (Deno.env.get("PAYLOAD_KIND") === "renewal") {
    const payload = await verifier.verifyAndDecodeRenewalInfo(signedPayload);
    console.log(
      `verified=renewal product_present=${Boolean(payload.productId)}`,
    );
  } else {
    const payload = await verifier.verifyAndDecodeNotification(signedPayload);
    console.log(
      `verified=notification bundle_match=${
        payload.data?.bundleId === BUNDLE_ID
      } environment=${payload.data?.environment ?? "-"}`,
    );
  }
} catch (error) {
  report(error);
}
