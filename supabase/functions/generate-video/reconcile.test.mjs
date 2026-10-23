import assert from "node:assert/strict";
import test from "node:test";

import { createVideoReconcileHandler } from "./reconcile.mjs";

const reconcileSecret = "dedicated-cron-secret-that-never-leaves-the-server";
const nowMs = Date.parse("2026-07-26T15:00:00.000Z");

function job(overrides = {}) {
  return {
    id: "34a0edfd-5ac9-45ea-9b31-dde0d73a8b8f",
    user_id: "0fb5b519-d40e-4502-8f44-462ea699e6c7",
    provider_name: "google",
    provider_kind: "text",
    provider_request_id: "google_interaction_123",
    status: "rendering",
    progress: 0.5,
    created_at: "2026-07-26T14:00:00.000Z",
    updated_at: "2026-07-26T14:30:00.000Z",
    ...overrides,
  };
}

function request(key = reconcileSecret) {
  return new Request(
    "https://project.supabase.co/functions/v1/generate-video?reconcile=google",
    {
      method: "POST",
      headers: {
        "X-X5-Reconcile-Secret": key,
      },
    },
  );
}

function dependencies(overrides = {}) {
  const calls = [];
  return {
    calls,
    deps: {
      reconcileSecret,
      nowMs: () => nowMs,
      claimBatch: async (parameters) => {
        calls.push(["claim", parameters]);
        return { status: "claimed", jobs: [job()] };
      },
      reconcileJob: async (row) => {
        calls.push(["reconcile", row.id]);
        return { ...row, status: "completed", progress: 1 };
      },
      failJob: async (parameters) => {
        calls.push(["fail", parameters]);
        return { status: "failed", refunded: true };
      },
      cleanupInput: async (row) => {
        calls.push(["cleanup", row.id]);
      },
      ...overrides,
    },
  };
}

test("requires the exact dedicated reconciliation secret", async () => {
  const handler = createVideoReconcileHandler(dependencies().deps);
  assert.equal((await handler(request("wrong-key"))).status, 401);
  assert.equal(
    (await handler(
      new Request(
        "https://project.supabase.co/functions/v1/generate-video?reconcile=google",
        {
          method: "POST",
          headers: {
            Authorization: "Bearer service-role-key",
            apikey: "service-role-key",
          },
        },
      ),
    )).status,
    401,
  );
  assert.equal(
    (await handler(
      new Request(
        "https://project.supabase.co/functions/v1/generate-video?reconcile=google",
        { method: "POST" },
      ),
    )).status,
    401,
  );
});

test("claims a bounded batch and reconciles provider-id jobs", async () => {
  const { deps, calls } = dependencies();
  const response = await createVideoReconcileHandler(deps)(request());

  assert.equal(response.status, 200);
  assert.deepEqual(calls[0], ["claim", {
    p_limit: 20,
    p_stale_after: "2 minutes",
    p_max_age: "24 hours",
  }]);
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 1);
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("reconciles OpenAI jobs through the same bounded cron path", async () => {
  const openAIJob = job({
    provider_name: "openai",
    provider_request_id: "video_openai_123",
  });
  const { deps, calls } = dependencies({
    claimBatch: async () => ({ status: "claimed", jobs: [openAIJob] }),
  });
  const response = await createVideoReconcileHandler(deps)(request());

  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.filter(([name]) => name === "reconcile"),
    [["reconcile", openAIJob.id]],
  );
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("fails and refunds jobs older than the bounded provider lifetime", async () => {
  const expired = job({
    created_at: "2026-07-25T14:59:59.000Z",
  });
  const { deps, calls } = dependencies({
    claimBatch: async () => ({ status: "claimed", jobs: [expired] }),
  });
  const response = await createVideoReconcileHandler(deps)(request());

  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.filter(([name]) => name === "fail"),
    [["fail", {
      p_job_id: expired.id,
      p_provider_request_id: expired.provider_request_id,
      p_error_code: "provider_timed_out",
    }]],
  );
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("refunds an expired ambiguous submit even when Google returned no id", async () => {
  const expired = job({
    provider_request_id: null,
    status: "queued",
    created_at: "2026-07-25T14:59:59.000Z",
  });
  const { deps, calls } = dependencies({
    claimBatch: async () => ({ status: "claimed", jobs: [expired] }),
  });
  const response = await createVideoReconcileHandler(deps)(request());

  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.filter(([name]) => name === "fail"),
    [["fail", {
      p_job_id: expired.id,
      p_provider_request_id: null,
      p_error_code: "provider_timed_out",
    }]],
  );
  assert.equal(calls.filter(([name]) => name === "reconcile").length, 0);
  assert.equal(calls.filter(([name]) => name === "cleanup").length, 1);
});

test("returns non-2xx when a claimed reconciliation cannot be completed", async () => {
  const { deps } = dependencies({
    reconcileJob: async () => {
      throw new Error("provider unavailable");
    },
  });
  const response = await createVideoReconcileHandler(deps)(request());
  assert.equal(response.status, 503);
});
