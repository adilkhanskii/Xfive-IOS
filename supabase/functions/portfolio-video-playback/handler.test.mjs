// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";
import { handlePortfolioVideoPlayback } from "./handler.mjs";

const ITEM = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const req = (b, h = {}) => new Request("https://x.test/f", { method: "POST", headers: { "Content-Type": "application/json", ...h }, body: JSON.stringify(b) });
const bunny = (status, extra = {}) => async () => new Response(JSON.stringify({ guid: VIDEO, videoLibraryId: 625830, status, length: 30, availableResolutions: status >= 3 ? "360p,720p" : "", thumbnailFileName: "thumbnail.jpg", ...extra }), { status: 200 });
function deps(o = {}) {
  return {
    env: { BUNNY_STREAM_LIBRARY_ID: "625830", BUNNY_STREAM_API_KEY: "k", BUNNY_STREAM_CDN_HOSTNAME: "vz-test.b-cdn.net", BUNNY_STREAM_TOKEN_KEY: "t" },
    anonKey: "anon", now: () => 1_900_000_000_000,
    verifyUser: async () => null,
    rpc: async () => ({ status: "granted", video_id: VIDEO }),
    fetchImpl: bunny(4),
    ...o,
  };
}

test("одобренный кейс — гость получает подписанную HLS-ссылку", async () => {
  const res = await handlePortfolioVideoPlayback(req({ item_id: ITEM }, { Authorization: "Bearer anon" }), deps());
  assert.equal(res.status, 200);
  const j = await res.json();
  assert.match(j.hls_url, /^https:\/\/vz-test\.b-cdn\.net\/bcdn_token=.+\/123e4567-e89b-42d3-a456-426614174000\/playlist\.m3u8$/);
  assert.match(j.mp4_url, /\/play_720p\.mp4$/);
});

test("пока Bunny кодирует — 202 processing", async () => {
  const res = await handlePortfolioVideoPlayback(req({ item_id: ITEM }), deps({ fetchImpl: bunny(2) }));
  assert.equal(res.status, 202);
});

test("нет доступа (не одобрен и не владелец) — 404", async () => {
  const res = await handlePortfolioVideoPlayback(req({ item_id: ITEM }), deps({ rpc: async () => ({ status: "not_found" }) }));
  assert.equal(res.status, 404);
});

test("плохой токен — 401, плохой id — 400", async () => {
  assert.equal((await handlePortfolioVideoPlayback(req({ item_id: ITEM }, { Authorization: "Bearer bad.jwt.x" }), deps())).status, 401);
  assert.equal((await handlePortfolioVideoPlayback(req({ item_id: "x" }), deps())).status, 400);
});
