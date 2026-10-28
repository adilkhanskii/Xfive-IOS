// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import { createVoiceStudioHandler } from "./handler.mjs";

const userID = "11111111-1111-4111-8111-111111111111";
const requestID = "22222222-2222-4222-8222-222222222222";

function setup(overrides = {}) {
  const calls = [];
  const client = {
    premadePreviews: async (ids) => {
      calls.push(["previews", ids.length]);
      return {
        previews: Object.fromEntries(
          ids.map((id) => [id, `https://storage.example/${id}.mp3`]),
        ),
        keyRejected: false,
      };
    },
    clone: async (parameters) => {
      calls.push(["clone", parameters.name, parameters.type]);
      return { voiceID: "CloneVoice123" };
    },
    design: async (parameters) => {
      calls.push(["design", parameters.description]);
      return {
        text: parameters.text,
        previews: [1, 2, 3].map((n) => ({
          generatedVoiceID: `generated_${n}_abcdef`,
          audioBase64: "SUQz",
          mediaType: "audio/mpeg",
          durationSecs: 5,
        })),
      };
    },
    createFromPreview: async (parameters) => {
      calls.push(["save", parameters.generatedVoiceID]);
      return { voiceID: "DesignVoice123" };
    },
    deleteVoice: async (id) => {
      calls.push(["provider-delete", id]);
      return { deleted: true };
    },
    ...(overrides.client || {}),
  };
  const deps = {
    verifyUser: async () => ({ id: userID }),
    voicesClient: () => client,
    cloneEnabled: () => true,
    quote: async () => ({
      status: "ok",
      credits: 1_000,
      voice_count: 0,
      voice_limit: 3,
    }),
    charge: async (parameters) => {
      calls.push(["charge", parameters.p_kind, parameters.p_cost_credits]);
      return { status: "charged", credits_remaining: 700 };
    },
    listVoices: async () => ({
      status: "ok",
      voices: [{ id: "Mine12345", name: "Мой", source: "clone" }],
    }),
    ownsVoice: async () => true,
    deleteVoiceRow: async (parameters) => {
      calls.push(["row-delete", parameters.p_provider_voice_id]);
      return { status: "deleted" };
    },
    ...overrides.deps,
  };
  return { calls, handler: createVoiceStudioHandler(deps) };
}

function jsonRequest(body) {
  return new Request("https://example.test/voice-studio", {
    method: "POST",
    headers: { Authorization: "Bearer t", "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function cloneRequest(
  { consent = "true", size = 64 * 1024, type = "audio/mp4" } = {},
) {
  const form = new FormData();
  form.set("action", "clone");
  form.set("request_id", requestID);
  form.set("name", "Мой голос");
  form.set("consent", consent);
  form.set("file", new Blob([new Uint8Array(size)], { type }), "voice.m4a");
  return new Request("https://example.test/voice-studio", {
    method: "POST",
    headers: { Authorization: "Bearer t" },
    body: form,
  });
}

test("catalog lists six premade voices with previews and my voices", async () => {
  const { handler } = setup();
  const response = await handler(jsonRequest({ action: "catalog" }));
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.premium_available, true);
  assert.equal(payload.premade.length, 6);
  assert.match(payload.premade[0].preview_url, /^https:\/\//);
  assert.deepEqual(payload.prices, {
    clone: 300,
    design: 50,
    save: 0,
    delete: 0,
  });
  assert.equal(payload.voice_limit, 3);
  assert.equal(payload.my_voices.length, 1);
});

test("catalog without key: premium off, cards without previews", async () => {
  const { handler } = setup({ deps: { voicesClient: () => null } });
  const payload = await (await handler(jsonRequest({ action: "catalog" })))
    .json();
  assert.equal(payload.premium_available, false);
  assert.ok(payload.premade.every((voice) => voice.preview_url === null));
});

test("catalog with a key without rights reports premium off", async () => {
  const { handler } = setup({
    client: {
      premadePreviews: async () => ({ previews: {}, keyRejected: true }),
    },
  });
  const payload = await (await handler(jsonRequest({ action: "catalog" })))
    .json();
  assert.equal(payload.premium_available, false);
});

test("clone charges 300 after the provider succeeds", async () => {
  const { handler, calls } = setup();
  const response = await handler(cloneRequest());
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.voice.id, "CloneVoice123");
  assert.equal(payload.cost_credits, 300);
  assert.deepEqual(calls.map(([name]) => name), ["clone", "charge"]);
  assert.deepEqual(calls[1], ["charge", "clone", 300]);
});

test("clone without consent never reaches the provider", async () => {
  const { handler, calls } = setup();
  const response = await handler(cloneRequest({ consent: "false" }));
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "consent_required");
  assert.deepEqual(calls, []);
});

test("clone rejects files over 10 MB and unsupported types", async () => {
  const big = setup();
  const tooLarge = await big.handler(
    cloneRequest({ size: 10 * 1024 * 1024 + 1 }),
  );
  assert.equal(tooLarge.status, 413);
  const wrong = setup();
  const badType = await wrong.handler(cloneRequest({ type: "video/mp4" }));
  assert.equal((await badType.json()).error.code, "invalid_audio_type");
  assert.deepEqual([...big.calls, ...wrong.calls], []);
});

test("clone with not enough credits fails before the provider, nothing charged", async () => {
  const { handler, calls } = setup({
    deps: {
      quote: async () => ({ status: "ok", credits: 100, voice_count: 0 }),
    },
  });
  const response = await handler(cloneRequest());
  const payload = await response.json();
  assert.equal(response.status, 402);
  assert.equal(payload.error.code, "insufficient_credits");
  assert.equal(payload.cost_credits, 300);
  assert.deepEqual(calls, []);
});

test("fourth own voice is refused before the provider", async () => {
  const { handler, calls } = setup({
    deps: {
      quote: async () => ({ status: "ok", credits: 5_000, voice_count: 3 }),
    },
  });
  const response = await handler(cloneRequest());
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "voice_limit");
  assert.deepEqual(calls, []);
});

