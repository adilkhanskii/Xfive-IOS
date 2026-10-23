const source = await Deno.readTextFile(
  new URL("./index.ts", import.meta.url),
);
const edgeVerifierSource = await Deno.readTextFile(
  new URL("./edge_jws_verifier.ts", import.meta.url),
);

function assertMatch(value: string, pattern: RegExp, message: string): void {
  if (!pattern.test(value)) throw new Error(message);
}

function assertNotMatch(value: string, pattern: RegExp, message: string): void {
  if (pattern.test(value)) throw new Error(message);
}

Deno.test("runtime uses source-pinned official Apple trust roots", () => {
  assertMatch(
    source,
    /pinnedAppleRootCertificates\(\)/,
    "the notification runtime is not using the pinned Apple roots",
  );
  assertNotMatch(
    source,
    /APPLE_ROOT_CA_CERTS_(?:PEM|BASE64)/,
    "the notification runtime still depends on mutable root secrets",
  );
});

Deno.test("production verifier uses the source-pinned App Store app id", () => {
  assertMatch(
    source,
    /APP_APPLE_ID/,
    "the notification runtime is not using the pinned App Store app id",
  );
  assertNotMatch(
    source,
    /Deno\.env\.get\("APPLE_APP_ID"\)/,
    "the notification runtime still depends on a mutable App Store app-id secret",
  );
});

Deno.test("runtime verifies both Apple JWS layers with the pinned Apple library", () => {
  assertMatch(
    source,
    /@apple\/app-store-server-library/,
    "Apple server library import is missing",
  );
  assertMatch(
    source,
    /verifyAndDecodeNotification\(\s*signedPayload,?\s*\)/,
    "outer signedPayload is not verified",
  );
  assertMatch(
    source,
    /verifyAndDecodeTransaction\(\s*signedTransaction,?\s*\)/,
    "inner signedTransactionInfo is not verified",
  );
  assertMatch(
    source,
    /VerificationStatus\.RETRYABLE_VERIFICATION_FAILURE/,
    "retryable Apple verification failures are not classified",
  );
});

Deno.test("runtime avoids live Apple OCSP that is incompatible with the Deno edge runtime", () => {
  assertMatch(
    source,
    /new EdgeCompatibleSignedDataVerifier\([\s\S]*?getAppleRootCertificates\(\),\s*false,\s*environment === "Production"/,
    "Apple verifier must retain signed JWS validation without live OCSP",
  );
});

Deno.test("runtime verifies ES256 directly without Edge-incompatible key export", () => {
  assertMatch(
    edgeVerifierSource,
    /KJUR\.jws\.JWS\.verify\(\s*jwt,\s*publicKey,\s*\["ES256"\],?\s*\)/,
    "the notification runtime is not using pure-JavaScript ES256 verification with an explicit algorithm allowlist",
  );
  assertNotMatch(
    edgeVerifierSource,
    /publicKey\.export\(/,
    "the notification runtime still uses Edge-incompatible public-key export",
  );
  assertMatch(
    edgeVerifierSource,
    /alg !== "ES256"/,
    "the notification runtime does not require Apple's ES256 algorithm",
  );
  assertMatch(
    edgeVerifierSource,
    /protected verifyEdgeCertificateChain\(/,
    "the notification runtime does not provide an Edge-compatible certificate-chain verifier",
  );
  assertMatch(
    edgeVerifierSource,
    /super\(\[\], enableOnlineChecks, environment, bundleId, appAppleId\)/,
    "the notification runtime still lets the Apple base class construct Node X.509 roots",
  );
  assertMatch(
    edgeVerifierSource,
    /edgeRootCertificates = appleRootCertificates\.map\(\s*parseCertificateBytes,?\s*\)/,
    "the notification runtime does not retain pure-JavaScript trusted roots",
  );
  assertMatch(
    edgeVerifierSource,
    /from "jsrsasign"/,
    "the notification runtime does not use the pure-JavaScript X.509 verifier",
  );
  assertMatch(
    edgeVerifierSource,
    /readCertHex\(Buffer\.from\(certificateBytes\)\.toString\("hex"\)\)/,
    "the notification runtime does not parse Apple header certificates directly with pure JavaScript",
  );
  assertMatch(
    edgeVerifierSource,
    /verifiesCertificateSignature\(\s*intermediateCertificate,/,
    "the intermediate certificate signature is not verified",
  );
  assertMatch(
    edgeVerifierSource,
    /verifiesCertificateSignature\(\s*leafCertificate,/,
    "the leaf certificate signature is not verified",
  );
  assertMatch(
    edgeVerifierSource,
    /getExtBasicConstraints\(\)/,
    "the intermediate CA basic constraint is not verified",
  );
  assertMatch(
    edgeVerifierSource,
    /getSignatureAlgorithmField\(\)[\s\S]*getSignatureAlgorithmName\(\)/,
    "certificate signature algorithm fields are not required to match",
  );
  assertMatch(
    edgeVerifierSource,
    /1\.2\.840\.113635\.100\.6\.11\.1/,
    "Apple's leaf certificate extension is not required",
  );
  assertMatch(
    edgeVerifierSource,
    /1\.2\.840\.113635\.100\.6\.2\.1/,
    "Apple's intermediate certificate extension is not required",
  );
  assertMatch(
    edgeVerifierSource,
    /getNotBefore\(\)[\s\S]*getNotAfter\(\)/,
    "certificate validity dates are not checked",
  );
  assertNotMatch(
    edgeVerifierSource,
    /intermediate\.verify\(|leaf\.verify\(/,
    "the notification runtime still uses Edge-incompatible Node X509Certificate.verify",
  );
  assertMatch(
    edgeVerifierSource,
    /publicKey instanceof KJUR\.crypto\.ECDSA/,
    "the notification runtime does not require an EC leaf key",
  );
  assertMatch(
    edgeVerifierSource,
    /getShortNISTPCurveName\(\) !== "P-256"/,
    "the notification runtime does not require the P-256 curve",
  );
  assertMatch(
    edgeVerifierSource,
    /signature\.length !== 64/,
    "the notification runtime does not require a 64-byte ES256 signature",
  );
  if (
    !edgeVerifierSource.includes(
      "const strictBase64UrlPattern = /^[A-Za-z0-9_-]+$/;",
    )
  ) {
    throw new Error(
      "JWS segments are not restricted to strict unpadded base64url",
    );
  }
  assertMatch(
    edgeVerifierSource,
    /const canonical = decoded\.toString\("base64"\)[\s\S]*canonical !== value/,
    "JWS base64url trailing bits are not required to be canonical",
  );
  assertNotMatch(
    edgeVerifierSource,
    /from "node:crypto"|verify as verifySignature|leaf\.publicKey|asymmetricKeyDetails|dsaEncoding|\.raw/,
    "the notification runtime still depends on Edge-incompatible Node certificate or signature operations",
  );
});

Deno.test("runtime applies only the dedicated service-role notification RPC", () => {
  assertMatch(
    source,
    /apply_verified_app_store_server_notification/,
    "dedicated notification RPC is missing",
  );
  assertMatch(
    source,
    /SUPABASE_SERVICE_ROLE_KEY/,
    "service role key is not used server-side",
  );
  assertMatch(
    source,
    /if \(import\.meta\.main\)[\s\S]*Deno\.serve/,
    "Edge runtime entrypoint is missing",
  );
});
