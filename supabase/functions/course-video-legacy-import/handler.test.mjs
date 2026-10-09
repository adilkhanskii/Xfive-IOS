// deno-lint-ignore-file require-await
// Без сети: Bunny, CDN, Storage и RPC — моки. Проверяем порядок шагов и то,
// что без явной команды ничего не меняется.
import assert from "node:assert/strict";
import test from "node:test";
import { handleCourseVideoLegacyImport } from "./handler.mjs";

const SECRET = "s".repeat(40);
const COURSE = "497f610e-8612-4b08-8f21-67f91ec93501";
const VIDEO = "123e4567-e89b-42d3-a456-426614174000";
const JOB = "99999999-9999-4999-8999-999999999999";
const BASE = "https://afwznqjpshybmqhlewmy.supabase.co";
const PATH = `courses/${COURSE}/lesson_A-abc.mp4`;
const SOURCE = `${BASE}/storage/v1/object/public/videos/${PATH}`;
const CDN = "vz-test.b-cdn.net";
const NOW = Date.parse("2026-10-09T12:00:00Z");

function req(body = {}, secret = SECRET) {
  return new Request(
    "https://x.test/functions/v1/course-video-legacy-import",
    {
      method: "POST",
      headers: {
        "X-X5-Reconcile-Secret": secret,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

const isSigned = (href) =>
  href.startsWith(`https://${CDN}/bcdn_token=`) && href.includes("expires=");

// bunnyStatus: статус видео у Bunny; cdnStatus: что отвечает CDN.
function world(
  { bunnyStatus = 4, cdnStatus = 200, archiveBytes = 1000 } = {},
) {
  return async (url, init = {}) => {
    const href = String(url);
    const method = init.method || "GET";
    if (href === SOURCE && method === "HEAD") {
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
    if (
      href.includes("video.bunnycdn.com") && href.includes(`/videos/${VIDEO}`)
    ) {
      return new Response(
        JSON.stringify({
          guid: VIDEO,
          videoLibraryId: 625830,
          status: bunnyStatus,
          encodeProgress: bunnyStatus === 4 ? 100 : 40,
          length: 600,
          thumbnailFileName: "thumbnail.jpg",
        }),
        { status: 200 },
      );
    }
    if (href.includes(CDN)) {
      // Токены ВКЛ: без подписи CDN отвечает 403.
      if (!isSigned(href) || cdnStatus !== 200) {
        return new Response("denied", {
          status: cdnStatus === 200 ? 403 : cdnStatus,
        });
      }
      if (href.endsWith(`/${VIDEO}/playlist.m3u8`)) {
        return new Response(
          "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720p/video.m3u8\n",
        );
      }
      if (href.endsWith(`/${VIDEO}/720p/video.m3u8`)) {
        return new Response("#EXTM3U\n#EXTINF:4,\nvideo0.ts\n");
      }
      if (href.endsWith(`/${VIDEO}/720p/video0.ts`)) {
        return new Response("x", { status: 206 });
      }
    }
    if (href === `${BASE}/storage/v1/object/copy`) {
      return new Response("{}", { status: 200 });
    }
    if (
      href ===
        `${BASE}/storage/v1/object/authenticated/course-video-originals/${PATH}` &&
      method === "HEAD"
    ) {
      return archiveBytes
        ? new Response(null, {
          status: 200,
          headers: { "content-length": String(archiveBytes) },
        })
        : new Response(null, { status: 404 });
    }
    if (
      href === `${BASE}/storage/v1/object/videos/${PATH}` && method === "DELETE"
    ) {
      return new Response("{}", { status: 200 });
    }
    return new Response("nope", { status: 404 });
  };
}

function deps({ job, jobs, rpcResults = {}, fetchImpl, env = {} } = {}) {
  const calls = { rpc: [], fetch: [] };
  const inner = fetchImpl || world();
  const d = {
    env: {
      COURSE_VIDEO_CRON_SECRET: SECRET,
      BUNNY_STREAM_LIBRARY_ID: "625830",
      BUNNY_STREAM_API_KEY: "api",
      BUNNY_STREAM_TOKEN_KEY: "token-key",
      BUNNY_STREAM_CDN_HOSTNAME: CDN,
      SUPABASE_URL: BASE,
      ...env,
    },
    now: () => NOW,
    serviceHeaders: () => ({ apikey: "svc" }),
    fetchImpl: async (url, init) => {
      calls.fetch.push({ url: String(url), method: init?.method || "GET" });
      return inner(url, init);
    },
    rpc: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name in rpcResults) {
        const value = rpcResults[name];
        return typeof value === "function" ? value(params) : value;
      }
      if (name === "course_video_legacy_import_enqueue") {
        return { enqueued: 0, retried: 0 };
      }
      if (name === "course_video_legacy_import_register") return "processing";
      if (name === "course_video_legacy_import_swap") return "swapped";
      if (name === "course_video_record_provider_status") {
        return { status: "recorded", asset_status: "ready" };
      }
      if (name === "course_video_legacy_import_can_remove") {
        return {
          ok: true,
          storage_path: PATH,
          bunny_video_id: VIDEO,
          source_bytes: 1000,
        };
      }
      if (name === "course_video_legacy_import_mark_removed") {
        return `original_${params.p_action}`;
      }
      return null;
    },
    rpcRows: async (name, params) => {
      calls.rpc.push({ name, params });
      if (name === "course_video_legacy_import_claim") return job ? [job] : [];
      if (name === "course_video_legacy_import_status") return jobs || [];
      if (name === "course_video_mirror_candidates") {
        return [{
          course_id: COURSE,
          lesson_id: "lesson_A",
          source_url: SOURCE,
        }];
      }
      return [];
    },
  };
  return { d, calls };
}

const baseJob = {
  id: JOB,
  course_id: COURSE,
  lesson_id: "lesson_A",
  source_url: SOURCE,
  storage_path: PATH,
  created_at: "2026-10-09T11:00:00Z",
};
const names = (calls) => calls.rpc.map((c) => c.name);
const sets = (calls) =>
  calls.rpc.filter((c) => c.name === "course_video_legacy_import_set")
    .map((c) => c.params);
const mutating = (calls) =>
  calls.fetch.filter((c) => c.method !== "GET" && c.method !== "HEAD");

test("без секрета — 403 и ни одного вызова", async () => {
  const { d, calls } = deps();
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }, "wrong"),
    d,
  );
  assert.equal(response.status, 403);
  assert.equal(calls.rpc.length + calls.fetch.length, 0);
});

