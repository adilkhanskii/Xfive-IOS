import assert from "node:assert/strict";
import test from "node:test";
import { FalSyncProvider, isFalMediaURL } from "./fal-sync-provider.mjs";

test("submits Sync Lipsync with signed video and audio URLs", async () => {
  let request;
  const provider = new FalSyncProvider({
    apiKey: "secret",
    fetchImpl: (url, options) => {
      request = { url: String(url), options };
      return Response.json({ request_id: "request_12345678" });
    },
  });
  const result = await provider.submit({
    videoURL: "https://storage.test/video",
    audioURL: "https://storage.test/audio",
  });
  assert.equal(result.requestID, "request_12345678");
  assert.equal(request.url, "https://queue.fal.run/fal-ai/sync-lipsync");
  assert.equal(request.options.headers.Authorization, "Key secret");
  assert.deepEqual(JSON.parse(request.options.body), {
    video_url: "https://storage.test/video",
    audio_url: "https://storage.test/audio",
  });
});

test("maps queue status and validates the result host", async () => {
  const responses = [
    Response.json({ status: "IN_PROGRESS" }),
    Response.json({
      video: {
        url: "https://v3.fal.media/files/output.mp4",
        content_type: "video/mp4",
      },
    }),
  ];
  const provider = new FalSyncProvider({
    apiKey: "secret",
    fetchImpl: () => responses.shift(),
  });
  assert.deepEqual(await provider.status("request_12345678"), {
    state: "processing",
    progress: 0.55,
  });
  assert.equal(
    (await provider.result("request_12345678")).mimeType,
    "video/mp4",
  );
  assert.equal(isFalMediaURL("https://evil.test/result.mp4"), false);
});

test("a lost submit response is ambiguous and cannot be double-submitted", async () => {
  const provider = new FalSyncProvider({
    apiKey: "secret",
    fetchImpl: () => {
      throw new Error("timeout");
    },
  });
  await assert.rejects(
    provider.submit({ videoURL: "https://a", audioURL: "https://b" }),
    (error) => error.submissionAmbiguous === true,
  );
});
