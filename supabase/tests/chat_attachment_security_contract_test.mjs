import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../migrations/20260801122000_secure_chat_attachments.sql",
    import.meta.url,
  ),
  "utf8",
);
const sunset = await readFile(
  new URL(
    "../sunset/20260901000000_remove_legacy_chat_media_writes.sql",
    import.meta.url,
  ),
  "utf8",
);

test("chat-media bucket is private and broad public policies exclude it", () => {
  assert.match(
    migration,
    /update storage\.buckets[\s\S]*set public = false[\s\S]*id = 'chat-media'/i,
  );
  assert.match(migration, /file_size_limit = 47000000/i);
  assert.match(
    migration,
    /allowed_mime_types[\s\S]*audio\/webm[\s\S]*video\/mp4/i,
  );
  const publicPolicy = policyBody("x5 storage public read");
  assert.doesNotMatch(publicPolicy, /chat-media/i);
});

test("chat-media upload is canonical while reads retain legacy membership paths", () => {
  const selectPolicy = policyBody("chat_media_participant_select");
  const insertPolicy = policyBody("chat_media_participant_insert");
  assert.match(
    selectPolicy,
    /chat\.id::text = case[\s\S]*foldername\(name\)\)\[1\] = 'chats'[\s\S]*foldername\(name\)\)\[2\][\s\S]*else \(storage\.foldername\(name\)\)\[1\]/i,
  );
  for (const policy of [selectPolicy, insertPolicy]) {
    assert.match(
      policy,
      /auth\.uid\(\)\)\s*::text\s*=\s*any\(chat\.participants::text\[\]\)/i,
    );
  }
  assert.match(insertPolicy, /owner_id\s*=\s*\(select auth\.uid\(\)\)::text/i);
  assert.match(insertPolicy, /cardinality\(storage\.foldername\(name\)\) = 2/i);
  assert.match(
    insertPolicy,
    /foldername\(name\)\)\[2\] = \(select auth\.uid\(\)\)::text/i,
  );
  assert.match(
    insertPolicy,
    /chat\.id::text = \(storage\.foldername\(name\)\)\[1\]/i,
  );
  assert.doesNotMatch(
    insertPolicy,
    /when \(storage\.foldername\(name\)\)\[1\] = 'chats'/i,
  );
});

test("message attachment guard requires exact canonical sender paths", () => {
  const guard = functionBody("x5_validate_message_attachment");
  assert.match(guard, /external_chat_media_url_forbidden/i);
  assert.match(
    guard,
    /cardinality\(storage\.foldername\(v_object_name\)\) <> 2/i,
  );
  assert.match(
    guard,
    /foldername\(v_object_name\)\)\[1\] is distinct from new\.chat_id::text/i,
  );
  assert.match(
    guard,
    /foldername\(v_object_name\)\)\[2\] is distinct from new\.sender_id::text/i,
  );
  assert.match(guard, /storage\.filename\(v_object_name\).*\!~/i);
  assert.match(guard, /storage\.objects/i);
  assert.match(guard, /v_object_owner is distinct from new\.sender_id::text/i);
  assert.match(guard, /new\.media_mime := v_object_mime/i);
  assert.match(
    guard,
    /new\.type = 'video'[\s\S]*video\/mp4[\s\S]*video\/webm/i,
  );
  assert.match(guard, /new\.type = 'audio'[\s\S]*audio\/webm/i);
  assert.match(guard, /metadata ->> 'size'/i);
  assert.match(guard, /new\.type = 'image'[\s\S]*v_object_size > 12582912/i);
  assert.match(guard, /new\.type = 'audio'[\s\S]*v_object_size > 20971520/i);
  assert.match(guard, /new\.type = 'video'[\s\S]*v_object_size > 47000000/i);
});

test("legacy writes have a bounded owner/member compatibility window", () => {
  const guard = functionBody("x5_validate_message_attachment");
  assert.match(
    guard,
    /v_is_legacy_path\s*:=\s*v_object_name like 'chats\/' \|\| new\.chat_id::text \|\| '\/%'/i,
  );
  const policy = policyBody("chat_media_legacy_insert_until_2026_09_01");
  assert.match(
    policy,
    /clock_timestamp\(\) < timestamptz '2026-09-01 00:00:00\+00'/i,
  );
  assert.match(policy, /owner_id = \(select auth\.uid\(\)\)::text/i);
  assert.match(policy, /foldername\(name\)\)\[1\] = 'chats'/i);
  assert.match(
    policy,
    /auth\.uid\(\)\)\s*::text\s*=\s*any\(chat\.participants::text\[\]\)/i,
  );
  assert.match(guard, /legacy_chat_media_write_sunset/i);
  assert.match(guard, /v_object_owner is distinct from new\.sender_id::text/i);
  for (
    const field of ["chat_id", "sender_id", "type", "media_url", "media_mime"]
  ) {
    assert.match(
      guard,
      new RegExp(`new\\.${field} is distinct from old\\.${field}`, "i"),
    );
  }
  assert.match(guard, /return new;[\s\S]*end if;/i);
  assert.match(sunset, /legacy_chat_media_sunset_not_due/i);
  assert.match(
    sunset,
    /drop policy if exists "chat_media_legacy_insert_until_2026_09_01"/i,
  );
});

test("non-media messages cannot smuggle media fields", () => {
  const guard = functionBody("x5_validate_message_attachment");
  assert.match(
    guard,
    /new\.type in \('text', 'task_card'\)[\s\S]*text_message_media_forbidden/i,
  );
});

function policyBody(name) {
  const match = migration.match(
    new RegExp(
      `create\\s+policy\\s+"${name}"[\\s\\S]*?;`,
      "i",
    ),
  );
  assert.ok(match, `${name} policy missing`);
  return match[0];
}

function functionBody(name) {
  const match = migration.match(
    new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "i",
    ),
  );
  assert.ok(match, `${name} missing`);
  return match[0];
}
