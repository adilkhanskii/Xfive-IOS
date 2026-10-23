import assert from "node:assert/strict";
import test from "node:test";

import * as storageModule from "./storage.mjs";

const { VideoStorage } = storageModule;

const pngBytes = Uint8Array.from([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);
const mp4Bytes = Uint8Array.from([
  0x00,
  0x00,
  0x00,
  0x18,
  0x66,
  0x74,
  0x79,
  0x70,
  0x69,
  0x73,
  0x6f,
  0x6d,
]);

test("decodes inline provider video only within the configured byte limit", () => {
  assert.equal(
    typeof storageModule.decodeBoundedProviderVideoBase64,
    "function",
  );
  const encoded = Buffer.from(mp4Bytes).toString("base64");
  assert.deepEqual(
    storageModule.decodeBoundedProviderVideoBase64(
      encoded,
      mp4Bytes.byteLength,
    ),
    mp4Bytes,
  );
  assert.throws(
    () =>
      storageModule.decodeBoundedProviderVideoBase64(
        encoded,
        mp4Bytes.byteLength - 1,
      ),
    /provider_result_too_large/,
  );
});

test("streams a provider response and stops before an unknown-length body grows", async () => {
  assert.equal(typeof storageModule.readResponseBodyBounded, "function");
  const response = new Response(
    new ReadableStream({
      start(controller) {
        controller.enqueue(Uint8Array.from([1, 2, 3]));
        controller.enqueue(Uint8Array.from([4, 5, 6]));
        controller.close();
      },
    }),
  );
  await assert.rejects(
    storageModule.readResponseBodyBounded(response, 5),
    /provider_result_too_large/,
  );
});

test("classifies a declared oversized provider result as permanent", async () => {
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async () =>
      new Response(null, {
        status: 200,
        headers: { "Content-Length": String((50 * 1024 * 1024) + 1) },
      }),
  });

  await assert.rejects(
    storage.downloadProviderVideo(
      "https://v3.fal.media/files/oversized.mp4",
      { providerName: "fal" },
    ),
    /provider_result_too_large/,
  );
});

test("stores the start image in the private per-owner input path", async () => {
  const calls = [];
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return new Response(null, { status: 200 });
    },
  });

  const object = await storage.storeStartImage({
    userId: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
    jobId: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    image: {
      mimeType: "image/png",
      dataBase64: Buffer.from(pngBytes).toString("base64"),
    },
  });

  assert.equal(
    object.path,
    "0fb5b519-d40e-4502-8f44-462ea699e6c7/34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f/start.png",
  );
  assert.match(calls[0].url, /video-generation-inputs/);
  assert.equal(calls[0].init.headers["x-upsert"], "false");
  assert.equal(calls[0].init.headers.Authorization, "Bearer service-secret");
});

test("creates only a short-lived signed URL for private objects", async () => {
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async () =>
      Response.json({
        signedURL:
          "/storage/v1/object/sign/video-generation-results/path?token=abc",
      }),
    now: () => new Date("2026-07-25T10:00:00.000Z"),
  });

  const signed = await storage.signResult("owner/job/result.mp4");
  assert.match(signed.signedUrl, /^https:\/\/project\.supabase\.co\/storage/);
  assert.equal(signed.expiresAt, "2026-07-25T10:15:00.000Z");
});

test("deletes only an exact per-owner start-image path", async () => {
  const calls = [];
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return new Response(null, { status: 200 });
    },
  });

  await storage.deleteStartImage(
    "0fb5b519-d40e-4502-8f44-462ea699e6c7/34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f/start.jpg",
  );
  assert.equal(calls[0].init.method, "DELETE");
  assert.match(calls[0].url, /video-generation-inputs/);

  for (
    const invalidPath of [
      "../start.jpg",
      "owner/job/result.mp4",
      "owner/job/start.jpg",
      "0fb5b519-d40e-4502-8f44-462ea699e6c7/34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f/other.jpg",
    ]
  ) {
    await assert.rejects(
      () => storage.deleteStartImage(invalidPath),
      /start_image_path_invalid/,
    );
  }
  assert.equal(calls.length, 1);
});

