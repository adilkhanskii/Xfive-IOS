import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const service = readFileSync(
  new URL("../../X5/Services/FruitStoryService.swift", import.meta.url),
  "utf8",
);
const view = readFileSync(
  new URL("../../X5/Views/Home/LiveFruitsView.swift", import.meta.url),
  "utf8",
);

test("Live Fruits prepares its generated first frame as exact 9:16 JPEG", () => {
  assert.match(service, /enum FruitStoryStartImagePreparer/);
  assert.match(service, /UIGraphicsImageRenderer/);
  assert.match(
    service,
    /targetPixelSize\s*=\s*CGSize\(\s*width:\s*720,\s*height:\s*1_280\s*\)/,
  );
  assert.match(
    view,
    /FruitStoryStartImagePreparer\.makeStartImage\(from:\s*frame\)/,
  );
  assert.doesNotMatch(view, /frame\.jpegData\(compressionQuality:/);
  assert.match(view, /aspectRatio:\s*"9:16"/);
  assert.match(view, /durationSeconds:\s*10/);
});

test("Live Fruits regenerates only the selected scene from the existing reference", () => {
  const regeneration = view.match(
    /private func regenerateFrame\(for scene: FruitStoryScene\) \{([\s\S]*?)\n    private func submitVideo/,
  );

  assert.ok(regeneration);
  assert.match(view, /@State private var regeneratingSceneID: String\?/);
  assert.match(view, /regenerateFrame\(for:\s*scene\.wrappedValue\)/);
  assert.match(
    regeneration[1],
    /guard\s+!isCreatingFrames,\s+regeneratingSceneID == nil/,
  );
  assert.match(regeneration[1], /characterReferenceBase64/);
  assert.match(regeneration[1], /referenceImages:\s*referenceImages/);
  assert.match(
    regeneration[1],
    /FruitStoryFrameRegeneration\.replacingFrame/,
  );
  assert.doesNotMatch(regeneration[1], /frameBase64BySceneID\s*=\s*\[:\]/);
  assert.doesNotMatch(regeneration[1], /characterReferenceBase64\s*=/);
  assert.doesNotMatch(regeneration[1], /scenes\s*=/);
});
