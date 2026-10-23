import assert from "node:assert/strict";
import test from "node:test";

import {
  extractFalVideo,
  FalKlingProvider,
  FalProviderError,
  mapFalQueueStatus,
} from "./fal-provider.mjs";

const submitRequest = {
  prompt: "Cinematic product reveal",
  aspectRatio: "9:16",
  durationSeconds: 5,
  startImageUrl: null,
  webhookUrl: null,
};

test("submits Kling V3 Standard text jobs through the fal async queue", async () => {
  const calls = [];
  const provider = new FalKlingProvider({
    apiKey: "server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return new Response(JSON.stringify({ request_id: "fal-request-1" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
  });

  const result = await provider.submit({
    prompt: "Cinematic product reveal",
    aspectRatio: "9:16",
    durationSeconds: 10,
    startImageUrl: null,
    webhookUrl:
      "https://example.supabase.co/functions/v1/generate-video?webhook=fal",
  });

  assert.equal(result.requestId, "fal-request-1");
  assert.match(calls[0].url, /kling-video\/v3\/standard\/text-to-video/);
  assert.match(calls[0].url, /fal_webhook=/);
  assert.equal(calls[0].init.headers.Authorization, "Key server-only-key");
  const body = JSON.parse(calls[0].init.body);
  assert.deepEqual(body, {
    prompt: "Cinematic product reveal",
    duration: "10",
    generate_audio: false,
    shot_type: "customize",
    aspect_ratio: "9:16",
    negative_prompt:
      "blur, distort, low quality, explicit sexual content, gore",
    cfg_scale: 0.5,
  });
  assert.doesNotMatch(calls[0].init.body, /server-only-key/);
});

test("uses the image-to-video route and a temporary signed input URL", async () => {
  const calls = [];
  const provider = new FalKlingProvider({
    apiKey: "server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({ request_id: "fal-request-2" });
    },
  });

  await provider.submit({
    prompt: "Bring the character to life",
    aspectRatio: "1:1",
    durationSeconds: 5,
    startImageUrl:
      "https://project.supabase.co/storage/v1/object/sign/private-input",
    webhookUrl: null,
  });

  assert.match(calls[0].url, /kling-video\/v3\/standard\/image-to-video/);
  assert.equal(
    JSON.parse(calls[0].init.body).start_image_url,
    "https://project.supabase.co/storage/v1/object/sign/private-input",
  );
  assert.equal(
    Object.hasOwn(JSON.parse(calls[0].init.body), "aspect_ratio"),
    false,
  );
});

test("submits Seedance 1.5 Pro text jobs with native audio and safety enabled", async () => {
  const calls = [];
  const provider = new FalKlingProvider({
    apiKey: "server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({ request_id: "seedance-request-text-1" });
    },
  });

  const result = await provider.submit({
    model: "seedance-1.5-pro",
    prompt: "A cinematic product reveal",
    aspectRatio: "9:16",
    durationSeconds: 10,
    resolution: "1080p",
    generateAudio: true,
    startImageUrl: null,
    webhookUrl:
      "https://example.supabase.co/functions/v1/generate-video?webhook=fal",
    enableSafetyChecker: false,
  });

  assert.equal(result.requestId, "seedance-request-text-1");
  assert.match(
    calls[0].url,
    /bytedance\/seedance\/v1\.5\/pro\/text-to-video/,
  );
  assert.match(calls[0].url, /fal_webhook=/);
  assert.equal(calls[0].init.headers.Authorization, "Key server-only-key");
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    prompt: "A cinematic product reveal",
    aspect_ratio: "9:16",
    resolution: "1080p",
    duration: "10",
    enable_safety_checker: true,
    generate_audio: true,
  });
  assert.doesNotMatch(calls[0].init.body, /server-only-key/);
});

test("submits Seedance 1.5 Pro image jobs with the official image_url field", async () => {
  const calls = [];
  const provider = new FalKlingProvider({
    apiKey: "server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({ request_id: "seedance-request-image-1" });
    },
  });

  await provider.submit({
    model: "seedance-1.5-pro",
    prompt: "Bring the character to life",
    aspectRatio: "16:9",
    durationSeconds: 5,
    resolution: "720p",
    generateAudio: false,
    startImageUrl:
      "https://project.supabase.co/storage/v1/object/sign/private-input",
    webhookUrl: null,
  });

  assert.match(
    calls[0].url,
    /bytedance\/seedance\/v1\.5\/pro\/image-to-video/,
  );
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    prompt: "Bring the character to life",
    aspect_ratio: "16:9",
    resolution: "720p",
    duration: "5",
    enable_safety_checker: true,
    generate_audio: false,
    image_url:
      "https://project.supabase.co/storage/v1/object/sign/private-input",
  });
  assert.equal(
    Object.hasOwn(JSON.parse(calls[0].init.body), "start_image_url"),
    false,
  );
});

