import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const edgeURL = new URL(
  "../functions/startup-chat/index.ts",
  import.meta.url,
);
const contractURL = new URL(
  "../functions/startup-chat/contract.mjs",
  import.meta.url,
);
const providerURL = new URL(
  "../functions/startup-chat/provider.mjs",
  import.meta.url,
);

test("startup chat endpoint is isolated and server authenticated", () => {
  assert.equal(existsSync(edgeURL), true);
  assert.equal(existsSync(contractURL), true);
  assert.equal(existsSync(providerURL), true);

  const source = readFileSync(edgeURL, "utf8");
  const provider = readFileSync(providerURL, "utf8");
  assert.match(
    source,
    /const openAIKey = \(Deno\.env\.get\("OPENAI_API_KEY"\) \|\| ""\)\.trim\(\)/,
  );
  assert.match(source, /createOpenAIStartupChatProvider/);
  assert.match(provider, /https:\/\/api\.openai\.com\/v1\/moderations/);
  assert.match(provider, /https:\/\/api\.openai\.com\/v1\/responses/);
  assert.match(source, /verifyUser/);
  assert.match(source, /Bearer/);
  assert.match(source, /safeError/);
  assert.doesNotMatch(source, /return json\([^)]*providerPayload/i);
});

test("startup chat response never includes secrets or raw provider payload", () => {
  const source = readFileSync(edgeURL, "utf8");

  assert.doesNotMatch(source, /apiKey\s*[,}]/);
  assert.doesNotMatch(source, /providerPayload\??\.error\??\.message/);
  assert.match(source, /assistant_unavailable/);
  assert.match(source, /Cache-Control.*no-store/s);
});

test("every post-claim failure path releases only its own lease generation", () => {
  const source = readFileSync(edgeURL, "utf8");
  const releaseCalls = source.match(/await releaseStartupChatClaim\(/g) || [];

  assert.match(source, /release_startup_chat_request/);
  assert.equal(
    releaseCalls.length,
    2,
    "provider/moderation failures and ambiguous completion must release",
  );
  assert.match(
    source,
    /!completion[\s\S]*?completion\.status !== "completed"[\s\S]*?await releaseStartupChatClaim\(/,
  );
  assert.match(
    source,
    /\} catch \(error\) \{[\s\S]*?await releaseStartupChatClaim\([\s\S]*?startup_chat_provider_failed/,
  );
  assert.match(
    source,
    /claim\.lease_token[\s\S]*?typeof[\s\S]*?leaseToken/,
  );
  assert.match(
    source,
    /complete_startup_chat_request[\s\S]*?p_lease_token:\s*leaseToken/,
  );
  assert.match(
    source,
    /release_startup_chat_request[\s\S]*?p_lease_token:\s*leaseToken/,
  );
  assert.doesNotMatch(
    source,
    /["']lease_token["']\s*:/,
    "the ownership token must never be included in a public client response",
  );
  const provider = readFileSync(providerURL, "utf8");
  assert.match(provider, /"Idempotency-Key": requestID/);
  assert.match(source, /providerError\?\.code === "content_rejected"/);
  assert.doesNotMatch(
    source,
    /claim_generation_credits|deduct_credits|generation_credits/,
    "Startup Chat must not mutate the user's credit balance",
  );
});
