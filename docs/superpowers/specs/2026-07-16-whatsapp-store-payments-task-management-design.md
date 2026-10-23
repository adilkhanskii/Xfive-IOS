# X5 WhatsApp Store, Payment Sync, and Task Management Design

Date: 2026-07-16

## Source of truth

This design translates Adilkhan's approved WhatsApp requests into one cross-platform contract:

- Remove the visible X Five Pro subscription offer.
- Sell 1,000, 2,000, and 5,000 credits as repeatable one-time purchases.
- Keep the verified badge as a separate 1,000 KZT monthly subscription.
- A successful store purchase must update the shared Supabase profile exactly once and remain retryable if delivery is interrupted.
- Add a visible `My Tasks` entry in Profile. The owner must be able to edit, deactivate, reactivate, and delete tasks they created.
- Apply the same behavior to native iOS and the Android/WebView experience.

## Existing payment architecture

The current branches already implement the intended catalog and exact-once purchase delivery:

- iOS uses StoreKit signed transactions, a server verifier, and an App Store transaction ledger.
- Android uses Google Play Billing, a server verifier, and an atomic entitlement RPC.
- CourseUP purchases use server-priced, atomic Supabase RPCs.

The implementation will preserve these paths. Legacy subscription products remain hidden but restorable so existing customers are not stranded.

The live audit also identified the direct TestFlight failure mode behind the reported pending purchase: Apple marks TestFlight transactions as `Sandbox`, while the deployed verifier currently routes every Sandbox transaction through an App Review-only allowlist. Purchases made by the two approved X5 developer accounts are therefore rejected after Apple succeeds. The safe fix is to extend the capped Sandbox allowlist only to App Review plus those exact two developer UUIDs; arbitrary Sandbox accounts must remain blocked.

## Task-management experience

Profile gets a `My Tasks` row/card. Opening it lands directly on the owner's task list, not the public Hub feed.

For each owned task:

- Edit changes the existing row; it never inserts a duplicate.
- Deactivate changes `open` to `cancelled`, removing it from the public feed.
- Reactivate changes `cancelled` to `open`.
- Delete removes the task after explicit confirmation.
- Completed or in-progress tasks remain visible to the owner. Unsafe status transitions are not offered.

iOS will add an owner-only task list and edit form using the same `tasks` table. Android/Web will repair the existing edit flow and add the missing status actions plus the Profile shortcut.

## Data and authorization

Supabase remains the single source of truth. Every task mutation is scoped by both task id and the authenticated owner's `author_id`. Existing RLS owner policies must remain the final enforcement layer.

The payment audit found a live verified-subscription ledger/profile drift. A forward repair migration will reconcile an active verified entitlement into `profiles.is_verified` and `profiles.verified_until`, and tests will cover renewal and expiry behavior without granting credits.

## Error handling

- Failed task mutations keep the current screen state and show a readable error.
- Payment delivery failures remain pending and retryable; clients must not report credits before the server confirms them.
- Reconciliation is idempotent and never increments credits.

## Verification

- Add focused unit/source-contract tests before implementation.
- Run Android/Web targeted tests, TypeScript build, and Expo typecheck.
- Run iOS tests/build checks available from the repository/CI and SQL regression tests.
- Query live Supabase after deployment to prove the repair and re-run security advisors.
