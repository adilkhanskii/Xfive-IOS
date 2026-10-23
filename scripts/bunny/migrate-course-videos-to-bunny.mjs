#!/usr/bin/env node
// Move existing course lesson videos from Supabase Storage bucket `videos`
// to Bunny Stream and point the lessons at the Bunny GUID.
//
// NOT EXECUTED. Dry-run is the default; nothing is written without --apply.
// Prerequisites: drafts/bunny-stream/20261001090000_course_video_assets.sql
// applied, playback function deployed, Bunny token authentication ON.
//
// Phases (see docs/BUNNY-STREAM-HANDOFF.md, "Migration"):
//   1. --apply                 copy file to Bunny, register asset, add
//                              bunnyVideoId to the lesson, KEEP videoUrl so
//                              old app builds still play the mp4.
//   2. --strip-legacy --apply  after every asset is `ready` and old builds are
//                              gone: remove videoUrl from those lessons.
//      --delete-storage        (with 2) also delete the Supabase objects.
//                              Irreversible — only after rollback window.
//   R. --rollback <manifest>   restore videoUrl, drop Bunny fields. Bunny
//                              videos become unreferenced and the reconciler
//                              deletes them after 7 days.
//
// Env (local shell only, never commit/print): SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY, BUNNY_STREAM_LIBRARY_ID, BUNNY_STREAM_API_KEY.
//
// Usage:
//   node scripts/bunny/migrate-course-videos-to-bunny.mjs [--course <uuid>]
//        [--limit N] [--apply] [--strip-legacy [--delete-storage]]
//        [--rollback <manifest.json>]

import { readFile, writeFile } from "node:fs/promises";

const args = parseArgs(process.argv.slice(2));
const APPLY = args.apply === true;
const env = {
  supabaseURL: requiredEnv("SUPABASE_URL").replace(/\/+$/, ""),
  serviceKey: requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
  libraryID: requiredEnv("BUNNY_STREAM_LIBRARY_ID"),
  bunnyKey: requiredEnv("BUNNY_STREAM_API_KEY"),
};
const STORAGE_PREFIX = `${env.supabaseURL}/storage/v1/object/public/videos/`;
const BUNNY_API = "https://video.bunnycdn.com";
const BUNNY_FIELDS = ["videoProvider", "bunnyVideoId", "videoStatus"];

const manifest = {
  created_at: new Date().toISOString(),
  mode: args.rollback
    ? "rollback"
    : args["strip-legacy"] ? "strip-legacy" : "copy",
  apply: APPLY,
  library_id: env.libraryID,
  entries: [],
};

try {
  if (args.rollback) {
    await rollback(String(args.rollback));
  } else if (args["strip-legacy"]) {
    await stripLegacy();
  } else {
    await copyToBunny();
  }
} finally {
  const file = `bunny-migration-${manifest.mode}-${
    manifest.created_at.replace(/[:.]/g, "-")
  }${APPLY ? "" : "-dry-run"}.json`;
  await writeFile(file, JSON.stringify(manifest, null, 2));
  console.log(`manifest: ${file} (${manifest.entries.length} entries)`);
  if (!APPLY) console.log("DRY RUN — nothing was changed. Re-run with --apply.");
}

// ---------------------------------------------------------------------------

