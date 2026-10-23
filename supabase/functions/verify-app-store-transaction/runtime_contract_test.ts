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
    "the verified purchase runtime is not using the pinned Apple roots",
  );
  assertNotMatch(
    source,
    /APPLE_ROOT_CA_CERTS_(?:PEM|BASE64)/,
    "the verified purchase runtime still depends on mutable root secrets",
  );
});

Deno.test("production verifier uses the source-pinned App Store app id", () => {
  assertMatch(
    source,
    /APP_APPLE_ID/,
    "the verified purchase runtime is not using the pinned App Store app id",
  );
  assertNotMatch(
    source,
    /Deno\.env\.get\("APPLE_APP_ID"\)/,
    "the verified purchase runtime still depends on a mutable App Store app-id secret",
  );
});

Deno.test("runtime verifies ES256 directly without Edge-incompatible key export", () => {
  assertMatch(
    edgeVerifierSource,
    /KJUR\.jws\.JWS\.verify\(\s*jwt,\s*publicKey,\s*\["ES256"\],?\s*\)/,
    "the verified purchase runtime is not using pure-JavaScript ES256 verification with an explicit algorithm allowlist",
  );
  assertNotMatch(
    edgeVerifierSource,
    /publicKey\.export\(/,
    "the verified purchase runtime still uses Edge-incompatible public-key export",
  );
  assertMatch(
    edgeVerifierSource,
    /alg !== "ES256"/,
    "the verified purchase runtime does not require Apple's ES256 algorithm",
  );
  assertMatch(
    edgeVerifierSource,
    /protected verifyEdgeCertificateChain\(/,
    "the verified purchase runtime does not provide an Edge-compatible certificate-chain verifier",
  );
  assertMatch(
    edgeVerifierSource,
    /super\(\[\], enableOnlineChecks, environment, bundleId, appAppleId\)/,
    "the verified purchase runtime still lets the Apple base class construct Node X.509 roots",
  );
  assertMatch(
    edgeVerifierSource,
    /edgeRootCertificates = appleRootCertificates\.map\(\s*parseCertificateBytes,?\s*\)/,
    "the verified purchase runtime does not retain pure-JavaScript trusted roots",
  );
  assertMatch(
    edgeVerifierSource,
    /from "jsrsasign"/,
    "the verified purchase runtime does not use the pure-JavaScript X.509 verifier",
  );
  assertMatch(
    edgeVerifierSource,
    /readCertHex\(Buffer\.from\(certificateBytes\)\.toString\("hex"\)\)/,
    "the verified purchase runtime does not parse Apple header certificates directly with pure JavaScript",
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
    "the verified purchase runtime still uses Edge-incompatible Node X509Certificate.verify",
  );
  assertMatch(
    edgeVerifierSource,
    /publicKey instanceof KJUR\.crypto\.ECDSA/,
    "the verified purchase runtime does not require an EC leaf key",
  );
  assertMatch(
    edgeVerifierSource,
    /getShortNISTPCurveName\(\) !== "P-256"/,
    "the verified purchase runtime does not require the P-256 curve",
  );
  assertMatch(
    edgeVerifierSource,
    /signature\.length !== 64/,
    "the verified purchase runtime does not require a 64-byte ES256 signature",
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
    "the verified purchase runtime still depends on Edge-incompatible Node certificate or signature operations",
  );
});
