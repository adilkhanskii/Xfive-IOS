import assert from "node:assert/strict";
import test from "node:test";

import {
  mapOpenAIVideoDuration,
  mapOpenAIVideoSize,
  mapOpenAIVideoStatus,
  OpenAIProviderError,
  OpenAIVideoProvider,
} from "./openai-provider.mjs";

const tinyPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

const submitRequest = {
  prompt: "A cinematic vertical product reveal",
  aspectRatio: "9:16",
  durationSeconds: 5,
  startImage: null,
};

test("maps the app durations and aspect ratios to Sora values", () => {
  assert.equal(mapOpenAIVideoDuration(5), "4");
  assert.equal(mapOpenAIVideoDuration(10), "8");
  assert.equal(mapOpenAIVideoSize("9:16"), "720x1280");
  assert.equal(mapOpenAIVideoSize("16:9"), "1280x720");

  assert.throws(() => mapOpenAIVideoDuration(12), /unsupported_duration/);
  assert.throws(() => mapOpenAIVideoSize("1:1"), /unsupported_aspect_ratio/);
});

test("submits a bounded JSON Sora job without leaking the API key", async () => {
  const calls = [];
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({
        id: "video_12345678",
        object: "video",
        status: "queued",
        progress: 0,
      });
    },
  });

  const result = await provider.submit(submitRequest);

  assert.deepEqual(result, {
    requestId: "video_12345678",
    kind: "text",
    status: "queued",
  });
  assert.equal(calls[0].url, "https://api.openai.com/v1/videos");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(
    calls[0].init.headers.Authorization,
    "Bearer openai-server-only-key",
  );
  assert.equal(calls[0].init.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    model: "sora-2",
    prompt: "A cinematic vertical product reveal",
    seconds: "4",
    size: "720x1280",
  });
  assert.doesNotMatch(
    calls[0].url + JSON.stringify(result),
    /openai-server-only-key/,
  );
});

test("submits a private in-memory image as a data URL input reference", async () => {
  let submittedBody;
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (_url, init) => {
      submittedBody = JSON.parse(init.body);
      return Response.json({
        id: "video_image_123456",
        status: "in_progress",
        progress: 20,
      });
    },
  });

  const result = await provider.submit({
    prompt: "Animate this product photo",
    aspectRatio: "16:9",
    durationSeconds: 10,
    startImage: { mimeType: "image/png", dataBase64: tinyPng },
  });

  assert.deepEqual(result, {
    requestId: "video_image_123456",
    kind: "image",
    status: "rendering",
  });
  assert.equal(submittedBody.seconds, "8");
  assert.equal(submittedBody.size, "1280x720");
  assert.equal(
    submittedBody.input_reference.image_url,
    `data:image/png;base64,${tinyPng}`,
  );
});

test("accepts a bounded data URL and a bounded HTTPS input reference", async () => {
  const references = [];
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (_url, init) => {
      references.push(JSON.parse(init.body).input_reference);
      return Response.json({
        id: `video_reference_${references.length}123456`,
        status: "queued",
      });
    },
  });

  await provider.submit({
    ...submitRequest,
    startImageUrl: `data:image/png;base64,${tinyPng}`,
  });
  await provider.submit({
    ...submitRequest,
    startImageUrl:
      "https://project.supabase.co/storage/v1/object/sign/private-input",
  });

  assert.deepEqual(references[0], {
    image_url: `data:image/png;base64,${tinyPng}`,
  });
  assert.deepEqual(references[1], {
    image_url:
      "https://project.supabase.co/storage/v1/object/sign/private-input",
  });
});

test("does not apply the HTTPS URL length cap to a valid data image", async () => {
  let submittedReference;
  const dataBase64 = Buffer.alloc(20 * 1024, 7).toString("base64");
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (_url, init) => {
      submittedReference = JSON.parse(init.body).input_reference;
      return Response.json({
        id: "video_large_reference_123456",
        status: "queued",
      });
    },
  });

  await provider.submit({
    ...submitRequest,
    startImageUrl: `data:image/png;base64,${dataBase64}`,
  });

  assert.equal(
    submittedReference.image_url,
    `data:image/png;base64,${dataBase64}`,
  );
});

test("rejects unsupported generation parameters before a provider request", async () => {
  let fetchCount = 0;
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async () => {
      fetchCount += 1;
      return Response.json({});
    },
  });

  for (
    const request of [
      { ...submitRequest, aspectRatio: "1:1" },
      { ...submitRequest, durationSeconds: 12 },
      {
        ...submitRequest,
        startImage: {
          mimeType: "image/gif",
          dataBase64: tinyPng,
        },
      },
      { ...submitRequest, startImageUrl: "http://example.test/image.png" },
    ]
  ) {
    await assert.rejects(
      () => provider.submit(request),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.equal(error.retryable, false);
        return true;
      },
    );
  }
  assert.equal(fetchCount, 0);
});

