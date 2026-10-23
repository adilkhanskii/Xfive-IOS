import assert from "node:assert/strict";
import test from "node:test";
import {
  buildFruitStoryResponsesRequest,
  normalizeFruitStoryRequest,
  normalizeProviderStory,
  shouldHoldFruitStoryOutcome,
} from "../story.mjs";

test("only ambiguous provider Responses outcomes are held", () => {
  assert.equal(
    shouldHoldFruitStoryOutcome({
      responsesDispatched: false,
      isProviderError: true,
      providerPhase: "moderation",
      providerStatus: null,
    }),
    false,
  );
  for (const providerStatus of [null, 200, 408, 409, 500, 503]) {
    assert.equal(
      shouldHoldFruitStoryOutcome({
        responsesDispatched: true,
        isProviderError: true,
        providerPhase: "responses",
        providerStatus,
      }),
      true,
    );
  }
  for (const providerStatus of [400, 401, 403, 404, 422, 429]) {
    assert.equal(
      shouldHoldFruitStoryOutcome({
        responsesDispatched: true,
        isProviderError: true,
        providerPhase: "responses",
        providerStatus,
      }),
      false,
    );
  }
  assert.equal(
    shouldHoldFruitStoryOutcome({
      responsesDispatched: true,
      isProviderError: false,
      providerPhase: null,
      providerStatus: null,
    }),
    false,
  );
});

test("only one fruit and 9:16 are accepted", () => {
  const questionnaire = normalizeFruitStoryRequest({
    fruit: "Манго",
    personality: "смелый",
    goal: "реклама",
    location: "кафе",
    event: "готовит лимонад",
    ending: "подмигивает",
    aspect_ratio: "9:16",
  });

  assert.equal(questionnaire.fruit, "Манго");
  assert.equal(questionnaire.aspectRatio, "9:16");
  assert.throws(
    () =>
      normalizeFruitStoryRequest({
        ...questionnaire,
        fruit: "манго и банан",
        aspect_ratio: "9:16",
      }),
    /single_fruit_required/,
  );
});

test("provider output and schema both require three scenes", () => {
  const scene = {
    title: "Сцена",
    visual_prompt: "Тот же герой",
    action: "Идёт",
    camera: "Общий план",
    caption: "Вперёд",
  };
  const story = normalizeProviderStory({
    hero: {
      canonical_fruit: "mango",
      character_count: 1,
    },
    title: "История",
    summary: "Короткая история",
    character_bible: "Один манго в синей бабочке",
    final_video_prompt: "Вертикальное видео",
    scenes: [scene, scene, scene],
  }, "mango");
  const request = buildFruitStoryResponsesRequest(
    {
      fruit: "Манго",
      personality: "смелый",
      goal: "реклама",
      location: "кафе",
      event: "готовит лимонад",
      ending: "подмигивает",
      aspectRatio: "9:16",
      canonicalHeroFruit: "mango",
    },
    "test-model",
  );

  assert.equal(story.scenes.length, 3);
  assert.equal(request.text.format.strict, true);
  assert.equal(request.text.format.schema.properties.scenes.maxItems, 3);
});

test("request has one canonical hero fruit and rejects ambiguous fruit lists", () => {
  const input = {
    fruit: "  MANGO  ",
    personality: "bold",
    goal: "promote a drink",
    location: "cafe",
    event: "mixes a lemonade",
    ending: "winks at the viewer",
    aspect_ratio: "9:16",
  };
  const questionnaire = normalizeFruitStoryRequest(input);

  assert.equal(questionnaire.fruit, "MANGO");
  assert.equal(questionnaire.canonicalHeroFruit, "mango");

  for (
    const fruit of [
      "mango + banana",
      "mango/banana",
      "mango, banana",
      "mango and banana",
      "манго и банан",
      "mango banana",
    ]
  ) {
    assert.throws(
      () => normalizeFruitStoryRequest({ ...input, fruit }),
      /single_fruit_required/,
      fruit,
    );
  }
});

