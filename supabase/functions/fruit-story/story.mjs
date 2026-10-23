export const FRUIT_STORY_LIMITS = Object.freeze({
  fruit: 80,
  field: 400,
  providerField: 1_200,
});

export class FruitStoryRequestError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "FruitStoryRequestError";
    this.code = code;
    this.status = status;
  }
}

export function shouldHoldFruitStoryOutcome({
  responsesDispatched,
  isProviderError,
  providerPhase,
  providerStatus,
}) {
  if (!responsesDispatched) return false;
  if (!isProviderError) return false;
  if (providerPhase !== "responses") return false;
  if (providerStatus === null) return true;
  if (providerStatus >= 200 && providerStatus < 300) return true;
  return providerStatus === 408 ||
    providerStatus === 409 ||
    providerStatus >= 500;
}

const questionnaireKeys = [
  "fruit",
  "personality",
  "goal",
  "location",
  "event",
  "ending",
];

const canonicalFruitAliases = Object.freeze([
  ["apple", ["apple", "apples", "яблоко", "яблоки", "яблока"]],
  ["apricot", ["apricot", "apricots", "абрикос", "абрикосы"]],
  ["avocado", ["avocado", "avocados", "авокадо"]],
  ["banana", ["banana", "bananas", "банан", "бананы", "банана"]],
  ["blackberry", ["blackberry", "blackberries", "ежевика", "ежевики"]],
  ["blueberry", ["blueberry", "blueberries", "голубика", "черника"]],
  ["cherry", ["cherry", "cherries", "вишня", "вишни", "черешня"]],
  ["coconut", ["coconut", "coconuts", "кокос", "кокосы"]],
  ["dragon-fruit", ["dragon fruit", "pitaya", "питайя", "драконий фрукт"]],
  ["durian", ["durian", "durians", "дуриан", "дурианы"]],
  ["fig", ["fig", "figs", "инжир"]],
  ["grape", ["grape", "grapes", "виноград", "виноградины"]],
  ["grapefruit", ["grapefruit", "grapefruits", "грейпфрут", "грейпфруты"]],
  ["guava", ["guava", "guavas", "гуава", "гуавы"]],
  ["kiwi", ["kiwi", "kiwifruit", "киви"]],
  ["lemon", ["lemon", "lemons", "лимон", "лимоны", "лимона"]],
  ["lime", ["lime", "limes", "лайм", "лаймы", "лайма"]],
  ["lychee", ["lychee", "litchi", "личи"]],
  ["mandarin", [
    "mandarin",
    "mandarins",
    "tangerine",
    "tangerines",
    "мандарин",
    "мандарины",
  ]],
  ["mango", ["mango", "mangos", "mangoes", "манго"]],
  ["melon", ["melon", "melons", "дыня", "дыни"]],
  ["orange", ["orange", "oranges", "апельсин", "апельсины", "апельсина"]],
  ["papaya", ["papaya", "papayas", "папайя", "папайи"]],
  ["passion-fruit", ["passion fruit", "maracuja", "маракуйя", "маракуйи"]],
  ["peach", ["peach", "peaches", "персик", "персики", "персика"]],
  ["pear", ["pear", "pears", "груша", "груши"]],
  ["persimmon", ["persimmon", "persimmons", "хурма", "хурмы"]],
  ["pineapple", ["pineapple", "pineapples", "ананас", "ананасы", "ананаса"]],
  ["plum", ["plum", "plums", "слива", "сливы"]],
  ["pomegranate", [
    "pomegranate",
    "pomegranates",
    "гранат",
    "гранаты",
    "граната",
  ]],
  ["raspberry", ["raspberry", "raspberries", "малина", "малины"]],
  ["rambutan", ["rambutan", "rambutans", "рамбутан", "рамбутаны"]],
  ["strawberry", ["strawberry", "strawberries", "клубника", "клубники"]],
  ["watermelon", ["watermelon", "watermelons", "арбуз", "арбузы", "арбуза"]],
]);

