// «Голос спит»: своих голосов X5 сколько угодно, хотя у ElevenLabs на
// тарифе только 10 мест. Запись голоса лежит в X5 (bucket voice-samples),
// клон у ElevenLabs — только пока нужен. Нет места → усыпляем самый давно
// не использованный голос X5 (удаляем у провайдера), будим нужный из записи.
// Чужие голоса аккаунта ElevenLabs (не из X5) не трогаем никогда.

export const VOICE_SAMPLE_BUCKET = "voice-samples";
// Голос, которым озвучивали последние 5 минут, не усыпляем.
export const VOICE_IDLE_SECONDS = 300;
// Сколько голосов максимум усыпим ради одного места (защита от цикла).
const MAX_EVICTIONS = 3;
// Для старых голосов без записи: перед сном озвучиваем этот текст их же
// голосом и храним как запись (~30 с речи, один раз на голос).
export const SAMPLE_CAPTURE_TEXT = [
  "Здравствуйте! Это мой голос в приложении X5.",
  "Я записываю его, чтобы озвучивать рекламу, ролики и сторис для своего бизнеса.",
  "Говорю спокойно и чётко, с обычной интонацией, как в жизни.",
  "Сегодня расскажу о новых товарах, скидках и о том, как к нам удобно записаться.",
  "Спасибо, что слушаете, и до скорой встречи!",
].join(" ");
const CAPTURE_MODEL = "eleven_multilingual_v2";

export class VoiceSleepError extends Error {
  constructor(code) {
    super(code);
    this.name = "VoiceSleepError";
    this.code = code;
  }
}

/** Путь записи: <user_id>/<постоянный id>.<ext> (проверяет и CHECK в базе). */
export function voiceSamplePath(userID, voiceID, type) {
  return `${userID}/${voiceID}.${sampleExtension(type)}`;
}

export function sampleExtension(type) {
  const t = String(type || "").toLowerCase();
  if (t.includes("wav") || t === "audio/wave") return "wav";
  if (t.includes("webm")) return "webm";
  if (t.includes("ogg")) return "ogg";
  if (t.includes("mp4") || t.includes("m4a") || t.includes("aac")) return "m4a";
  return "mp3";
}

export function sampleType(path) {
  const ext = String(path || "").split(".").pop();
  return {
    wav: "audio/wav",
    webm: "audio/webm",
    ogg: "audio/ogg",
    m4a: "audio/mp4",
    mp3: "audio/mpeg",
  }[ext] || "audio/mpeg";
}

/** Хранилище записей через Storage REST с ключом service_role. */
export class VoiceSampleStorage {
  constructor({ supabaseURL, serviceRoleKey, fetchImpl = fetch }) {
    this.root = `${
      String(supabaseURL || "").replace(/\/+$/, "")
    }/storage/v1/object`;
    this.key = String(serviceRoleKey || "").trim();
    this.fetchImpl = fetchImpl;
  }

  #headers(extra = {}) {
    return { apikey: this.key, Authorization: `Bearer ${this.key}`, ...extra };
  }

  async upload(path, bytes, type) {
    const response = await this.fetchImpl(
      `${this.root}/${VOICE_SAMPLE_BUCKET}/${path}`,
      {
        method: "POST",
        headers: this.#headers({ "Content-Type": type, "x-upsert": "true" }),
        body: bytes,
      },
    );
    await response.body?.cancel().catch(() => null);
    if (!response.ok) throw new VoiceSleepError("sample_upload_failed");
  }

  async download(path) {
    const response = await this.fetchImpl(
      `${this.root}/authenticated/${VOICE_SAMPLE_BUCKET}/${path}`,
      { headers: this.#headers() },
    );
    if (!response.ok) {
      await response.body?.cancel().catch(() => null);
      throw new VoiceSleepError("sample_missing");
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  async remove(path) {
    const response = await this.fetchImpl(
      `${this.root}/${VOICE_SAMPLE_BUCKET}`,
      {
        method: "DELETE",
        headers: this.#headers({ "Content-Type": "application/json" }),
        body: JSON.stringify({ prefixes: [path] }),
      },
    );
    await response.body?.cancel().catch(() => null);
  }
}

/** Озвучка текста голосом — для записи старых голосов перед первым сном. */
export async function captureVoiceSample(
  { apiKey, voiceID, fetchImpl = fetch },
) {
  const url = new URL(
    `https://api.elevenlabs.io/v1/text-to-speech/${
      encodeURIComponent(voiceID)
    }`,
  );
  url.searchParams.set("output_format", "mp3_44100_128");
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      "xi-api-key": apiKey,
      "Content-Type": "application/json",
      Accept: "audio/mpeg",
    },
    body: JSON.stringify({
      text: SAMPLE_CAPTURE_TEXT,
      model_id: CAPTURE_MODEL,
    }),
    signal: AbortSignal.timeout(90_000),
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => null);
    throw new VoiceSleepError("sample_capture_failed");
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength < 32 * 1024) {
    throw new VoiceSleepError("sample_capture_short");
  }
  return bytes;
}

