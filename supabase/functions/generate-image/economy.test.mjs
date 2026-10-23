import test from "node:test";
import assert from "node:assert/strict";
import * as economyModule from "./economy.mjs";

import {
  buildFinalPrompt,
  generationCategories,
  generationModels,
  generationSizes,
  googleResponseFormat,
  IMAGE_CREDIT_COST,
  normalizeGenerationRequest,
  normalizeImages,
  normalizeQuantity,
  sanitizeProviderDiagnostic,
} from "./economy.mjs";

test("redacts provider credentials from server diagnostics", () => {
  const message = sanitizeProviderDiagnostic(
    "Consumer api_key:AIzaSyExampleSecretValue123456789 was suspended; " +
      "Bearer sensitive-token-value-123456789",
  );

  assert.equal(message.includes("AIzaSyExampleSecretValue"), false);
  assert.equal(message.includes("sensitive-token-value"), false);
  assert.match(message, /REDACTED_GOOGLE_API_KEY/);
  assert.match(message, /Bearer \[REDACTED\]/);
});

test("normalizes provider, category, prompt, and fixed credit cost", () => {
  const request = normalizeGenerationRequest({
    provider: "google",
    category: "logo",
    prompt: "  premium bakery mark  ",
  });

  assert.equal(request.provider, "gpt");
  assert.equal(request.model, "gpt-image-2");
  assert.equal(request.category.id, "logo");
  assert.equal(request.prompt, "premium bakery mark");
  assert.equal(request.costCredits, IMAGE_CREDIT_COST);
});

test("keeps only supported image model ids", () => {
  const gptImage2 = normalizeGenerationRequest({
    model: "gpt-image-2",
    category: "post",
    prompt: "make a premium post",
  });
  const nanoBanana2 = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "make a post",
  });
  const nanoBanana2Lite = normalizeGenerationRequest({
    model: "gemini-3.1-flash-lite-image",
    category: "post",
    prompt: "make a fast draft",
  });

  assert.equal(gptImage2.provider, "gpt");
  assert.equal(gptImage2.model, "gpt-image-2");
  assert.equal(nanoBanana2.provider, "google");
  assert.equal(nanoBanana2.model, "gemini-3.1-flash-image");
  assert.equal(nanoBanana2Lite.provider, "google");
  assert.equal(nanoBanana2Lite.model, "gemini-3.1-flash-lite-image");
});

test("rejects removed image models before credits are spent", () => {
  assert.throws(
    () =>
      normalizeGenerationRequest({
        model: "gpt-image-1.5",
        category: "post",
        prompt: "old model",
      }),
    /unsupported_model/,
  );
  assert.throws(
    () =>
      normalizeGenerationRequest({
        model: "gemini-3.1-flash-image-preview",
        category: "post",
        prompt: "old preview model",
      }),
    /unsupported_model/,
  );
});

test("rejects an unknown explicit category instead of silently changing it", () => {
  assert.throws(
    () =>
      normalizeGenerationRequest({
        provider: "unknown",
        category: "unknown",
        prompt: "launch creative",
      }),
    /unsupported_category/,
  );
});

test("normalizes quantity, size, and multiplied credit cost", () => {
  const request = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "make three vertical posts",
    quantity: 3,
    size: "portrait",
  });

  assert.equal(request.quantity, 3);
  assert.equal(request.costCredits, IMAGE_CREDIT_COST * 3);
  assert.equal(request.size.id, "portrait");
  assert.equal(request.size.openaiSize, "1024x1536");
  assert.equal(request.size.googleAspectRatio, "9:16");
});

test("clamps generation quantity to supported UI range", () => {
  assert.equal(normalizeQuantity(0), 1);
  assert.equal(normalizeQuantity(99), 4);
  assert.equal(normalizeQuantity("bad"), 1);
});

test("defines supported generation models", () => {
  assert.deepEqual(
    generationModels.map((model) => model.id),
    [
      "gpt-image-2",
      "gemini-3.1-flash-image",
      "gemini-3.1-flash-lite-image",
    ],
  );
});

