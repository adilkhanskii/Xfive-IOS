import assert from "node:assert/strict";
import test from "node:test";
import {
  createVoiceSleeper,
  sampleType,
  voiceSamplePath,
} from "./voice-sleep.mjs";

const USER = "11111111-2222-4333-8444-555555555555";

// Мини-база user_voices + фейковый ElevenLabs с ограничением мест.
function world({ slots = 2, voices = [] } = {}) {
  const rows = new Map(voices.map((v) => [v.id, { asleep: false, ...v }]));
  const provider = new Set(
    voices.filter((v) => !v.asleep).map((v) => v.live || v.id),
  );
  const stored = new Map();
  const calls = [];
  let n = 0;
  const live = (r) => (r.asleep ? null : r.live || r.id);
  const rpc = async (name, p) => {
    calls.push(name);
    const r = rows.get(p.p_provider_voice_id);
    switch (name) {
      case "user_voice_state":
        if (!r || p.p_user_id !== USER) return { owned: false };
        return {
          owned: true,
          id: r.id,
          name: r.name || "Мой",
          asleep: r.asleep,
          live_voice_id: live(r),
          sample_path: r.sample || null,
        };
      case "touch_user_voice":
        if (r) r.used = Infinity;
        return { status: "ok" };
      case "set_user_voice_sample":
        r.sample = p.p_sample_path;
        return { status: "ok" };
      case "user_voice_sleep_candidates":
        return {
          voices: [...rows.values()]
            .filter((x) => !x.asleep && x.id !== p.p_exclude && x.used !== Infinity)
            .sort((a, b) => (a.used || 0) - (b.used || 0))
            .map((x) => ({
              id: x.id,
              user_id: USER,
              live_voice_id: live(x),
              sample_path: x.sample || null,
            })),
        };
      case "mark_user_voice_asleep":
        if (!r || r.asleep || !r.sample || live(r) !== p.p_live_voice_id) {
          return { status: "skipped" };
        }
        r.asleep = true;
        r.live = null;
        return { status: "asleep" };
      case "mark_user_voice_awake":
        if (!r) return { status: "not_found" };
        if (!r.asleep) return { status: "already_awake", live_voice_id: live(r) };
        r.asleep = false;
        r.live = p.p_live_voice_id;
        return { status: "awake", live_voice_id: r.live };
      default:
        throw new Error(name);
    }
  };
  const client = {
    async clone() {
      if (provider.size >= slots) {
        const e = new Error("full");
        e.code = "elevenlabs_voice_slots_full";
        throw e;
      }
      n += 1;
      const id = `NewVoice${String(n).padStart(4, "0")}`;
      provider.add(id);
      return { voiceID: id };
    },
    async deleteVoice(id) {
      provider.delete(id);
      return { deleted: true };
    },
  };
  const storage = {
    async upload(path, bytes) {
      stored.set(path, bytes);
    },
    async download(path) {
      if (!stored.has(path)) throw new Error("missing");
      return stored.get(path);
    },
    async remove(path) {
      stored.delete(path);
    },
  };
  for (const v of voices) if (v.sample) stored.set(v.sample, new Uint8Array(40000));
  const captured = [];
  const sleeper = createVoiceSleeper({
    rpc,
    voices: client,
    storage,
    capture: async (id) => {
      captured.push(id);
      return new Uint8Array(40000);
    },
  });
  return { rows, provider, stored, calls, sleeper, captured, client, rpc };
}

test("awake voice: returns current id, no provider calls", async () => {
  const w = world({ voices: [{ id: "VoiceAAAA1", sample: `${USER}/VoiceAAAA1.m4a` }] });
  assert.equal(await w.sleeper.ensureAwake(USER, "VoiceAAAA1"), "VoiceAAAA1");
  assert.deepEqual([...w.provider], ["VoiceAAAA1"]);
});

test("foreign voice is refused", async () => {
  const w = world({ voices: [{ id: "VoiceAAAA1" }] });
  await assert.rejects(
    w.sleeper.ensureAwake("99999999-2222-4333-8444-555555555555", "VoiceAAAA1"),
    /voice_not_owned/,
  );
});

test("asleep voice wakes from its sample when there is room", async () => {
  const w = world({
    slots: 2,
    voices: [{ id: "VoiceAAAA1", asleep: true, sample: `${USER}/VoiceAAAA1.m4a` }],
  });
  const live = await w.sleeper.ensureAwake(USER, "VoiceAAAA1");
  assert.equal(live, "NewVoice0001");
  assert.equal(w.rows.get("VoiceAAAA1").asleep, false);
  assert.ok(w.provider.has("NewVoice0001"));
});

