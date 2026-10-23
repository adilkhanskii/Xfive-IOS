import assert from "node:assert/strict";
import test from "node:test";

import {
  GoogleGeminiVideoProvider,
  GoogleProviderError,
  mapGoogleInteractionStatus,
} from "./google-provider.mjs";
import {
  selectVideoProvider,
  selectVideoProviderByName,
} from "./video-provider.mjs";

const tinyPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const webhookParameters = {
  webhookUrl:
    "https://project.supabase.co/functions/v1/generate-video?webhook=google",
  webhookMetadata: {
    job_id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    claim_token:
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  },
};

test("prefers fal, then Gemini, then the OpenAI video fallback", () => {
  assert.equal(
    selectVideoProvider({
      falKey: "fal-key",
      googleKey: "google-key",
      openAIKey: "openai-key",
      fetchImpl: async () => Response.json({}),
    }).name,
    "fal",
  );
  assert.equal(
    selectVideoProvider({
      falKey: "",
      googleKey: "google-key",
      openAIKey: "openai-key",
      fetchImpl: async () => Response.json({}),
    }).name,
    "google",
  );
  assert.equal(
    selectVideoProvider({
      falKey: "",
      googleKey: "",
      openAIKey: "openai-key",
      fetchImpl: async () => Response.json({}),
    }).name,
    "openai",
  );
  assert.throws(
    () =>
      selectVideoProvider({
        falKey: "",
        googleKey: "",
        openAIKey: "",
        fetchImpl: async () => Response.json({}),
      }),
    /provider_not_configured/,
  );
});

test("reconciliation selects the provider that originally owns the job", () => {
  assert.equal(
    selectVideoProviderByName("google", {
      falKey: "fal-key",
      googleKey: "google-key",
      openAIKey: "openai-key",
      fetchImpl: async () => Response.json({}),
    }).name,
    "google",
  );
  assert.equal(
    selectVideoProviderByName("openai", {
      falKey: "fal-key",
      googleKey: "google-key",
      openAIKey: "openai-key",
      fetchImpl: async () => Response.json({}),
    }).name,
    "openai",
  );
  assert.throws(
    () =>
      selectVideoProviderByName("fal", {
        falKey: "",
        googleKey: "google-key",
        openAIKey: "openai-key",
        fetchImpl: async () => Response.json({}),
      }),
    /provider_not_configured/,
  );
});

test("submits background URI video generation to Gemini Omni Flash", async () => {
  const calls = [];
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({
        id: "v1_interaction_123456",
        status: "in_progress",
      });
    },
  });

  const result = await provider.submit({
    prompt: "A cinematic vertical product reveal",
    aspectRatio: "9:16",
    durationSeconds: 10,
    startImage: null,
    webhookUrl:
      "https://project.supabase.co/functions/v1/generate-video?webhook=google",
    webhookMetadata: {
      job_id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
      claim_token:
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    },
  });

  assert.deepEqual(result, {
    requestId: "v1_interaction_123456",
    kind: "text",
    status: "rendering",
  });
  assert.equal(
    calls[0].url,
    "https://generativelanguage.googleapis.com/v1beta/interactions",
  );
  assert.equal(calls[0].init.headers["x-goog-api-key"], "google-server-key");
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.model, "gemini-omni-flash-preview");
  assert.equal(body.background, true);
  assert.equal(body.store, true);
  assert.equal(body.input, "A cinematic vertical product reveal");
  assert.deepEqual(body.response_format, {
    type: "video",
    delivery: "uri",
    aspect_ratio: "9:16",
    duration: "10s",
  });
  assert.deepEqual(body.webhook_config, {
    uris: [
      "https://project.supabase.co/functions/v1/generate-video?webhook=google",
    ],
    user_metadata: {
      job_id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
      claim_token:
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    },
  });
  assert.doesNotMatch(calls[0].url + calls[0].init.body, /google-server-key/);
});

test("rejects square video before sending a Google request", async () => {
  let fetchCount = 0;
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () => {
      fetchCount += 1;
      return Response.json({
        id: "v1_interaction_123456",
        status: "in_progress",
      });
    },
  });

  await assert.rejects(
    provider.submit({
      prompt: "A square product reveal",
      aspectRatio: "1:1",
      durationSeconds: 5,
      startImage: null,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "unsupported_aspect_ratio");
      assert.equal(error.retryable, false);
      return true;
    },
  );
  assert.equal(fetchCount, 0);
});

test("classifies a transport failure as an ambiguous submission", async () => {
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () => {
      throw new Error("ECONNRESET");
    },
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
      ...webhookParameters,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.submissionAmbiguous, true);
      return true;
    },
  );
});

test("requires opaque callback correlation before a Google submit", async () => {
  let fetchCount = 0;
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () => {
      fetchCount += 1;
      return Response.json({});
    },
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_webhook_invalid");
      assert.equal(error.retryable, false);
      return true;
    },
  );
  assert.equal(fetchCount, 0);
});

test("classifies Google 408 and 5xx submit responses as ambiguous", async () => {
  for (const status of [408, 500, 503]) {
    const provider = new GoogleGeminiVideoProvider({
      apiKey: "google-server-key",
      fetchImpl: async () => Response.json({ error: "retry" }, { status }),
    });

    await assert.rejects(
      provider.submit({
        prompt: "A cinematic product reveal",
        aspectRatio: "9:16",
        durationSeconds: 5,
        webhookUrl:
          "https://project.supabase.co/functions/v1/generate-video?webhook=google",
        webhookMetadata: {
          job_id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
          claim_token:
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        },
      }),
      (error) => {
        assert.ok(error instanceof GoogleProviderError);
        assert.equal(error.retryable, true);
        assert.equal(error.submissionAmbiguous, true);
        return true;
      },
    );
  }
});

