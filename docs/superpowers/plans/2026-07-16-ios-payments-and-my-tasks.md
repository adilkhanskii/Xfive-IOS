# iOS Payment Reconciliation and My Tasks Implementation Plan

> Execute continuously with TDD. Preserve the visible credit Store and separate verified subscription already present in build 181.

**Goal:** Add owner task management to iOS and repair verified-subscription profile synchronization without weakening exact-once payment delivery.

**Architecture:** Extend `HubService` with owner-scoped load/update/delete APIs, add an owner list/edit flow reachable from Profile, and add a tested Supabase reconciliation migration for verified entitlements. Keep StoreKit and CourseUP purchase paths unchanged except where a regression test proves a gap.

**Tech Stack:** SwiftUI, StoreKit 2, URLSession/PostgREST, XCTest, Supabase PostgreSQL/Edge Functions.

---

### Task 1: Owner task service contract

**Files:**
- Modify: `X5/Services/HubService.swift`
- Test: `X5Tests/HubTaskManagementTests.swift`

1. Add failing tests for owner task query/status/edit/delete request construction and allowed status transitions.
2. Add owner-scoped `loadMyTasks`, `updateTask`, `setTaskActive`, and `deleteTask` methods.
3. Require an authenticated access token and scope mutations by both `id` and `author_id`.
4. Run the focused test target.

### Task 2: iOS My Tasks UI

**Files:**
- Modify: `X5/Views/ProfileView.swift`
- Modify: `X5/Views/Hub/HubView.swift`
- Modify: `X5/Views/Hub/TaskDetailView.swift`
- Create: `X5/Views/Hub/MyTasksView.swift`
- Modify/Create tests under: `X5Tests/`

1. Add failing UI/source tests for the Profile entry and owner actions.
2. Add `My Tasks` navigation from Profile.
3. Show all owned tasks with status, edit, deactivate/reactivate, and delete actions.
4. Reuse the task editor for updates and refresh both owner/public lists after mutations.
5. Run focused tests and compile checks.

### Task 3: Verified entitlement reconciliation

**Files:**
- Create migration using `npx supabase migration new ...`
- Create SQL regression test under `supabase/tests/`

1. Add a failing SQL regression proving an active verified entitlement repairs stale profile state without changing credits.
2. Add an idempotent reconciliation function/trigger or scheduled-safe path consistent with the existing entitlement ledger.
3. Backfill currently active verified rows and clear only provably expired verification state.
4. Run local SQL tests, deploy the migration, verify live rows, and run database advisors.

### Task 4: TestFlight Sandbox delivery repair

**Files:**
- Create migration using `npx supabase migration new ...`
- Modify the App Store verifier only if the allowlist contract requires it.
- Add SQL/Edge regression tests.

1. Add a failing test proving a TestFlight Sandbox purchase from either exact approved X5 developer UUID is accepted under the existing per-product cap.
2. Keep arbitrary Sandbox users blocked and keep App Review support intact.
3. Deploy the least-privilege allowlist change and re-run verifier smoke tests.
4. Verify the previously unfinished TestFlight transaction can be retried without a second charge.

### Task 5: Full iOS/payment verification

1. Run the iOS test suite available on the current platform/CI.
2. Run Edge Function and SQL tests for StoreKit delivery, refunds, notifications, CourseUP purchases, and reconciliation.
3. Verify App Store products/function versions remain unchanged and active.
4. Commit and push only scoped files.
