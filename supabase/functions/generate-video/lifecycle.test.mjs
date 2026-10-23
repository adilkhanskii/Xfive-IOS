import assert from "node:assert/strict";
import test from "node:test";

import * as lifecycle from "./lifecycle.mjs";

function makeJob(overrides = {}) {
  return {
    id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    user_id: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
    status: "rendering",
    provider_name: "fal",
    provider_kind: "text",
    provider_request_id: "fal-request-123",
    input_object_path:
      "0fb5b519-d40e-4502-8f44-462ea699e6c7/34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f/start.jpg",
    ...overrides,
  };
}

test("a terminal FAL success completes the job and terminal replay only cleans input", async () => {
  assert.equal(typeof lifecycle.handleFalTerminalWebhook, "function");
  const calls = [];
  const job = makeJob();
  const payload = {
    request_id: job.provider_request_id,
    status: "OK",
    payload: {
      video: {
        url: "https://v3.fal.media/files/result.mp4",
        content_type: "video/mp4",
        file_size: 12,
      },
    },
  };
  const dependencies = {
    extractResult: (body) => {
      calls.push(["extract", body]);
      return { url: body.video.url, mimeType: "video/mp4" };
    },
    finalizeResult: async ({ job: finalizedJob, loadResult }) => {
      calls.push(["finalize", finalizedJob.id, await loadResult()]);
      return { status: "completed" };
    },
    failJob: async () => {
      throw new Error("failure path must not run");
    },
    cleanupInput: async (cleanedJob) => {
      calls.push(["cleanup", cleanedJob.input_object_path]);
    },
  };

  assert.deepEqual(
    await lifecycle.handleFalTerminalWebhook({
      job,
      requestId: job.provider_request_id,
      payload,
      ...dependencies,
    }),
    { status: "completed", replayed: false },
  );
  assert.deepEqual(calls, [
    ["extract", payload.payload],
    [
      "finalize",
      job.id,
      {
        url: "https://v3.fal.media/files/result.mp4",
        mimeType: "video/mp4",
      },
    ],
  ]);

  calls.length = 0;
  assert.deepEqual(
    await lifecycle.handleFalTerminalWebhook({
      job: makeJob({ status: "completed" }),
      requestId: job.provider_request_id,
      payload,
      ...dependencies,
    }),
    { status: "completed", replayed: true },
  );
  assert.deepEqual(calls, [["cleanup", job.input_object_path]]);
});

test("a terminal FAL error refunds once and cleans the private input", async () => {
  const calls = [];
  const job = makeJob();
  const payload = {
    request_id: job.provider_request_id,
    status: "ERROR",
    error: "provider rejected the render",
  };

  assert.deepEqual(
    await lifecycle.handleFalTerminalWebhook({
      job,
      requestId: job.provider_request_id,
      payload,
      extractResult: () => {
        throw new Error("success path must not run");
      },
      finalizeResult: async () => {
        throw new Error("success path must not run");
      },
      failJob: async ({ job: failedJob, requestId }) => {
        calls.push(["fail", failedJob.id, requestId]);
        return { status: "failed", refunded: true };
      },
      cleanupInput: async (cleanedJob) => {
        calls.push(["cleanup", cleanedJob.input_object_path]);
      },
    }),
    { status: "failed", replayed: false },
  );
  assert.deepEqual(calls, [
    ["fail", job.id, job.provider_request_id],
    ["cleanup", job.input_object_path],
  ]);
});

test("a malformed signed FAL terminal status does not refund", async () => {
  let failCount = 0;
  await assert.rejects(
    lifecycle.handleFalTerminalWebhook({
      job: makeJob(),
      requestId: makeJob().provider_request_id,
      payload: { request_id: makeJob().provider_request_id, status: "QUEUED" },
      extractResult: () => null,
      finalizeResult: async () => ({ status: "completed" }),
      failJob: async () => {
        failCount += 1;
        return { status: "failed" };
      },
      cleanupInput: async () => undefined,
    }),
    /fal_webhook_status_invalid/,
  );
  assert.equal(failCount, 0);
});

