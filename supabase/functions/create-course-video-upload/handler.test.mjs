// deno-lint-ignore-file require-await
// Async stubs deliberately model the production network/RPC dependency shape.
import assert from "node:assert/strict";
import test from "node:test";
import {
  BUNNY_STREAM_TUS_ENDPOINT,
  handleCreateCourseVideoUpload,
} from "./handler.mjs";

const USER = "11111111-1111-4111-8111-111111111111";
const COURSE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const LEASE = "99999999-9999-4999-8999-999999999999";
const API_KEY = "server-only-bunny-api-key";

function validBody(overrides = {}) {
  return {
    course_id: COURSE,
    lesson_id: "lesson_E43F20F8-B2C6-4838-9E81-202864717743",
    upload_key: "lv_0123456789abcdef",
    title: "Course lesson",
    file_name: "lesson.mov",
    content_type: "video/quicktime",
    source_bytes: 8 * 1024 * 1024 * 1024,
    ...overrides,
  };
}

function request(body, headers = { Authorization: "Bearer user-jwt" }) {
  return new Request(
    "https://example.test/functions/v1/create-course-video-upload",
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
      BUNNY_STREAM_API_KEY: API_KEY,
      BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net",
      BUNNY_STREAM_TOKEN_KEY: "token-key",
    },
    now: () => 1_900_000_000_000,
    verifyUser: async () => ({ id: USER }),
    randomUUID: () => LEASE,
    logger: { error() {}, warn() {} },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "course_video_claim_upload") {
        return { status: "claimed", reclaimed: false };
      }
      if (name === "course_video_complete_upload") {
        return { status: "completed", video_id: params.p_video_id };
      }
      return null;
    },
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), init });
      return new Response(JSON.stringify({ guid: VIDEO }), { status: 200 });
    },
    ...overrides,
  };
  return { deps, calls };
}

test("rejects missing bearer before any RPC or Bunny call", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCreateCourseVideoUpload(
    request(validBody(), {}),
    deps,
  );
  assert.equal(response.status, 401);
  assert.equal(calls.rpc.length, 0);
  assert.equal(calls.fetch.length, 0);
});

test("rejects an unverifiable JWT", async () => {
  const { deps, calls } = dependencies({ verifyUser: async () => null });
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 401);
  assert.equal(calls.rpc.length, 0);
});

test("validates the body before the broker", async () => {
  const { deps, calls } = dependencies();
  for (
    const bad of [
      { course_id: "not-a-uuid" },
      { lesson_id: "bad lesson id" },
      { upload_key: "short" },
      { content_type: "image/png" },
      { source_bytes: 0 },
      { source_bytes: 50 * 1024 * 1024 * 1024 },
    ]
  ) {
    const response = await handleCreateCourseVideoUpload(
      request(validBody(bad)),
      deps,
    );
    assert.equal(response.status, 400, JSON.stringify(bad));
  }
  assert.equal(calls.rpc.length, 0);
});

test("missing Bunny config answers 503 without calling the broker", async () => {
  const { deps, calls } = dependencies({ env: {} });
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "video_upload_unavailable",
  });
  assert.equal(calls.rpc.length, 0);
});

test("broker passes the verified user id; disabled flag maps to 503", async () => {
  const { deps, calls } = dependencies({
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      return { status: "disabled" };
    },
  });
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 503);
  assert.equal(calls.rpc[0].name, "course_video_claim_upload");
  assert.equal(calls.rpc[0].params.p_user_id, USER);
  assert.equal(calls.rpc[0].params.p_course_id, COURSE);
  assert.equal(calls.fetch.length, 0);
});

test("non-author is refused with 403 and no Bunny object is created", async () => {
  for (const status of ["not_authorized", "course_unavailable"]) {
    const { deps, calls } = dependencies({
      rpc: async () => ({ status }),
    });
    const response = await handleCreateCourseVideoUpload(
      request(validBody()),
      deps,
    );
    assert.equal(response.status, 403);
    assert.equal(calls.fetch.length, 0);
  }
});

