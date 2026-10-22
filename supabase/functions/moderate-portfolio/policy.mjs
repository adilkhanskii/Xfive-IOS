// Вторая линия автопроверки портфолио (Диас 22.10, tg 8620/8621): OpenAI
// omni-moderation на КАРТИНКАХ ловит только 18+, насилие и самоповреждение.
// Наркотики (и их реклама/продажа), оружие, экстремизм, мошенничество на фото и
// кадрах видео он не видит — их проверяет модель с картинками по правилам ниже.
// Ошибка проверки = не одобряем (кейс остаётся скрытым и проверяется повторно).

export const POLICY_MODEL_DEFAULT = "gpt-4.1-mini";
export const POLICY_MAX_IMAGES = 8;

export const POLICY_VIOLATIONS = Object.freeze([
  "sexual",
  "drugs",
  "weapons",
  "extremism",
  "fraud",
  "violence",
  "hate",
  "other_illegal",
]);

const POLICY_PROMPT = [
  "Ты модератор публичного портфолио маркетологов (Казахстан, СНГ).",
  "Проверь текст и все картинки (это фото работ и кадры видео).",
  "Запрещено и должно быть отмечено:",
  "sexual — порнография, обнажёнка, секс-услуги, эскорт, интим-реклама;",
  "drugs — наркотики, их употребление, продажа, реклама, закладки, «соли», вейпы с наркотиками;",
  "weapons — продажа или реклама оружия, боеприпасов, взрывчатки;",
  "extremism — терроризм, экстремистская символика и призывы;",
  "fraud — мошенничество: пирамиды, «лёгкий заработок», обнал, продажа поддельных документов, карт, аккаунтов, схемы обмана;",
  "violence — жестокость, кровь, угрозы;",
  "hate — разжигание ненависти;",
  "other_illegal — иная явно незаконная деятельность.",
  "Обычная реклама бизнеса (салоны, еда, одежда, авто, недвижимость, кейсы таргета) — разрешена.",
  "Отвечай только JSON по схеме.",
].join("\n");

/** Тело запроса Chat Completions с картинками и строгим JSON-ответом. */
export function buildPolicyRequest({ text, imageUrls, model = POLICY_MODEL_DEFAULT }) {
  const content = [
    { type: "text", text: `Текст кейса:\n${text || "(нет текста)"}` },
    ...imageUrls.slice(0, POLICY_MAX_IMAGES).map((url) => ({
      type: "image_url",
      image_url: { url, detail: "low" },
    })),
  ];
  return {
    model,
    temperature: 0,
    messages: [
      { role: "system", content: POLICY_PROMPT },
      { role: "user", content },
    ],
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "portfolio_policy",
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: ["allowed", "violations", "reason"],
          properties: {
            allowed: { type: "boolean" },
            violations: {
              type: "array",
              items: { type: "string", enum: [...POLICY_VIOLATIONS] },
            },
            reason: { type: "string" },
          },
        },
      },
    },
  };
}

/** Разбор ответа модели. Непонятный ответ → { ok: false } (не одобряем). */
export function parsePolicyResponse(payload) {
  const raw = payload?.choices?.[0]?.message?.content;
  if (typeof raw !== "string") return { ok: false };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false };
  }
  if (typeof parsed?.allowed !== "boolean" || !Array.isArray(parsed?.violations)) {
    return { ok: false };
  }
  const violations = parsed.violations.filter((v) => POLICY_VIOLATIONS.includes(v));
  // Модель сказала «разрешено», но назвала нарушение — считаем нарушением.
  const allowed = parsed.allowed && violations.length === 0;
  return {
    ok: true,
    allowed,
    violations: allowed ? [] : (violations.length ? violations : ["other_illegal"]),
    reason: typeof parsed.reason === "string" ? parsed.reason.slice(0, 300) : "",
  };
}

export function policyRejectReason(violations) {
  const map = {
    sexual: "Материал отклонен: сексуальный контент",
    drugs: "Материал отклонен: наркотики",
    weapons: "Материал отклонен: оружие",
    extremism: "Материал отклонен: экстремизм",
    fraud: "Материал отклонен: мошенничество",
    violence: "Материал отклонен: насилие",
    hate: "Материал отклонен: разжигание ненависти",
    other_illegal: "Материал отклонен: запрещенная деятельность",
  };
  for (const key of POLICY_VIOLATIONS) {
    if (violations.includes(key)) return map[key];
  }
  return "Материал отклонен автоматической модерацией";
}

// --- Видео из Bunny: какие кадры проверять --------------------------------
// Bunny после кодирования кладёт рядом с роликом: thumbnail_1..5.jpg (кадры по
// всей длине) и seek/_0.jpg, _1.jpg … (листы раскадровки — десятки кадров).
// Проверено 22.10 на тестовом ролике.
export const BUNNY_STATUS_FINISHED = 4;
export const BUNNY_FAILED_STATUSES = Object.freeze([5, 6]);

export function bunnyFrameCandidates() {
  return [
    "seek/_0.jpg",
    "seek/_1.jpg",
    "seek/_2.jpg",
    "thumbnail_1.jpg",
    "thumbnail_2.jpg",
    "thumbnail_3.jpg",
    "thumbnail_4.jpg",
    "thumbnail_5.jpg",
  ];
}

export function bunnyVideoIdFromMediaUrl(value) {
  const match = /^bunny-stream:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/
    .exec(String(value || "").trim());
  return match ? match[1] : null;
}