test("без course_id ничего не делает", async () => {
  const { d, calls } = deps();
  const response = await handleCourseVideoLegacyImport(
    req({ action: "import" }),
    d,
  );
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error, "course_id_required");
  assert.equal(calls.rpc.length + calls.fetch.length, 0);
});

test("по умолчанию dry_run: только чтение", async () => {
  const { d, calls } = deps();
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE }),
    d,
  );
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.dry_run, true);
  assert.equal(payload.candidates.length, 1);
  assert.deepEqual(names(calls), [
    "course_video_mirror_candidates",
    "course_video_legacy_import_status",
  ]);
  assert.equal(calls.fetch.length, 0);
});

test("без ключа токенов не работает (проверяем только подписанную ссылку)", async () => {
  const { d, calls } = deps({ env: { BUNNY_STREAM_TOKEN_KEY: "" } });
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  assert.equal(response.status, 503);
  assert.equal(calls.rpc.length, 0);
});

test("неизвестное действие — 400", async () => {
  const { d } = deps();
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "nuke" }),
    d,
  );
  assert.equal(response.status, 400);
});

test("queued: Bunny тянет файл по URL, asset регистрируется", async () => {
  const { d, calls } = deps({ job: { ...baseJob, status: "queued" } });
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  const payload = await response.json();
  assert.equal(payload.results[0].status, "processing");
  const fetchCall = calls.fetch.find((c) => c.url.endsWith("/videos/fetch"));
  assert.ok(fetchCall);
  const register = calls.rpc.find((c) =>
    c.name === "course_video_legacy_import_register"
  );
  assert.deepEqual(register.params, {
    p_job_id: JOB,
    p_video_id: VIDEO,
    p_library_id: "625830",
    p_source_bytes: 1000,
  });
  // Урок на этом шаге не меняется.
  assert.ok(!names(calls).includes("course_video_legacy_import_swap"));
  const enqueue = calls.rpc.find((c) =>
    c.name === "course_video_legacy_import_enqueue"
  );
  assert.deepEqual(enqueue.params, {
    p_course_id: COURSE,
    p_retry_failed: false,
  });
});