test("claimed slot creates a Bunny video and returns a TUS signature only", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.tus_endpoint, BUNNY_STREAM_TUS_ENDPOINT);
  assert.equal(payload.video_id, VIDEO);
  assert.equal(payload.library_id, "625830");
  assert.equal(payload.upload_required, true);
  assert.match(payload.authorization_signature, /^[0-9a-f]{64}$/);
  assert.equal(payload.authorization_expire, 1_900_000_000 + 24 * 60 * 60);
  assert.equal(payload.upload_headers.VideoId, VIDEO);
  // never a playable/public URL, never the API key
  assert.equal(payload.playback_url, undefined);
  assert.ok(!JSON.stringify(payload).includes(API_KEY));
  assert.equal(calls.fetch.length, 1);
  assert.equal(calls.fetch[0].init.headers.AccessKey, API_KEY);
  assert.equal(calls.rpc[1].name, "course_video_complete_upload");
  assert.equal(calls.rpc[1].params.p_video_id, VIDEO);
  assert.equal(calls.rpc[1].params.p_lease_token, LEASE);
});

test("signature matches Bunny's sha256(library + key + expire + video)", async () => {
  const { deps } = dependencies();
  const payload = await (await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  )).json();
  const expected = Array.from(
    new Uint8Array(
      await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(
          `625830${API_KEY}${payload.authorization_expire}${VIDEO}`,
        ),
      ),
    ),
  ).map((b) => b.toString(16).padStart(2, "0")).join("");
  assert.equal(payload.authorization_signature, expected);
});

test("replay re-signs the same video without creating another", async () => {
  const { deps, calls } = dependencies({
    rpc: async (name) => {
      calls.rpc.push({ name });
      return {
        status: "replay",
        video_id: VIDEO,
        asset_status: "awaiting_upload",
      };
    },
  });
  const payload = await (await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  )).json();
  assert.equal(payload.video_id, VIDEO);
  assert.equal(payload.upload_required, true);
  assert.equal(calls.fetch.length, 0);
  assert.equal(calls.rpc.length, 1);
});

test("replay of a finished upload does not hand out a new signature", async () => {
  const { deps } = dependencies({
    rpc: async () => ({
      status: "replay",
      video_id: VIDEO,
      asset_status: "ready",
    }),
  });
  const payload = await (await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  )).json();
  assert.equal(payload.upload_required, false);
  assert.equal(payload.authorization_signature, undefined);
});

test("reclaimed slot finds the ambiguous Bunny object by title first", async () => {
  const { deps, calls } = dependencies({
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "course_video_claim_upload") {
        return { status: "claimed", reclaimed: true };
      }
      return { status: "completed" };
    },
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), init });
      return new Response(
        JSON.stringify({
          items: [{
            guid: VIDEO,
            title:
              `X5 lesson ${COURSE} lesson_E43F20F8-B2C6-4838-9E81-202864717743 lv_0123456789abcdef`,
          }],
        }),
        { status: 200 },
      );
    },
  });
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 200);
  assert.equal(calls.fetch.length, 1);
  assert.equal(calls.fetch[0].init.method, "GET");
});

test("status mapping for rate limit, in-progress, conflict, expired", async () => {
  const cases = [
    ["rate_limited", 429],
    ["in_progress", 425],
    ["idempotency_conflict", 409],
    ["expired", 410],
  ];
  for (const [status, http] of cases) {
    const { deps } = dependencies({ rpc: async () => ({ status }) });
    const response = await handleCreateCourseVideoUpload(
      request(validBody()),
      deps,
    );
    assert.equal(response.status, http, status);
  }
});

test("Bunny create failure returns 502 and does not complete the slot", async () => {
  const { deps, calls } = dependencies({
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), init });
      return new Response("{}", { status: 401 });
    },
  });
  const response = await handleCreateCourseVideoUpload(
    request(validBody()),
    deps,
  );
  assert.equal(response.status, 502);
  assert.ok(
    !calls.rpc.some((call) => call.name === "course_video_complete_upload"),
  );
});
