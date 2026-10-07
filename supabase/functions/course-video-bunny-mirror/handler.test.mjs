// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";
import { handleCourseVideoBunnyMirror, verifyHLS } from "./handler.mjs";

const SECRET = "s".repeat(40);
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const JOB = "99999999-9999-4999-8999-999999999999";
const SOURCE =
  "https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/courses/c/l.mp4";
const CDN = "vz-test.b-cdn.net";
const HLS = `https://${CDN}/${VIDEO}/playlist.m3u8`;
const NOW = Date.parse("2026-10-01T12:00:00Z");

function req(body = {}, secret = SECRET) {
  return new Request("https://x.test/functions/v1/course-video-bunny-mirror", {
    method: "POST",
    headers: {
      "X-X5-Reconcile-Secret": secret,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function cdnFetch(overrides = {}) {
  return async (url, init = {}) => {
    const href = String(url);
    if (overrides[href]) return overrides[href](init);
    if (href === SOURCE && init.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: { "content-length": "1000" },
      });
    }
    if (href.endsWith("/videos/fetch")) {
      return new Response(JSON.stringify({ success: true, id: VIDEO }), {
        status: 200,
      });
    }
    if (href.includes(`/videos/${VIDEO}`)) {
      return new Response(
        JSON.stringify({
          guid: VIDEO,
          videoLibraryId: 625830,
          status: 4,
          length: 60,
        }),
        { status: 200 },
      );
    }
    if (href === HLS) {
      return new Response(
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720p/video.m3u8\n",
      );
    }
    if (href.endsWith("/720p/video.m3u8")) {
      return new Response("#EXTM3U\n#EXTINF:4,\nvideo0.ts\n");
    }
    if (href.endsWith("/720p/video0.ts")) {
      return new Response("x", { status: 206 });
    }
    if (init.method === "DELETE") return new Response("{}", { status: 200 });
    return new Response("nope", { status: 404 });
  };
}

function deps(job, overrides = {}) {
  const calls = { rpc: [], fetch: [] };
  const fetchImpl = overrides.fetchImpl || cdnFetch();
  const d = {
    env: {
      COURSE_VIDEO_CRON_SECRET: SECRET,
      BUNNY_STREAM_LIBRARY_ID: "625830",
      BUNNY_STREAM_API_KEY: "api",
      BUNNY_STREAM_CDN_HOSTNAME: CDN,
      SUPABASE_URL: "https://afwznqjpshybmqhlewmy.supabase.co",
    },
    now: () => NOW,
    serviceHeaders: () => ({ apikey: "svc" }),
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), method: init?.method || "GET" });
      return fetchImpl(url, init);
    },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "course_video_mirror_swap") return "swapped";
      if (name === "course_video_mirror_can_delete") return true;
      if (name === "course_video_mirror_enqueue") return 0;
      return null;
    },
    rpcRows: async (
      name,
    ) => (name === "course_video_mirror_claim" ? [job] : []),
    ...overrides,
  };
  return { d, calls };
}

const baseJob = {
  id: JOB,
  course_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  lesson_id: "l1",
  source_url: SOURCE,
  storage_path: "courses/c/l.mp4",
  created_at: "2026-10-01T11:00:00Z",
};

const sets = (calls) =>
  calls.rpc.filter((c) => c.name === "course_video_mirror_set").map((c) =>
    c.params
  );

test("requires the cron secret", async () => {
  const { d, calls } = deps(baseJob);
  assert.equal(
    (await handleCourseVideoBunnyMirror(req({}, "wrong"), d)).status,
    403,
  );
  assert.equal(calls.rpc.length, 0);
});

test("queued job asks Bunny to fetch the public URL", async () => {
  const { d, calls } = deps({ ...baseJob, status: "queued" });
  const res = await (await handleCourseVideoBunnyMirror(req(), d)).json();
  assert.equal(res.results[0].status, "encoding");
  const fetchCall = calls.fetch.find((c) => c.url.endsWith("/videos/fetch"));
  assert.equal(fetchCall.method, "POST");
  assert.equal(sets(calls)[0].p_bunny_video_id, VIDEO);
});

