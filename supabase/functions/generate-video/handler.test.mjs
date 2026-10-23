import assert from "node:assert/strict";
import test from "node:test";

import { createGenerateVideoHandler } from "./handler.mjs";
import { FalProviderError } from "./fal-provider.mjs";
import { GoogleProviderError } from "./google-provider.mjs";
import {
  selectVideoProvider,
  selectVideoProviderByName,
} from "./video-provider.mjs";

const requestBody = {
  idempotency_key: "video-request-handler-1",
  prompt: "A cinematic product reveal",
  aspect_ratio: "9:16",
  duration_seconds: 5,
};

function makeJob(overrides = {}) {
  return {
    id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    user_id: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
    status: "queued",
    progress: 0.05,
    cost_credits: 650,
    refunded_at: null,
    error_code: null,
    result_object_path: null,
    created_at: "2026-07-25T10:00:00.000Z",
    updated_at: "2026-07-25T10:00:01.000Z",
    ...overrides,
  };
}

function dependencies(overrides = {}) {
  const calls = [];
  const adapter = {
    submit: async () => ({ requestId: "provider-request-123", kind: "text" }),
  };
  return {
    calls,
    deps: {
      verifyUser: async () => ({ id: makeJob().user_id }),
      moderateRequest: async (normalized) => {
        calls.push(["moderate", {
          prompt: normalized.prompt,
          hasStartImage: Boolean(normalized.startImage),
        }]);
        return { allowed: true };
      },
      selectProvider: () => ({ name: "fal", adapter }),
      selectFallbackProvider: () => null,
      claimJob: async (parameters) => {
        calls.push(["claim", parameters]);
        return { status: "claimed", job_id: makeJob().id };
      },
      switchProvider: async (parameters) => {
        calls.push(["switch", parameters]);
        return { status: "switched" };
      },
      getJob: async ({ jobId, userId }) => {
        calls.push(["get", { jobId, userId }]);
        return makeJob();
      },
      markSubmitted: async (parameters) => {
        calls.push(["submitted", parameters]);
        return { status: "submitted" };
      },
      bindGoogleWebhook: async (parameters) => {
        calls.push(["google_bound", parameters]);
        return { status: "bound" };
      },
      recordInput: async (parameters) => {
        calls.push(["recorded_input", parameters]);
        return { status: "recorded" };
      },
      markRendering: async () => ({ status: "rendering" }),
      failJob: async (parameters) => {
        calls.push(["failed", parameters]);
        return { status: "failed", refunded: true };
      },
      markSubmissionRejected: async (parameters) => {
        calls.push(["rejection_marked", parameters]);
        return { status: "marked" };
      },
      sleep: async (milliseconds) => {
        calls.push(["slept", milliseconds]);
      },
      storeStartImage: async () => null,
      deleteStartImage: async (path) => {
        calls.push(["deleted_input", path]);
      },
      signStartImage: async () => null,
      signResult: async () => null,
      reconcileJob: async (job) => job,
      webhookUrl:
        "https://project.supabase.co/functions/v1/generate-video?webhook=fal",
      googleWebhookUrl:
        "https://project.supabase.co/functions/v1/generate-video?webhook=google",
      ...overrides,
    },
  };
}

test("requires an authenticated Supabase user", async () => {
  const { deps } = dependencies({ verifyUser: async () => null });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), {
    error: {
      code: "unauthorized",
      message: "Authentication is required.",
      retryable: false,
    },
  });
});

test("rejects an unsupported ratio before moderation, provider selection, or credit claim", async () => {
  let moderationCount = 0;
  let providerSelectionCount = 0;
  let claimCount = 0;
  const { deps } = dependencies({
    moderateRequest: async () => {
      moderationCount += 1;
      return { allowed: true };
    },
    selectProvider: () => {
      providerSelectionCount += 1;
      return {
        name: "google",
        adapter: { submit: async () => ({ requestId: "google-request-123" }) },
      };
    },
    claimJob: async () => {
      claimCount += 1;
      return { status: "claimed", job_id: makeJob().id };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({ ...requestBody, aspect_ratio: "1:1" }),
    }),
  );

  assert.equal(response.status, 400);
  assert.equal(
    (await response.json()).error.message,
    "unsupported_aspect_ratio",
  );
  assert.equal(moderationCount, 0);
  assert.equal(providerSelectionCount, 0);
  assert.equal(claimCount, 0);
});