test("a lost race at charge time deletes the provider voice", async () => {
  const { handler, calls } = setup({
    deps: {
      charge: async () => ({
        status: "insufficient_credits",
        credits_remaining: 10,
      }),
    },
  });
  const response = await handler(cloneRequest());
  assert.equal(response.status, 402);
  assert.deepEqual(calls.at(-1), ["provider-delete", "CloneVoice123"]);
});

test("design returns three previews and charges 50", async () => {
  const { handler, calls } = setup();
  const response = await handler(jsonRequest({
    action: "design",
    request_id: requestID,
    description: "Молодая женщина, тёплый спокойный голос, лёгкая улыбка",
  }));
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.previews.length, 3);
  assert.equal(payload.cost_credits, 50);
  assert.deepEqual(calls.at(-1), ["charge", "design", 50]);
});

test("saving a designed preview is free and goes to my voices", async () => {
  const { handler, calls } = setup();
  const response = await handler(jsonRequest({
    action: "save_design",
    request_id: requestID,
    name: "Диктор",
    description: "Молодая женщина, тёплый спокойный голос, лёгкая улыбка",
    generated_voice_id: "generated_1_abcdef",
  }));
  const payload = await response.json();
  assert.equal(response.status, 200);
  assert.equal(payload.voice.source, "design");
  assert.deepEqual(calls.at(-1), ["charge", "save", 0]);
});

test("delete removes the provider voice first, then the row, for free", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    jsonRequest({ action: "delete", voice_id: "Mine12345" }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    ["provider-delete", "Mine12345"],
    ["row-delete", "Mine12345"],
  ]);
});

test("delete of someone else's voice is not found", async () => {
  const { handler, calls } = setup({ deps: { ownsVoice: async () => false } });
  const response = await handler(
    jsonRequest({ action: "delete", voice_id: "Other12345" }),
  );
  assert.equal(response.status, 404);
  assert.deepEqual(calls, []);
});

test("without ELEVENLABS_API_KEY every paid action is premium_unavailable", async () => {
  const { handler } = setup({ deps: { voicesClient: () => null } });
  for (
    const request of [
      cloneRequest(),
      jsonRequest({
        action: "design",
        request_id: requestID,
        description: "x".repeat(30),
      }),
    ]
  ) {
    const response = await handler(request);
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error.code, "premium_unavailable");
  }
});

test("clone on a plan without cloning: clone_requires_plan before credits and provider", async () => {
  const { handler, calls } = setup({
    deps: {
      cloneEnabled: () => false,
      quote: async () => ({ status: "ok", credits: 0, voice_count: 0, voice_limit: 3 }),
    },
  });
  const response = await handler(cloneRequest());
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error.code, "clone_requires_plan");
  assert.deepEqual(calls, []);
  const catalog = await (await handler(jsonRequest({ action: "catalog" }))).json();
  assert.equal(catalog.premium_available, true);
  assert.equal(catalog.clone_available, false);
});

test("clone rejected by the provider plan maps to clone_requires_plan, nothing charged", async () => {
  const rejected = Object.assign(new Error("elevenlabs_rejected"), {
    name: "ElevenLabsVoicesError",
    keyRejected: true,
  });
  const { handler, calls } = setup({
    client: {
      clone: async () => {
        throw rejected;
      },
    },
  });
  const response = await handler(cloneRequest());
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error.code, "clone_requires_plan");
  assert.equal(calls.filter(([name]) => name === "charge").length, 0);
});

test("requires authentication", async () => {
  const { handler } = setup({ deps: { verifyUser: async () => null } });
  const response = await handler(jsonRequest({ action: "catalog" }));
  assert.equal(response.status, 401);
});
