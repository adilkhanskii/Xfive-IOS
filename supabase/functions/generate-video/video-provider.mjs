import { FalKlingProvider } from "./fal-provider.mjs";
import { GoogleGeminiVideoProvider } from "./google-provider.mjs";
import { OpenAIVideoProvider } from "./openai-provider.mjs";
import { BytePlusSeedanceProvider } from "./byteplus-provider.mjs";

const BYTEPLUS_MODELS = new Set([
  "seedance-1.5-pro",
  "seedance-2.0-fast",
]);

export function selectVideoProvider({
  model = "auto",
  bytePlusKey,
  falKey,
  googleKey,
  openAIKey,
  fetchImpl = fetch,
}) {
  if (BYTEPLUS_MODELS.has(model)) {
    if (!String(bytePlusKey || "").trim()) {
      throw new Error("provider_not_configured");
    }
    return {
      name: "byteplus",
      requestedModel: model,
      adapter: new BytePlusSeedanceProvider({
        apiKey: String(bytePlusKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (model !== "auto") {
    throw new Error("unsupported_model");
  }
  if (String(falKey || "").trim()) {
    return {
      name: "fal",
      requestedModel: model,
      adapter: new FalKlingProvider({
        apiKey: String(falKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (String(googleKey || "").trim()) {
    return {
      name: "google",
      requestedModel: model,
      adapter: new GoogleGeminiVideoProvider({
        apiKey: String(googleKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (String(openAIKey || "").trim()) {
    return {
      name: "openai",
      requestedModel: model,
      adapter: new OpenAIVideoProvider({
        apiKey: String(openAIKey).trim(),
        fetchImpl,
      }),
    };
  }
  throw new Error("provider_not_configured");
}

export function selectVideoProviderByName(
  providerName,
  {
    model = "auto",
    bytePlusKey,
    falKey,
    googleKey,
    openAIKey,
    fetchImpl = fetch,
  },
) {
  if (!["auto", ...BYTEPLUS_MODELS].includes(model)) {
    throw new Error("unsupported_model");
  }
  if (BYTEPLUS_MODELS.has(model) && providerName !== "byteplus") {
    throw new Error("provider_not_configured");
  }
  if (providerName === "byteplus" && String(bytePlusKey || "").trim()) {
    return {
      name: "byteplus",
      requestedModel: model,
      adapter: new BytePlusSeedanceProvider({
        apiKey: String(bytePlusKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (providerName === "fal" && String(falKey || "").trim()) {
    return {
      name: "fal",
      requestedModel: model,
      adapter: new FalKlingProvider({
        apiKey: String(falKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (providerName === "google" && String(googleKey || "").trim()) {
    return {
      name: "google",
      requestedModel: model,
      adapter: new GoogleGeminiVideoProvider({
        apiKey: String(googleKey).trim(),
        fetchImpl,
      }),
    };
  }
  if (providerName === "openai" && String(openAIKey || "").trim()) {
    return {
      name: "openai",
      requestedModel: model,
      adapter: new OpenAIVideoProvider({
        apiKey: String(openAIKey).trim(),
        fetchImpl,
      }),
    };
  }
  throw new Error("provider_not_configured");
}