test("moderates text before any credit claim or provider submission", async () => {
  let claimCount = 0;
  let submitCount = 0;
  const { deps } = dependencies({
    moderateRequest: async (normalized) => {
      assert.equal(normalized.prompt, requestBody.prompt);
      return { allowed: false };
    },
    claimJob: async () => {
      claimCount += 1;
      return { status: "claimed", job_id: makeJob().id };
    },
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          submitCount += 1;
          return { requestId: "provider-request-123", kind: "text" };
        },
      },
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), {
    error: {
      code: "content_rejected",
      message: "This request did not pass the safety check.",
      retryable: false,
    },
  });
  assert.equal(claimCount, 0);
  assert.equal(submitCount, 0);
});

test("moderates the optional start image before any credit claim", async () => {
  let claimCount = 0;
  const imageRequest = {
    ...requestBody,
    idempotency_key: "video-request-image-moderation-1",
    start_image: {
      mime_type: "image/jpeg",
      data_base64: "/9j/2Q==",
    },
  };
  const { deps } = dependencies({
    moderateRequest: async (normalized) => {
      assert.equal(normalized.startImage.mimeType, "image/jpeg");
      assert.equal(normalized.startImage.dataBase64, "/9j/2Q==");
      return { allowed: false };
    },
    claimJob: async () => {
      claimCount += 1;
      return { status: "claimed", job_id: makeJob().id };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(imageRequest),
    }),
  );

  assert.equal(response.status, 422);
  assert.equal((await response.json()).error.code, "content_rejected");
  assert.equal(claimCount, 0);
});

test("fails closed without claiming when moderation is unavailable", async () => {
  let claimCount = 0;
  const { deps } = dependencies({
    moderateRequest: async () => {
      throw new Error("provider response with secret details");
    },
    claimJob: async () => {
      claimCount += 1;
      return { status: "claimed", job_id: makeJob().id };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );
  const serialized = JSON.stringify(await response.json());

  assert.equal(response.status, 503);
  assert.match(serialized, /safety_service_unavailable/);
  assert.doesNotMatch(serialized, /provider response|secret/i);
  assert.equal(claimCount, 0);
});

test("claims once, submits once, and never returns the provider request id", async () => {
  const { deps, calls } = dependencies();
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 202);
  assert.equal(payload.replayed, false);
  assert.equal(payload.job.id, makeJob().id);
  assert.equal(calls.filter(([name]) => name === "moderate").length, 1);
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "submitted").length, 1);
  assert.doesNotMatch(JSON.stringify(payload), /provider-request-123/);
});

test("passes the allowlisted Seedance settings to provider selection and submit", async () => {
  let selectedInput = null;
  let submittedInput = null;
  const { deps } = dependencies({
    selectProvider: (normalized) => {
      selectedInput = normalized;
      return {
        name: "fal",
        requestedModel: normalized.model,
        adapter: {
          submit: async (parameters) => {
            submittedInput = parameters;
            return { requestId: "seedance-provider-request-1", kind: "text" };
          },
        },
      };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-seedance-handler-1",
        model: "seedance-1.5-pro",
        resolution: "1080p",
        generate_audio: true,
      }),
    }),
  );

  assert.equal(response.status, 202);
  assert.equal(selectedInput.model, "seedance-1.5-pro");
  assert.equal(submittedInput.model, "seedance-1.5-pro");
  assert.equal(submittedInput.resolution, "1080p");
  assert.equal(submittedInput.generateAudio, true);
});

test("does not silently fall back from an explicit Seedance request", async () => {
  let fallbackSelections = 0;
  const { deps, calls } = dependencies({
    selectProvider: () => ({
      name: "fal",
      requestedModel: "seedance-1.5-pro",
      adapter: {
        submit: async () => {
          throw new FalProviderError("provider_unavailable", {
            retryable: true,
            safeToFallback: true,
            httpStatus: 429,
          });
        },
      },
    }),
    selectFallbackProvider: () => {
      fallbackSelections += 1;
      return {
        name: "google",
        requestedModel: "auto",
        adapter: {
          submit: async () => ({ requestId: "google-request-123" }),
        },
      };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-seedance-no-fallback",
        model: "seedance-1.5-pro",
        resolution: "720p",
        generate_audio: true,
      }),
    }),
  );

  assert.equal(response.status, 503);
  assert.equal(fallbackSelections, 0);
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "switch").length, 0);
  assert.equal(calls.filter(([name]) => name === "failed").length, 1);
});

