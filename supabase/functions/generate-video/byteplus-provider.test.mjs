import test from "node:test";
import assert from "node:assert/strict";

import {
  BytePlusProviderError,
  BytePlusSeedanceProvider,
  mapBytePlusStatus,
} from "./byteplus-provider.mjs";

test("submits Seedance 2.0 Fast directly to the official BytePlus API", async () => {
  const calls = [];
  const provider = new BytePlusSeedanceProvider({
    apiKey: "ark-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({ id: "cgt-20260817-direct-fast" });
    },
  });

  const result = await provider.submit({
    model: "seedance-2.0-fast",
    prompt: "A product rotates under studio light",
    aspectRatio: "9:16",
    durationSeconds: 5,
    resolution: "720p",
    generateAudio: true,
    startImageUrl: "https://example.supabase.co/storage/start.jpg",
  });

  assert.deepEqual(result, {
    requestId: "cgt-20260817-direct-fast",
    kind: "image",
  });
  assert.equal(
    calls[0].url,
    "https://ark.ap-southeast.bytepluses.com/api/v3/contents/generations/tasks",
  );
  assert.equal(calls[0].init.headers.Authorization, "Bearer ark-secret");
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    model: "dreamina-seedance-2-0-fast-260128",
    content: [
      { type: "text", text: "A product rotates under studio light" },
      {
        type: "image_url",
        image_url: {
          url: "https://example.supabase.co/storage/start.jpg",
        },
      },
    ],
    generate_audio: true,
    ratio: "9:16",
    duration: 5,
    resolution: "720p",
    watermark: false,
  });
});

test("keeps legacy Seedance 1.5 requests on BytePlus rather than fal", async () => {
  let body;
  const provider = new BytePlusSeedanceProvider({
    apiKey: "ark-secret",
    fetchImpl: async (_url, init) => {
      body = JSON.parse(init.body);
      return Response.json({ id: "cgt-20260817-direct-legacy" });
    },
  });

  await provider.submit({
    model: "seedance-1.5-pro",
    prompt: "City lights",
    aspectRatio: "16:9",
    durationSeconds: 10,
    resolution: "1080p",
    generateAudio: false,
  });
  assert.equal(body.model, "seedance-1-5-pro-251215");
});

test("rejects unsupported 1080p for Seedance 2.0 Fast before billing", async () => {
  const provider = new BytePlusSeedanceProvider({ apiKey: "ark-secret" });
  await assert.rejects(
    () =>
      provider.submit({
        model: "seedance-2.0-fast",
        prompt: "City lights",
        aspectRatio: "16:9",
        durationSeconds: 5,
        resolution: "1080p",
        generateAudio: true,
      }),
    (error) => {
      assert.ok(error instanceof BytePlusProviderError);
      assert.equal(error.code, "provider_resolution_invalid");
      assert.equal(error.retryable, false);
      return true;
    },
  );
});

test("maps official task states and returns the MP4 URL", () => {
  assert.deepEqual(mapBytePlusStatus({ status: "queued" }), {
    status: "queued",
    progress: 0.05,
    completed: false,
  });
  assert.deepEqual(mapBytePlusStatus({ status: "running" }), {
    status: "rendering",
    progress: 0.5,
    completed: false,
  });
  assert.deepEqual(
    mapBytePlusStatus({
      status: "succeeded",
      content: {
        video_url:
          "https://ark-content-generation-ap-southeast-1.tos-ap-southeast-1.volces.com/video.mp4",
      },
    }),
    {
      status: "completed",
      progress: 0.9,
      completed: true,
      result: {
        url:
          "https://ark-content-generation-ap-southeast-1.tos-ap-southeast-1.volces.com/video.mp4",
        mimeType: "video/mp4",
        byteLength: 0,
      },
    },
  );
  assert.equal(mapBytePlusStatus({ status: "failed" }).status, "failed");
});

test("treats a lost submit response as ambiguous to prevent double billing", async () => {
  const provider = new BytePlusSeedanceProvider({
    apiKey: "ark-secret",
    fetchImpl: async () => {
      throw new TypeError("connection reset");
    },
  });
  await assert.rejects(
    () =>
      provider.submit({
        model: "seedance-2.0-fast",
        prompt: "City lights",
        aspectRatio: "16:9",
        durationSeconds: 5,
        resolution: "720p",
        generateAudio: true,
      }),
    (error) => {
      assert.equal(error.submissionAmbiguous, true);
      assert.equal(error.retryable, true);
      return true;
    },
  );
});
