import assert from "node:assert/strict";
import test from "node:test";
import {
  buildPolicyRequest,
  bunnyFrameCandidates,
  bunnyVideoIdFromMediaUrl,
  parsePolicyResponse,
  policyRejectReason,
} from "./policy.mjs";

const reply = (obj) => ({
  choices: [{ message: { content: JSON.stringify(obj) } }],
});

test("запрос проверки: текст + кадры видео, строгий JSON", () => {
  const body = buildPolicyRequest({
    text: "Кейс",
    imageUrls: ["https://a/1.jpg", "https://a/seek/_0.jpg"],
  });
  const content = body.messages[1].content;
  assert.equal(content.filter((c) => c.type === "image_url").length, 2);
  assert.equal(body.response_format.json_schema.strict, true);
  for (
    const word of [
      "наркотики",
      "оружия",
      "терроризм",
      "мошенничество",
      "порнография",
    ]
  ) {
    assert.ok(body.messages[0].content.includes(word), word);
  }
});

test("наркотики / оружие / мошенничество → отклонить с понятной причиной", () => {
  for (
    const [v, reason] of [
      ["drugs", "наркотики"],
      ["weapons", "оружие"],
      ["fraud", "мошенничество"],
      ["extremism", "экстремизм"],
      ["sexual", "сексуальный"],
    ]
  ) {
    const d = parsePolicyResponse(
      reply({ allowed: false, violations: [v], reason: "x" }),
    );
    assert.equal(d.ok, true);
    assert.equal(d.allowed, false);
    assert.ok(policyRejectReason(d.violations).includes(reason), v);
  }
});

test("«разрешено», но с нарушением — всё равно отклонить", () => {
  const d = parsePolicyResponse(
    reply({ allowed: true, violations: ["drugs"], reason: "" }),
  );
  assert.equal(d.allowed, false);
});

test("непонятный ответ модели — не одобрять", () => {
  assert.equal(
    parsePolicyResponse({ choices: [{ message: { content: "ok" } }] }).ok,
    false,
  );
  assert.equal(parsePolicyResponse({}).ok, false);
  assert.equal(parsePolicyResponse(reply({ allowed: "yes" })).ok, false);
});

test("чистый кейс — разрешено", () => {
  const d = parsePolicyResponse(
    reply({ allowed: true, violations: [], reason: "" }),
  );
  assert.deepEqual([d.ok, d.allowed], [true, true]);
});

test("видео из Bunny проверяется по кадрам ролика, а не только по обложке", () => {
  const frames = bunnyFrameCandidates();
  assert.ok(frames.includes("seek/_0.jpg"));
  assert.ok(frames.filter((f) => f.startsWith("thumbnail_")).length >= 5);
  assert.equal(
    bunnyVideoIdFromMediaUrl(
      "bunny-stream:092d3930-ef7e-412c-bacf-cba72fcf9fb8",
    ),
    "092d3930-ef7e-412c-bacf-cba72fcf9fb8",
  );
  assert.equal(bunnyVideoIdFromMediaUrl("https://evil/bunny-stream:x"), null);
});
