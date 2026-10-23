import { Buffer } from "node:buffer";
import {
  Environment,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { KJUR, X509 } from "jsrsasign";

interface PayloadValidator<T> {
  validate(value: unknown): value is T;
}

const APPLE_LEAF_CERTIFICATE_OID = "1.2.840.113635.100.6.11.1";
const APPLE_INTERMEDIATE_CERTIFICATE_OID = "1.2.840.113635.100.6.2.1";
const MAX_CERTIFICATE_CLOCK_SKEW_MS = 60_000;
const strictBase64UrlPattern = /^[A-Za-z0-9_-]+$/;
const strictBase64Pattern = /^[A-Za-z0-9+/]*={0,2}$/;

function decodeBase64URL(value: string): Buffer {
  if (!strictBase64UrlPattern.test(value) || value.length % 4 === 1) {
    throw new Error("invalid_base64url");
  }
  const standard = value.replace(/-/g, "+").replace(/_/g, "/");
  const decoded = Buffer.from(
    standard.padEnd(Math.ceil(standard.length / 4) * 4, "="),
    "base64",
  );
  const canonical = decoded.toString("base64").replace(/=+$/, "")
    .replace(/\+/g, "-").replace(/\//g, "_");
  if (canonical !== value) throw new Error("invalid_base64url");
  return decoded;
}

function decodeBase64Certificate(value: string): Buffer {
  if (
    value.length === 0 ||
    value.length % 4 === 1 ||
    !strictBase64Pattern.test(value) ||
    (value.includes("=") && value.length % 4 !== 0)
  ) {
    throw new Error("invalid_certificate_base64");
  }
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.length === 0 ||
    decoded.toString("base64").replace(/=+$/, "") !==
      value.replace(/=+$/, "")
  ) {
    throw new Error("invalid_certificate_base64");
  }
  return decoded;
}

function parseJSONSegment(value: string): unknown {
  return JSON.parse(decodeBase64URL(value).toString("utf8"));
}

export function parseCertificateBytes(certificateBytes: Uint8Array): X509 {
  const parsed = new X509();
  parsed.readCertHex(Buffer.from(certificateBytes).toString("hex"));
  return parsed;
}

export function parseCertificateTime(value: string): number {
  const utcTime = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(
    value,
  );
  const generalizedTime = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(
    value,
  );
  const match = generalizedTime ?? utcTime;
  if (!match) throw new Error("invalid_certificate_time");

  const shortYear = utcTime ? Number(match[1]) : undefined;
  const year = generalizedTime
    ? Number(match[1])
    : (shortYear! >= 50 ? 1900 : 2000) + shortYear!;
  const offset = 2;
  const month = Number(match[offset]);
  const day = Number(match[offset + 1]);
  const hour = Number(match[offset + 2]);
  const minute = Number(match[offset + 3]);
  const second = Number(match[offset + 4]);
  const timestamp = Date.UTC(year, month - 1, day, hour, minute, second);
  const parsed = new Date(timestamp);
  if (
    !Number.isFinite(timestamp) ||
    parsed.getUTCFullYear() !== year ||
    parsed.getUTCMonth() !== month - 1 ||
    parsed.getUTCDate() !== day ||
    parsed.getUTCHours() !== hour ||
    parsed.getUTCMinutes() !== minute ||
    parsed.getUTCSeconds() !== second
  ) {
    throw new Error("invalid_certificate_time");
  }
  return timestamp;
}

function checkCertificateDates(certificate: X509, effectiveDate: Date): void {
  const effectiveTime = effectiveDate.getTime();
  if (!Number.isFinite(effectiveTime)) {
    throw new VerificationException(VerificationStatus.INVALID_CERTIFICATE);
  }
  const notBefore = parseCertificateTime(certificate.getNotBefore());
  const notAfter = parseCertificateTime(certificate.getNotAfter());
  if (
    notBefore > effectiveTime + MAX_CERTIFICATE_CLOCK_SKEW_MS ||
    notAfter < effectiveTime - MAX_CERTIFICATE_CLOCK_SKEW_MS
  ) {
    throw new VerificationException(VerificationStatus.INVALID_CERTIFICATE);
  }
}

function verifiesCertificateSignature(
  certificate: X509,
  issuer: X509,
): boolean {
  try {
    if (
      certificate.getSignatureAlgorithmField() !==
        certificate.getSignatureAlgorithmName()
    ) {
      return false;
    }
    return certificate.verifySignature(issuer.getPublicKey());
  } catch {
    return false;
  }
}

/**
 * Keeps Apple's bundle, app-id and environment checks while replacing the two
 * Node crypto operations that are not implemented consistently by the Supabase
 * Edge runtime: X.509 chain verification and public-key export. The chain is
 * verified against the pinned Apple roots with pure JavaScript, then the ES256
 * JWS signature is checked directly with the verified P-256 leaf key.
 */
export class EdgeCompatibleSignedDataVerifier extends SignedDataVerifier {
  private readonly edgeRootCertificates: X509[];

  constructor(
    appleRootCertificates: Buffer[],
    enableOnlineChecks: boolean,
    environment: Environment,
    bundleId: string,
    appAppleId?: number,
  ) {
    // The base verifier's root list is deliberately empty so its constructor
    // never instantiates Node X509Certificate objects in the Edge runtime.
    super([], enableOnlineChecks, environment, bundleId, appAppleId);
    this.edgeRootCertificates = appleRootCertificates.map(
      parseCertificateBytes,
    );
  }

  protected verifyEdgeCertificateChain(
    leafCertificate: X509,
    intermediateCertificate: X509,
    effectiveDate: Date,
  ): X509 {
    if (this.enableOnlineChecks) {
      throw new VerificationException(
        VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
      );
    }

    let runtimeStage = "root_parse";
    try {
      let trustedRootCertificate: X509 | undefined;

      for (const rootCertificate of this.edgeRootCertificates) {
        runtimeStage = "root_parse";
        runtimeStage = "root_signature";
        if (
          intermediateCertificate.getIssuerHex() ===
            rootCertificate.getSubjectHex() &&
          verifiesCertificateSignature(
            intermediateCertificate,
            rootCertificate,
          )
        ) {
          trustedRootCertificate = rootCertificate;
          break;
        }
      }

      runtimeStage = "intermediate_constraints";
      const intermediateConstraints = intermediateCertificate
        .getExtBasicConstraints();
      runtimeStage = "chain_validation";
      const validChain = trustedRootCertificate !== undefined &&
        leafCertificate.getIssuerHex() ===
          intermediateCertificate.getSubjectHex() &&
        verifiesCertificateSignature(
          leafCertificate,
          intermediateCertificate,
        ) &&
        intermediateConstraints?.cA === true &&
        leafCertificate.getExtInfo(APPLE_LEAF_CERTIFICATE_OID) !== undefined &&
        intermediateCertificate.getExtInfo(
            APPLE_INTERMEDIATE_CERTIFICATE_OID,
          ) !== undefined;
      if (!validChain || !trustedRootCertificate) {
        throw new VerificationException(
          VerificationStatus.VERIFICATION_FAILURE,
        );
      }

      runtimeStage = "certificate_dates";
      checkCertificateDates(leafCertificate, effectiveDate);
      checkCertificateDates(intermediateCertificate, effectiveDate);
      checkCertificateDates(trustedRootCertificate, effectiveDate);
      return leafCertificate;
    } catch (error) {
      if (error instanceof VerificationException) throw error;
      throw new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error(`edge_x509_${runtimeStage}_runtime`),
      );
    }
  }

  protected override verifyJWT<T>(
    jwt: string,
    validator: PayloadValidator<T>,
    signedDateExtractor: (decodedJWT: T) => Date,
  ): Promise<T> {
    let runtimeStage = "segments";
    try {
      const segments = jwt.split(".");
      if (
        segments.length !== 3 ||
        segments.some((segment) => segment.length === 0)
      ) {
        throw new VerificationException(VerificationStatus.FAILURE);
      }

      runtimeStage = "payload_decode";
      const decodedJWT = parseJSONSegment(segments[1]);
      runtimeStage = "payload_validate";
      if (!validator.validate(decodedJWT)) {
        throw new VerificationException(VerificationStatus.FAILURE);
      }
      if (
        this.environment === Environment.XCODE ||
        this.environment === Environment.LOCAL_TESTING
      ) {
        return Promise.resolve(decodedJWT);
      }

      let leafCertificate: X509;
      let intermediateCertificate: X509;
      try {
        runtimeStage = "header_decode";
        const header = parseJSONSegment(segments[0]);
        if (
          typeof header !== "object" ||
          header === null ||
          (header as Record<string, unknown>).alg !== "ES256"
        ) {
          throw new Error("invalid_apple_jws_algorithm");
        }
        const chain = (header as Record<string, unknown>).x5c;
        if (!Array.isArray(chain) || chain.length !== 3) {
          throw new VerificationException(
            VerificationStatus.INVALID_CHAIN_LENGTH,
          );
        }
        if (!chain.every((certificate) => typeof certificate === "string")) {
          throw new Error("invalid_apple_certificate_chain");
        }
        leafCertificate = parseCertificateBytes(
          decodeBase64Certificate(chain[0]),
        );
        intermediateCertificate = parseCertificateBytes(
          decodeBase64Certificate(chain[1]),
        );
      } catch (error) {
        if (error instanceof VerificationException) throw error;
        throw new VerificationException(
          VerificationStatus.INVALID_CERTIFICATE,
          error instanceof Error ? error : undefined,
        );
      }

      runtimeStage = "effective_date";
      const effectiveDate = this.enableOnlineChecks
        ? new Date()
        : signedDateExtractor(decodedJWT);
      runtimeStage = "certificate_chain";
      const verifiedLeaf = this.verifyEdgeCertificateChain(
        leafCertificate,
        intermediateCertificate,
        effectiveDate,
      );
      runtimeStage = "key_constraints";
      const publicKey = verifiedLeaf.getPublicKey();
      if (
        !(publicKey instanceof KJUR.crypto.ECDSA) ||
        publicKey.getShortNISTPCurveName() !== "P-256"
      ) {
        throw new VerificationException(
          VerificationStatus.VERIFICATION_FAILURE,
        );
      }
      runtimeStage = "signature_decode";
      const signature = decodeBase64URL(segments[2]);
      if (signature.length !== 64) {
        throw new VerificationException(
          VerificationStatus.VERIFICATION_FAILURE,
        );
      }
      runtimeStage = "signature_verify";
      const validSignature = KJUR.jws.JWS.verify(jwt, publicKey, ["ES256"]);
      if (!validSignature) {
        throw new VerificationException(
          VerificationStatus.VERIFICATION_FAILURE,
        );
      }
      return Promise.resolve(decodedJWT);
    } catch (error) {
      if (error instanceof VerificationException) throw error;
      throw new VerificationException(
        VerificationStatus.VERIFICATION_FAILURE,
        new Error(`edge_jws_${runtimeStage}_runtime`),
      );
    }
  }
}
