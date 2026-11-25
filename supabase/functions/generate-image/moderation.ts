// Второй слой фильтра после promptSafety: бесплатная модерация OpenAI ловит
// пересказы, которых нет в списке слов («Show the woman with nothing on» —
// рецензент Google Play 25.11). Сбой или таймаут модерации генерацию не
// блокирует: дальше всё равно стоит фильтр самого провайдера.

const MODERATION_URL = "https://api.openai.com/v1/moderations";
const BLOCK_CATEGORIES = ["sexual", "sexual/minors", "violence/graphic"];

type ModerationPayload = {
  results?: Array<{
    flagged?: boolean;
    categories?: Record<string, boolean>;
    category_scores?: Record<string, number>;
  }>;
};

// Третий слой — сама готовая картинка: пересказ можно придумать любой
// («Have the woman wear nothing but a necklace» прошёл и список, и модерацию
// текста — рецензент 25.11, Gemini), а рецензент смотрит на картинку.
// Обычная реклама в портфолио X5 (109 картинок): sexual ≤ 0.01, флагов нет.
const IMAGE_BLOCK_CATEGORIES = ["sexual", "violence/graphic"];

export async function isImageFlagged(
  images: Array<{ base64: string; mimeType: string }>,
  apiKey: string | undefined,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  if (!apiKey || images.length === 0) return false;
  const verdicts = await Promise.all(images.map(async (image) => {
    try {
      const response = await fetchImpl(MODERATION_URL, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: "omni-moderation-latest",
          input: [{
            type: "image_url",
            image_url: { url: `data:${image.mimeType};base64,${image.base64}` },
          }],
        }),
        signal: AbortSignal.timeout(10000),
      });
      if (!response.ok) {
        console.warn(JSON.stringify({
          event: "image_moderation_failed",
          status: response.status,
        }));
        return false;
      }
      const payload = await response.json() as ModerationPayload;
      const result = payload.results?.[0];
      const hits = IMAGE_BLOCK_CATEGORIES.filter((name) =>
        result?.categories?.[name] === true
      );
      console.log(JSON.stringify({
        event: "image_moderation",
        blocked: hits,
        sexual:
          Math.round(Number(result?.category_scores?.sexual || 0) * 1000) /
          1000,
      }));
      return hits.length > 0;
    } catch (error) {
      // сбой модерации генерацию не ломает — как у текста
      console.warn(JSON.stringify({
        event: "image_moderation_failed",
        reason: error instanceof Error ? error.name : "unknown",
      }));
      return false;
    }
  }));
  return verdicts.some(Boolean);
}

export async function isPromptFlagged(
  text: string | null | undefined,
  apiKey: string | undefined,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  // «Avoid: nudity» — это запрет, а не просьба (как в promptSafety).
  const input = String(text || "").split(/[.,]?\s*Avoid:/i)[0].trim();
  if (!input || !apiKey) return false;
  try {
    const response = await fetchImpl(MODERATION_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "omni-moderation-latest",
        input: input.slice(0, 4000),
      }),
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) {
      console.warn(JSON.stringify({
        event: "prompt_moderation_failed",
        status: response.status,
      }));
      return false;
    }
    const payload = await response.json() as ModerationPayload;
    const categories = payload.results?.[0]?.categories || {};
    const hits = BLOCK_CATEGORIES.filter((name) => categories[name] === true);
    console.log(JSON.stringify({
      event: "prompt_moderation",
      flagged: Boolean(payload.results?.[0]?.flagged),
      blocked: hits,
    }));
    return hits.length > 0;
  } catch (error) {
    console.warn(JSON.stringify({
      event: "prompt_moderation_failed",
      reason: error instanceof Error ? error.name : "unknown",
    }));
    return false;
  }
}
