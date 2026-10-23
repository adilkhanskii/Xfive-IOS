# iOS Consumable Refund Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development while implementing every behavior below. This task must remain inline because the owner explicitly prohibited overlapping agents.

**Goal:** Reconcile Apple refunds for the currently sold 1,000, 2,000, and 5,000 credit packs exactly once in Production and Sandbox, including refunds received while the app was offline.

**Architecture:** Apple-signed refunded consumables enter the existing verifier, which validates the signed identity and calls one new postgres-owned RPC. The RPC can subtract only the `credits_granted` value from a matching immutable purchase ledger row, records the refund in a separate append-only ledger, and permits a negative profile balance so already-spent refunded credits become debt. StoreKit online updates and a bounded `Transaction.all` sweep use the same idempotent delivery path and trigger a server profile refresh.

**Tech Stack:** Swift/StoreKit 2, Deno/TypeScript Supabase Edge Functions, PostgreSQL migrations and rollback tests, XCTest and Python source-contract tests.

---

### Task 1: Lock the verifier contract with RED tests

**Files:**
- Modify: `supabase/functions/verify-app-store-transaction/validation_test.ts`
- Modify: `supabase/functions/verify-app-store-transaction/index_test.ts`
- Create: `supabase/functions/verify-app-store-transaction/consumable_refund_contract_test.ts`

- [x] Add a validation test whose Apple-verified payload is a credit pack with `quantity: 1`, matching `appAccountToken`, and a signed `revocationDate`; assert the normalized transaction remains a consumable refund.
- [x] Keep legacy subscription revocations rejected and add mismatch/date tests for consumable refunds.
- [x] Add handler tests asserting a consumable refund calls `applyVerifiedConsumableRefund`, never the purchase grant RPC, and returns the RPC result.
- [x] Add migration source-contract tests requiring both Production and Sandbox source-ledger lookups, strict immutable identity checks, append-only ACLs, exact-once replay, and debt-safe subtraction:

```sql
set credits = coalesce(credits, 0) - v_credits_reversed
```

- [x] Run the focused Deno tests and confirm RED because the new route, dependency, and migration do not yet exist.

### Task 2: Add the owner-bound refund ledger and RPC

**Files:**
- Create: `supabase/migrations/20260716050000_app_store_consumable_refunds.sql`
- Create: `supabase/tests/20260716_app_store_consumable_refunds_test.sql`

- [x] Create `public.app_store_consumable_refunds` with primary key `(environment, transaction_id)`, owner/account/date/quantity fields, positive `credits_reversed`, RLS forced, and no direct privileges for API roles or `service_role`.
- [x] Create postgres-owned `SECURITY DEFINER` RPC:

```sql
public.apply_verified_app_store_consumable_refund(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_quantity integer
) returns jsonb
```

- [x] Lock the profile and environment-specific source purchase row, require an exact immutable tuple, derive the reversal only from `source.credits_granted`, insert the refund before subtracting, and return `credits_granted: 0` for both `applied` and `already_applied`.
- [x] Do not clamp the profile balance; existing spending RPCs already require `credits >= cost`, so a negative balance is debt-safe.
- [x] Add rollback SQL coverage for Production, Sandbox, replay with a new `signed_date`, cross-user/identity conflicts, exact negative balance, debt reuse prevention, and immutable ACLs.

### Task 3: Route signed consumable refunds through the verifier

**Files:**
- Modify: `supabase/functions/verify-app-store-transaction/validation.ts`
- Modify: `supabase/functions/verify-app-store-transaction/index.ts`

- [x] Permit `revocationDate` for current consumable IDs only after the existing product/type/quantity/account checks; continue rejecting revoked legacy subscriptions.
- [x] Add `applyVerifiedConsumableRefund` to `HandlerDependencies` and route consumable revocations to it before Sandbox/purchase routing.
- [x] Call only `apply_verified_app_store_consumable_refund` with normalized Apple-signed fields; map source/mismatch/conflict errors fail-closed.
- [x] Run focused Deno tests and confirm GREEN.

### Task 4: Reconcile online and offline refunds in StoreKit

**Files:**
- Modify: `X5/Services/IAPService.swift`
- Modify: `X5/X5App.swift`
- Modify: `X5Tests/IAPCreditStoreTests.swift`
- Existing coverage: `X5Tests/IAPLifecycleDecisionTests.swift`
- Modify: `scripts/tests/test_ios_purchase_lifecycle_source.py`

- [x] Add RED tests for `IAPProductCatalog.shouldReconcileRevocation(productID:)`: all three credit packs and verified monthly are true; legacy plans and unknown products are false.
- [x] Reuse the bounded newest-20 `Transaction.all` collector for both supported refund kinds.
- [x] Keep the lifecycle key scoped by account and `revocationDate`; refunds call the same verifier and never mutate credits locally.
- [x] Publish a credit-refund notification after an applied online/restore refund and have `X5App` reload the authoritative profile.
- [x] Run Python source contracts (GREEN); XCTest remains assigned to macOS CI because Xcode/Swift are unavailable on Windows.

### Task 5: Verify and commit

**Files:** all files above only, plus this plan.

- [x] Run `deno fmt --check`, `deno lint`, `deno check index.ts`, and `deno test --allow-read` in the verifier directory.
- [x] Run `python -m unittest discover -s scripts/tests -p "test_*.py"` and `git diff --check`.
- [x] Inspect `git diff --stat`, ensure unrelated `scripts/__pycache__/` remains untracked and unstaged, then commit with `fix(iap): reconcile consumable refunds`.