test("replays the owned job without another provider submission or debit", async () => {
  let submitCount = 0;
  const { deps } = dependencies({
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          submitCount += 1;
          return { requestId: "provider-request-123", kind: "text" };
        },
      },
    }),
    claimJob: async () => ({
      status: "replay",
      job_id: makeJob().id,
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 200);
  assert.equal((await response.json()).replayed, true);
  assert.equal(submitCount, 0);
});

test("falls back from a failed FAL submit to Google without claiming twice", async () => {
  let rowProvider = "fal";
  let claimedToken = "";
  let submittedGoogleWebhook = null;
  const { deps, calls } = dependencies({
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          throw new FalProviderError("provider_unavailable", {
            retryable: true,
            safeToFallback: true,
            httpStatus: 429,
          });
        },
      },
    }),
    selectFallbackProvider: (providerName) => {
      assert.equal(providerName, "fal");
      return {
        name: "google",
        adapter: {
          submit: async (parameters) => {
            submittedGoogleWebhook = parameters;
            return {
              requestId: "google-request-123",
              kind: "text",
              status: "rendering",
            };
          },
        },
      };
    },
    claimJob: async (parameters) => {
      claimedToken = parameters.p_claim_token;
      calls.push(["claim", parameters]);
      return { status: "claimed", job_id: makeJob().id };
    },
    switchProvider: async (parameters) => {
      calls.push(["switch", parameters]);
      rowProvider = parameters.p_new_provider_name;
      return { status: "switched" };
    },
    getJob: async ({ jobId, userId }) => {
      calls.push(["get", { jobId, userId, rowProvider }]);
      return makeJob({ provider_name: rowProvider });
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 202);
  assert.equal(payload.replayed, false);
  assert.equal(rowProvider, "google");
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "switch").length, 1);
  assert.equal(calls.filter(([name]) => name === "submitted").length, 0);
  assert.equal(calls.filter(([name]) => name === "google_bound").length, 1);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
  assert.equal(
    submittedGoogleWebhook.webhookUrl,
    deps.googleWebhookUrl,
  );
  assert.deepEqual(submittedGoogleWebhook.webhookMetadata, {
    job_id: makeJob().id,
    claim_token: claimedToken,
  });
  assert.match(claimedToken, /^[0-9a-f]{64}$/);
  const switchCall = calls.find(([name]) => name === "switch")[1];
  assert.deepEqual(
    {
      expected: switchCall.p_expected_provider_name,
      next: switchCall.p_new_provider_name,
    },
    { expected: "fal", next: "google" },
  );
  assert.ok(
    calls.find(([name, value]) =>
      name === "get" && value.rowProvider === "google"
    ),
  );
});

