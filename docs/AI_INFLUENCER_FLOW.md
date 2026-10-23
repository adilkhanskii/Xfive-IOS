# AI Influencer — release-safe product flow

## Current release status

AI Influencer is **in development** for every account, including developer
accounts. Opening it must show the release gate only. It must not call a model,
reserve credits, deduct credits, upload a reference, or display a fake success.

## Required production flow

The feature is a four-stage wizard. A later stage cannot start until the user
accepts the result of the previous stage.

### 1. Character questionnaire

1. Character type: human, creature, or hybrid.
2. Identity: name, gender, age, origin or ethnicity.
3. Face: shape, eyes and eye colour, nose, mouth, ears or horns.
4. Body: build, height, proportions and optional non-human traits.
5. Skin: tone or material, texture, freckles, scars and other distinguishing
   details.
6. Style: hair, clothes, accessories and visual direction.
7. Optional free-text detail for attributes not covered by controls.

### 2. Character image

1. Select an approved image model from the X5 image catalog.
2. Select aspect ratio and quality.
3. Generate images only — no voice or video is started at this stage.
4. Let the user regenerate or approve one image.
5. Persist the approved character identity so later content keeps the same face
   and defining traits.

### 3. Voice

1. Select language, voice, speaking style and speed.
2. Enter or generate a short test phrase.
3. Generate a preview without starting video.
4. Save the approved voice configuration against the character.

### 4. Video

1. Use the approved character image and voice.
2. Enter the scene, speech and target format.
3. Select duration, aspect ratio and an approved video model.
4. Show the exact credit price before submission.
5. Generate through the server queue with idempotency, progress, safe failure
   handling and an automatic refund when generation fails.

## Release acceptance

- The same character remains recognisable in repeated images and video.
- No stage can silently skip an unapproved result.
- Credits are charged server-side exactly once and only for a real provider job.
- Failed jobs never display success and never leave credits reserved.
- Real-person references require usage rights; synthetic media is labelled.
- The feature gate is removed only after a real end-to-end image, voice and video
  test passes on a non-developer account.

## Product reference

The control structure follows Higgsfield AI Influencer Studio: character type
first, then identity, face, body, skin and style. Higgsfield describes the same
content pipeline as character image, consistent identity, voice and video:

- https://higgsfield.ai/blog/how-to-create-ai-influencer
- https://higgsfield.ai/blog/Higgsfield-Google-Bring-Your-Character-to-Life