test("classifies transport and ambiguous submit failures without fallback", async () => {
  for (
    const fetchImpl of [
      async () => {
        throw new Error("ECONNRESET with sensitive transport detail");
      },
      async () =>
        Response.json(
          { error: { code: "server_error", message: "private detail" } },
          { status: 503 },
        ),
    ]
  ) {
    const provider = new OpenAIVideoProvider({
      apiKey: "openai-server-only-key",
      fetchImpl,
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.equal(error.retryable, true);
        assert.equal(error.safeToFallback, false);
        assert.equal(error.submissionAmbiguous, true);
        assert.doesNotMatch(JSON.stringify(error), /sensitive|private detail/);
        return true;
      },
    );
  }
});

test("keeps only safe bounded diagnostics from definitive submit failures", async () => {
  for (
    const expectation of [
      {
        status: 429,
        upstreamCode: "rate_limit_exceeded",
        code: "provider_rate_limited",
        retryable: true,
        safeToFallback: true,
      },
      {
        status: 403,
        upstreamCode: "permission_denied",
        code: "provider_rejected",
        retryable: false,
        safeToFallback: true,
      },
      {
        status: 400,
        upstreamCode: "content_policy_violation",
        code: "provider_rejected",
        retryable: false,
        safeToFallback: false,
      },
    ]
  ) {
    const provider = new OpenAIVideoProvider({
      apiKey: "openai-server-only-key",
      fetchImpl: async () =>
        Response.json(
          {
            error: {
              code: expectation.upstreamCode,
              message: "sensitive upstream message",
            },
          },
          { status: expectation.status },
        ),
    });

    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.equal(error.code, expectation.code);
        assert.equal(error.retryable, expectation.retryable);
        assert.equal(error.safeToFallback, expectation.safeToFallback);
        assert.equal(error.submissionAmbiguous, false);
        assert.equal(error.providerStatus, expectation.status);
        assert.equal(
          error.providerCode,
          expectation.upstreamCode.toUpperCase(),
        );
        assert.doesNotMatch(JSON.stringify(error), /sensitive upstream/);
        return true;
      },
    );
  }
});

test("bounds and validates every submit JSON response", async () => {
  for (
    const response of [
      new Response(`{"id":"${"a".repeat(1024 * 1024)}"}`, {
        headers: { "Content-Type": "application/json" },
      }),
      new Response("not-json", {
        status: 403,
        headers: { "Content-Type": "text/plain" },
      }),
      Response.json({ id: "invalid/id", status: "queued" }),
    ]
  ) {
    const provider = new OpenAIVideoProvider({
      apiKey: "openai-server-only-key",
      fetchImpl: async () => response,
    });
    await assert.rejects(
      () => provider.submit(submitRequest),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.match(
          error.code,
          /provider_(?:response_too_large|response_invalid|response_ambiguous)/,
        );
        return true;
      },
    );
  }
});

test("maps OpenAI lifecycle states and clamps provider progress", () => {
  assert.deepEqual(mapOpenAIVideoStatus({ status: "queued", progress: 0 }), {
    status: "queued",
    progress: 0.05,
    completed: false,
  });
  assert.deepEqual(
    mapOpenAIVideoStatus({ status: "in_progress", progress: 45 }),
    { status: "rendering", progress: 0.45, completed: false },
  );
  assert.deepEqual(
    mapOpenAIVideoStatus({ status: "in_progress", progress: 1000 }),
    { status: "rendering", progress: 0.9, completed: false },
  );
  assert.deepEqual(mapOpenAIVideoStatus({ status: "completed" }), {
    status: "completed",
    progress: 0.9,
    completed: true,
  });
  assert.deepEqual(
    mapOpenAIVideoStatus({
      status: "failed",
      error: { message: "must never escape" },
    }),
    {
      status: "failed",
      progress: 1,
      completed: true,
      errorCode: "provider_failed",
    },
  );
  assert.throws(
    () => mapOpenAIVideoStatus({ status: "mystery" }),
    /provider_status_invalid/,
  );
});