async function copyToBunny() {
  const lessons = (await loadLessons()).filter((item) =>
    typeof item.lesson.videoUrl === "string" &&
    item.lesson.videoUrl.startsWith(STORAGE_PREFIX) &&
    !item.lesson.bunnyVideoId
  ).slice(0, limit());

  for (const item of lessons) {
    const entry = {
      course_id: item.courseID,
      lesson_id: item.lesson.id,
      legacy_video_url: item.lesson.videoUrl,
      storage_path: decodeURIComponent(
        item.lesson.videoUrl.slice(STORAGE_PREFIX.length),
      ),
      status: "planned",
    };
    manifest.entries.push(entry);

    const head = await fetch(item.lesson.videoUrl, { method: "HEAD" });
    entry.source_bytes = Number(head.headers.get("content-length")) || null;
    entry.source_content_type = head.headers.get("content-type");
    if (!head.ok) {
      entry.status = `skipped_source_${head.status}`;
      continue;
    }
    console.log(
      `${APPLY ? "COPY" : "would copy"} ${entry.course_id}/${entry.lesson_id} ` +
        `(${formatBytes(entry.source_bytes)})`,
    );
    if (!APPLY) continue;

    const created = await bunny(`/library/${env.libraryID}/videos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: `X5 lesson ${entry.course_id} ${entry.lesson_id} migration`,
      }),
    });
    entry.bunny_video_id = created?.guid;
    if (!entry.bunny_video_id) {
      entry.status = "failed_create";
      continue;
    }

    // Stream Supabase -> Bunny without buffering the whole file.
    const source = await fetch(item.lesson.videoUrl);
    if (!source.ok || !source.body) {
      entry.status = `failed_download_${source.status}`;
      continue;
    }
    const upload = await fetch(
      `${BUNNY_API}/library/${env.libraryID}/videos/${entry.bunny_video_id}`,
      {
        method: "PUT",
        headers: {
          AccessKey: env.bunnyKey,
          "Content-Type": "application/octet-stream",
        },
        body: source.body,
        duplex: "half",
      },
    );
    if (!upload.ok) {
      entry.status = `failed_upload_${upload.status}`;
      continue;
    }

    const registered = await rpc("course_video_register_migrated", {
      p_course_id: entry.course_id,
      p_lesson_id: entry.lesson_id,
      p_video_id: entry.bunny_video_id,
      p_library_id: env.libraryID,
      p_legacy_video_url: entry.legacy_video_url,
      p_source_bytes: entry.source_bytes,
    });
    if (registered?.status !== "registered") {
      entry.status = "failed_register";
      continue;
    }
    const attached = await rpc("course_video_attach_to_lesson", {
      p_course_id: entry.course_id,
      p_lesson_id: entry.lesson_id,
      p_video_id: entry.bunny_video_id,
      p_keep_legacy: true,
    });
    entry.status = attached?.status === "attached"
      ? "copied_keep_legacy"
      : `failed_attach_${attached?.status ?? "error"}`;
  }
}

async function stripLegacy() {
  const lessons = (await loadLessons()).filter((item) =>
    item.lesson.videoProvider === "bunny" &&
    typeof item.lesson.bunnyVideoId === "string" &&
    typeof item.lesson.videoUrl === "string" &&
    item.lesson.videoUrl.startsWith(STORAGE_PREFIX)
  ).slice(0, limit());

  for (const item of lessons) {
    const entry = {
      course_id: item.courseID,
      lesson_id: item.lesson.id,
      legacy_video_url: item.lesson.videoUrl,
      storage_path: decodeURIComponent(
        item.lesson.videoUrl.slice(STORAGE_PREFIX.length),
      ),
      bunny_video_id: item.lesson.bunnyVideoId,
      status: "planned",
    };
    manifest.entries.push(entry);

    const asset = await rest(
      `/rest/v1/course_video_assets?select=status,course_id,lesson_id&bunny_video_id=eq.${entry.bunny_video_id}`,
    );
    const row = Array.isArray(asset) ? asset[0] : null;
    if (
      row?.status !== "ready" || row.course_id !== entry.course_id ||
      row.lesson_id !== entry.lesson_id
    ) {
      entry.status = `skipped_asset_${row?.status ?? "missing"}`;
      continue;
    }
    console.log(
      `${APPLY ? "STRIP" : "would strip"} videoUrl ${entry.course_id}/${entry.lesson_id}` +
        (args["delete-storage"] ? " + delete storage object" : ""),
    );
    if (!APPLY) continue;

    const attached = await rpc("course_video_attach_to_lesson", {
      p_course_id: entry.course_id,
      p_lesson_id: entry.lesson_id,
      p_video_id: entry.bunny_video_id,
      p_keep_legacy: false,
    });
    if (attached?.status !== "attached") {
      entry.status = `failed_strip_${attached?.status ?? "error"}`;
      continue;
    }
    entry.status = "stripped";

    if (args["delete-storage"]) {
      const removed = await fetch(
        `${env.supabaseURL}/storage/v1/object/videos/${
          entry.storage_path.split("/").map(encodeURIComponent).join("/")
        }`,
        { method: "DELETE", headers: serviceHeaders() },
      );
      entry.status = removed.ok
        ? "stripped_storage_deleted"
        : `stripped_storage_delete_failed_${removed.status}`;
    }
  }
}

async function rollback(manifestPath) {
  const source = JSON.parse(await readFile(manifestPath, "utf8"));
  for (const original of source.entries || []) {
    if (!original.legacy_video_url || !original.course_id || !original.lesson_id) {
      continue;
    }
    const entry = { ...original, status: "planned" };
    manifest.entries.push(entry);
    console.log(
      `${APPLY ? "RESTORE" : "would restore"} ${entry.course_id}/${entry.lesson_id}`,
    );
    if (!APPLY) continue;

    const rows = await rest(
      `/rest/v1/courses?select=id,categories&id=eq.${entry.course_id}`,
    );
    const course = Array.isArray(rows) ? rows[0] : null;
    if (!course) {
      entry.status = "skipped_course_missing";
      continue;
    }
    let touched = 0;
    for (const category of arrayOf(course.categories)) {
      for (const day of arrayOf(category?.days)) {
        for (const lesson of arrayOf(day?.lessons)) {
          if (lesson?.id !== entry.lesson_id) continue;
          for (const key of BUNNY_FIELDS) delete lesson[key];
          lesson.videoUrl = entry.legacy_video_url;
          touched += 1;
        }
      }
    }
    if (touched !== 1) {
      entry.status = `skipped_lesson_matches_${touched}`;
      continue;
    }
    const patched = await fetch(
      `${env.supabaseURL}/rest/v1/courses?id=eq.${entry.course_id}`,
      {
        method: "PATCH",
        headers: {
          ...serviceHeaders(),
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({ categories: course.categories }),
      },
    );
    entry.status = patched.ok ? "restored" : `failed_restore_${patched.status}`;
  }
}

// ---------------------------------------------------------------------------

async function loadLessons() {
  const filter = args.course ? `&id=eq.${String(args.course)}` : "";
  const rows = await rest(`/rest/v1/courses?select=id,categories${filter}`);
  const result = [];
  for (const course of arrayOf(rows)) {
    for (const category of arrayOf(course.categories)) {
      for (const day of arrayOf(category?.days)) {
        for (const lesson of arrayOf(day?.lessons)) {
          if (lesson && typeof lesson.id === "string") {
            result.push({ courseID: course.id, lesson });
          }
        }
      }
    }
  }
  return result;
}

function serviceHeaders() {
  return { apikey: env.serviceKey, Authorization: `Bearer ${env.serviceKey}` };
}

async function rest(path) {
  const response = await fetch(`${env.supabaseURL}${path}`, {
    headers: serviceHeaders(),
  });
  if (!response.ok) throw new Error(`Supabase REST ${response.status} for ${path.split("?")[0]}`);
  return await response.json();
}

async function rpc(name, body) {
  const response = await fetch(`${env.supabaseURL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { ...serviceHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return response.ok ? await response.json().catch(() => null) : null;
}

async function bunny(path, init) {
  const response = await fetch(`${BUNNY_API}${path}`, {
    ...init,
    headers: { AccessKey: env.bunnyKey, Accept: "application/json", ...init.headers },
  });
  return response.ok ? await response.json().catch(() => null) : null;
}

function arrayOf(value) {
  return Array.isArray(value) ? value : [];
}

function limit() {
  const value = Number(args.limit);
  return Number.isInteger(value) && value > 0 ? value : Infinity;
}

function formatBytes(bytes) {
  return bytes ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : "size unknown";
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing env ${name}`);
    process.exit(2);
  }
  return value;
}

function parseArgs(list) {
  const parsed = {};
  for (let index = 0; index < list.length; index += 1) {
    const item = list[index];
    if (!item.startsWith("--")) continue;
    const key = item.slice(2);
    const next = list[index + 1];
    if (next !== undefined && !next.startsWith("--")) {
      parsed[key] = next;
      index += 1;
    } else {
      parsed[key] = true;
    }
  }
  return parsed;
}
