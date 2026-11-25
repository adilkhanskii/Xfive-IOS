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
  }>;
};

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