test("downgrades Nano Banana 2 Lite image size to its supported 1K output", () => {
  const twoKSize = generationSizes.find((size) => size.id === "square_2k");

  assert.equal(
    googleResponseFormat(twoKSize, "gemini-3.1-flash-image").image_size,
    "2K",
  );
  assert.equal(
    googleResponseFormat(twoKSize, "gemini-3.1-flash-lite-image").image_size,
    "1K",
  );
});

test("requests the JPEG response format supported by current Nano Banana models", () => {
  assert.equal(
    googleResponseFormat(generationSizes[0], "gemini-3.1-flash-image")
      .mime_type,
    "image/jpeg",
  );
  assert.equal(
    googleResponseFormat(generationSizes[0], "gemini-3.1-flash-lite-image")
      .mime_type,
    "image/jpeg",
  );
});

test("defines supported generation sizes", () => {
  assert.deepEqual(
    generationSizes.map((size) => size.id),
    [
      "square",
      "portrait",
      "landscape",
      "vertical_2_3",
      "portrait_3_4",
      "portrait_4_5",
      "landscape_3_2",
      "landscape_4_3",
      "wide",
      "square_2k",
      "portrait_2k",
      "landscape_2k",
    ],
  );
});

test("rejects missing prompts", () => {
  assert.throws(
    () =>
      normalizeGenerationRequest({
        provider: "gpt",
        category: "post",
        prompt: "  ",
      }),
    /prompt_required/,
  );
});

test("allows image edit requests without a prompt", () => {
  const request = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "custom",
    prompt: "",
    images: [{ mimeType: "image/png", data: "abc123" }],
  });

  assert.equal(request.prompt, "Improve the provided image.");
  assert.equal(request.images.length, 1);
});

test("builds category-specific generation prompt", () => {
  const logo = generationCategories.find((category) => category.id === "logo");
  const finalPrompt = buildFinalPrompt("minimal coffee brand", logo);

  assert.match(finalPrompt, /logo/i);
  assert.match(finalPrompt, /minimal coffee brand/);
});

test("builds conservative edit prompt when images are attached", () => {
  const finalPrompt = buildFinalPrompt(
    "improve image",
    generationCategories[0],
    true,
  );

  assert.match(finalPrompt, /Preserve the original subject/i);
  assert.match(finalPrompt, /Do not invent unrelated objects/i);
  assert.match(finalPrompt, /text readability/i);
});

test("normalizes image references for edit requests", () => {
  const images = normalizeImages([
    { mimeType: "image/jpg", data: "data:image/jpeg;base64,abc123" },
    { mimeType: "text/plain", data: "bad" },
  ]);

  assert.deepEqual(images, [
    { mimeType: "image/jpeg", data: "abc123", role: "style_reference" },
  ]);
});

test("prefers the Gemini key and removes duplicate provider keys", () => {
  const keys = economyModule.normalizeProviderKeys?.([
    " new-gemini-key ",
    "old-google-key",
    "new-gemini-key",
    "",
  ]);

  assert.deepEqual(keys, ["new-gemini-key", "old-google-key"]);
});

test("rotates Google keys for authentication, quota, and transient failures", () => {
  const suspended = economyModule.shouldRetryGoogleWithNextKey?.({
    error: {
      code: 403,
      status: "PERMISSION_DENIED",
      message:
        "Permission denied: Consumer 'api_key:redacted' has been suspended.",
      details: [{ reason: "CONSUMER_SUSPENDED" }],
    },
  }, 403);
  const invalidPrompt = economyModule.shouldRetryGoogleWithNextKey?.({
    error: {
      code: 400,
      status: "INVALID_ARGUMENT",
      message: "Prompt is invalid.",
    },
  }, 400);

  assert.equal(suspended, true);
  assert.equal(economyModule.shouldRetryGoogleWithNextKey?.({}, 429), true);
  assert.equal(economyModule.shouldRetryGoogleWithNextKey?.({}, 503), true);
  assert.equal(invalidPrompt, false);
});

test("falls back from Google to GPT only for provider availability failures", () => {
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(400), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(401), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(403), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(404), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(408), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(409), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(422), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(429), true);
  assert.equal(economyModule.shouldFallbackGoogleToGPT?.(500), true);
});

