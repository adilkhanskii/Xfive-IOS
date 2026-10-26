import assert from "node:assert/strict";
import test from "node:test";

import { ElevenLabsVoicesClient } from "./elevenlabs-voices.mjs";

function client(handler) {
  const requests = [];
  const instance = new ElevenLabsVoicesClient({
    apiKey: "eleven-secret",
    fetchImpl: (url, options) => {
      requests.push({ url: String(url), options });
      return handler(String(url), options);
    },
  });
  return { instance, requests };
}

test("premade previews come from GET /v1/voices/{id} and are cached", async () => {
  const { instance, requests } = client(() =>
    Response.json({
      preview_url: "https://storage.googleapis.com/x/preview.mp3",
    })
  );
  const first = await instance.premadePreviews(["JBFqnCBsd6RMkjVDRZzb"]);
  await instance.premadePreviews(["JBFqnCBsd6RMkjVDRZzb"]);
  assert.equal(
    first.previews.JBFqnCBsd6RMkjVDRZzb,
    "https://storage.googleapis.com/x/preview.mp3",
  );
  assert.equal(requests.length, 1);
  assert.equal(
    requests[0].url,
    "https://api.elevenlabs.io/v1/voices/JBFqnCBsd6RMkjVDRZzb",
  );
  assert.equal(requests[0].options.headers["xi-api-key"], "eleven-secret");
});

test("a 401 on previews is reported as a rejected key", async () => {
  const { instance } = client(() => Response.json({}, { status: 401 }));
  const result = await instance.premadePreviews(["JBFqnCBsd6RMkjVDRZzb"]);
  assert.equal(result.keyRejected, true);
  assert.equal(result.previews.JBFqnCBsd6RMkjVDRZzb, null);
});

test("clone posts multipart files to /v1/voices/add", async () => {
  const { instance, requests } = client(() =>
    Response.json({ voice_id: "NewVoice1234", requires_verification: false })
  );
  const audio = new Blob([new Uint8Array(1024)], { type: "audio/mp4" });
  const result = await instance.clone({
    name: "Мой",
    audio,
    type: "audio/mp4",
  });
  assert.equal(result.voiceID, "NewVoice1234");
  assert.equal(requests[0].url, "https://api.elevenlabs.io/v1/voices/add");
  const form = requests[0].options.body;
  assert.ok(form instanceof FormData);
  assert.equal(form.get("name"), "Мой");
  assert.equal(form.get("files").name, "sample.m4a");
  assert.equal("Content-Type" in requests[0].options.headers, false);
});

test("design asks eleven_ttv_v3 for previews with Russian sample text", async () => {
  const { instance, requests } = client(() =>
    Response.json({
      text: "sample",
      previews: [
        {
          generated_voice_id: "gen_abc12345",
          audio_base_64: "SUQz",
          media_type: "audio/mpeg",
          duration_secs: 4,
        },
        { generated_voice_id: "bad id!", audio_base_64: "SUQz" },
      ],
    })
  );
  const result = await instance.design({
    description: "d".repeat(30),
    text: "т".repeat(120),
  });
  const url = new URL(requests[0].url);
  assert.equal(url.pathname, "/v1/text-to-voice/design");
  assert.equal(url.searchParams.get("output_format"), "mp3_44100_128");
  const body = JSON.parse(requests[0].options.body);
  assert.equal(body.model_id, "eleven_ttv_v3");
  assert.equal(body.text.length, 120);
  assert.equal(result.previews.length, 1);
});

test("saving a preview posts generated_voice_id to /v1/text-to-voice", async () => {
  const { instance, requests } = client(() =>
    Response.json({ voice_id: "Saved1234567" })
  );
  const result = await instance.createFromPreview({
    name: "Диктор",
    description: "d".repeat(30),
    generatedVoiceID: "gen_abc12345",
  });
  assert.equal(result.voiceID, "Saved1234567");
  assert.equal(requests[0].url, "https://api.elevenlabs.io/v1/text-to-voice");
  assert.equal(
    JSON.parse(requests[0].options.body).generated_voice_id,
    "gen_abc12345",
  );
});

test("delete treats 404 as already gone", async () => {
  const { instance, requests } = client(() =>
    new Response(null, { status: 404 })
  );
  assert.deepEqual(await instance.deleteVoice("Gone12345678"), {
    deleted: true,
  });
  assert.equal(requests[0].options.method, "DELETE");
});

test("refuses to start without a key", () => {
  assert.throws(() => new ElevenLabsVoicesClient({ apiKey: "" }));
});
