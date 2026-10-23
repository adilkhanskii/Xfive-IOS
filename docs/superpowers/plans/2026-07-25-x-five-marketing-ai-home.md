# Xfive marketing AI Home Implementation Plan

## Task 1: Lock the brand and Home routes

Files:

- Modify `X5/Views/Home/HomeView.swift`
- Modify `X5/Info.plist`
- Modify `project.yml`
- Add/modify tests under `scripts/tests/` and `X5Tests/`

Steps:

1. Add a failing source test requiring the exact visible brand
   `Xfive marketing` and forbidding `X5 AI` as the app title.
2. Add testable Home route values for image generation, Startup Chat, Hub,
   video generation, and Live Fruits.
3. Update the compact Home header and primary image hero.
4. Connect image generation to `ImageGeneratorView` and Hub to
   `x5SwitchTab`.
5. Run the focused source tests and macOS Swift tests.

## Task 2: Repair and prove course video upload

Files:

- Modify `X5/Services/CourseVideoUploadPreparation.swift` only if live evidence
  shows a remaining defect
- Modify `X5/Services/SupabaseResumableVideoUploader.swift` only if needed
- Modify `X5/Views/CourseEditorView.swift` only if status/retry state is wrong
- Modify upload tests

Steps:

1. Correlate the client build number with Supabase Storage logs.
2. Prove whether failure occurs in photo import, staging, transcode, TUS
   creation, TUS patching, or course save.
3. Add a failing regression test for the exact boundary.
4. Apply the smallest fix and keep 6 MiB TUS chunks.
5. Run upload tests, push CI, and verify a real build-190-or-newer upload in
   storage logs.

## Task 3: Add the shared video job backend

Files:

- Add one migration under `supabase/migrations/`
- Add `supabase/functions/generate-video/`
- Add backend contract tests

Steps:

1. Add failing tests for authentication, idempotency, ownership, credit
   reserve/refund, provider submission, and safe status responses.
2. Add private result storage and RLS-protected video job rows.
3. Adapt the fal Kling V3 asynchronous queue contract and Google Gemini Omni
   Flash fallback behind a provider interface.
4. Add OpenAI multimodal moderation before the credit claim.
5. Add webhook verification/reconciliation and exact-once terminal refund.
6. Deploy only after tests pass and at least one server-side video provider is
   confirmed available.

## Task 4: Add the native video generator

Files:

- Add `X5/Services/VideoGenerationService.swift`
- Add `X5/Views/Home/VideoGeneratorView.swift`
- Add Swift tests

Steps:

1. Add failing request, polling, retry, and status mapping tests.
2. Build text-to-video and image-to-video forms using the shared job endpoint.
3. Show queued, rendering, completed, failed, and refunded states.
4. Persist recent X5 jobs and render completed output from signed URLs.
5. Route all Home video cards to this screen.

## Task 5: Add Startup Chat

Files:

- Add `supabase/functions/startup-chat/`
- Add `X5/Services/StartupChatService.swift`
- Add `X5/Views/Home/StartupChatView.swift`
- Add backend and Swift tests

Steps:

1. Add failing auth, request-validation, and response-decoding tests.
2. Adapt the existing OpenAI server integration to a concise startup mentor.
3. Add native conversation UI with retry and loading state.
4. Route the Home promo card to the real assistant.

## Task 6: Add Live Fruits

Files:

- Add `supabase/functions/fruit-story/`
- Add native fruit flow models, service, and views
- Add backend and Swift tests

Steps:

1. Add failing tests for exactly one fruit, exactly three scenes, structured
   scenario output, ordering, and ownership.
2. Build the questionnaire and strict scenario generation.
3. Reuse current image generation for the canonical fruit and scene frames.
4. Build the editable/reorderable three-card storyboard.
5. Support per-scene regeneration without replacing other frames.
6. Submit the approved storyboard through the shared video job.

## Task 7: Full verification and TestFlight

1. Run all Python, Node/Deno, SQL contract, and Swift tests.
2. Request a two-pass review: spec compliance, then code quality.
3. Resolve every finding and rerun the complete gate.
4. Bump the build number, upload TestFlight, wait for `VALID`, and assign only
   groups `123` and `321`.
5. Verify live backend/storage logs without exposing personal data.
6. Prepare a client message describing only the changes actually present in
   the released build.