test("completed provider output is stored, ledger-completed, and cleaned", async () => {
  assert.equal(typeof lifecycle.finalizeVideoGenerationResult, "function");
  const calls = [];
  const job = makeJob();
  const mp4 = Uint8Array.from([
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

  assert.deepEqual(
    await lifecycle.finalizeVideoGenerationResult({
      job,
      providerName: "fal",
      loadResult: async () => ({
        url: "https://v3.fal.media/files/result.mp4",
        mimeType: "video/mp4",
      }),
      decodeBase64: () => {
        throw new Error("inline path must not run");
      },
      downloadVideo: async (url, options) => {
        calls.push(["download", url, options]);
        return mp4;
      },
      storeResult: async ({ userId, jobId, bytes }) => {
        calls.push(["store", userId, jobId, bytes]);
        return {
          path: `${userId}/${jobId}/result.mp4`,
          sha256: "a".repeat(64),
          mimeType: "video/mp4",
        };
      },
      completeJob: async (parameters) => {
        calls.push(["complete", parameters]);
        return { status: "completed" };
      },
      failJob: async () => {
        throw new Error("failure path must not run");
      },
      cleanupInput: async (cleanedJob) => {
        calls.push(["cleanup", cleanedJob.input_object_path]);
      },
    }),
    { status: "completed" },
  );
  assert.equal(calls.filter(([name]) => name === "download").length, 1);
  assert.equal(calls.filter(([name]) => name === "store").length, 1);
  assert.equal(calls.filter(([name]) => name === "complete").length, 1);
  assert.deepEqual(calls.at(-1), ["cleanup", job.input_object_path]);
});

test("stores bounded provider bytes without re-encoding or downloading", async () => {
  const calls = [];
  const job = makeJob();
  const mp4 = Uint8Array.from([
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

  const outcome = await lifecycle.finalizeVideoGenerationResult({
    job,
    providerName: "google",
    loadResult: async () => ({ dataBytes: mp4, mimeType: "video/mp4" }),
    decodeBase64: () => {
      throw new Error("base64 path must not run");
    },
    downloadVideo: async () => {
      throw new Error("download path must not run");
    },
    storeResult: async ({ bytes }) => {
      calls.push(["store", bytes]);
      return {
        path: `${job.user_id}/${job.id}/result.mp4`,
        sha256: "a".repeat(64),
        mimeType: "video/mp4",
      };
    },
    completeJob: async () => ({ status: "completed" }),
    failJob: async () => {
      throw new Error("failure path must not run");
    },
    cleanupInput: async () => undefined,
  });

  assert.deepEqual(outcome, { status: "completed" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1], mp4);
});

test("permanent completed-result violations refund and clean the job", async () => {
  const calls = [];
  const job = makeJob();

  assert.deepEqual(
    await lifecycle.finalizeVideoGenerationResult({
      job,
      providerName: "fal",
      loadResult: async () => {
        throw new Error("provider_result_too_large");
      },
      decodeBase64: () => {
        throw new Error("unreachable");
      },
      downloadVideo: async () => {
        throw new Error("unreachable");
      },
      storeResult: async () => {
        throw new Error("unreachable");
      },
      completeJob: async () => {
        throw new Error("unreachable");
      },
      failJob: async (parameters) => {
        calls.push(["fail", parameters]);
        return { status: "failed", refunded: true };
      },
      cleanupInput: async (cleanedJob) => {
        calls.push(["cleanup", cleanedJob.input_object_path]);
      },
    }),
    { status: "failed" },
  );
  assert.equal(calls[0][1].p_error_code, "provider_result_too_large");
  assert.deepEqual(calls.at(-1), ["cleanup", job.input_object_path]);
});

test("transient completed-result transport and storage failures remain retryable", async () => {
  const job = makeJob();
  for (
    const errorCode of [
      "provider_result_unavailable",
      "video_storage_upload_failed_503",
    ]
  ) {
    let failCount = 0;
    let cleanupCount = 0;
    await assert.rejects(
      lifecycle.finalizeVideoGenerationResult({
        job,
        providerName: "fal",
        loadResult: async () => ({
          url: "https://v3.fal.media/files/result.mp4",
        }),
        decodeBase64: () => {
          throw new Error("unreachable");
        },
        downloadVideo: async () => {
          if (errorCode === "provider_result_unavailable") {
            throw new Error(errorCode);
          }
          return Uint8Array.from([0, 0, 0, 0]);
        },
        storeResult: async () => {
          throw new Error(errorCode);
        },
        completeJob: async () => {
          throw new Error("unreachable");
        },
        failJob: async () => {
          failCount += 1;
        },
        cleanupInput: async () => {
          cleanupCount += 1;
        },
      }),
      new RegExp(errorCode),
    );
    assert.equal(failCount, 0);
    assert.equal(cleanupCount, 0);
  }
});