test("classifies Google 429 as retryable but definitely not accepted", async () => {
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      Response.json(
        { error: { status: "RESOURCE_EXHAUSTED" } },
        { status: 429 },
      ),
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
      ...webhookParameters,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_rate_limited");
      assert.equal(error.retryable, true);
      assert.equal(error.submissionAmbiguous, false);
      assert.equal(error.providerStatus, 429);
      assert.equal(error.providerCode, "RESOURCE_EXHAUSTED");
      return true;
    },
  );
});

test("keeps only bounded safe diagnostics from a definitive Google rejection", async () => {
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      Response.json(
        {
          error: {
            status: "INVALID_ARGUMENT",
            message: "sensitive upstream detail that must not be exposed",
          },
        },
        { status: 400 },
      ),
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
      ...webhookParameters,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_rejected");
      assert.equal(error.providerStatus, 400);
      assert.equal(error.providerCode, "INVALID_ARGUMENT");
      assert.doesNotMatch(JSON.stringify(error), /sensitive upstream detail/);
      return true;
    },
  );
});

test("preserves the HTTP status when Google returns a non-JSON rejection", async () => {
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      new Response("not-json", {
        status: 403,
        headers: { "Content-Type": "text/plain" },
      }),
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
      ...webhookParameters,
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_response_invalid");
      assert.equal(error.providerStatus, 403);
      assert.equal(error.submissionAmbiguous, false);
      return true;
    },
  );
});

test("rejects an oversized Google JSON response without buffering it all", async () => {
  const oversized = `{"id":"${"a".repeat(1024 * 1024)}"}`;
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      new Response(oversized, {
        headers: { "Content-Type": "application/json" },
      }),
  });

  await assert.rejects(
    provider.submit({
      prompt: "A cinematic product reveal",
      aspectRatio: "9:16",
      durationSeconds: 5,
      webhookUrl:
        "https://project.supabase.co/functions/v1/generate-video?webhook=google",
      webhookMetadata: {
        job_id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
        claim_token:
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      },
    }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_response_too_large");
      assert.equal(error.submissionAmbiguous, true);
      return true;
    },
  );
});

test("bounds Google status JSON reads as well as submit responses", async () => {
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      new Response(`{"status":"${"x".repeat(1024 * 1024)}"}`, {
        headers: { "Content-Type": "application/json" },
      }),
  });

  await assert.rejects(
    provider.status({ requestId: "google_interaction_123" }),
    (error) => {
      assert.ok(error instanceof GoogleProviderError);
      assert.equal(error.code, "provider_response_too_large");
      assert.equal(error.submissionAmbiguous, false);
      return true;
    },
  );
});

test("streams a large inline GET video into bounded bytes", async () => {
  const videoBytes = Buffer.alloc(1024 * 1024 + 32);
  videoBytes.write("0000ftypisom", 0, "ascii");
  const inlineVideo = videoBytes.toString("base64");
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          output_video: {
            data: inlineVideo,
            mime_type: "video/mp4",
          },
          id: "google_interaction_123",
          status: "completed",
        }),
        { headers: { "Content-Type": "application/json" } },
      ),
  });

  const status = await provider.status({
    requestId: "google_interaction_123",
  });

  assert.equal(status.status, "completed");
  assert.equal(status.result.dataBytes.byteLength, videoBytes.byteLength);
  assert.equal(
    Buffer.from(status.result.dataBytes.subarray(0, 12)).toString("ascii"),
    "0000ftypisom",
  );
  assert.equal("dataBase64" in status.result, false);
});

test("sends private in-memory image data to Gemini without a public URL", async () => {
  const calls = [];
  const provider = new GoogleGeminiVideoProvider({
    apiKey: "google-server-key",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json({
        id: "v1_interaction_654321",
        status: "in_progress",
      });
    },
  });

  await provider.submit({
    prompt: "Animate this product photo",
    aspectRatio: "16:9",
    durationSeconds: 5,
    startImage: { mimeType: "image/png", dataBase64: tinyPng },
    ...webhookParameters,
  });

  assert.deepEqual(JSON.parse(calls[0].init.body).input, [
    { type: "image", data: tinyPng, mime_type: "image/png" },
    { type: "text", text: "Animate this product photo" },
  ]);
});

test("maps stored interaction states and extracts URI or inline MP4", () => {
  assert.deepEqual(mapGoogleInteractionStatus({ status: "in_progress" }), {
    status: "rendering",
    progress: 0.5,
    completed: false,
  });
  assert.deepEqual(
    mapGoogleInteractionStatus({
      status: "completed",
      output_video: {
        uri:
          "https://generativelanguage.googleapis.com/v1beta/files/abc:download?alt=media",
        mime_type: "video/mp4",
      },
    }),
    {
      status: "completed",
      progress: 0.9,
      completed: true,
      result: {
        url:
          "https://generativelanguage.googleapis.com/v1beta/files/abc:download?alt=media",
        mimeType: "video/mp4",
      },
    },
  );
  assert.deepEqual(
    mapGoogleInteractionStatus({
      status: "completed",
      output_video: { data: "AAAA", mime_type: "video/mp4" },
    }),
    {
      status: "completed",
      progress: 0.9,
      completed: true,
      result: { dataBase64: "AAAA", mimeType: "video/mp4" },
    },
  );
  assert.deepEqual(mapGoogleInteractionStatus({ status: "failed" }), {
    status: "failed",
    progress: 1,
    completed: true,
    errorCode: "provider_failed",
  });
  assert.deepEqual(mapGoogleInteractionStatus({ status: "incomplete" }), {
    status: "failed",
    progress: 1,
    completed: true,
    errorCode: "provider_incomplete",
  });
});
