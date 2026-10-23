export const MODERATION_MODEL = "omni-moderation-latest";

/**
 * @typedef {{
 *   status: "pending" | "approved" | "rejected",
 *   reason: string,
 *   result: Record<string, unknown>,
 *   model: string | null,
 *   error: string | null,
 * }} ModerationDecision
 */

/**
 * A provider or preparation failure is not a moderation verdict. Keep the item
 * private and retryable until the automatic check can produce a real decision.
 *
 * @param {{
 *   code: string,
 *   error?: string | null,
 *   result?: Record<string, unknown>,
 *   model?: string | null,
 * }} options
 * @returns {ModerationDecision}
 */
export function automaticPendingDecision({
  code,
  error = null,
  result = {},
  model = MODERATION_MODEL,
}) {
  return {
    status: "pending",
    reason: "Автоматическая проверка ожидает повтора",
    result: {
      ...result,
      retryable: true,
      retry_reason: code,
    },
    model,
    error,
  };
}

/**
 * @param {any} result
 * @param {Record<string, unknown>} payload
 * @param {string | null} model
 * @returns {ModerationDecision}
 */
export function decisionFromModerationResult(
  result,
  payload,
  model = MODERATION_MODEL,
) {
  if (
    !result ||
    typeof result.flagged !== "boolean" ||
    !result.categories ||
    typeof result.categories !== "object"
  ) {
    return automaticPendingDecision({
      code: "moderation_response_invalid",
      error: "moderation_response_invalid",
      result: { reason: "moderation_response_invalid", payload },
      model,
    });
  }

  const flaggedCategories = Object.entries(result.categories)
    .filter(([, value]) => value === true)
    .map(([key]) => key);

  if (result.flagged || flaggedCategories.length > 0) {
    return {
      status: "rejected",
      reason: reasonFor(flaggedCategories),
      result: payload,
      model,
      error: null,
    };
  }

  return {
    status: "approved",
    reason: "Проверено автоматически",
    result: payload,
    model,
    error: null,
  };
}

/** @param {string[]} categories */
function reasonFor(categories) {
  if (categories.includes("sexual/minors")) {
    return "Материал отклонен: запрещенный сексуальный контент";
  }
  if (categories.some((category) => category.startsWith("sexual"))) {
    return "Материал отклонен: сексуальный контент";
  }
  if (categories.some((category) => category.startsWith("violence"))) {
    return "Материал отклонен: насилие";
  }
  if (categories.some((category) => category.startsWith("hate"))) {
    return "Материал отклонен: разжигание ненависти";
  }
  if (categories.some((category) => category.startsWith("self-harm"))) {
    return "Материал отклонен: самоповреждение";
  }
  if (categories.some((category) => category.startsWith("illicit"))) {
    return "Материал отклонен: запрещенная деятельность";
  }
  if (categories.some((category) => category.startsWith("harassment"))) {
    return "Материал отклонен: угрозы или травля";
  }
  return "Материал отклонен автоматической модерацией";
}