const fruitAliasToCanonical = new Map(
  canonicalFruitAliases.flatMap(([canonical, aliases]) =>
    aliases.map((alias) => [normalizeComparableText(alias), canonical])
  ),
);

export function normalizeFruitStoryRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new FruitStoryRequestError("invalid_request");
  }

  const result = {};
  for (const key of questionnaireKeys) {
    const value = boundedText(
      body[key],
      key === "fruit" ? FRUIT_STORY_LIMITS.fruit : FRUIT_STORY_LIMITS.field,
      `${key}_required`,
    );
    result[key] = value;
  }

  result.canonicalHeroFruit = canonicalHeroFruit(result.fruit);
  if (String(body.aspect_ratio || "").trim() !== "9:16") {
    throw new FruitStoryRequestError("invalid_aspect_ratio");
  }

  return { ...result, aspectRatio: "9:16" };
}

export function normalizeFruitStoryEdgeRequest(body) {
  const questionnaire = normalizeFruitStoryRequest(body);
  if (typeof body.request_id !== "string") {
    throw new FruitStoryRequestError("invalid_request_id");
  }
  const requestID = body.request_id.trim().toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(requestID)
  ) {
    throw new FruitStoryRequestError("invalid_request_id");
  }
  return { ...questionnaire, requestID };
}

export async function buildFruitStoryIdentity(questionnaire) {
  const canonical = JSON.stringify({
    fruit: questionnaire.fruit,
    personality: questionnaire.personality,
    goal: questionnaire.goal,
    location: questionnaire.location,
    event: questionnaire.event,
    ending: questionnaire.ending,
    aspect_ratio: questionnaire.aspectRatio,
  });
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return {
    requestID: questionnaire.requestID,
    fingerprint: Array.from(new Uint8Array(digest))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join(""),
  };
}

export function moderationInput(questionnaire) {
  return questionnaireKeys
    .map((key) => `${key}: ${questionnaire[key]}`)
    .join("\n");
}

export function buildFruitStoryJSONSchema(canonicalHeroFruit) {
  const expectedHero = normalizeComparableText(canonicalHeroFruit);
  if (!expectedHero) {
    throw new FruitStoryRequestError("single_fruit_required");
  }

  return {
    type: "object",
    additionalProperties: false,
    required: [
      "hero",
      "title",
      "summary",
      "character_bible",
      "final_video_prompt",
      "scenes",
    ],
    properties: {
      hero: {
        type: "object",
        additionalProperties: false,
        required: ["canonical_fruit", "character_count"],
        properties: {
          canonical_fruit: { type: "string", enum: [expectedHero] },
          character_count: { type: "integer", enum: [1] },
        },
      },
      title: { type: "string", minLength: 1, maxLength: 160 },
      summary: { type: "string", minLength: 1, maxLength: 500 },
      character_bible: { type: "string", minLength: 1, maxLength: 1_200 },
      final_video_prompt: { type: "string", minLength: 1, maxLength: 2_000 },
      scenes: {
        type: "array",
        minItems: 3,
        maxItems: 3,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["title", "visual_prompt", "action", "camera", "caption"],
          properties: {
            title: { type: "string", minLength: 1, maxLength: 120 },
            visual_prompt: { type: "string", minLength: 1, maxLength: 1_200 },
            action: { type: "string", minLength: 1, maxLength: 500 },
            camera: { type: "string", minLength: 1, maxLength: 300 },
            caption: { type: "string", minLength: 1, maxLength: 240 },
          },
        },
      },
    },
  };
}

