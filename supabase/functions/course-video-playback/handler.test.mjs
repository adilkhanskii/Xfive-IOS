// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";
import { handleCourseVideoPlayback } from "./handler.mjs";
import { signedDirectoryURL } from "../_shared/bunny-stream.mjs";

const USER = "22222222-2222-4222-8222-222222222222";
const COURSE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const NOW = 1_900_000_000_000;

function jwt(payload) {
  const encode = (value) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_")
      .replace(/=+$/, "");
  return `${encode({ alg: "HS256" })}.${encode(payload)}.signature`;
}

function request(body, token = jwt({ role: "authenticated", sub: USER })) {
  return new Request(
    "https://example.test/functions/v1/course-video-playback",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    },
  );
}

function dependencies(overrides = {}) {
  const calls = { rpc: [], verify: 0 };
  const deps = {
    env: {
      BUNNY_STREAM_LIBRARY_ID: "625830",
      BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net",
      BUNNY_STREAM_TOKEN_KEY: "token-key",
    },
    now: () => NOW,
    verifyUser: async () => {
      calls.verify += 1;
      return { id: USER };
    },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      return {
        status: "granted",
        video_id: VIDEO,
        length_seconds: 600,
        thumbnail_file_name: "thumbnail.jpg",
      };
    },
    logger: { error() {} },
    ...overrides,
  };
  return { deps, calls };
}

const body = { course_id: COURSE, lesson_id: "l1" };

test("entitled user gets a short-lived token-signed HLS URL", async () => {
  const { deps, calls } = dependencies();
  const response = await handleCourseVideoPlayback(request(body), deps);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const payload = await response.json();
  assert.equal(calls.rpc[0].name, "course_video_playback_grant");
  assert.equal(calls.rpc[0].params.p_user_id, USER);
  assert.equal(payload.status, "ready");
  assert.equal(payload.expires_at, NOW / 1000 + 2 * 60 * 60);
  const url = new URL(payload.hls_url);
  assert.equal(url.host, "vz-test.b-cdn.net");
  assert.ok(url.pathname.startsWith("/bcdn_token="));
  assert.ok(url.pathname.endsWith(`/${VIDEO}/playlist.m3u8`));
  assert.ok(payload.hls_url.includes(`expires=${payload.expires_at}`));
  assert.ok(payload.hls_url.includes("token_path=%2F" + VIDEO + "%2F"));
  assert.ok(!payload.hls_url.includes("token-key"));
  assert.ok(payload.thumbnail_url.endsWith(`/${VIDEO}/thumbnail.jpg`));
  // never the permanent unsigned URL
  assert.notEqual(
    payload.hls_url,
    `https://vz-test.b-cdn.net/${VIDEO}/playlist.m3u8`,
  );
});

test("token follows Bunny directory-token algorithm", async () => {
  const url = await signedDirectoryURL({
    cdnHostname: "vz-test.b-cdn.net",
    tokenKey: "token-key",
    videoID: VIDEO,
    file: "playlist.m3u8",
    expires: 1_900_007_200,
  });
  const path = `/${VIDEO}/`;
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`token-key${path}1900007200token_path=${path}`),
    ),
  );
  const token = btoa(String.fromCharCode(...digest)).replace(/\+/g, "-")
    .replace(/\//g, "_").replace(/=+$/, "");
  assert.equal(
    url,
    `https://vz-test.b-cdn.net/bcdn_token=${token}&expires=1900007200&token_path=${
      encodeURIComponent(path)
    }${path}playlist.m3u8`,
  );
});

test("long lessons get TTL of length + 1h, capped at 12h", async () => {
  const { deps } = dependencies({
    rpc: async () => ({
      status: "granted",
      video_id: VIDEO,
      length_seconds: 5 * 3600,
    }),
  });
  const payload = await (await handleCourseVideoPlayback(request(body), deps))
    .json();
  assert.equal(payload.expires_at, NOW / 1000 + 6 * 3600);
  const { deps: longDeps } = dependencies({
    rpc: async () => ({
      status: "granted",
      video_id: VIDEO,
      length_seconds: 20 * 3600,
    }),
  });
  const longPayload =
    await (await handleCourseVideoPlayback(request(body), longDeps))
      .json();
  assert.equal(longPayload.expires_at, NOW / 1000 + 12 * 3600);
});

test("guest with the anon key is passed as null user (free lessons only)", async () => {
  const { deps, calls } = dependencies();
  await handleCourseVideoPlayback(request(body, jwt({ role: "anon" })), deps);
  assert.equal(calls.verify, 0);
  assert.equal(calls.rpc[0].params.p_user_id, null);
  const { deps: pubDeps, calls: pubCalls } = dependencies();
  await handleCourseVideoPlayback(request(body, "sb_publishable_abc"), pubDeps);
  assert.equal(pubCalls.rpc[0].params.p_user_id, null);
});

test("invalid user token is 401, not a silent guest", async () => {
  const { deps, calls } = dependencies({ verifyUser: async () => null });
  const response = await handleCourseVideoPlayback(request(body), deps);
  assert.equal(response.status, 401);
  assert.equal(calls.rpc.length, 0);
});

test("grant statuses map to HTTP codes without URLs", async () => {
  const cases = [
    ["not_entitled", 403],
    ["not_authenticated", 401],
    ["processing", 202],
    ["failed", 422],
    ["not_bunny_lesson", 409],
    ["lesson_unavailable", 404],
    ["weird", 503],
  ];
  for (const [status, http] of cases) {
    const { deps } = dependencies({ rpc: async () => ({ status }) });
    const response = await handleCourseVideoPlayback(request(body), deps);
    assert.equal(response.status, http, status);
    const payload = await response.json();
    assert.equal(payload.hls_url, undefined);
  }
  const { deps } = dependencies({ rpc: async () => null });
  assert.equal(
    (await handleCourseVideoPlayback(request(body), deps)).status,
    503,
  );
});

test("missing token key fails closed", async () => {
  const { deps, calls } = dependencies({
    env: {
      BUNNY_STREAM_LIBRARY_ID: "625830",
      BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net",
    },
  });
  const response = await handleCourseVideoPlayback(request(body), deps);
  assert.equal(response.status, 503);
  assert.equal(calls.rpc.length, 0);
});

test("bad body is 400", async () => {
  const { deps } = dependencies();
  for (
    const bad of [{}, { course_id: "x", lesson_id: "l1" }, {
      course_id: COURSE,
      lesson_id: "a b",
    }]
  ) {
    assert.equal(
      (await handleCourseVideoPlayback(request(bad), deps)).status,
      400,
    );
  }
});