test("derives a stable legacy identity from every semantic generation input", async () => {
  const request = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "A premium coffee ad",
    quantity: 2,
    size: "portrait",
    images: [{ mimeType: "image/png", data: "reference-image-one" }],
  });
  const sameRequest = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "A premium coffee ad",
    quantity: 2,
    size: "portrait",
    images: [{ mimeType: "image/png", data: "reference-image-one" }],
  });
  const changedReference = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "A premium coffee ad",
    quantity: 2,
    size: "portrait",
    images: [{ mimeType: "image/png", data: "reference-image-two" }],
  });

  const identity = await economyModule.buildGenerationIdentity?.(request, {});
  const repeated = await economyModule.buildGenerationIdentity?.(
    sameRequest,
    {},
  );
  const changed = await economyModule.buildGenerationIdentity?.(
    changedReference,
    {},
  );

  assert.equal(identity.isLegacy, true);
  assert.equal(identity.requestKey, repeated.requestKey);
  assert.equal(identity.fingerprint, repeated.fingerprint);
  assert.notEqual(identity.fingerprint, changed.fingerprint);
  assert.match(identity.requestKey, /^legacy:[a-f0-9]{64}$/);
  assert.doesNotMatch(
    JSON.stringify(identity),
    /premium coffee|reference-image/i,
  );
});

test("hashes explicit idempotency keys without storing the raw key", async () => {
  const request = normalizeGenerationRequest({
    model: "gpt-image-2",
    prompt: "A clean launch poster",
  });
  const identity = await economyModule.buildGenerationIdentity?.(request, {
    requestId: "client-request-018f9f2c",
  });

  assert.equal(identity.isLegacy, false);
  assert.match(identity.requestKey, /^explicit:[a-f0-9]{64}$/);
  assert.doesNotMatch(identity.requestKey, /client-request/);
});

test("rejects malformed explicit idempotency keys before provider work", async () => {
  const request = normalizeGenerationRequest({
    model: "gpt-image-2",
    prompt: "A clean launch poster",
  });

  await assert.rejects(
    economyModule.buildGenerationIdentity?.(request, {
      idempotencyKey: "x",
    }),
    /invalid_idempotency_key/,
  );
});

test("keeps replay manifests free of prompts and raw image bytes", () => {
  const manifest = economyModule.buildGenerationResultManifest?.({
    provider: "gpt",
    model: "gpt-image-2",
    fallbackFrom: "google",
    objects: [{
      path: "user/request/1/0.png",
      mimeType: "image/png",
      sha256: "a".repeat(64),
    }],
  });

  assert.deepEqual(manifest, {
    version: 1,
    provider: "gpt",
    model: "gpt-image-2",
    fallbackFrom: "google",
    objects: [{
      path: "user/request/1/0.png",
      mimeType: "image/png",
      sha256: "a".repeat(64),
    }],
  });
  assert.doesNotMatch(JSON.stringify(manifest), /prompt|base64|imageBase64/i);
});

test("detects only supported generated image formats before private storage", () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]).toString(
    "base64",
  );
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0]).toString("base64");
  const webp = Buffer.from("RIFF0000WEBP", "ascii").toString("base64");
  const unknown = Buffer.from("not-an-image", "ascii").toString("base64");

  assert.deepEqual(economyModule.detectGeneratedImageFormat?.(png), {
    mimeType: "image/png",
    extension: "png",
  });
  assert.deepEqual(economyModule.detectGeneratedImageFormat?.(jpeg), {
    mimeType: "image/jpeg",
    extension: "jpg",
  });
  assert.deepEqual(economyModule.detectGeneratedImageFormat?.(webp), {
    mimeType: "image/webp",
    extension: "webp",
  });
  assert.throws(
    () => economyModule.detectGeneratedImageFormat?.(unknown),
    /unsupported_generated_image_format/,
  );
});