test("uses Google only after a definitive FAL 429 rejection", async () => {
  const providerUrls = [];
  const fetchImpl = async (url) => {
    const value = String(url);
    providerUrls.push(value);
    if (value.startsWith("https://queue.fal.run/")) {
      return Response.json(
        { error: "upstream unavailable" },
        { status: 429 },
      );
    }
    if (
      value ===
        "https://generativelanguage.googleapis.com/v1beta/interactions"
    ) {
      return Response.json({
        id: "google-real-fallback-123",
        status: "in_progress",
      });
    }
    throw new Error("unexpected provider URL");
  };
  const { deps, calls } = dependencies({
    selectProvider: () =>
      selectVideoProvider({
        falKey: "fal-server-key",
        googleKey: "google-server-key",
        fetchImpl,
      }),
    selectFallbackProvider: () =>
      selectVideoProviderByName("google", {
        falKey: "fal-server-key",
        googleKey: "google-server-key",
        fetchImpl,
      }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 202);
  assert.match(providerUrls[0], /^https:\/\/queue\.fal\.run\//);
  assert.equal(
    providerUrls[1],
    "https://generativelanguage.googleapis.com/v1beta/interactions",
  );
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "switch").length, 1);
});

test("falls back from a definitive Google 403 to OpenAI without claiming twice", async () => {
  let rowProvider = "google";
  const fallbackSelections = [];
  const { deps, calls } = dependencies({
    selectProvider: () => ({
      name: "google",
      adapter: {
        submit: async () => {
          throw new GoogleProviderError("provider_rejected", {
            retryable: false,
            submissionAmbiguous: false,
            providerStatus: 403,
            providerCode: "PERMISSION_DENIED",
          });
        },
      },
    }),
    selectFallbackProvider: (providerName) => {
      fallbackSelections.push(providerName);
      assert.equal(providerName, "google");
      return {
        name: "openai",
        adapter: {
          submit: async (parameters) => {
            assert.equal(parameters.startImage, null);
            assert.equal(parameters.webhookUrl, null);
            return {
              requestId: "video_openai_request_123",
              kind: "text",
              status: "queued",
            };
          },
        },
      };
    },
    switchProvider: async (parameters) => {
      calls.push(["switch", parameters]);
      rowProvider = parameters.p_new_provider_name;
      return { status: "switched" };
    },
    getJob: async ({ jobId, userId }) => {
      calls.push(["get", { jobId, userId, rowProvider }]);
      return makeJob({ provider_name: rowProvider });
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 202);
  assert.deepEqual(fallbackSelections, ["google"]);
  assert.equal(rowProvider, "openai");
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "switch").length, 1);
  assert.equal(calls.filter(([name]) => name === "google_bound").length, 0);
  assert.equal(calls.filter(([name]) => name === "submitted").length, 1);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
  assert.deepEqual(
    calls.find(([name]) => name === "switch")[1],
    {
      p_job_id: makeJob().id,
      p_user_id: makeJob().user_id,
      p_claim_token: calls.find(([name]) => name === "claim")[1].p_claim_token,
      p_expected_provider_name: "google",
      p_new_provider_name: "openai",
    },
  );
});

test("can switch FAL to Google to OpenAI while preserving one claim", async () => {
  let rowProvider = "fal";
  const { deps, calls } = dependencies({
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          throw new FalProviderError("provider_unavailable", {
            retryable: true,
            safeToFallback: true,
            httpStatus: 429,
          });
        },
      },
    }),
    selectFallbackProvider: (providerName) => {
      if (providerName === "fal") {
        return {
          name: "google",
          adapter: {
            submit: async () => {
              throw new GoogleProviderError("provider_rejected", {
                retryable: false,
                submissionAmbiguous: false,
                providerStatus: 403,
                providerCode: "PERMISSION_DENIED",
              });
            },
          },
        };
      }
      if (providerName === "google") {
        return {
          name: "openai",
          adapter: {
            submit: async () => ({
              requestId: "video_openai_request_123",
              kind: "text",
              status: "queued",
            }),
          },
        };
      }
      return null;
    },
    switchProvider: async (parameters) => {
      calls.push(["switch", parameters]);
      rowProvider = parameters.p_new_provider_name;
      return { status: "switched" };
    },
    getJob: async ({ jobId, userId }) => {
      calls.push(["get", { jobId, userId, rowProvider }]);
      return makeJob({ provider_name: rowProvider });
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-provider-chain-1",
      }),
    }),
  );

  assert.equal(response.status, 202);
  assert.equal(rowProvider, "openai");
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.deepEqual(
    calls.filter(([name]) => name === "switch").map(([, value]) => [
      value.p_expected_provider_name,
      value.p_new_provider_name,
    ]),
    [["fal", "google"], ["google", "openai"]],
  );
  assert.equal(calls.filter(([name]) => name === "submitted").length, 1);
  assert.equal(calls.filter(([name]) => name === "google_bound").length, 0);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
});

test("does not fall back from an ambiguous Google submission", async () => {
  let fallbackSelections = 0;
  const { deps, calls } = dependencies({
    selectProvider: () => ({
      name: "google",
      adapter: {
        submit: async () => {
          throw new GoogleProviderError("provider_transport_ambiguous", {
            retryable: true,
            submissionAmbiguous: true,
            providerStatus: 503,
          });
        },
      },
    }),
    selectFallbackProvider: () => {
      fallbackSelections += 1;
      return {
        name: "openai",
        adapter: {
          submit: async () => ({
            requestId: "video_openai_request_123",
          }),
        },
      };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-google-ambiguous-no-fallback",
      }),
    }),
  );

  assert.equal(response.status, 202);
  assert.equal((await response.json()).submission_pending, true);
  assert.equal(fallbackSelections, 0);
  assert.equal(calls.filter(([name]) => name === "switch").length, 0);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
});

