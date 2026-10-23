import assert from "node:assert/strict";
import test from "node:test";

import {
  automaticPendingDecision,
  decisionFromModerationResult,
} from "./decision.mjs";

test("safe automatic moderation is approved", () => {
  const decision = decisionFromModerationResult({
    flagged: false,
    categories: {
      sexual: false,
      violence: false,
    },
  }, { raw: "payload" });

  assert.equal(decision.status, "approved");
  assert.match(decision.reason, /автомат/i);
  assert.equal(decision.error, null);
  assert.equal(decision.result.raw, "payload");
});

test("flagged automatic moderation is rejected", () => {
  const decision = decisionFromModerationResult({
    flagged: true,
    categories: {
      sexual: true,
      violence: false,
    },
  }, { raw: "payload" });

  assert.equal(decision.status, "rejected");
  assert.match(decision.reason, /сексуаль/i);
  assert.equal(decision.error, null);
});

test("automatic moderation failures stay pending for retry", () => {
  const decision = automaticPendingDecision({
    code: "provider_unavailable",
    error: "OpenAI 503",
    result: { openai_status: 503 },
  });

  assert.equal(decision.status, "pending");
  assert.equal(decision.result.retryable, true);
  assert.equal(decision.result.retry_reason, "provider_unavailable");
  assert.equal(decision.error, "OpenAI 503");
  assert.doesNotMatch(decision.reason, /ручн/i);
});

test("invalid automatic moderation response stays pending for retry", () => {
  const decision = decisionFromModerationResult(
    { categories: {} },
    { raw: "invalid" },
  );

  assert.equal(decision.status, "pending");
  assert.equal(decision.result.retryable, true);
  assert.equal(decision.result.retry_reason, "moderation_response_invalid");
  assert.equal(decision.error, "moderation_response_invalid");
});