test("missing source never reaches Bunny", async () => {
  const { d, calls } = deps({ ...baseJob, status: "queued" }, {
    fetchImpl: cdnFetch({
      [SOURCE]: async () => new Response(null, { status: 404 }),
    }),
  });
  await handleCourseVideoBunnyMirror(req(), d);
  assert.equal(sets(calls)[0].p_status, "failed");
  assert.ok(!calls.fetch.some((c) => c.url.endsWith("/videos/fetch")));
});

test("encoded video is verified (playlist + segment) before swap", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "encoding",
    bunny_video_id: VIDEO,
  });
  const res = await (await handleCourseVideoBunnyMirror(req(), d)).json();
  assert.equal(res.results[0].status, "swapped");
  assert.ok(calls.fetch.some((c) => c.url.endsWith("/720p/video0.ts")));
  const swap = calls.rpc.find((c) => c.name === "course_video_mirror_swap");
  assert.equal(swap.params.p_hls_url, HLS);
  assert.ok(!calls.fetch.some((c) => c.method === "DELETE"));
});

test("failed verification (e.g. token auth on) blocks the swap", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "encoding",
    bunny_video_id: VIDEO,
  }, {
    fetchImpl: cdnFetch({
      [HLS]: async () => new Response("", { status: 403 }),
    }),
  });
  await handleCourseVideoBunnyMirror(req(), d);
  assert.ok(!calls.rpc.some((c) => c.name === "course_video_mirror_swap"));
  assert.equal(sets(calls)[0].p_status, "encoding");
});

test("Bunny encode error fails the job without swap or delete", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "encoding",
    bunny_video_id: VIDEO,
  }, {
    fetchImpl: cdnFetch({
      [`https://video.bunnycdn.com/library/625830/videos/${VIDEO}`]: async () =>
        new Response(JSON.stringify({ guid: VIDEO, status: 5 }), {
          status: 200,
        }),
    }),
  });
  await handleCourseVideoBunnyMirror(req(), d);
  assert.equal(sets(calls)[0].p_status, "failed");
  assert.ok(!calls.rpc.some((c) => c.name === "course_video_mirror_swap"));
});

test("swapped job waits for the grace period", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "swapped",
    bunny_video_id: VIDEO,
    hls_url: HLS,
    swapped_at: "2026-10-01T11:30:00Z",
  });
  const res = await (await handleCourseVideoBunnyMirror(req(), d)).json();
  assert.equal(res.results[0].status, "swapped_waiting_grace");
  assert.ok(!calls.fetch.some((c) => c.method === "DELETE"));
});

test("after grace + reverify + guard the storage object is deleted", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "swapped",
    bunny_video_id: VIDEO,
    hls_url: HLS,
    swapped_at: "2026-10-01T11:30:00Z",
  });
  const res = await (await handleCourseVideoBunnyMirror(
    req({ delete_grace_minutes: 0 }),
    d,
  )).json();
  assert.equal(res.results[0].status, "storage_deleted");
  const del = calls.fetch.find((c) => c.method === "DELETE");
  assert.equal(
    del.url,
    "https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/videos/courses/c/l.mp4",
  );
});

test("delete guard refusal keeps the object", async () => {
  const { d, calls } = deps({
    ...baseJob,
    status: "swapped",
    bunny_video_id: VIDEO,
    hls_url: HLS,
    swapped_at: "2026-09-01T00:00:00Z",
  }, {
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      return name === "course_video_mirror_can_delete" ? false : null;
    },
  });
  await handleCourseVideoBunnyMirror(req(), d);
  assert.ok(!calls.fetch.some((c) => c.method === "DELETE"));
});

test("dry run only lists candidates", async () => {
  const { d, calls } = deps(baseJob, {
    rpcRows: async (name) => {
      calls.rpc.push({ name });
      return [{ lesson_id: "l1" }];
    },
  });
  const res =
    await (await handleCourseVideoBunnyMirror(req({ dry_run: true }), d))
      .json();
  assert.equal(res.candidates.length, 1);
  assert.deepEqual(calls.rpc.map((c) => c.name), [
    "course_video_mirror_candidates",
  ]);
  assert.equal(calls.fetch.length, 0);
});

test("verifyHLS rejects non-playlists", async () => {
  const bad = await verifyHLS(async () => new Response("<html>"), HLS);
  assert.equal(bad.ok, false);
});