test("queued: fetch без GUID -> fetching, затем поиск по названию", async () => {
  const noID = async (url, init) =>
    String(url).endsWith("/videos/fetch")
      ? new Response(JSON.stringify({ success: true }), { status: 200 })
      : world()(url, init);
  const first = deps({
    job: { ...baseJob, status: "queued" },
    fetchImpl: noID,
  });
  await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    first.d,
  );
  assert.equal(sets(first.calls)[0].p_status, "fetching");

  const search = async (url, init) => {
    if (String(url).includes("/videos?")) {
      return new Response(
        JSON.stringify({ items: [{ guid: VIDEO, title: `X5 legacy ${JOB}` }] }),
        { status: 200 },
      );
    }
    return world()(url, init);
  };
  const second = deps({
    job: {
      ...baseJob,
      status: "fetching",
      fetch_requested_at: "2026-10-09T11:59:00Z",
    },
    fetchImpl: search,
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    second.d,
  )).json();
  assert.equal(payload.results[0].status, "processing");
});

test("queued: открытый файл недоступен -> failed, Bunny не вызывается", async () => {
  const gone = async (url, init) =>
    String(url) === SOURCE
      ? new Response(null, { status: 404 })
      : world()(url, init);
  const { d, calls } = deps({
    job: { ...baseJob, status: "queued" },
    fetchImpl: gone,
  });
  await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  assert.equal(sets(calls)[0].p_status, "failed");
  assert.ok(!calls.fetch.some((c) => c.url.endsWith("/videos/fetch")));
});

test("processing: Bunny ещё кодирует -> ждём, урок не трогаем", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
    fetchImpl: world({ bunnyStatus: 3 }),
    rpcResults: {
      course_video_record_provider_status: {
        status: "recorded",
        asset_status: "processing",
      },
    },
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "processing");
  assert.equal(sets(calls)[0].p_status, "processing");
  assert.ok(!names(calls).includes("course_video_legacy_import_swap"));
});

test("processing: ready + подписанный HLS отвечает -> swap", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "swapped");
  const cdnCalls = calls.fetch.filter((c) => c.url.includes(CDN));
  assert.equal(cdnCalls.length, 3);
  assert.ok(cdnCalls.every((c) => isSigned(c.url)), "только подписанные");
  // Статус asset записан общим RPC до swap.
  const order = names(calls);
  assert.ok(
    order.indexOf("course_video_record_provider_status") <
      order.indexOf("course_video_legacy_import_swap"),
  );
  // Ни подписи, ни ключей в ответе.
  assert.ok(!JSON.stringify(payload).includes("bcdn_token"));
  assert.ok(!JSON.stringify(payload).includes("token-key"));
});

test("processing: CDN отвечает 403 -> swap не делаем", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
    fetchImpl: world({ cdnStatus: 403 }),
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "processing");
  assert.match(sets(calls)[0].p_error, /^verify: master 403/);
  assert.ok(!names(calls).includes("course_video_legacy_import_swap"));
});

test("processing: ошибка кодирования -> failed", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
    fetchImpl: world({ bunnyStatus: 5 }),
    rpcResults: {
      course_video_record_provider_status: {
        status: "recorded",
        asset_status: "failed",
      },
    },
  });
  await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  assert.equal(sets(calls)[0].p_status, "failed");
});

test("processing: видео удалили в Bunny -> ledger 6 и failed", async () => {
  const deleted = async (url, init) =>
    String(url).includes(`/videos/${VIDEO}`)
      ? new Response("{}", { status: 404 })
      : world()(url, init);
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
    fetchImpl: deleted,
  });
  await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  const recorded = calls.rpc.find((c) =>
    c.name === "course_video_record_provider_status"
  );
  assert.equal(recorded.params.p_provider_status, 6);
  assert.equal(sets(calls)[0].p_status, "failed");
});

test("сбой посреди шага не валит задачу", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
    rpcResults: {
      course_video_record_provider_status: () => {
        throw new Error("boom");
      },
    },
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "error");
  assert.equal(sets(calls)[0].p_status, "processing");
  assert.match(sets(calls)[0].p_error, /boom/);
});

