import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const helperUrl = new URL(
  "../functions/fruit-story/story.mjs",
  import.meta.url,
);
const edgeUrl = new URL("../functions/fruit-story/index.ts", import.meta.url);
const helperExists = existsSync(helperUrl);
const helper = helperExists ? await import(helperUrl) : null;
const edge = existsSync(edgeUrl) ? readFileSync(edgeUrl, "utf8") : "";
const migrationNames = readdirSync(
  new URL("../migrations/", import.meta.url),
).filter((name) => name.endsWith("_fruit_story_idempotency.sql"));
const migration = migrationNames.length === 1
  ? readFileSync(
    new URL(`../migrations/${migrationNames[0]}`, import.meta.url),
    "utf8",
  )
  : "";
const controlFlowTestUrl = new URL(
  "./20260725_fruit_story_rate_limit_test.sql",
  import.meta.url,
);

test("fruit story helper and edge function exist", () => {
  assert.equal(helperExists, true);
  assert.equal(existsSync(edgeUrl), true);
});

test("questionnaire accepts one bounded fruit and fixes the format to 9:16", () => {
  assert.ok(helper);
  const result = helper.normalizeFruitStoryRequest({
    fruit: "  Манго  ",
    personality: "дерзкий",
    goal: "реклама напитка",
    location: "летнее кафе",
    event: "герой смешивает лимонад",
    ending: "дружелюбно подмигивает",
    aspect_ratio: "9:16",
  });

  assert.equal(result.fruit, "Манго");
  assert.equal(result.aspectRatio, "9:16");
  assert.throws(
    () =>
      helper.normalizeFruitStoryRequest({
        fruit: "яблоко, банан",
        personality: "милый",
        goal: "история",
        location: "кухня",
        event: "танец",
        ending: "улыбка",
        aspect_ratio: "9:16",
      }),
    /single_fruit_required/,
  );
});

test("provider story is accepted only with exactly three complete scenes", () => {
  assert.ok(helper);
  const story = helper.normalizeProviderStory({
    hero: {
      canonical_fruit: "mango",
      character_count: 1,
    },
    title: "Манго открывает кафе",
    summary: "Три коротких шага героя.",
    character_bible: "Один манго с круглыми глазами и синей бабочкой.",
    final_video_prompt: "Vertical cinematic fruit story.",
    scenes: [1, 2, 3].map((index) => ({
      title: `Сцена ${index}`,
      visual_prompt: `Кадр ${index} с тем же манго`,
      action: `Действие ${index}`,
      camera: `Камера ${index}`,
      caption: `Текст ${index}`,
    })),
  }, "mango");

  assert.equal(story.scenes.length, 3);
  assert.deepEqual(story.scenes.map((scene) => scene.id), [
    "scene-1",
    "scene-2",
    "scene-3",
  ]);
  assert.throws(
    () =>
      helper.normalizeProviderStory(
        { ...story, scenes: story.scenes.slice(0, 2) },
        "mango",
      ),
    /invalid_story/,
  );
});

test("structured output schema fixes three scenes and forbids extra fields", () => {
  assert.ok(helper);
  const schema = helper.buildFruitStoryResponsesRequest(
    helper.normalizeFruitStoryRequest({
      fruit: "Mango",
      personality: "bold",
      goal: "advertise",
      location: "cafe",
      event: "walks in",
      ending: "waves",
      aspect_ratio: "9:16",
    }),
    "test-model",
  ).text.format.schema;

  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.scenes.minItems, 3);
  assert.equal(schema.properties.scenes.maxItems, 3);
  assert.equal(schema.properties.scenes.items.additionalProperties, false);
});

test("edge function authenticates, moderates, and uses Responses structured output", () => {
  assert.match(edge, /verifyUser/);
  assert.match(edge, /\/v1\/moderations/);
  assert.match(edge, /omni-moderation-latest/);
  assert.match(edge, /\/v1\/responses/);
  assert.match(edge, /json_schema/);
  assert.match(edge, /strict:\s*true/);
  assert.doesNotMatch(edge, /SUPABASE_SERVICE_ROLE_KEY/);
});

test("backend emits one canonical hero and rejects unseparated fruit names", () => {
  assert.ok(helper);
  const input = {
    fruit: "MANGO",
    personality: "bold",
    goal: "advertise",
    location: "cafe",
    event: "walks in",
    ending: "waves",
    aspect_ratio: "9:16",
  };
  const result = helper.normalizeFruitStoryRequest(input);

  assert.equal(result.canonicalHeroFruit, "mango");
  assert.throws(
    () =>
      helper.normalizeFruitStoryRequest({
        ...input,
        fruit: "mango banana",
      }),
    /single_fruit_required/,
  );
});

