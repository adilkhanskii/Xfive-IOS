import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../migrations/20260801115000_push_tokens_contract.sql",
    import.meta.url,
  ),
  "utf8",
);
const edge = await readFile(
  new URL("../functions/register-push-token/index.ts", import.meta.url),
  "utf8",
);
const iosPush = await readFile(
  new URL("../../X5/Services/PushNotifications.swift", import.meta.url),
  "utf8",
);

test("fresh environments get the canonical user/platform upsert key", () => {
  assert.match(migration, /create table if not exists public\.push_tokens/i);
  assert.match(
    migration,
    /constraint push_tokens_user_id_platform_key unique \(user_id, platform\)/i,
  );
  assert.match(
    migration,
    /group by user_id, platform[\s\S]*push_tokens_user_platform_duplicates/i,
  );
  assert.match(
    migration,
    /conkey = array\[v_user_id_attnum, v_platform_attnum\]::smallint\[\]/i,
  );
  assert.match(
    migration,
    /add constraint x5_push_tokens_user_platform_unique[\s\S]*unique \(user_id, platform\)/i,
  );
});

test("platform contract preserves legacy expo rows but rejects unknown labels", () => {
  assert.match(
    migration,
    /platform not in \('ios', 'android', 'web', 'expo'\)[\s\S]*push_tokens_unknown_platform/i,
  );
  assert.match(
    migration,
    /x5_push_tokens_platform_check[\s\S]*check \(platform in \('ios', 'android', 'web', 'expo'\)\)/i,
  );
});

test("authenticated clients can manage only their own token rows", () => {
  for (const action of ["select", "insert", "update", "delete"]) {
    const policy = policyBody(`x5_push_tokens_${action}_own`);
    assert.match(policy, /to authenticated/i);
    assert.match(policy, /auth\.uid\(\)\) = user_id/i);
  }
  assert.match(
    migration,
    /revoke all on table public\.push_tokens from public, anon, authenticated/i,
  );
  assert.match(
    migration,
    /grant select on table public\.push_tokens to authenticated/i,
  );
  assert.doesNotMatch(
    migration,
    /grant (?:insert|update|delete|select, insert)[^;]*on table public\.push_tokens to authenticated/i,
  );
  assert.doesNotMatch(migration, /create policy[\s\S]*to anon/i);
});

test("registration atomically reassigns a provider token between accounts", () => {
  assert.match(
    migration,
    /unique \(platform, token\)/i,
  );
  assert.match(
    migration,
    /partition by token_row\.platform, token_row\.token/i,
  );
  assert.match(migration, /duplicate_rank > 1/i);
  assert.match(
    migration,
    /token_row\.token = profile\.push_token[\s\S]*token_row\.user_id <> profile\.id/i,
  );
  assert.match(
    migration,
    /partition by profile\.push_token[\s\S]*duplicate_rank > 1/i,
  );
  assert.match(
    migration,
    /create unique index if not exists x5_profiles_push_token_unique[\s\S]*on public\.profiles \(push_token\)[\s\S]*where push_token is not null/i,
  );
  const register = functionBody("x5_register_push_token");
  assert.match(register, /x5_push_token_registry/i);
  assert.match(register, /push-token:' \|\| p_platform \|\| ':' \|\| p_token/i);
  assert.match(register, /push-user-platform:/i);
  assert.match(
    register,
    /delete from public\.push_tokens[\s\S]*platform = p_platform[\s\S]*token = p_token[\s\S]*user_id <> p_user_id/i,
  );
  assert.match(
    register,
    /profile\.id <> p_user_id[\s\S]*profile\.push_token = p_token/i,
  );
  assert.match(register, /on conflict \(user_id, platform\) do update/i);
  assert.match(
    migration,
    /grant execute on function public\.x5_register_push_token\(uuid, text, text\)[\s\S]*to service_role/i,
  );
  assert.match(edge, /admin\.rpc\("x5_register_push_token"/i);
  assert.doesNotMatch(edge, /\.from\("push_tokens"\)[\s\S]{0,120}\.upsert/i);
});

test("logout contract records exact tuple deletion", () => {
  assert.match(
    migration,
    /clients delete the exact user_id, platform, and token tuple/i,
  );
  const unregister = functionBody("x5_unregister_push_token");
  assert.match(unregister, /service_role_required/i);
  assert.match(unregister, /p_platform not in \('ios', 'android', 'web'\)/i);
  assert.match(
    unregister,
    /token_row\.user_id = p_user_id[\s\S]*token_row\.platform = p_platform[\s\S]*token_row\.token = p_token/i,
  );
  assert.match(
    unregister,
    /profile\.id = p_user_id[\s\S]*profile\.push_token = p_token/i,
  );
  assert.match(unregister, /pg_advisory_xact_lock/i);
  assert.match(
    migration,
    /grant execute on function public\.x5_unregister_push_token\(uuid, text, text\)[\s\S]*to service_role/i,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.x5_unregister_push_token[\s\S]*to authenticated/i,
  );
});

test("iOS token writes use only the canonical atomic Edge endpoint", () => {
  assert.match(iosPush, /functions\/v1\/register-push-token/i);
  assert.doesNotMatch(iosPush, /rest\/v1\/(?:profiles|push_tokens)/i);
  assert.doesNotMatch(
    iosPush,
    /upsertLegacyToken|deleteCanonicalTokenDirectly|clearProfileTokenDirectly/i,
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

function policyBody(name) {
  const match = migration.match(
    new RegExp(`create\\s+policy\\s+${name}[\\s\\S]*?;`, "i"),
  );
  assert.ok(match, `${name} policy missing`);
  return match[0];
}