test("does not fall back for FAL auth or content rejection", async () => {
  for (const status of [401, 422]) {
    let fallbackSelections = 0;
    const fetchImpl = async () =>
      Response.json({ error: "rejected" }, { status });
    const { deps, calls } = dependencies({
      selectProvider: () =>
        selectVideoProvider({
          falKey: "fal-server-key",
          googleKey: "google-server-key",
          fetchImpl,
        }),
      selectFallbackProvider: () => {
        fallbackSelections += 1;
        return selectVideoProviderByName("google", {
          falKey: "fal-server-key",
          googleKey: "google-server-key",
          fetchImpl,
        });
      },
    });
    const handler = createGenerateVideoHandler(deps);
    const response = await handler(
      new Request(
        "https://example.test/generate-video",
        {
          method: "POST",
          headers: { Authorization: "Bearer user-token" },
          body: JSON.stringify(requestBody),
        },
      ),
    );

    assert.equal(response.status, 503);
    assert.equal(fallbackSelections, 0);
    assert.equal(calls.filter(([name]) => name === "claim").length, 1);
    assert.equal(calls.filter(([name]) => name === "switch").length, 0);
    assert.equal(calls.filter(([name]) => name === "failed").length, 1);
  }
});

test("refunds exactly once when Google rejects a submit with 429", async () => {
  const { deps, calls } = dependencies({
    selectProvider: () =>
      selectVideoProvider({
        falKey: "",
        googleKey: "google-server-key",
        fetchImpl: async () =>
          Response.json(
            { error: { status: "RESOURCE_EXHAUSTED" } },
            { status: 429 },
          ),
      }),
  });
  const response = await createGenerateVideoHandler(deps)(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "google-rate-limit-refund-1",
      }),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 503);
  assert.equal(payload.error.retryable, true);
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.deepEqual(
    calls.filter(([name]) => name === "failed"),
    [["failed", {
      p_job_id: makeJob().id,
      p_provider_request_id: null,
      p_error_code: "provider_submission_failed",
    }]],
  );
  assert.equal(calls.filter(([name]) => name === "get").length, 0);
});

test("retries the exact-once refund when Google 429 meets transient RPC failures", async () => {
  let failAttempts = 0;
  const { deps, calls } = dependencies({
    selectProvider: () =>
      selectVideoProvider({
        falKey: "",
        googleKey: "google-server-key",
        fetchImpl: async () =>
          Response.json(
            { error: { status: "RESOURCE_EXHAUSTED" } },
            { status: 429 },
          ),
      }),
    failJob: async (parameters) => {
      calls.push(["failed", parameters]);
      failAttempts += 1;
      if (failAttempts < 3) {
        throw new Error("temporary PostgREST failure");
      }
      return { status: "failed", refunded: true };
    },
  });
  const response = await createGenerateVideoHandler(deps)(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "google-rate-limit-refund-retry-1",
      }),
    }),
  );

  assert.equal(response.status, 503);
  assert.equal(failAttempts, 3);
  const delays = calls
    .filter(([name]) => name === "slept")
    .map(([, milliseconds]) => milliseconds);
  assert.equal(delays.length, 2);
  assert.ok(delays.every((milliseconds) => milliseconds > 0));
  assert.ok(delays[1] > delays[0]);
  assert.equal(
    calls.filter(([name]) => name === "rejection_marked").length,
    0,
  );
});

