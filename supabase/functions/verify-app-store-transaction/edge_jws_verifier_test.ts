import { Buffer } from "node:buffer";
import { Environment } from "@apple/app-store-server-library";
import { KJUR } from "jsrsasign";
import {
  EdgeCompatibleSignedDataVerifier,
  parseCertificateBytes,
  parseCertificateTime,
} from "./edge_jws_verifier.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, received ${String(actual)}`);
  }
}

function assertThrows(callback: () => unknown): void {
  try {
    callback();
  } catch {
    return;
  }
  throw new Error("expected callback to throw");
}

async function assertRejects(
  callback: () => unknown | Promise<unknown>,
): Promise<void> {
  try {
    await callback();
  } catch {
    return;
  }
  throw new Error("expected promise to reject");
}

const appleLibraryEntry = import.meta.resolve(
  "@apple/app-store-server-library",
);
const appleFixtureSource = await Deno.readTextFile(
  new URL("./tests/unit-tests/jws_verification.test.js", appleLibraryEntry),
);

function appleFixture(name: string): string {
  const match = new RegExp(
    `const ${name} = "([A-Za-z0-9+/=]+)";`,
  ).exec(appleFixtureSource);
  if (!match) throw new Error(`missing Apple fixture: ${name}`);
  return match[1];
}

class ChainFixtureVerifier extends EdgeCompatibleSignedDataVerifier {
  constructor(rootBase64: string) {
    super(
      [Buffer.from(rootBase64, "base64")],
      false,
      Environment.PRODUCTION,
      "com.x5studio.app",
      6764340680,
    );
  }

  verifyFixture(
    leafBase64: string,
    intermediateBase64: string,
    effectiveDate: Date,
  ) {
    return this.verifyEdgeCertificateChain(
      parseCertificateBytes(Buffer.from(leafBase64, "base64")),
      parseCertificateBytes(Buffer.from(intermediateBase64, "base64")),
      effectiveDate,
    );
  }
}

Deno.test("parses X.509 UTC time using the RFC 5280 year window", () => {
  assertEquals(
    parseCertificateTime("230124194429Z"),
    Date.UTC(2023, 0, 24, 19, 44, 29),
  );
  assertEquals(
    parseCertificateTime("491231235959Z"),
    Date.UTC(2049, 11, 31, 23, 59, 59),
  );
  assertEquals(
    parseCertificateTime("500101000000Z"),
    Date.UTC(1950, 0, 1, 0, 0, 0),
  );
});

Deno.test("parses X.509 generalized time", () => {
  assertEquals(
    parseCertificateTime("20510124194429Z"),
    Date.UTC(2051, 0, 24, 19, 44, 29),
  );
});

Deno.test("rejects malformed or impossible X.509 times", () => {
  assertThrows(() => parseCertificateTime("20230230194429Z"));
  assertThrows(() => parseCertificateTime("230124194429+0000"));
  assertThrows(() => parseCertificateTime("not-a-time"));
});

Deno.test("verifies Apple's real signing chain and rejects trust failures", async () => {
  const realRoot = appleFixture("REAL_APPLE_ROOT_BASE64_ENCODED");
  const realIntermediate = appleFixture(
    "REAL_APPLE_INTERMEDIATE_BASE64_ENCODED",
  );
  const realLeaf = appleFixture(
    "REAL_APPLE_SIGNING_CERTIFICATE_BASE64_ENCODED",
  );
  const verifier = new ChainFixtureVerifier(realRoot);
  const key = await verifier.verifyFixture(
    realLeaf,
    realIntermediate,
    new Date(1761962975000),
  );
  assertEquals(key.getPublicKey() instanceof KJUR.crypto.ECDSA, true);

  const tamperedLeaf = Buffer.from(realLeaf, "base64");
  tamperedLeaf[tamperedLeaf.length - 1] ^= 1;
  await assertRejects(() =>
    verifier.verifyFixture(
      tamperedLeaf.toString("base64"),
      realIntermediate,
      new Date(1761962975000),
    )
  );
  await assertRejects(() =>
    verifier.verifyFixture(
      realLeaf,
      realIntermediate,
      new Date("2040-01-01T00:00:00Z"),
    )
  );

  const untrustedVerifier = new ChainFixtureVerifier(
    appleFixture("ROOT_CA_BASE64_ENCODED"),
  );
  await assertRejects(() =>
    untrustedVerifier.verifyFixture(
      realLeaf,
      realIntermediate,
      new Date(1761962975000),
    )
  );
});

Deno.test("rejects Apple chains with the wrong certificate-purpose OID", async () => {
  const verifier = new ChainFixtureVerifier(
    appleFixture("ROOT_CA_BASE64_ENCODED"),
  );
  const effectiveDate = new Date("2023-02-01T00:00:00Z");
  await assertRejects(() =>
    verifier.verifyFixture(
      appleFixture("LEAF_CERT_INVALID_OID_BASE64_ENCODED"),
      appleFixture("INTERMEDIATE_CA_BASE64_ENCODED"),
      effectiveDate,
    )
  );
  await assertRejects(() =>
    verifier.verifyFixture(
      appleFixture("LEAF_CERT_FOR_INTERMEDIATE_CA_INVALID_OID_BASE64_ENCODED"),
      appleFixture("INTERMEDIATE_CA_INVALID_OID_BASE64_ENCODED"),
      effectiveDate,
    )
  );
});