test("keeps the legacy response shape while adding fresh private URLs", () => {
  const request = normalizeGenerationRequest({
    model: "gemini-3.1-flash-image",
    category: "post",
    prompt: "Coffee launch",
    quantity: 1,
    size: "square",
  });
  const response = economyModule.buildGenerationResponse?.({
    normalized: request,
    imageBase64s: ["encoded-image"],
    imageUrls: ["https://example.test/fresh-signed-url"],
    provider: "gpt",
    model: "gpt-image-2",
    fallbackFrom: "google",
    creditsRemaining: 940,
  });

  assert.equal(response.imageBase64, "encoded-image");
  assert.deepEqual(response.imageBase64s, ["encoded-image"]);
  assert.equal(response.imageUrl, "https://example.test/fresh-signed-url");
  assert.deepEqual(response.imageUrls, [
    "https://example.test/fresh-signed-url",
  ]);
  assert.equal(response.prompt, "Coffee launch");
  assert.equal(response.fallbackFrom, "google");
  assert.equal(response.creditsRemaining, 940);
});

test("keeps Google requests available when only the GPT fallback key exists", () => {
  assert.equal(
    economyModule.hasUsableGenerationProvider?.("google", 0, 1),
    true,
  );
  assert.equal(
    economyModule.hasUsableGenerationProvider?.("google", 0, 0),
    false,
  );
  assert.equal(
    economyModule.hasUsableGenerationProvider?.("gpt", 0, 1),
    false,
  );
});

test("extracts image data from the current Interactions API steps response", () => {
  const payload = {
    steps: [
      {
        type: "model_output",
        content: [
          { type: "text", text: "Done" },
          {
            type: "image",
            mime_type: "image/jpeg",
            data: "current-image-data",
          },
        ],
      },
    ],
  };

  assert.equal(
    economyModule.extractGoogleImageData?.(payload),
    "current-image-data",
  );
});

test("keeps legacy Google image response fallbacks", () => {
  assert.equal(
    economyModule.extractGoogleImageData?.({
      output_image: { data: "sdk-image-data" },
    }),
    "sdk-image-data",
  );
  assert.equal(
    economyModule.extractGoogleImageData?.({
      candidates: [{
        content: { parts: [{ inlineData: { data: "candidate-image-data" } }] },
      }],
    }),
    "candidate-image-data",
  );
});

test("never exposes provider API keys in user-facing errors", () => {
  const safeMessage = economyModule.safeProviderErrorMessage?.(
    "google",
    "Permission denied: Consumer 'api_key:AIzaSySecretValue' has been suspended.",
  );

  assert.equal(
    safeMessage,
    "Генерация временно недоступна. Кредиты возвращены. Повторите позже.",
  );
  assert.doesNotMatch(safeMessage || "", /AIza|api_key|consumer/i);
});

test("keeps deployed Google batch error parsing when syncing the function source", () => {
  const message = economyModule.extractGoogleErrorMessage?.([
    { error: { message: "Batch request was rejected" } },
  ], 400);

  assert.equal(message, "Batch request was rejected");
});

test("a structured brief is not truncated mid-instruction", () => {
  // A sales creative sends the angle, the composition rules and the roles of
  // the uploaded photo, logo and references. The old 900-character cap cut the
  // tail off as soon as the seller typed a long description, so the uploaded
  // pictures lost their meaning and every angle produced the same creative.
  const brief = [
    "Создай профессиональный рекламный баннер или карточку товара на русском языке.",
    "Главное требование — угол продаж: Через боль клиента.",
    "Товар или услуга: " + "детали предложения, цена и город. ".repeat(30),
    "Роли загруженных материалов: изображение 1 является основной фотографией; " +
    "изображение 2 является логотипом.",
  ].join("\n");

  assert.ok(brief.length > 900, "the regression case must exceed the old cap");
  const request = normalizeGenerationRequest({
    prompt: brief,
    category: "target_ad",
  });

  assert.ok(request.prompt.includes("угол продаж"));
  assert.ok(request.prompt.includes("изображение 2 является логотипом"));
  assert.equal(request.prompt.length, brief.length);
});

test("an absurd prompt is still capped", () => {
  const request = normalizeGenerationRequest({ prompt: "а".repeat(9000) });
  assert.equal(request.prompt.length, economyModule.MAX_PROMPT_CHARACTERS);
});