test("import ничего не удаляет из Storage", async () => {
  const { d, calls } = deps({
    job: { ...baseJob, status: "processing", bunny_video_id: VIDEO },
  });
  await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "import" }),
    d,
  );
  assert.ok(
    !calls.fetch.some((c) =>
      c.url.includes("/storage/v1/object/") &&
      c.method === "DELETE"
    ),
  );
});

const swappedJob = {
  ...baseJob,
  status: "swapped",
  bunny_video_id: VIDEO,
  source_bytes: 1000,
};

test("remove_originals без confirm — 400, ничего не трогает", async () => {
  const { d, calls } = deps({ jobs: [swappedJob] });
  const response = await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", mode: "delete" }),
    d,
  );
  assert.equal(response.status, 400);
  assert.equal(calls.rpc.length + calls.fetch.length, 0);
});

test("remove_originals: SQL-проверка отказала -> Storage не трогаем", async () => {
  const { d, calls } = deps({
    jobs: [swappedJob],
    rpcResults: {
      course_video_legacy_import_can_remove: {
        ok: false,
        reason: "grace_period",
      },
    },
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", confirm: COURSE }),
    d,
  )).json();
  assert.equal(payload.results[0].reason, "grace_period");
  assert.equal(mutating(calls).length, 0);
});

test("remove_originals: Bunny не finished -> Storage не трогаем", async () => {
  const { d, calls } = deps({
    jobs: [swappedJob],
    fetchImpl: world({ bunnyStatus: 3 }),
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", confirm: COURSE }),
    d,
  )).json();
  assert.equal(payload.results[0].reason, "bunny_not_finished");
  assert.equal(mutating(calls).length, 0);
});

test("remove_originals archive: копия -> сверка -> удаление -> отметка", async () => {
  const { d, calls } = deps({
    jobs: [swappedJob, { ...baseJob, id: "other", status: "processing" }],
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", confirm: COURSE }),
    d,
  )).json();
  assert.equal(payload.mode, "archive");
  assert.equal(payload.processed, 1, "только swapped");
  assert.equal(payload.results[0].status, "original_archived");
  const storage = calls.fetch.filter((c) =>
    c.url.includes("/storage/v1/object/")
  )
    .map((c) => `${c.method} ${c.url.replace(BASE, "")}`);
  assert.deepEqual(storage, [
    "POST /storage/v1/object/copy",
    `HEAD /storage/v1/object/authenticated/course-video-originals/${PATH}`,
    `DELETE /storage/v1/object/videos/${PATH}`,
    `HEAD /storage/v1/object/public/videos/${PATH}`,
  ]);
  const mark = calls.rpc.find((c) =>
    c.name === "course_video_legacy_import_mark_removed"
  );
  assert.equal(mark.params.p_archive_path, `course-video-originals/${PATH}`);
});

test("remove_originals archive: копия не подтвердилась -> оригинал остаётся", async () => {
  const { d, calls } = deps({
    jobs: [swappedJob],
    fetchImpl: world({ archiveBytes: 0 }),
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", confirm: COURSE }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "archive_unverified");
  assert.ok(!calls.fetch.some((c) => c.method === "DELETE"));
  assert.ok(!names(calls).includes("course_video_legacy_import_mark_removed"));
});

test("remove_originals archive: размер копии не совпал -> оригинал остаётся", async () => {
  const { d, calls } = deps({
    jobs: [swappedJob],
    fetchImpl: world({ archiveBytes: 999 }),
  });
  const payload = await (await handleCourseVideoLegacyImport(
    req({ course_id: COURSE, action: "remove_originals", confirm: COURSE }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "archive_unverified");
  assert.ok(!calls.fetch.some((c) => c.method === "DELETE"));
});

test("remove_originals delete: без копии, сразу удаление", async () => {
  const { d, calls } = deps({ jobs: [swappedJob] });
  const payload = await (await handleCourseVideoLegacyImport(
    req({
      course_id: COURSE,
      action: "remove_originals",
      confirm: COURSE,
      mode: "delete",
      grace_minutes: 0,
    }),
    d,
  )).json();
  assert.equal(payload.results[0].status, "original_deleted");
  assert.ok(!calls.fetch.some((c) => c.url.endsWith("/object/copy")));
  const guard = calls.rpc.find((c) =>
    c.name === "course_video_legacy_import_can_remove"
  );
  assert.equal(guard.params.p_grace_minutes, 0);
});
