import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../migrations/20260801123000_private_portfolio_media.sql",
    import.meta.url,
  ),
  "utf8",
);
const edge = await readFile(
  new URL("../functions/moderate-portfolio/index.ts", import.meta.url),
  "utf8",
);

test("portfolio bucket is private and broad public read excludes it", () => {
  assert.match(
    migration,
    /update storage\.buckets[\s\S]*set public = false[\s\S]*id = 'portfolio'/i,
  );
  const broadRead = migration.split(
    'create policy "x5 storage public read"',
    2,
  )[1].split(";", 1)[0];
  assert.doesNotMatch(broadRead, /portfolio/i);
});

test("storage read is limited to owner or an approved row reference", () => {
  const selectPolicy = migration.split(
    'create policy "portfolio_media_owner_or_approved_select"',
    2,
  )[1].split(";", 1)[0];
  assert.match(selectPolicy, /auth\.uid/i);
  assert.match(selectPolicy, /x5_portfolio_object_is_approved\(name\)/i);
  const approval = functionBody("x5_portfolio_object_is_approved");
  assert.match(approval, /moderation_status = 'approved'/i);
  assert.match(approval, /object\/public\/portfolio/i);
});

test("portfolio uploads are immutable, owner-bound and path constrained", () => {
  const insertPolicy = migration.split(
    'create policy "x5 storage authenticated write"',
    2,
  )[1].split(";", 1)[0];
  assert.match(insertPolicy, /owner_id = \(select auth\.uid\(\)\)::text/i);
  assert.match(
    insertPolicy,
    /foldername\(name\)\)\[1\] = \(select auth\.uid\(\)\)::text/i,
  );
  assert.match(insertPolicy, /thumbnails/i);
  const updatePolicy = migration.split(
    'create policy "x5 storage authenticated update"',
    2,
  )[1].split(";", 1)[0];
  assert.doesNotMatch(updatePolicy, /portfolio/i);
});

test("rejected-only and stale orphan objects are cleaned through Storage API", () => {
  const cleanup = functionBody("x5_list_portfolio_cleanup_paths");
  assert.match(cleanup, /moderation_status <> 'rejected'/i);
  assert.match(cleanup, /moderation_status = 'rejected'/i);
  assert.match(cleanup, /interval '24 hours'/i);
  assert.match(edge, /x5_list_portfolio_cleanup_paths/i);
  assert.match(edge, /storage\.from\("portfolio"\)\.remove\(paths\)/i);
  assert.doesNotMatch(migration, /delete\s+from\s+storage\.objects/i);
});

test("private moderation input uses a short-lived signed URL", () => {
  assert.match(edge, /createSignedUrl\(path, 300\)/i);
  assert.match(edge, /storage\/v1\/object\/public\/portfolio/i);
  assert.match(edge, /storage\/v1\/object\/portfolio/i);
  assert.doesNotMatch(
    edge,
    /signedUrl[\s\S]{0,100}\.from\("portfolio_items"\)\.update/i,
  );
});

function functionBody(name) {
  const matches = [...migration.matchAll(
    new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "gi",
    ),
  )];
  assert.ok(matches.length > 0, `${name} missing`);
  return matches.at(-1)[0];
}