test("durably marks a definitive Google rejection when immediate refund retries exhaust", async () => {
  const { deps, calls } = dependencies({
    selectProvider: () =>
      selectVideoProvider({
        falKey: "",
        googleKey: "google-server-key",
        fetchImpl: async () =>
          Response.json(
            { error: { status: "RESOURCE_EXHAUSTED" } },
            { status: 429 },
          ),
      }),
    failJob: async (parameters) => {
      calls.push(["failed", parameters]);
      throw new Error("temporary PostgREST failure");
    },
  });
  const response = await createGenerateVideoHandler(deps)(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "google-rate-limit-refund-outbox-1",
      }),
    }),
  );

  assert.equal(response.status, 503);
  assert.equal(calls.filter(([name]) => name === "failed").length, 3);
  const markers = calls.filter(([name]) => name === "rejection_marked");
  assert.equal(markers.length, 1);
  assert.equal(markers[0][1].p_job_id, makeJob().id);
  assert.match(markers[0][1].p_claim_token, /^[a-f0-9]{64}$/);
  assert.equal(
    markers[0][1].p_error_code,
    "provider_submission_failed",
  );
});

test("keeps an ambiguous FAL submission reserved for reconciliation", async () => {
  for (
    const fetchImpl of [
      async () => {
        throw new DOMException("timed out", "TimeoutError");
      },
      async () => {
        throw new Error("ECONNRESET");
      },
      async () => Response.json({ error: "gateway timeout" }, { status: 504 }),
    ]
  ) {
    let fallbackSelections = 0;
    const { deps, calls } = dependencies({
      selectProvider: () =>
        selectVideoProvider({
          falKey: "fal-server-key",
          googleKey: "google-server-key",
          fetchImpl,
        }),
      selectFallbackProvider: () => {
        fallbackSelections += 1;
        return selectVideoProviderByName("google", {
          falKey: "fal-server-key",
          googleKey: "google-server-key",
          fetchImpl,
        });
      },
    });
    const handler = createGenerateVideoHandler(deps);
    const response = await handler(
      new Request(
        "https://example.test/generate-video",
        {
          method: "POST",
          headers: { Authorization: "Bearer user-token" },
          body: JSON.stringify(requestBody),
        },
      ),
    );

    assert.equal(response.status, 202);
    assert.equal(fallbackSelections, 0);
    assert.equal(calls.filter(([name]) => name === "claim").length, 1);
    assert.equal(calls.filter(([name]) => name === "switch").length, 0);
    assert.equal(calls.filter(([name]) => name === "failed").length, 0);
    assert.equal(
      calls.filter(([name]) => name === "rejection_marked").length,
      0,
    );
    assert.equal(calls.filter(([name]) => name === "get").length, 1);
  }
});

test("does not refund after provider accepted but submission recording is uncertain", async () => {
  let fallbackSelections = 0;
  let markAttempts = 0;
  const { deps, calls } = dependencies({
    selectFallbackProvider: () => {
      fallbackSelections += 1;
      return {
        name: "google",
        adapter: { submit: async () => ({ requestId: "google-request-123" }) },
      };
    },
    markSubmitted: async () => {
      markAttempts += 1;
      throw new Error("ambiguous RPC transport failure");
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 202);
  assert.equal(payload.job.status, "queued");
  assert.equal(fallbackSelections, 0);
  assert.equal(calls.filter(([name]) => name === "claim").length, 1);
  assert.equal(calls.filter(([name]) => name === "switch").length, 0);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
  assert.equal(markAttempts, 3);
  assert.equal(calls.filter(([name]) => name === "get").length, 4);
});

test("records private input before submit and recovers a known provider request", async () => {
  const inputPath = `${makeJob().user_id}/${makeJob().id}/start.jpg`;
  let providerSubmitted = false;
  let markAttempts = 0;
  const { deps, calls } = dependencies({
    storeStartImage: async () => ({
      path: inputPath,
      mimeType: "image/jpeg",
    }),
    signStartImage: async () => ({
      signedUrl: "https://project.supabase.co/storage/v1/object/sign/input",
    }),
    recordInput: async (parameters) => {
      assert.equal(providerSubmitted, false);
      calls.push(["recorded_input", parameters]);
      return { status: "recorded" };
    },
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          providerSubmitted = true;
          return {
            requestId: "provider-request-123",
            kind: "image",
          };
        },
      },
    }),
    markSubmitted: async () => {
      markAttempts += 1;
      throw new Error("ambiguous RPC transport failure");
    },
    getJob: async ({ jobId, userId }) => {
      calls.push(["get", { jobId, userId }]);
      return makeJob({
        provider_name: "fal",
        provider_kind: "image",
        provider_request_id: "provider-request-123",
        input_object_path: inputPath,
      });
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-record-input-recovery-1",
        start_image: {
          mime_type: "image/jpeg",
          data_base64: "/9j/2Q==",
        },
      }),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 202);
  assert.equal(payload.submission_pending, undefined);
  assert.equal(markAttempts, 1);
  assert.equal(calls.filter(([name]) => name === "recorded_input").length, 1);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
  assert.equal(calls.filter(([name]) => name === "deleted_input").length, 0);
});