test("reconciles Seedance jobs when only the legacy provider kind was persisted", async () => {
  const calls = [];
  const provider = new FalKlingProvider({
    apiKey: "server-only-key",
    fetchImpl: async (url) => {
      const value = String(url);
      calls.push(value);
      if (value.includes("/kling-video/")) {
        return Response.json({ error: "request not found" }, { status: 404 });
      }
      if (value.endsWith("/status")) {
        return Response.json({ status: "IN_PROGRESS" });
      }
      return Response.json({
        video: {
          url: "https://v3.fal.media/files/seedance-result.mp4",
          content_type: "video/mp4",
          file_size: 4_000_000,
        },
      });
    },
  });

  assert.deepEqual(
    await provider.status({ requestId: "seedance-request-1", kind: "text" }),
    { status: "rendering", progress: 0.5, completed: false },
  );
  assert.deepEqual(
    await provider.result({ requestId: "seedance-request-1", kind: "text" }),
    {
      url: "https://v3.fal.media/files/seedance-result.mp4",
      mimeType: "video/mp4",
      byteLength: 4_000_000,
    },
  );
  assert.equal(calls.filter((url) => url.includes("/kling-video/")).length, 2);
  assert.equal(
    calls.filter((url) => url.includes("/bytedance/seedance/")).length,
    2,
  );
});

test("falls back only after a definitive fal overload rejection", async () => {
  for (const status of [429]) {
    const provider = new FalKlingProvider({
      apiKey: "server-only-key",
      fetchImpl: async () => Response.json({ error: "busy" }, { status }),
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof FalProviderError);
        assert.equal(error.httpStatus, status);
        assert.equal(error.retryable, true);
        assert.equal(error.safeToFallback, true);
        assert.equal(error.submissionAmbiguous, false);
        return true;
      },
    );
  }

  for (const status of [408, 502, 503, 504]) {
    const provider = new FalKlingProvider({
      apiKey: "server-only-key",
      fetchImpl: async () => Response.json({ error: "busy" }, { status }),
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof FalProviderError);
        assert.equal(error.httpStatus, status);
        assert.equal(error.retryable, true);
        assert.equal(error.safeToFallback, false);
        assert.equal(error.submissionAmbiguous, true);
        return true;
      },
    );
  }

  for (const status of [400, 401, 403, 422]) {
    const provider = new FalKlingProvider({
      apiKey: "server-only-key",
      fetchImpl: async () => Response.json({ error: "rejected" }, { status }),
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof FalProviderError);
        assert.equal(error.httpStatus, status);
        assert.equal(error.retryable, false);
        assert.equal(error.safeToFallback, false);
        return true;
      },
    );
  }
});

test("classifies timeout and connection reset as ambiguous, never fallback-safe", async () => {
  for (
    const failure of [
      new DOMException("timed out", "TimeoutError"),
      new Error("ECONNRESET"),
    ]
  ) {
    const provider = new FalKlingProvider({
      apiKey: "server-only-key",
      fetchImpl: async () => {
        throw failure;
      },
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof FalProviderError);
        assert.equal(error.code, "provider_transport_ambiguous");
        assert.equal(error.retryable, true);
        assert.equal(error.safeToFallback, false);
        return true;
      },
    );
  }
});

test("maps queue states without leaking provider errors", () => {
  assert.deepEqual(mapFalQueueStatus({ status: "IN_QUEUE" }), {
    status: "queued",
    progress: 0.05,
    completed: false,
  });
  assert.deepEqual(mapFalQueueStatus({ status: "IN_PROGRESS" }), {
    status: "rendering",
    progress: 0.5,
    completed: false,
  });
  assert.deepEqual(mapFalQueueStatus({ status: "COMPLETED" }), {
    status: "completed",
    progress: 0.9,
    completed: true,
  });
  assert.deepEqual(
    mapFalQueueStatus({
      status: "COMPLETED",
      error: "private upstream diagnostics",
    }),
    {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: "provider_failed",
    },
  );
});

test("accepts only an HTTPS MP4 provider result", () => {
  assert.deepEqual(
    extractFalVideo({
      video: {
        url: "https://v3.fal.media/files/result.mp4",
        content_type: "video/mp4",
        file_size: 4_000_000,
      },
    }),
    {
      url: "https://v3.fal.media/files/result.mp4",
      mimeType: "video/mp4",
      byteLength: 4_000_000,
    },
  );

  assert.throws(
    () =>
      extractFalVideo({
        video: {
          url: "http://example.test/result.mp4",
          content_type: "video/mp4",
        },
      }),
    /provider_result_invalid/,
  );
});