test("stores an idempotent bounded MP4 result and rejects other bytes", async () => {
  const calls = [];
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return new Response(null, { status: 200 });
    },
  });
  const object = await storage.storeResult({
    userId: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
    jobId: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    bytes: mp4Bytes,
  });

  assert.equal(
    object.path,
    "0fb5b519-d40e-4502-8f44-462ea699e6c7/34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f/result.mp4",
  );
  assert.match(object.sha256, /^[0-9a-f]{64}$/);
  assert.equal(object.mimeType, "video/mp4");
  assert.equal(calls[0].init.headers["x-upsert"], "true");
  await assert.rejects(
    () =>
      storage.storeResult({
        userId: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
        jobId: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
        bytes: pngBytes,
      }),
    /generated_video_invalid/,
  );
});

test("downloads only allowlisted HTTPS provider video within the private bucket limit", async () => {
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async (url) => {
      assert.match(String(url), /^https:\/\//);
      return new Response(mp4Bytes, {
        headers: {
          "Content-Type": "video/mp4",
          "Content-Length": String(mp4Bytes.byteLength),
        },
      });
    },
  });
  assert.deepEqual(
    await storage.downloadProviderVideo(
      "https://v3.fal.media/files/result.mp4",
      { providerName: "fal" },
    ),
    mp4Bytes,
  );
  assert.deepEqual(
    await storage.downloadProviderVideo(
      "https://ark-content-generation-ap-southeast-1.tos-ap-southeast-1.volces.com/result.mp4",
      { providerName: "byteplus" },
    ),
    mp4Bytes,
  );
  await assert.rejects(
    () =>
      storage.downloadProviderVideo("http://v3.fal.media/result.mp4", {
        providerName: "fal",
      }),
    /provider_result_invalid/,
  );
  await assert.rejects(
    () =>
      storage.downloadProviderVideo("https://127.0.0.1/result.mp4", {
        providerName: "fal",
      }),
    /provider_result_invalid/,
  );
  await assert.rejects(
    () =>
      storage.downloadProviderVideo("https://attacker.example/result.mp4", {
        providerName: "google",
      }),
    /provider_result_invalid/,
  );
  await assert.rejects(
    () =>
      storage.downloadProviderVideo("https://volces.com.attacker.example/result.mp4", {
        providerName: "byteplus",
      }),
    /provider_result_invalid/,
  );
});

test("checks every redirect and never forwards the Google API key cross-host", async () => {
  const calls = [];
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), headers: init.headers });
      if (calls.length === 1) {
        return new Response(null, {
          status: 302,
          headers: {
            Location: "https://storage.googleapis.com/video/result.mp4",
          },
        });
      }
      return new Response(mp4Bytes, {
        status: 200,
        headers: {
          "Content-Type": "video/mp4",
          "Content-Length": String(mp4Bytes.byteLength),
        },
      });
    },
  });

  assert.deepEqual(
    await storage.downloadProviderVideo(
      "https://generativelanguage.googleapis.com/v1beta/files/a:download",
      {
        providerName: "google",
        headers: { "x-goog-api-key": "google-server-secret" },
      },
    ),
    mp4Bytes,
  );
  assert.equal(calls[0].headers["x-goog-api-key"], "google-server-secret");
  assert.equal(calls[1].headers["x-goog-api-key"], undefined);
});

test("rejects a provider redirect to an untrusted or private destination", async () => {
  const storage = new VideoStorage({
    supabaseUrl: "https://project.supabase.co",
    serviceKey: "service-secret",
    fetchImpl: async () =>
      new Response(null, {
        status: 302,
        headers: {
          Location: "https://169.254.169.254/latest/meta-data",
        },
      }),
  });

  await assert.rejects(
    () =>
      storage.downloadProviderVideo(
        "https://v3.fal.media/files/result.mp4",
        { providerName: "fal" },
      ),
    /provider_result_invalid/,
  );
});