test("slots full: least recently used X5 voice sleeps, wanted one wakes", async () => {
  const w = world({
    slots: 2,
    voices: [
      { id: "VoiceOld01", used: 1, sample: `${USER}/VoiceOld01.mp3` },
      { id: "VoiceNew02", used: 5, sample: `${USER}/VoiceNew02.mp3` },
      { id: "VoiceWant3", asleep: true, sample: `${USER}/VoiceWant3.m4a` },
    ],
  });
  const live = await w.sleeper.ensureAwake(USER, "VoiceWant3");
  assert.equal(live, "NewVoice0001");
  assert.equal(w.rows.get("VoiceOld01").asleep, true, "oldest went to sleep");
  assert.equal(w.rows.get("VoiceNew02").asleep, false);
  assert.ok(!w.provider.has("VoiceOld01"));
  assert.equal(w.provider.size, 2);
});

test("old voice without a sample is recorded before it sleeps", async () => {
  const w = world({
    slots: 1,
    voices: [
      { id: "VoiceLegacy", used: 1 },
      { id: "VoiceWant3", asleep: true, sample: `${USER}/VoiceWant3.m4a` },
    ],
  });
  await w.sleeper.ensureAwake(USER, "VoiceWant3");
  assert.deepEqual(w.captured, ["VoiceLegacy"]);
  assert.equal(w.rows.get("VoiceLegacy").sample, `${USER}/VoiceLegacy.mp3`);
  assert.ok(w.stored.has(`${USER}/VoiceLegacy.mp3`));
  assert.equal(w.rows.get("VoiceLegacy").asleep, true);
  // и сам потом просыпается из этой записи
  w.rows.get("VoiceWant3").used = 0;
  assert.match(await w.sleeper.ensureAwake(USER, "VoiceLegacy"), /^NewVoice/);
});

test("nothing to evict: slots-full error goes up (caller refunds)", async () => {
  const w = world({
    slots: 1,
    voices: [{ id: "VoiceWant3", asleep: true, sample: `${USER}/VoiceWant3.m4a` }],
  });
  w.provider.add("ForeignAccountVoice");
  await assert.rejects(
    w.sleeper.ensureAwake(USER, "VoiceWant3"),
    (e) => e.code === "elevenlabs_voice_slots_full",
  );
  assert.ok(w.provider.has("ForeignAccountVoice"), "non-X5 voices untouched");
});

test("parallel wake: the extra clone is deleted, existing id is used", async () => {
  const w = world({
    slots: 5,
    voices: [{ id: "VoiceWant3", asleep: true, sample: `${USER}/VoiceWant3.m4a` }],
  });
  const original = w.client.clone.bind(w.client);
  w.client.clone = async (args) => {
    const made = await original(args);
    // пока мы клонировали, другой запрос уже разбудил голос
    const r = w.rows.get("VoiceWant3");
    if (r.asleep) {
      r.asleep = false;
      r.live = "OtherWake99";
      w.provider.add("OtherWake99");
    }
    return made;
  };
  assert.equal(await w.sleeper.ensureAwake(USER, "VoiceWant3"), "OtherWake99");
  assert.ok(!w.provider.has("NewVoice0001"));
});

test("provider refuses delete: voice is marked awake again", async () => {
  const w = world({
    slots: 1,
    voices: [
      { id: "VoiceOld01", used: 1, sample: `${USER}/VoiceOld01.mp3` },
      { id: "VoiceWant3", asleep: true, sample: `${USER}/VoiceWant3.m4a` },
    ],
  });
  w.client.deleteVoice = async () => {
    throw new Error("down");
  };
  await assert.rejects(w.sleeper.ensureAwake(USER, "VoiceWant3"));
  assert.equal(w.rows.get("VoiceOld01").asleep, false);
  assert.equal(w.rows.get("VoiceOld01").live, "VoiceOld01");
});

test("sample path and type helpers match the DB check", () => {
  const path = voiceSamplePath(USER, "VoiceAAAA1", "audio/x-m4a");
  assert.match(path, /^[0-9a-f-]{36}\/[A-Za-z0-9]{8,40}\.(mp3|m4a|wav|webm|ogg)$/);
  assert.equal(sampleType(path), "audio/mp4");
  assert.equal(sampleType(`${USER}/x.webm`), "audio/webm");
});