test("passes the private in-memory start image to OpenAI without signing a public URL", async () => {
  const inputPath = `${makeJob().user_id}/${makeJob().id}/start.jpg`;
  let signAttempts = 0;
  const { deps, calls } = dependencies({
    storeStartImage: async () => ({
      path: inputPath,
      mimeType: "image/jpeg",
    }),
    signStartImage: async () => {
      signAttempts += 1;
      return {
        signedUrl: "https://project.supabase.co/storage/v1/object/sign/input",
      };
    },
    selectProvider: () => ({
      name: "openai",
      adapter: {
        submit: async (parameters) => {
          assert.deepEqual(parameters.startImage, {
            mimeType: "image/jpeg",
            dataBase64: "/9j/2Q==",
            byteLength: 4,
          });
          assert.equal(parameters.startImageUrl, null);
          return {
            requestId: "video_openai_request_123",
            kind: "image",
            status: "queued",
          };
        },
      },
    }),
    getJob: async ({ jobId, userId }) => {
      calls.push(["get", { jobId, userId }]);
      return makeJob({
        provider_name: "openai",
        provider_kind: "image",
        provider_request_id: "video_openai_request_123",
        input_object_path: inputPath,
      });
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-openai-private-image-1",
        start_image: {
          mime_type: "image/jpeg",
          data_base64: "/9j/2Q==",
        },
      }),
    }),
  );

  assert.equal(response.status, 202);
  assert.equal(signAttempts, 0);
  assert.equal(calls.filter(([name]) => name === "recorded_input").length, 1);
  assert.equal(calls.filter(([name]) => name === "submitted").length, 1);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
});

test("retries submission recording idempotently before returning pending", async () => {
  let markAttempts = 0;
  const { deps, calls } = dependencies({
    markSubmitted: async (parameters) => {
      markAttempts += 1;
      calls.push(["submitted", parameters]);
      if (markAttempts === 1) {
        throw new Error("temporary RPC transport failure");
      }
      return { status: "submitted" };
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-submission-retry-1",
      }),
    }),
  );
  const payload = await response.json();

  assert.equal(response.status, 202);
  assert.equal(payload.submission_pending, undefined);
  assert.equal(markAttempts, 2);
  assert.equal(calls.filter(([name]) => name === "failed").length, 0);
});

test("a later status read cleans input retained by orphan reconciliation", async () => {
  const inputPath = `${makeJob().user_id}/${makeJob().id}/start.png`;
  const failed = makeJob({
    status: "failed",
    progress: 1,
    refunded_at: "2026-07-25T10:16:00.000Z",
    error_code: "submission_orphan_reconciled",
    input_object_path: inputPath,
  });
  const { deps, calls } = dependencies({
    getJob: async () => failed,
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request(
      `https://example.test/generate-video?job_id=${failed.id}`,
      { headers: { Authorization: "Bearer user-token" } },
    ),
  );

  assert.equal(response.status, 200);
  assert.equal((await response.json()).job.status, "failed");
  assert.deepEqual(
    calls.filter(([name]) => name === "deleted_input"),
    [["deleted_input", inputPath]],
  );
});

test("removes a private start image after terminal submission failure", async () => {
  const inputPath = `${makeJob().user_id}/${makeJob().id}/start.jpg`;
  const { deps, calls } = dependencies({
    storeStartImage: async () => ({
      path: inputPath,
      mimeType: "image/jpeg",
    }),
    signStartImage: async () => ({
      signedUrl: "https://project.supabase.co/storage/v1/object/sign/input",
    }),
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          throw new Error("terminal submit failure");
        },
      },
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-cleanup-on-failure-1",
        start_image: {
          mime_type: "image/jpeg",
          data_base64: "/9j/2Q==",
        },
      }),
    }),
  );

  assert.equal(response.status, 503);
  assert.deepEqual(
    calls.filter(([name]) => name === "deleted_input"),
    [["deleted_input", inputPath]],
  );
});