export function buildFruitStoryResponsesRequest(questionnaire, model) {
  return {
    model,
    instructions: [
      "Ты создаёшь короткие рекламные раскадровки для Xfive marketing.",
      "Используй ровно один фрукт-персонаж и не добавляй другие фрукты.",
      "Сохраняй одну внешность, одежду и пропорции героя во всех трёх сценах.",
      "Верни ровно три последовательные сцены для вертикального формата 9:16.",
      "Пиши по-русски, конкретно и безопасно для широкой аудитории.",
    ].join(" "),
    input: [{
      role: "user",
      content: [
        `Фрукт: ${questionnaire.fruit}`,
        `Характер: ${questionnaire.personality}`,
        `Цель: ${questionnaire.goal}`,
        `Локация: ${questionnaire.location}`,
        `Событие: ${questionnaire.event}`,
        `Финал: ${questionnaire.ending}`,
        `Canonical hero fruit: ${questionnaire.canonicalHeroFruit}`,
        "Формат: 9:16.",
      ].join("\n"),
    }],
    text: {
      format: {
        type: "json_schema",
        name: "fruit_story",
        schema: buildFruitStoryJSONSchema(questionnaire.canonicalHeroFruit),
        strict: true,
      },
    },
    max_output_tokens: 2_400,
    store: false,
  };
}

export function extractStructuredStory(payload, canonicalHeroFruit) {
  const direct = typeof payload?.output_text === "string"
    ? payload.output_text.trim()
    : "";
  const output = Array.isArray(payload?.output) ? payload.output : [];
  const nested = output
    .flatMap((item) => Array.isArray(item?.content) ? item.content : [])
    .map((item) => typeof item?.text === "string" ? item.text.trim() : "")
    .find(Boolean);
  const raw = direct || nested;
  if (!raw) throw new FruitStoryRequestError("invalid_story", 502);

  try {
    return normalizeProviderStory(JSON.parse(raw), canonicalHeroFruit);
  } catch (error) {
    if (error instanceof FruitStoryRequestError) throw error;
    throw new FruitStoryRequestError("invalid_story", 502);
  }
}

export function normalizeProviderStory(value, canonicalHeroFruit) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new FruitStoryRequestError("invalid_story", 502);
  }
  if (!Array.isArray(value.scenes) || value.scenes.length !== 3) {
    throw new FruitStoryRequestError("invalid_story", 502);
  }
  const expectedHero = normalizeComparableText(canonicalHeroFruit);
  const providerHero = value.hero;
  if (
    !expectedHero ||
    !providerHero ||
    typeof providerHero !== "object" ||
    Array.isArray(providerHero) ||
    normalizeComparableText(providerHero.canonical_fruit) !== expectedHero ||
    providerHero.character_count !== 1
  ) {
    throw new FruitStoryRequestError("invalid_story", 502);
  }

  const story = {
    hero: {
      canonical_fruit: expectedHero,
      character_count: 1,
    },
    title: providerText(value.title),
    summary: providerText(value.summary),
    character_bible: providerText(value.character_bible),
    final_video_prompt: providerText(value.final_video_prompt, 2_000),
    scenes: value.scenes.map((scene, index) => {
      if (!scene || typeof scene !== "object" || Array.isArray(scene)) {
        throw new FruitStoryRequestError("invalid_story", 502);
      }
      return {
        id: `scene-${index + 1}`,
        title: providerText(scene.title),
        visual_prompt: providerText(scene.visual_prompt),
        action: providerText(scene.action),
        camera: providerText(scene.camera),
        caption: providerText(scene.caption),
      };
    }),
  };
  assertSingleProviderHero(story, expectedHero);
  return story;
}

function canonicalHeroFruit(value) {
  const comparable = normalizeComparableText(value);
  if (
    !comparable ||
    /[+,;\/\\&|\n]|\s(?:and|or|with|и|или|с)\s/iu.test(comparable)
  ) {
    throw new FruitStoryRequestError("single_fruit_required");
  }

  const mentioned = detectCanonicalFruits(comparable);
  if (mentioned.size > 1) {
    throw new FruitStoryRequestError("single_fruit_required");
  }
  const exactKnownFruit = fruitAliasToCanonical.get(comparable);
  if (exactKnownFruit) return exactKnownFruit;

  if (!/^[\p{L}\p{M}]+$/u.test(comparable)) {
    throw new FruitStoryRequestError("single_fruit_required");
  }
  return comparable;
}