test("strict schema binds the declared hero to the requested canonical fruit", () => {
  const questionnaire = normalizeFruitStoryRequest({
    fruit: "Mango",
    personality: "bold",
    goal: "promote a drink",
    location: "cafe",
    event: "mixes a lemonade",
    ending: "winks at the viewer",
    aspect_ratio: "9:16",
  });
  const request = buildFruitStoryResponsesRequest(questionnaire, "test-model");
  const schema = request.text.format.schema;
  const hero = schema.properties.hero;

  assert.ok(schema.required.includes("hero"));
  assert.equal(hero.additionalProperties, false);
  assert.deepEqual(hero.properties.canonical_fruit.enum, ["mango"]);
  assert.deepEqual(hero.properties.character_count.enum, [1]);
});

test("provider story must match the requested hero and contain no second fruit hero", () => {
  const scene = {
    title: "Scene",
    visual_prompt: "The same mango hero enters the cafe",
    action: "Walks",
    camera: "Wide shot",
    caption: "Forward",
  };
  const story = {
    hero: {
      canonical_fruit: "mango",
      character_count: 1,
    },
    title: "Mango story",
    summary: "One hero completes a short adventure.",
    character_bible: "One mango hero with round eyes and a blue bow tie.",
    final_video_prompt: "Vertical cinematic fruit story.",
    scenes: [scene, scene, scene],
  };

  assert.equal(
    normalizeProviderStory(story, "mango").hero.canonical_fruit,
    "mango",
  );
  assert.throws(
    () =>
      normalizeProviderStory({
        ...story,
        hero: { canonical_fruit: "banana", character_count: 1 },
      }, "mango"),
    /invalid_story/,
  );
  assert.throws(
    () =>
      normalizeProviderStory({
        ...story,
        hero: { canonical_fruit: "mango", character_count: 2 },
      }, "mango"),
    /invalid_story/,
  );
  assert.throws(
    () =>
      normalizeProviderStory({
        ...story,
        character_bible: "Mango and banana are two fruit heroes.",
      }, "mango"),
    /invalid_story/,
  );
  assert.throws(
    () =>
      normalizeProviderStory({
        ...story,
        character_bible: "A mango hero meets another mango hero.",
      }, "mango"),
    /invalid_story/,
  );
  assert.throws(
    () =>
      normalizeProviderStory({
        ...story,
        character_bible: "Герой-манго встречает другого героя-манго.",
      }, "mango"),
    /invalid_story/,
  );
});

test("a non-character fruit ingredient is not treated as a second hero", () => {
  const scene = {
    title: "Lemonade",
    visual_prompt: "The same mango hero squeezes lemons into a glass",
    action: "The mango mixes a fresh lemonade",
    camera: "Medium shot",
    caption: "Fresh lemonade",
  };

  const story = normalizeProviderStory({
    hero: {
      canonical_fruit: "mango",
      character_count: 1,
    },
    title: "Mango lemonade",
    summary: "One mango hero prepares lemonade for cafe guests.",
    character_bible: "The same bold mango hero in a blue apron.",
    final_video_prompt:
      "A vertical story where the mango squeezes lemons and serves lemonade.",
    scenes: [scene, scene, scene],
  }, "mango");

  assert.equal(story.hero.canonical_fruit, "mango");
  assert.equal(story.hero.character_count, 1);
  assert.equal(story.scenes.length, 3);
});

test("three scenes with the same single hero is not mistaken for three heroes", () => {
  const scene = {
    title: "Scene",
    visual_prompt: "The same mango hero continues the story",
    action: "Walks",
    camera: "Wide shot",
    caption: "Forward",
  };
  const story = normalizeProviderStory({
    hero: {
      canonical_fruit: "mango",
      character_count: 1,
    },
    title: "Mango story",
    summary: "Three scenes follow the same mango hero.",
    character_bible: "One mango hero with a blue bow tie.",
    final_video_prompt:
      "No other fruit characters appear. The same mango hero returns in another scene.",
    scenes: [scene, scene, scene],
  }, "mango");

  assert.equal(story.hero.character_count, 1);
});
