import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const migrationPath = new URL(
  "../migrations/20260728010000_hub_tasks_immediately_visible.sql",
  import.meta.url,
);
const hubServicePath = new URL("../../X5/Services/HubService.swift", import.meta.url);

test("new open Hub tasks are immediately visible to specialists", () => {
  assert.equal(
    existsSync(migrationPath),
    true,
    "missing migration that removes the one-hour task visibility gate",
  );

  const migration = readFileSync(migrationPath, "utf8");
  assert.match(
    migration,
    /alter column public_visible_at set default now\(\)/i,
  );
  assert.match(
    migration,
    /set public_visible_at = now\(\)[\s\S]*public_visible_at > now\(\)/i,
  );
  assert.match(
    migration,
    /create policy "tasks_select"[\s\S]*coalesce\(public_visible_at,\s*created_at,\s*now\(\)\)\s*<=\s*now\(\)/i,
  );
  assert.doesNotMatch(
    migration,
    /x5_user_has_active_verified_badge|interval\s*'1 hour'/i,
  );
});

test("the iOS create payload requests immediate visibility", () => {
  const source = readFileSync(hubServicePath, "utf8");

  assert.match(
    source,
    /"public_visible_at":\s*Self\.iso8601String\(from:\s*Date\(\)\)/,
  );
});
