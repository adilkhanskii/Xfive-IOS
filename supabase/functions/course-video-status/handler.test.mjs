// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";
import { handleCourseVideoStatus } from "./handler.mjs";

const USER = "11111111-1111-4111-8111-111111111111";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const OTHER = "223e4567-e89b-42d3-a456-426614174000";
const CRON = "c".repeat(40);

function req(body, { headers = {}, query = "" } = {}) {
  return new Request(
    `https://example.test/functions/v1/course-video-status${query}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    },
  );
}

function dependencies(overrides = {}) {
  const calls = { rpc: [], fetch: [] };
  const deps = {
    env: {
      BUNNY_STREAM_LIBRARY_ID: "625830",
      BUNNY_STREAM_API_KEY: "api-key",
      BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net",
      COURSE_VIDEO_CRON_SECRET: CRON,
    },
    now: () => 1_900_000_000_000,
    verifyUser: async () => ({ id: USER }),
    logger: { error() {}, warn() {} },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "course_video_record_provider_status") {
        return {
          status: "recorded",
          asset_status: params.p_provider_status === 4 ? "ready" : "processing",
        };
      }
      if (name === "course_video_owner_lookup") {
        return {
          status: "found",
          asset_status: "processing",
          last_checked_at: null,
        };
      }
      if (name === "course_video_reconcile_batch") {
        return { refresh: [VIDEO], delete: [OTHER], abandoned: 0 };
      }
      if (name === "course_video_mark_deleted") return { status: "deleted" };
      return null;
    },
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), method: init?.method });
      if (init?.method === "DELETE") return new Response("{}", { status: 200 });
      return new Response(
        JSON.stringify({
          guid: VIDEO,
          videoLibraryId: 625830,
          status: 4,
          encodeProgress: 100,
          length: 3600,
          availableResolutions: "480p,720p,1080p",
          thumbnailFileName: "thumbnail.jpg",
          width: 1920,
          height: 1080,
        }),
        { status: 200 },
      );
    },
    ...overrides,
  };
  return { deps, calls };
}

test("webhook re-reads Bunny instead of trusting the payload", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCourseVideoStatus(
    req({ VideoLibraryId: 625830, VideoGuid: VIDEO, Status: 5 }),
    deps,
  );
  assert.equal(response.status, 200);
  assert.equal(calls.fetch.length, 1);
  assert.ok(calls.fetch[0].url.endsWith(`/library/625830/videos/${VIDEO}`));
  const record = calls.rpc.find((call) =>
    call.name === "course_video_record_provider_status"
  );
  assert.equal(record.params.p_provider_status, 4); // from API, not webhook "5"
  assert.equal(record.params.p_length_seconds, 3600);
});

test("webhook for a foreign library is acknowledged and ignored", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCourseVideoStatus(
    req({ VideoLibraryId: 1, VideoGuid: VIDEO, Status: 3 }),
    deps,
  );
  assert.equal(response.status, 200);
  assert.equal(calls.fetch.length, 0);
});

test("optional webhook secret is enforced when configured", async () => {
  const { deps } = dependencies();
  deps.env.BUNNY_STREAM_WEBHOOK_SECRET = "hook-secret";
  const denied = await handleCourseVideoStatus(
    req({ VideoLibraryId: 625830, VideoGuid: VIDEO, Status: 3 }),
    deps,
  );
  assert.equal(denied.status, 403);
  const allowed = await handleCourseVideoStatus(
    req({ VideoLibraryId: 625830, VideoGuid: VIDEO, Status: 3 }, {
      query: "?secret=hook-secret",
    }),
    deps,
  );
  assert.equal(allowed.status, 200);
});

test("owner polling refreshes an in-flight asset", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCourseVideoStatus(
    req({ video_id: VIDEO }, { headers: { Authorization: "Bearer user" } }),
    deps,
  );
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.status, "ready");
  assert.equal(calls.rpc[0].params.p_user_id, USER);
});

test("polling by a stranger is 404 and never calls Bunny", async () => {
  const { deps, calls } = dependencies({
    rpc: async () => ({ status: "not_found" }),
  });
  const response = await handleCourseVideoStatus(
    req({ video_id: VIDEO }, { headers: { Authorization: "Bearer user" } }),
    deps,
  );
  assert.equal(response.status, 404);
  assert.equal(calls.fetch.length, 0);
});

test("polling without a user is 401", async () => {
  const { deps } = dependencies({ verifyUser: async () => null });
  const response = await handleCourseVideoStatus(
    req({ video_id: VIDEO }),
    deps,
  );
  assert.equal(response.status, 401);
});

test("reconcile requires the cron secret", async () => {
  const { deps, calls } = dependencies();
  const denied = await handleCourseVideoStatus(
    req({}, {
      query: "?reconcile=1",
      headers: { "X-X5-Reconcile-Secret": "wrong" },
    }),
    deps,
  );
  assert.equal(denied.status, 403);
  assert.equal(calls.rpc.length, 0);
});

test("reconcile refreshes and deletes only ledger videos", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCourseVideoStatus(
    req({}, {
      query: "?reconcile=1",
      headers: { "X-X5-Reconcile-Secret": CRON },
    }),
    deps,
  );
  const payload = await response.json();
  assert.deepEqual(payload, {
    ok: true,
    refreshed: 1,
    deleted: 1,
    delete_failed: 0,
    abandoned: 0,
  });
  const deletes = calls.fetch.filter((call) => call.method === "DELETE");
  assert.equal(deletes.length, 1);
  assert.ok(deletes[0].url.endsWith(`/videos/${OTHER}`));
  assert.ok(
    calls.rpc.some((call) => call.name === "course_video_mark_deleted"),
  );
});

test("failed Bunny delete leaves the row for retry", async () => {
  const { deps, calls } = dependencies({
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), method: init?.method });
      return new Response("{}", { status: 500 });
    },
  });
  const payload = await (await handleCourseVideoStatus(
    req({}, {
      query: "?reconcile=1",
      headers: { "X-X5-Reconcile-Secret": CRON },
    }),
    deps,
  )).json();
  assert.equal(payload.deleted, 0);
  assert.equal(payload.delete_failed, 1);
  assert.ok(
    !calls.rpc.some((call) => call.name === "course_video_mark_deleted"),
  );
});

test("short cron secret config fails closed", async () => {
  const { deps } = dependencies();
  deps.env.COURSE_VIDEO_CRON_SECRET = "short";
  const response = await handleCourseVideoStatus(
    req({}, {
      query: "?reconcile=1",
      headers: { "X-X5-Reconcile-Secret": "short" },
    }),
    deps,
  );
  assert.equal(response.status, 403);
});