test("strict schema and provider validation bind the story to the requested hero", () => {
  assert.ok(helper);
  const questionnaire = helper.normalizeFruitStoryRequest({
    fruit: "Mango",
    personality: "bold",
    goal: "advertise",
    location: "cafe",
    event: "walks in",
    ending: "waves",
    aspect_ratio: "9:16",
  });
  const schema = helper.buildFruitStoryResponsesRequest(
    questionnaire,
    "test-model",
  ).text.format.schema;

  assert.ok(schema.required.includes("hero"));
  assert.deepEqual(
    schema.properties.hero.properties.canonical_fruit.enum,
    ["mango"],
  );
  assert.deepEqual(
    schema.properties.hero.properties.character_count.enum,
    [1],
  );

  const scene = {
    title: "Scene",
    visual_prompt: "The same mango hero enters the cafe",
    action: "Walks",
    camera: "Wide shot",
    caption: "Forward",
  };
  const story = {
    hero: { canonical_fruit: "mango", character_count: 1 },
    title: "Mango story",
    summary: "One hero completes a short story.",
    character_bible: "Mango and banana are two fruit heroes.",
    final_video_prompt: "Vertical cinematic fruit story.",
    scenes: [scene, scene, scene],
  };

  assert.throws(
    () => helper.normalizeProviderStory(story, "mango"),
    /invalid_story/,
  );

  assert.throws(
    () =>
      helper.normalizeProviderStory({
        ...story,
        character_bible: "A mango hero meets another mango hero.",
      }, "mango"),
    /invalid_story/,
  );
});

test("edge request requires a UUID and hashes only the normalized questionnaire", async () => {
  assert.ok(helper);
  const base = {
    request_id: "81111111-1111-4111-8111-111111111111",
    fruit: "Mango",
    personality: "bold",
    goal: "advertise",
    location: "cafe",
    event: "walks in",
    ending: "waves",
    aspect_ratio: "9:16",
  };
  const normalized = helper.normalizeFruitStoryEdgeRequest(base);
  const identity = await helper.buildFruitStoryIdentity(normalized);
  const secondIdentity = await helper.buildFruitStoryIdentity(
    helper.normalizeFruitStoryEdgeRequest({
      ...base,
      request_id: "82222222-2222-4222-8222-222222222222",
    }),
  );

  assert.equal(
    normalized.requestID,
    "81111111-1111-4111-8111-111111111111",
  );
  assert.match(identity.fingerprint, /^[0-9a-f]{64}$/);
  assert.equal(identity.fingerprint, secondIdentity.fingerprint);
  assert.throws(
    () =>
      helper.normalizeFruitStoryEdgeRequest({
        ...base,
        request_id: "not-a-uuid",
      }),
    /invalid_request_id/,
  );
  assert.throws(
    () =>
      helper.normalizeFruitStoryEdgeRequest({
        ...base,
        request_id: undefined,
      }),
    /invalid_request_id/,
  );
});