/**
 * deps: rpc(name, params), voices (ElevenLabsVoicesClient: clone/deleteVoice),
 * storage (upload/download/remove), capture(liveVoiceID) → mp3 bytes,
 * idleSeconds, log.
 */
export function createVoiceSleeper(deps) {
  const idle = deps.idleSeconds ?? VOICE_IDLE_SECONDS;
  const log = deps.log || (() => {});

  async function sleepVoice(candidate) {
    let samplePath = candidate.sample_path;
    if (!samplePath) {
      // Старый голос без записи: сначала сохраняем его звучание.
      try {
        const bytes = await deps.capture(candidate.live_voice_id);
        samplePath = voiceSamplePath(
          candidate.user_id,
          candidate.id,
          "audio/mpeg",
        );
        await deps.storage.upload(samplePath, bytes, "audio/mpeg");
        await deps.rpc("set_user_voice_sample", {
          p_provider_voice_id: candidate.id,
          p_sample_path: samplePath,
        });
      } catch (error) {
        log(
          "voice-sleep: capture failed",
          candidate.id,
          error?.code || error?.message,
        );
        return false;
      }
    }
    const marked = await deps.rpc("mark_user_voice_asleep", {
      p_provider_voice_id: candidate.id,
      p_live_voice_id: candidate.live_voice_id,
      p_idle_seconds: idle,
    }).catch(() => null);
    if (marked?.status !== "asleep") return false;
    try {
      await deps.voices.deleteVoice(candidate.live_voice_id);
      log("voice-sleep: asleep", candidate.id);
      return true;
    } catch {
      // Провайдер не удалил — голос жив, возвращаем как было.
      await deps.rpc("mark_user_voice_awake", {
        p_provider_voice_id: candidate.id,
        p_live_voice_id: candidate.live_voice_id,
      }).catch(() => null);
      return false;
    }
  }

  async function freeOneSlot(excludeID) {
    const result = await deps.rpc("user_voice_sleep_candidates", {
      p_exclude: excludeID || null,
      p_idle_seconds: idle,
    }).catch(() => null);
    for (const candidate of result?.voices || []) {
      if (await sleepVoice(candidate)) return true;
    }
    return false;
  }

  /** Создать голос у провайдера; мест нет — усыпить давно не использованный и повторить. */
  async function withRoom(create, excludeID) {
    for (let attempt = 0;; attempt += 1) {
      try {
        return await create();
      } catch (error) {
        if (
          error?.code !== "elevenlabs_voice_slots_full" ||
          attempt >= MAX_EVICTIONS
        ) {
          throw error;
        }
        if (!(await freeOneSlot(excludeID))) throw error;
      }
    }
  }

  /** Текущий id у ElevenLabs для озвучки; спит — будим из записи. */
  async function ensureAwake(userID, voiceID) {
    const state = await deps.rpc("user_voice_state", {
      p_user_id: userID,
      p_provider_voice_id: voiceID,
    });
    if (state?.owned !== true) throw new VoiceSleepError("voice_not_owned");
    await deps.rpc("touch_user_voice", { p_provider_voice_id: voiceID })
      .catch(() => null);
    if (state.asleep !== true && state.live_voice_id) {
      return state.live_voice_id;
    }

    const bytes = await deps.storage.download(state.sample_path);
    const type = sampleType(state.sample_path);
    const created = await withRoom(
      () =>
        deps.voices.clone({
          name: state.name,
          audio: new Blob([bytes], { type }),
          type,
        }),
      voiceID,
    );
    const marked = await deps.rpc("mark_user_voice_awake", {
      p_provider_voice_id: voiceID,
      p_live_voice_id: created.voiceID,
    }).catch(() => null);
    if (marked?.status === "awake") {
      log("voice-sleep: awake", voiceID);
      return created.voiceID;
    }
    // Параллельно уже разбудили — лишний клон убираем, берём их id.
    await deps.voices.deleteVoice(created.voiceID).catch(() => null);
    if (marked?.status === "already_awake" && marked.live_voice_id) {
      return marked.live_voice_id;
    }
    throw new VoiceSleepError("wake_failed");
  }

  return { ensureAwake, withRoom, freeOneSlot, sleepVoice };
}
