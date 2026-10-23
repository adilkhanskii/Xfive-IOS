# X5 Course Client Fixes Implementation Plan

> Execute this plan from `codex/x5-course-client-fixes-20260714`. Keep TestFlight upload out of the validation loop until the unsigned CI suite is green.

**Goal:** Make course editing lossless, restore the missing live module, add author/full-screen video, and connect paid-course ownership to an atomic credits purchase.

**Architecture:** Extract pure draft/access/zoom policies for tests, keep network work in focused services, stage media until the parent Save, and perform paid-course purchase in one authenticated Postgres RPC.

**Tech stack:** Swift 5.9, SwiftUI, AVKit, StoreKit-backed credits, Supabase REST/RPC, XcodeGen, XCTest, GitHub Actions.

---

## Task 1: Establish regression tests and unsigned CI

**Files:**

- Modify: `project.yml`
- Create: `X5Tests/CourseDraftTests.swift`
- Create: `X5Tests/CourseAccessPolicyTests.swift`
- Create: `X5Tests/VideoViewportStateTests.swift`
- Create: `X5Tests/CoursePurchaseResponseTests.swift`
- Create: `.github/workflows/ios-course-ci.yml`

1. Add an `X5Tests` unit-test target with dependency on `X5` and iOS 16 simulator deployment.
2. Write tests that express the acceptance criteria before production types exist.
3. Add a branch-scoped, non-signing workflow that generates the Xcode project and runs the tests on an available iPhone simulator.
4. Push the test-only commit and capture the expected red failure.

## Task 2: Extract a lossless course draft

**Files:**

- Create: `X5/Models/CourseDraft.swift`
- Modify: `X5/Views/CourseEditorView.swift`
- Test: `X5Tests/CourseDraftTests.swift`

1. Implement `CourseDraft`, `CourseCategoryDraft`, `CourseDayDraft`, and `CourseLessonDraft` with stable IDs and media staging fields.
2. Implement conversion from `Course` and JSON payload generation.
3. Make a selected replacement retain `savedVideoURL` until upload succeeds.
4. Replace the private editable structures in `CourseEditorView` with the testable draft types.
5. Run the draft tests.

## Task 3: Make editor Save retry-safe and persist the author

**Files:**

- Modify: `X5/Services/CoursesService.swift`
- Modify: `X5/Views/CourseEditorView.swift`
- Modify: `X5/Services/UserProfile.swift`
- Test: `X5Tests/CourseDraftTests.swift`

1. Add `persistedCourseId` state initialized from the edited course.
2. Store a created draft ID before any upload and reuse it on all retries.
3. Stage all existing-course media until parent Save.
4. Keep pending media on failure and replace saved URLs only after successful upload.
5. Add the author field and safe default from `CurrentUser`.
6. PATCH `author_name`, categories, and metadata only after media uploads succeed.
7. Improve HTTP error propagation and require a non-empty affected-row response for PATCH.
8. Run editor model tests.

## Task 4: Add explicit author UI

**Files:**

- Modify: `X5/Views/CoursesView.swift`
- Test: `X5Tests/CourseDraftTests.swift`

1. Add a small reusable author line.
2. Render it on the featured card, academy card, row, and detail header when present.
3. Preserve existing dark X5 styling and accessibility labels.

## Task 5: Add full-screen zoomable direct video

**Files:**

- Create: `X5/Models/VideoViewportState.swift`
- Modify: `X5/Views/LessonPlayerView.swift`
- Test: `X5Tests/VideoViewportStateTests.swift`

1. Implement scale clamping and reset in a pure state type.
2. Reuse one `AVPlayer` between inline and full-screen presentations.
3. Add a visible full-screen button.
4. Add pinch, pan, double-tap reset, and a native close/reset toolbar in the cover.
5. Keep YouTube fallback behavior unchanged.
6. Run viewport tests.

## Task 6: Correct paid-course access and purchase

**Files:**

- Create: `X5/Models/CourseAccessPolicy.swift`
- Create: `X5/Services/CoursePurchaseService.swift`
- Modify: `X5/Views/CoursesView.swift`
- Modify: `X5/Services/UserProfile.swift`
- Create: `supabase/migrations/20260714_purchase_course_atomic.sql`
- Test: `X5Tests/CourseAccessPolicyTests.swift`
- Test: `X5Tests/CoursePurchaseResponseTests.swift`

1. Implement the pure access policy and remove `Subscription.isPro` from paid-course ownership.
2. Add the atomic, auth-bound, idempotent purchase RPC with strict grants.
3. Add the Swift RPC client and typed response/errors.
4. Show course price, current credits, purchase confirmation, and actionable failure text.
5. Refresh `CurrentUser` after success and immediately unlock the course from server state.
6. Keep free-preview lessons playable while the course is locked.
7. Run access and purchase response tests.

## Task 7: Repair and verify live course data

**Files:**

- Create: `scripts/repair-target-course.ps1`
- Create: `diagnostics/course-repair/.gitkeep`
- Create at runtime: `diagnostics/course-repair/<timestamp>-before.json`
- Create at runtime: `diagnostics/course-repair/<timestamp>-after.json`

1. Read all matching rows and write the pre-change JSON plus SHA-256.
2. Dry-run a merge of recovered “Основы таргета” with the target module 2.
3. Verify stable unique IDs and that the target video URL is unchanged.
4. Apply the target PATCH and hide the three duplicate rows.
5. Read again and write the post-change JSON plus SHA-256.
6. Verify exactly one public target, two modules, preserved author, and playable video.

## Task 8: Harden credits and App Store entitlement delivery

**Files:**

- Modify: `X5/Services/IAPService.swift`
- Modify: `X5/X5App.swift`
- Create: `supabase/functions/verify-app-store-transaction/`
- Create: `supabase/migrations/20260714160000_verified_app_store_transaction_ledger.sql`
- Test: `X5Tests/IAPLifecycleDecisionTests.swift`
- Test: `supabase/tests/20260714_entitlement_hardening_test.sql`

1. Revoke client execution of every direct credit/IAP mutation function.
2. Send only StoreKit's signed transaction JWS from iOS.
3. Verify Apple certificate chain, bundle, product, environment, expiry, revocation, and account token in a JWT-authenticated Edge Function.
4. Apply verified transactions through a service-role-only, exact-once ledger RPC.
5. Preserve prior legitimate periods without double-crediting the first restore after upgrade.
6. Keep one app-lifetime StoreKit listener, retry one expired Supabase JWT, and finish only applied/skipped transactions.
7. Re-evaluate paid state against the subscription expiration when the app becomes active.

## Task 9: Full verification and handoff

**Files:**

- Modify if needed: `project.yml`
- Modify if needed: `.github/workflows/ios-course-ci.yml`
- Modify: `docs/superpowers/plans/2026-07-14-x5-course-client-fixes.md` only for factual completion notes

1. Run formatting/syntax checks available on Windows.
2. Push the implementation commits and run the unsigned GitHub Actions test workflow.
3. Inspect the complete CI log and fix every compile/test failure.
4. Review the diff for secrets, unrelated changes, and live-data safety.
5. Confirm the production course read matches the post-repair assertions.
6. Report branch, commits, CI URL, repaired data, and any step that still requires a physical-device check.

## Completion state (2026-07-14)

- Tasks 1-8 are implemented locally.
- The exact-ID production course repair and validator passed.
- Database migration `20260714160000` and `verify-app-store-transaction` are deployed.
- Apple verifier tests: 12 passed; database rollback suite passed.
- Task 9 remains open until the pushed macOS/Xcode CI run is green.
