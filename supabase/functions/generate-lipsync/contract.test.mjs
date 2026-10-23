import assert from "node:assert/strict";
import test from "node:test";
import {
  buildLipsyncFingerprint,
  LIPSYNC_CREDITS_PER_SECOND,
  normalizeLipsyncRequest,
  publicLipsyncJob,
} from "./contract.mjs";

const body = {
  request_id: "11111111-1111-4111-8111-111111111111",
  video_asset_id: "22222222-2222-4222-8222-222222222222",
  audio_asset_id: "33333333-3333-4333-8333-333333333333",
  duration_seconds: 10,
};

test("normalizes owner asset IDs and computes the x2 credit price", async () => {
  const normalized = normalizeLipsyncRequest(body);
  assert.equal(LIPSYNC_CREDITS_PER_SECOND, 50);
  assert.equal(normalized.costCredits, 500);
  assert.match(await buildLipsyncFingerprint(normalized), /^[0-9a-f]{64}$/);
});

test("rejects malformed IDs and unsupported durations before debit", () => {
  assert.throws(
    () => normalizeLipsyncRequest({ ...body, request_id: "bad" }),
    /invalid_asset_or_request_id/,
  );
  assert.throws(
    () => normalizeLipsyncRequest({ ...body, duration_seconds: 61 }),
    /unsupported_duration/,
  );
});

test("public job never exposes private object paths", () => {
  const job = publicLipsyncJob({
    id: body.request_id,
    job_status: "completed",
    result_object_path: "secret/path.mp4",
    cost_credits: 500,
  }, {
    signedURL: "https://example.test/signed",
    expiresAt: "2026-08-25T12:00:00Z",
  });
  assert.equal(job.result_url, "https://example.test/signed");
  assert.doesNotMatch(JSON.stringify(job), /secret\/path/);
});
