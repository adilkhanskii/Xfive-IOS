import assert from "node:assert/strict";
import test from "node:test";

import {
  buildPublicVideoJob,
  buildVideoGenerationIdentity,
  normalizeVideoGenerationRequest,
  VideoRequestError,
} from "./contract.mjs";

const tinyPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

test("normalizes a text-to-video request and keeps pricing server-owned", () => {
  const normalized = normalizeVideoGenerationRequest({
    idempotency_key: "video-request-0001",
    prompt: "  A cinematic launch video for a coffee shop  ",
    aspect_ratio: "9:16",
    duration_seconds: 10,
    credits_reserved: 1,
  });

  assert.equal(
    normalized.prompt,
    "A cinematic launch video for a coffee shop",
  );
  assert.equal(normalized.aspectRatio, "9:16");
  assert.equal(normalized.durationSeconds, 10);
  assert.equal(normalized.costCredits, 1200);
  assert.equal(normalized.model, "auto");
  assert.equal(normalized.resolution, "720p");
  assert.equal(normalized.generateAudio, false);
  assert.equal(normalized.startImage, null);
});

test("normalizes an explicit Seedance 1.5 Pro request", () => {
  const normalized = normalizeVideoGenerationRequest({
    idempotency_key: "video-seedance-0001",
    prompt: "A cinematic launch video for a coffee shop",
    aspect_ratio: "9:16",
    duration_seconds: 10,
    model: "seedance-1.5-pro",
    resolution: "1080p",
    generate_audio: true,
  });

  assert.equal(normalized.model, "seedance-1.5-pro");
  assert.equal(normalized.resolution, "1080p");
  assert.equal(normalized.generateAudio, true);
  assert.equal(normalized.costCredits, 1200);
});

test("normalizes Seedance 2.0 Fast and rejects unsupported 1080p", () => {
  const normalized = normalizeVideoGenerationRequest({
    idempotency_key: "video-seedance-fast-0001",
    prompt: "A cinematic product reveal",
    aspect_ratio: "9:16",
    duration_seconds: 5,
    model: "seedance-2.0-fast",
    resolution: "720p",
  });

  assert.equal(normalized.model, "seedance-2.0-fast");
  assert.equal(normalized.generateAudio, true);
  assert.equal(normalized.costCredits, 650);
  assert.throws(
    () =>
      normalizeVideoGenerationRequest({
        idempotency_key: "video-seedance-fast-0002",
        prompt: "A cinematic product reveal",
        aspect_ratio: "9:16",
        duration_seconds: 5,
        model: "seedance-2.0-fast",
        resolution: "1080p",
      }),
    (error) =>
      error instanceof VideoRequestError &&
      error.code === "unsupported_resolution",
  );
});

test("accepts a private-safe base64 start image up to eight MiB", () => {
  const normalized = normalizeVideoGenerationRequest({
    idempotency_key: "video-request-0002",
    prompt: "Animate the product with a gentle camera orbit",
    aspect_ratio: "9:16",
    duration_seconds: 5,
    start_image: {
      mime_type: "image/png",
      data_base64: `data:image/png;base64,${tinyPng}`,
    },
  });

  assert.equal(normalized.costCredits, 650);
  assert.equal(normalized.startImage.mimeType, "image/png");
  assert.equal(normalized.startImage.dataBase64, tinyPng);
  assert.ok(normalized.startImage.byteLength > 0);
  assert.ok(normalized.startImage.byteLength <= 8 * 1024 * 1024);
});

test("rejects invalid prompts, duration, aspect ratio, key, and images", () => {
  const base = {
    idempotency_key: "video-request-0003",
    prompt: "A valid prompt",
    aspect_ratio: "16:9",
    duration_seconds: 5,
  };

  for (
    const [patch, code] of [
      [{ prompt: " " }, "prompt_required"],
      [{ duration_seconds: 9 }, "unsupported_duration"],
      [{ aspect_ratio: "4:5" }, "unsupported_aspect_ratio"],
      [{ aspect_ratio: "1:1" }, "unsupported_aspect_ratio"],
      [{ model: "seedance-latest" }, "unsupported_model"],
      [{ resolution: "4k" }, "unsupported_resolution"],
      [{ generate_audio: "true" }, "invalid_generate_audio"],
      [{ idempotency_key: "short" }, "invalid_idempotency_key"],
      [{
        start_image: { mime_type: "image/gif", data_base64: tinyPng },
      }, "unsupported_start_image"],
      [{
        start_image: {
          mime_type: "image/png",
          data_base64: "A".repeat(12 * 1024 * 1024),
        },
      }, "start_image_too_large"],
    ]
  ) {
    assert.throws(
      () => normalizeVideoGenerationRequest({ ...base, ...patch }),
      (error) => error instanceof VideoRequestError && error.code === code,
    );
  }
});

test("hashes idempotency and semantic inputs without retaining raw media", async () => {
  const normalized = normalizeVideoGenerationRequest({
    idempotency_key: "video-request-0004",
    prompt: "Animate this still image",
    aspect_ratio: "9:16",
    duration_seconds: 5,
    start_image: { mime_type: "image/png", data_base64: tinyPng },
  });
  const identity = await buildVideoGenerationIdentity(normalized);

  assert.match(identity.requestKey, /^explicit:[0-9a-f]{64}$/);
  assert.match(identity.fingerprint, /^[0-9a-f]{64}$/);
  assert.notEqual(identity.requestKey, identity.fingerprint);
  assert.doesNotMatch(JSON.stringify(identity), /iVBOR/);
});

test("fingerprints model, resolution, and native audio settings", async () => {
  const base = {
    idempotency_key: "video-request-model-fingerprint",
    prompt: "Animate this still image",
    aspect_ratio: "9:16",
    duration_seconds: 5,
    model: "seedance-1.5-pro",
    resolution: "720p",
    generate_audio: true,
  };
  const baseline = await buildVideoGenerationIdentity(
    normalizeVideoGenerationRequest(base),
  );

  for (
    const patch of [
      { model: "auto", generate_audio: false },
      { resolution: "1080p" },
      { generate_audio: false },
    ]
  ) {
    const changed = await buildVideoGenerationIdentity(
      normalizeVideoGenerationRequest({ ...base, ...patch }),
    );
    assert.notEqual(changed.fingerprint, baseline.fingerprint);
  }
});

test("returns only the public job contract and a temporary signed result", () => {
  const job = buildPublicVideoJob(
    {
      id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
      status: "completed",
      progress: 1,
      cost_credits: 1200,
      refunded_at: null,
      error_code: null,
      provider_request_id: "secret-provider-id",
      result_object_path: "private/path/result.mp4",
      created_at: "2026-07-25T10:00:00.000Z",
      updated_at: "2026-07-25T10:05:00.000Z",
    },
    {
      signedUrl: "https://project.supabase.co/storage/v1/object/sign/result",
      expiresAt: "2026-07-25T10:20:00.000Z",
    },
  );

  assert.deepEqual(job, {
    id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    status: "completed",
    progress: 1,
    credits_reserved: 1200,
    refunded: false,
    result_url: "https://project.supabase.co/storage/v1/object/sign/result",
    result_url_expires_at: "2026-07-25T10:20:00.000Z",
    asset_id: null,
    error_code: null,
    created_at: "2026-07-25T10:00:00.000Z",
    updated_at: "2026-07-25T10:05:00.000Z",
  });
  assert.doesNotMatch(JSON.stringify(job), /provider|object_path|FAL_KEY/i);
});