test("retrieves bounded status and returns authenticated bounded content", async () => {
  const calls = [];
  const expected = makeMp4Bytes(1024);
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      if (String(url).endsWith("/content")) {
        return new Response(expected, {
          headers: {
            "Content-Type": "video/mp4",
            "Content-Length": String(expected.byteLength),
          },
        });
      }
      return Response.json({
        id: "video_status_123456",
        status: "completed",
        progress: 100,
      });
    },
  });

  const status = await provider.status({
    requestId: "video_status_123456",
  });
  const result = await provider.result({
    requestId: "video_status_123456",
  });

  assert.deepEqual(status, {
    status: "completed",
    progress: 0.9,
    completed: true,
  });
  assert.deepEqual(result, {
    dataBytes: expected,
    mimeType: "video/mp4",
    byteLength: expected.byteLength,
  });
  assert.equal(
    calls[0].url,
    "https://api.openai.com/v1/videos/video_status_123456",
  );
  assert.equal(
    calls[0].init.headers.Authorization,
    "Bearer openai-server-only-key",
  );
  assert.equal(
    calls[2].url,
    "https://api.openai.com/v1/videos/video_status_123456/content",
  );
});

test("does not return a result before the OpenAI job is complete", async () => {
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async () =>
      Response.json({
        id: "video_pending_123456",
        status: "in_progress",
        progress: 40,
      }),
  });

  await assert.rejects(
    () => provider.result({ requestId: "video_pending_123456" }),
    (error) => {
      assert.ok(error instanceof OpenAIProviderError);
      assert.equal(error.code, "provider_result_not_ready");
      assert.equal(error.retryable, true);
      return true;
    },
  );
});

test("downloads authenticated MP4 content into bounded bytes", async () => {
  const calls = [];
  const expected = makeMp4Bytes(1024);
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return new Response(expected, {
        headers: {
          "Content-Type": "video/mp4",
          "Content-Length": String(expected.byteLength),
        },
      });
    },
  });

  const bytes = await provider.download({
    requestId: "video_download_123456",
  });

  assert.deepEqual(bytes, expected);
  assert.equal(
    calls[0].url,
    "https://api.openai.com/v1/videos/video_download_123456/content",
  );
  assert.equal(
    calls[0].init.headers.Authorization,
    "Bearer openai-server-only-key",
  );
});

test("rejects oversized, truncated, disguised, or failed video downloads", async () => {
  const maxVideoBytes = 50 * 1024 * 1024;
  const cases = [
    new Response(null, {
      headers: {
        "Content-Type": "video/mp4",
        "Content-Length": String(maxVideoBytes + 1),
      },
    }),
    new Response(makeMp4Bytes(8), {
      headers: { "Content-Type": "video/mp4" },
    }),
    new Response("<html>not a video</html>", {
      headers: { "Content-Type": "video/mp4" },
    }),
    new Response(makeMp4Bytes(32), {
      headers: { "Content-Type": "application/json" },
    }),
    Response.json(
      { error: { code: "server_error", message: "private message" } },
      { status: 503 },
    ),
  ];

  for (const response of cases) {
    const provider = new OpenAIVideoProvider({
      apiKey: "openai-server-only-key",
      fetchImpl: async () => response,
    });
    await assert.rejects(
      () =>
        provider.download({
          requestId: "video_download_123456",
        }),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.doesNotMatch(JSON.stringify(error), /private message/);
        return true;
      },
    );
  }
});

test("cancels a streamed video as soon as it exceeds the result limit", async () => {
  const chunk = new Uint8Array(1024 * 1024);
  chunk.set(makeMp4Bytes(12), 0);
  let pulls = 0;
  let cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      pulls += 1;
      controller.enqueue(chunk);
    },
    cancel() {
      cancelled = true;
    },
  });
  const provider = new OpenAIVideoProvider({
    apiKey: "openai-server-only-key",
    fetchImpl: async () =>
      new Response(stream, {
        headers: { "Content-Type": "video/mp4" },
      }),
  });

  await assert.rejects(
    () =>
      provider.download({
        requestId: "video_download_123456",
      }),
    (error) => {
      assert.ok(error instanceof OpenAIProviderError);
      assert.equal(error.code, "provider_result_too_large");
      return true;
    },
  );
  assert.equal(cancelled, true);
  assert.ok(pulls <= 52);
});

test("requires a configured key and never copies it into an error", () => {
  for (const apiKey of ["", null, undefined]) {
    assert.throws(
      () => new OpenAIVideoProvider({ apiKey }),
      (error) => {
        assert.ok(error instanceof OpenAIProviderError);
        assert.equal(error.code, "provider_not_configured");
        assert.equal(error.retryable, false);
        assert.doesNotMatch(JSON.stringify(error), /sk-|server-only/);
        return true;
      },
    );
  }
});

function makeMp4Bytes(length) {
  const bytes = new Uint8Array(length);
  if (length >= 8) {
    bytes.set(new TextEncoder().encode("0000ftyp"), 0);
  }
  return bytes;
}