function assertSingleProviderHero(story, expectedHero) {
  const heroTexts = [
    story.title,
    story.summary,
    story.character_bible,
    story.final_video_prompt,
    ...story.scenes.flatMap((scene) => [
      scene.title,
      scene.visual_prompt,
      scene.action,
      scene.caption,
    ]),
  ];
  if (heroTexts.some(hasMultipleCharacterLanguage)) {
    throw new FruitStoryRequestError("invalid_story", 502);
  }
}

function hasMultipleCharacterLanguage(value) {
  const comparable = normalizeComparableText(value)
    .replace(
      /\b(?:no|without)\s+(?:other|additional|extra|any)\s+(?:fruit\s+)?(?:heroes|characters)\b/giu,
      "",
    )
    .replace(
      /(?:^|[^\p{L}\p{M}])(?:без|нет)\s+(?:друг[\p{L}]*|дополнительн[\p{L}]*)?\s*(?:фрукт[\p{L}]*[- ]?)?(?:геро[\p{L}]*|персонаж[\p{L}]*)(?=$|[^\p{L}\p{M}])/giu,
      "",
    );
  const characterNoun =
    /(?:^|[^\p{L}\p{M}])(?:fruit|fruits|hero|heroes|character|characters|фрукт[\p{L}]*|геро[\p{L}]*|персонаж[\p{L}]*)(?=$|[^\p{L}\p{M}])/iu;

  if (
    /(?:^|[^\p{L}\p{M}])(?:two|three|four|several|multiple|many|два|две|три|четыре|несколько|много)[ \t]+(?:[\p{L}\p{M}-]+[ \t]+){0,1}(?:fruit|fruits|hero|heroes|character|characters|фрукт[\p{L}]*|геро[\p{L}]*|персонаж[\p{L}]*)(?=$|[^\p{L}\p{M}])/iu
      .test(comparable) ||
    /(?:^|[^\p{L}\p{M}])(?:heroes|characters|герои|персонажи)(?=$|[^\p{L}\p{M}])/iu
      .test(comparable)
  ) {
    return true;
  }

  const markerPattern =
    /(?:^|[^\p{L}\p{M}])(?:another|second|additional|extra|other|друг[\p{L}]*|втор[\p{L}]*|дополнительн[\p{L}]*|ещ[её]\s+один[\p{L}]*)(?=$|[^\p{L}\p{M}])/giu;
  for (const marker of comparable.matchAll(markerPattern)) {
    const followingWords = comparable
      .slice((marker.index || 0) + marker[0].length)
      .replace(/[^\p{L}\p{M}-]+/gu, " ")
      .trim()
      .split(/\s+/u)
      .slice(0, 2)
      .join(" ");
    if (
      characterNoun.test(followingWords) ||
      detectCanonicalFruits(followingWords).size > 0
    ) {
      return true;
    }
  }
  return false;
}

function detectCanonicalFruits(value) {
  const comparable = ` ${
    normalizeComparableText(value)
      .replace(/[^\p{L}\p{M}]+/gu, " ")
  } `;
  const result = new Set();
  for (const [canonical, aliases] of canonicalFruitAliases) {
    if (
      aliases.some((alias) =>
        comparable.includes(` ${normalizeComparableText(alias)} `)
      )
    ) {
      result.add(canonical);
    }
  }
  return result;
}

function normalizeComparableText(value) {
  return typeof value === "string"
    ? value.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase(
      "en-US",
    )
    : "";
}

function boundedText(value, maxLength, requiredCode) {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) throw new FruitStoryRequestError(requiredCode);
  if (text.length > maxLength) {
    throw new FruitStoryRequestError("field_too_long");
  }
  return text;
}

function providerText(value, maxLength = FRUIT_STORY_LIMITS.providerField) {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text || text.length > maxLength) {
    throw new FruitStoryRequestError("invalid_story", 502);
  }
  return text;
}