test("fruit story has one private authenticated idempotency ledger", () => {
  assert.equal(migrationNames.length, 1);
  assert.match(migration, /create table public\.fruit_story_requests/);
  assert.match(migration, /unique \(user_id, request_id\)/);
  assert.match(migration, /request_fingerprint ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(
    migration,
    /alter table public\.fruit_story_requests force row level security/,
  );
  assert.match(
    migration,
    /alter table public\.fruit_story_request_attempts force row level security/,
  );
  assert.match(
    migration,
    /revoke all on table public\.fruit_story_requests[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.match(
    migration,
    /revoke all on table public\.fruit_story_request_attempts[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.doesNotMatch(migration, /create policy[\s\S]*fruit_story_requests/i);
  assert.doesNotMatch(
    migration,
    /\b(fruit|personality|goal|location|event|ending|prompt)\b\s+(text|jsonb)/i,
    "the private ledger must not persist raw questionnaire fields",
  );
});

test("fruit story claims are user-owned, replayable, and rate limited", () => {
  assert.match(
    migration,
    /function public\.claim_fruit_story_request\(p_request_id uuid, p_request_fingerprint text\)/,
  );
  assert.match(migration, /security definer/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /count\(\*\)[\s\S]*>= 25/);
  assert.match(migration, /interval '3 seconds'/);
  assert.match(
    migration,
    /lease_expires_at = now\(\) \+ interval '75 seconds'/,
  );
  assert.match(migration, /'status', 'rate_limited'/);
  assert.match(migration, /'status', 'in_progress'/);
  assert.match(migration, /'status', 'replay'/);
  assert.match(migration, /'status', 'ambiguous'/);
  assert.match(migration, /'status', 'idempotency_conflict'/);
  assert.match(migration, /replay_until = now\(\) \+ interval '30 days'/);
  assert.doesNotMatch(migration, /'status', 'replay_expired'/);
  assert.match(
    migration,
    /request\.status = 'completed'[\s\S]*?'status', 'replay'/,
  );
  assert.match(
    migration,
    /request\.status = 'processing'[\s\S]*request\.lease_expires_at <= now\(\)[\s\S]*'ambiguous'/,
  );
});

test("fruit story RPCs retain attempts and reject stale lease owners", () => {
  const releaseFunction = migration.match(
    /create or replace function public\.release_fruit_story_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";
  const completeFunction = migration.match(
    /create or replace function public\.complete_fruit_story_request[\s\S]*?\$function\$;/,
  )?.[0] ?? "";

  assert.match(
    migration,
    /function public\.complete_fruit_story_request\(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid, p_story jsonb\)/,
  );
  assert.match(
    migration,
    /function public\.release_fruit_story_request\(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid\)/,
  );
  assert.match(
    migration,
    /function public\.hold_fruit_story_request\(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid\)/,
  );
  assert.match(
    completeFunction,
    /request\.lease_token <> p_lease_token[\s\S]*'status', 'lease_conflict'/,
  );
  assert.match(
    releaseFunction,
    /request\.lease_token <> p_lease_token[\s\S]*'status', 'lease_conflict'/,
  );
  assert.doesNotMatch(
    releaseFunction,
    /delete from public\.fruit_story_request_attempts/,
  );
  assert.match(
    migration,
    /grant execute on function public\.claim_fruit_story_request[\s\S]*to authenticated/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.(claim|complete|release|hold)_fruit_story_request[\s\S]*to service_role/,
  );
});

test("edge uses the authenticated ledger and a stable provider request key", () => {
  assert.match(edge, /normalizeFruitStoryEdgeRequest/);
  assert.match(edge, /buildFruitStoryIdentity/);
  assert.match(edge, /claim_fruit_story_request/);
  assert.match(edge, /complete_fruit_story_request/);
  assert.match(edge, /release_fruit_story_request/);
  assert.match(edge, /hold_fruit_story_request/);
  assert.match(edge, /status === "rate_limited"/);
  assert.match(edge, /status === "in_progress"/);
  assert.match(edge, /status === "replay"/);
  assert.match(edge, /"Retry-After"/);
  assert.match(edge, /"Idempotency-Key": providerIdempotencyKey/);
  assert.match(edge, /"X-Client-Request-Id": identity\.requestID/);
  assert.match(edge, /fruit-story\\0/);
  assert.doesNotMatch(edge, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.doesNotMatch(
    edge,
    /claim_generation_credits|deduct_credits|generation_credits/,
  );
});

test("ambiguous Responses outcomes are held while definitive failures release", () => {
  assert.match(edge, /let responsesDispatched = false/);
  assert.match(edge, /responsesDispatched = true/);
  assert.match(edge, /shouldHoldFruitStoryOutcome/);
  assert.match(edge, /await holdFruitStoryClaim\(/);
  assert.match(
    edge,
    /if \(ambiguousOutcome\)[\s\S]*?await holdFruitStoryClaim\([\s\S]*?else[\s\S]*?await releaseFruitStoryClaim\(/,
  );
  assert.doesNotMatch(
    edge,
    /\} catch \(error\) \{\s*await releaseFruitStoryClaim\(/,
  );
});

test("transactional SQL test exercises fruit story burst and daily limits", () => {
  assert.equal(existsSync(controlFlowTestUrl), true);
  const sqlTest = readFileSync(controlFlowTestUrl, "utf8");

  assert.match(sqlTest, /claim_fruit_story_request/);
  assert.match(sqlTest, /release_fruit_story_request/);
  assert.match(sqlTest, /active_lease_allowed_duplicate_provider_attempt/);
  assert.match(sqlTest, /expired_lease_was_reclaimed/);
  assert.match(sqlTest, /delayed_provider_result_was_not_recovered/);
  assert.match(sqlTest, /delayed_completion_was_not_replayed/);
  assert.match(sqlTest, /ambiguous_request_created_duplicate_attempt/);
  assert.match(sqlTest, /completed_replay_did_not_survive_cache_window/);
  assert.match(sqlTest, /retry_burst_limit_was_bypassed/);
  assert.match(sqlTest, /retry_daily_limit_was_bypassed/);
  assert.match(sqlTest, /fruit_story_attempt_ledger_is_directly_readable/);
  assert.match(sqlTest, /rollback;/);
});
