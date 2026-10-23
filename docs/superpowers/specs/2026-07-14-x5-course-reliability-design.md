# X5 Course Reliability Design

**Date:** 2026-07-14
**Source branch:** `codex/xfive-marketing-testflight-169` at `635f604d5f85e745c0e8c888599c7266724c1ba3`
**Implementation branch:** `codex/x5-course-client-fixes-20260714`

## Goal

Fix the client-reported course failures without changing the rest of the X5 product:

- replacing or editing a lesson video must never silently remove the saved video;
- saving a course must not create duplicate draft rows or drop untouched modules;
- direct videos must support a true full-screen presentation and pinch zoom;
- the course author must be visible and persisted;
- paid-course access must follow course ownership, not the generic Pro subscription flag;
- the live course data must be backed up and repaired reversibly.

## Evidence and root causes

The live `courses` response on 2026-07-14 contains one target course, “Таргетированная реклама”. It has `author_name = DOPAMINE`, a price of `50000`, one surviving category named “2 модуль”, and one working Bunny CDN video URL. The missing first module is therefore a stored-data problem, not a rendering filter. Three public “Новый курс” rows created within the same second contain the missing “Основы таргета” content and an empty copy of module 2.

The current editor creates a new row before uploading media, but keeps the created ID only in a local variable. If a later upload or PATCH fails, the next Save creates another row. This matches the three duplicate drafts in production.

For existing courses, the lesson sheet uploads a replacement file immediately, while the course JSON is persisted only after the parent editor Save. Closing the parent editor, or a later PATCH failure, leaves uploaded media disconnected from the saved lesson. The UI can then appear to lose the newly selected video. Media must be staged in the draft and committed from one explicit Save flow.

The player is an embedded SwiftUI `VideoPlayer` with no full-screen presentation and no zoom state.

`CourseDetailView` currently grants access when `Subscription.isPro` is true and opens the subscription paywall for a paid course. The profile model already has `purchased_course_ids`; therefore Pro and course ownership have been conflated.

The course author is decoded by `CoursesService`, but no course card/detail renders it and the editor does not persist it.

## Architecture

### 1. Lossless editor draft

Introduce testable draft models in `X5/Models/CourseDraft.swift`. They preserve stable category/day/lesson IDs and every media field when converting a `Course` to editable state and back to the JSON payload.

The view owns a `persistedCourseId` state initialized from `editing?.id`. When a new hidden row is created, that ID is stored immediately and reused for every retry. The Save button remains disabled while work is in flight.

All imported lesson media is staged in the draft. The parent Save performs this ordered sequence:

1. create or reuse the hidden course row;
2. upload the cover and pending lesson media;
3. update only the corresponding draft media URLs after successful uploads;
4. PATCH metadata, author, and the complete validated categories payload;
5. refresh the course list and dismiss only after a successful response.

An upload failure keeps the old saved URL and the pending local file, shows an error, and lets Save be retried with the same course ID. The editor never clears an existing URL merely because a replacement was selected.

### 2. Author identity

The editor gets `CurrentUser` from the environment. Existing `author_name` is preserved. A new course defaults to the current profile display name, then falls back to the authenticated email prefix and finally “Xfive marketing”. The author field is editable and is persisted with every Save. Course cards and details show `Автор: <name>` when non-empty.

### 3. Paid-course ownership

Add a pure `CourseAccessPolicy`:

- free course or zero price: full access;
- authenticated profile whose `purchased_course_ids` contains the course ID: full access;
- otherwise: only free-preview lessons are playable;
- Pro subscription alone does not unlock an independently priced course.

Add a security-definer Postgres RPC `purchase_course(p_course_id text, p_expected_price integer)` that:

- derives the buyer from `auth.uid()` and rejects anonymous calls;
- locks the buyer profile row;
- reads the current public course price on the server;
- refuses a stale client confirmation with `price_changed` and performs no charge;
- returns success without charging again when already purchased;
- rejects missing/hidden courses and insufficient credits;
- atomically deducts credits and appends the course ID once;
- grants execute only to `authenticated`.

The iOS `CoursePurchaseService` calls the RPC with the access token. On success it refreshes `CurrentUser`, so the access gate updates from server state. When credits are insufficient, the existing subscription/credit paywall can be opened, but it is not mistaken for course ownership.

Credits obtained through StoreKit are server-owned. iOS sends only
`VerificationResult.jwsRepresentation` to a JWT-authenticated Edge Function.
The function uses Apple's official App Store Server Library and current Apple
Root CAs to verify the signature, bundle, environment, product, expiration,
revocation, and `appAccountToken`. A service-role-only Postgres function records
the verified transaction in a globally unique ledger and grants each renewal
exactly once. Legacy client claim and direct credit mutation functions are not
executable by `anon` or `authenticated`.

### 4. Full-screen and zoomable video

Keep `AVPlayer` as the single playback engine. The inline player gets a visible full-screen control. A `fullScreenCover` presents the same player on a black background with:

- native dismiss and reset controls;
- pinch scale clamped to `1...4`;
- double-tap reset;
- pan while zoomed, with reset when scale returns to 1;
- playback paused only when leaving the lesson, not while transitioning to full screen.

YouTube links continue to open in the system app/browser and are not passed into the direct-video zoom player.

### 5. Live-data repair

Before mutation, export the four current course rows to a timestamped JSON backup in `diagnostics/course-repair/` and record SHA-256. The repair is idempotent:

- merge the recovered “Основы таргета” category from one duplicate into the target course;
- preserve the target course’s current module 2 object and working video URL byte-for-byte;
- keep `author_name = DOPAMINE`;
- set the three duplicate “Новый курс” rows to `is_public = false` instead of deleting them.

The repair script must support dry-run and verify the postcondition with a fresh read. No destructive deletion is part of this change.

## Error handling and observability

Every REST/RPC failure includes the HTTP status and a short server message in `CoursesService.error` or `CoursePurchaseService.error`. No access token, service key, or full profile payload is logged. Media upload and course save diagnostics include only course/lesson IDs and stage names.

## Test strategy

An `X5Tests` target covers:

- draft round-trip preserves module count, stable IDs, sibling lessons, and existing video URLs;
- selecting a replacement does not erase the old URL before upload succeeds;
- retry reuses the persisted course ID;
- access is granted for free and purchased courses, denied for Pro-only paid courses;
- course purchase responses decode success/already-owned/insufficient-credit states;
- video zoom clamping and reset behavior.

A separate non-signing GitHub Actions workflow runs `xcodegen` and `xcodebuild test` on a simulator. The existing TestFlight workflow does not trigger from the implementation branch.

## Acceptance criteria

1. Editing text in a lesson and saving keeps its previous video URL.
2. Replacing video and forcing an upload/PATCH failure leaves a retryable draft and never creates a second course row.
3. Saving an edit to module 2 leaves module 1 and all untouched lessons intact.
4. The target live course shows both recovered module 1 and the existing module 2 video after repair.
5. Direct video opens full screen, pinches to zoom, pans while zoomed, and resets.
6. `DOPAMINE` appears on the target course card/detail.
7. Pro-only users cannot open a paid course unless its ID is in `purchased_course_ids`.
8. Purchase is atomic and idempotent; a repeated request never double-charges.
9. Unit tests and the unsigned iOS simulator build pass on GitHub Actions.