test("returns bounded Google diagnostics after a definitive rejected submit", async () => {
  const { deps } = dependencies({
    selectProvider: () => ({
      name: "google",
      adapter: {
        submit: async () => {
          throw new GoogleProviderError("provider_rejected", {
            retryable: false,
            submissionAmbiguous: false,
            providerStatus: 400,
            providerCode: "INVALID_ARGUMENT",
          });
        },
      },
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-google-diagnostic-1",
      }),
    }),
  );

  assert.equal(response.status, 503);
  const payload = await response.json();
  assert.deepEqual(payload.error.provider, {
    name: "google",
    status: 400,
    code: "INVALID_ARGUMENT",
  });
});

test("returns the bounded adapter code when Google gives no HTTP diagnostic", async () => {
  const { deps } = dependencies({
    selectProvider: () => ({
      name: "google",
      adapter: {
        submit: async () => {
          throw new GoogleProviderError("provider_status_invalid", {
            retryable: false,
            submissionAmbiguous: false,
          });
        },
      },
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify({
        ...requestBody,
        idempotency_key: "video-google-diagnostic-2",
      }),
    }),
  );

  assert.equal(response.status, 503);
  const payload = await response.json();
  assert.deepEqual(payload.error.provider, {
    name: "google",
    code: "provider_status_invalid",
  });
});

test("returns insufficient credits before provider submission", async () => {
  let submitCount = 0;
  const { deps } = dependencies({
    selectProvider: () => ({
      name: "fal",
      adapter: {
        submit: async () => {
          submitCount += 1;
        },
      },
    }),
    claimJob: async () => ({
      status: "insufficient_credits",
      credits_remaining: 100,
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );

  assert.equal(response.status, 402);
  assert.equal((await response.json()).error.code, "insufficient_credits");
  assert.equal(submitCount, 0);
});

test("sanitizes a thrown claim infrastructure error", async () => {
  const { deps } = dependencies({
    claimJob: async () => {
      throw new Error("postgres password and internal host");
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request("https://example.test/generate-video", {
      method: "POST",
      headers: { Authorization: "Bearer user-token" },
      body: JSON.stringify(requestBody),
    }),
  );
  const serialized = JSON.stringify(await response.json());

  assert.equal(response.status, 503);
  assert.match(serialized, /service_unavailable/);
  assert.doesNotMatch(serialized, /postgres|password|internal host/i);
});

test("GET hides jobs not owned by the authenticated user", async () => {
  const { deps } = dependencies({ getJob: async () => null });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request(
      `https://example.test/generate-video?job_id=${makeJob().id}`,
      { headers: { Authorization: "Bearer user-token" } },
    ),
  );

  assert.equal(response.status, 404);
  assert.equal((await response.json()).error.code, "job_not_found");
});

test("sanitizes a thrown job lookup infrastructure error", async () => {
  const { deps } = dependencies({
    getJob: async () => {
      throw new Error("rest endpoint leaked service key");
    },
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request(
      `https://example.test/generate-video?job_id=${makeJob().id}`,
      { headers: { Authorization: "Bearer user-token" } },
    ),
  );
  const serialized = JSON.stringify(await response.json());

  assert.equal(response.status, 503);
  assert.match(serialized, /service_unavailable/);
  assert.doesNotMatch(serialized, /endpoint|service key/i);
});

test("signs only a completed private result object", async () => {
  const completed = makeJob({
    status: "completed",
    progress: 1,
    result_object_path: `${makeJob().user_id}/${makeJob().id}/result.mp4`,
  });
  const { deps } = dependencies({
    getJob: async () => completed,
    signResult: async () => ({
      signedUrl: "https://project.supabase.co/storage/v1/object/sign/result",
      expiresAt: "2026-07-25T10:20:00.000Z",
    }),
  });
  const handler = createGenerateVideoHandler(deps);
  const response = await handler(
    new Request(
      `https://example.test/generate-video?job_id=${makeJob().id}`,
      { headers: { Authorization: "Bearer user-token" } },
    ),
  );
  const payload = await response.json();

  assert.equal(payload.job.status, "completed");
  assert.match(payload.job.result_url, /\/object\/sign\//);
  assert.doesNotMatch(JSON.stringify(payload), /result_object_path/);
});
