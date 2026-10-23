// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";
import { handleCreatePortfolioVideoUpload, MAX_PORTFOLIO_SOURCE_BYTES } from "./handler.mjs";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";

const body = (o = {}) => ({
  course_id: USER, lesson_id: "portfolio", upload_key: "pv_0123456789abcdef",
  title: "Portfolio video", file_name: "IMG_0001.MOV", content_type: "video/quicktime",
  source_bytes: 143_173_434, ...o,
});
const req = (b, h = { Authorization: "Bearer user-jwt" }) => new Request("https://x.test/f", {
  method: "POST", headers: { "Content-Type": "application/json", ...h }, body: JSON.stringify(b),
});
function deps(o = {}) {
  const calls = { rpc: [], fetch: [] };
  return {
    calls,
    env: { BUNNY_STREAM_LIBRARY_ID: "625830", BUNNY_STREAM_API_KEY: "k", BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net", BUNNY_STREAM_TOKEN_KEY: "t" },
    now: () => 1_900_000_000_000,
    verifyUser: async () => ({ id: USER }),
    logger: { error() {} },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "portfolio_video_claim_upload") return { status: "claimed" };
      if (name === "portfolio_video_record_upload") return { status: "recorded" };
      return null;
    },
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), init });
      return new Response(JSON.stringify({ guid: VIDEO }), { status: 200 });
    },
    ...o,
  };
}

test("видео 143 МБ получает TUS-подпись Bunny и bunny-stream ссылку", async () => {
  const d = deps();
  const res = await handleCreatePortfolioVideoUpload(req(body()), d);
  assert.equal(res.status, 200);
  const j = await res.json();
  assert.equal(j.video_id, VIDEO);
  assert.equal(j.media_url, `bunny-stream:${VIDEO}`);
  assert.equal(j.upload_required, true);
  assert.match(j.authorization_signature, /^[0-9a-f]{64}$/);
  assert.ok(d.calls.fetch[0].url.endsWith("/library/625830/videos"));
  assert.deepEqual(d.calls.rpc.map((c) => c.name), ["portfolio_video_claim_upload", "portfolio_video_record_upload"]);
  assert.ok(!JSON.stringify(j).includes('"k"'), "ключ Bunny не уходит клиенту");
});

test("чужой owner — 403, без гостя — 401", async () => {
  assert.equal((await handleCreatePortfolioVideoUpload(req(body({ course_id: OTHER })), deps())).status, 403);
  assert.equal((await handleCreatePortfolioVideoUpload(req(body(), {}), deps())).status, 401);
});

test("не видео, не portfolio или слишком большое — 400", async () => {
  for (const b of [body({ content_type: "image/jpeg" }), body({ lesson_id: "lesson-1" }), body({ source_bytes: MAX_PORTFOLIO_SOURCE_BYTES + 1 })]) {
    assert.equal((await handleCreatePortfolioVideoUpload(req(b), deps())).status, 400);
  }
});

test("повтор с тем же ключом — тот же ролик, без нового в Bunny", async () => {
  const d = deps({ rpc: async (name) => (name === "portfolio_video_claim_upload" ? { status: "replay", video_id: VIDEO } : null) });
  const res = await handleCreatePortfolioVideoUpload(req(body()), d);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).video_id, VIDEO);
  assert.equal(d.calls.fetch.length, 0);
});

test("лимит в час — 429", async () => {
  const d = deps({ rpc: async () => ({ status: "rate_limited" }) });
  assert.equal((await handleCreatePortfolioVideoUpload(req(body()), d)).status, 429);
});
