# Disposable X5 payment SQL audit

This is an isolated SQL runtime test, **not** an App Store/StoreKit/bank E2E test.
It never connects to an existing database or container, pulls an image, publishes
ports, or mounts host directories. It requires the already-local `postgres:17`
image and a working Docker CLI. No package installation is required.

## Evidence and commands

Baseline counterexample, pinned to `512f5463c97daa282ea66ea83050a7a489d1fc18`:

```powershell
node diagnostics/x5-audit/sql-race-runtime.mjs
```

Output: `sql-race-runtime-result.json`. An exit code of zero in this mode means
the **known baseline defect was reproduced**, with control and exact-once checks
passing. It does not mean the product is free of the defect.

Check the working-tree fix without overwriting the baseline evidence:

```powershell
node diagnostics/x5-audit/sql-race-runtime.mjs --with-fix
```

This loads only `20260907070000_serialize_verified_profile_projection.sql` after
the unchanged baseline migrations. Output: `sql-race-fixed-result.json`. The
same blocked-session schedule must preserve `isVerified=true`, one active ledger
row, and the exact committed expiration. The fix file's SHA-256 is recorded.

## What is real and what is a fixture

- Seventeen complete payment/retention migrations are executed from the pinned
  Git revision, including their tables, constraints, grants, triggers, renamed
  internal RPCs, refund projections, and reconciliation functions.
- The original badge predicate, retention trigger function, and trigger are
  mechanically extracted from the older mixed hub/retention migration.
- `fixture-infrastructure.sql` supplies empty Supabase/platform infrastructure:
  roles, `auth.users`, the relevant `profiles` columns, an empty courses table,
  and inert `cron` scheduling storage. No payment rule is stubbed.
- A synthetic App Review UUID with the required review email satisfies the
  actual lockdown migration. No real account, credential, balance, or purchase
  is imported.
- Grant/refund RPCs execute with `SET ROLE service_role`; the reconciliation job
  runs as the database owner, matching its privileged scheduled-job interface.
- An old expired badge is seeded as a clearly synthetic fixture. The new renewal
  is then applied by the actual `apply_verified_app_store_transaction` function.

## Controlled renewal race

1. Sequential control: real renewal RPC commits, then the real rebuild executes.
   The profile remains verified with one current ledger row.
2. Session A starts `READ COMMITTED`, applies a legitimate synthetic renewal
   through the real RPC, and deliberately keeps its transaction open.
3. Session B calls the real `x5_reconcile_store_profiles(10000)` function.
4. An observer verifies `pg_stat_activity.wait_event_type = Lock` and checks that
   `pg_blocking_pids(B)` includes the exact PID of session A.
5. A commits, then B completes. The baseline leaves one active ledger row but
   sets `is_verified=false` and `verified_until=NULL`. The fixed mode must keep
   the badge and exact new expiry instead.
6. A subsequent standalone rebuild serves as a recovery control.

The JSON report contains actual decoded RPC inputs as stored in the immutable
ledger (including precise purchase, signing, and expiration timestamps), session
output, lock PIDs, before/after profiles, source hashes, PostgreSQL version,
isolation level, Docker isolation settings, and cleanup outcome.

## Bounded P01/P03 SQL coverage

- P01 subset: the three server-priced packs grant exactly 1000 + 2000 + 5000 =
  8000 credits, all permanent, read through new database connections.
- P03 subset: two overlapping deliveries of one transaction plus three later
  replays add only 1000 credits and leave one ledger row.
- A different account is rejected with both the original and substituted account
  token; its credit balance remains zero.
- Full refund and refund reversal apply -1000/+1000 once. Repeated event IDs
  return `already_applied` with zero additional delta.
- Fixed mode also executes the exact emergency function rollback and forward
  reapply against this synthetic database. Both expected function-body hashes
  must match, and profile/consumable/subscription/event fingerprints must remain
  unchanged. This verifies the DDL escape hatch, **not** backup or disaster
  recovery. The old race is not exercised while the rollback is installed.

These checks do not prove actual money charged, Apple JWS acceptance, iPhone UI,
app restart behavior, production schema parity, Sandbox purchases, or every
possible refund/lifecycle ordering. They must not be promoted to full P01/P03
acceptance.

## Cleanup

Each run creates one `x5-audit-payment-sql-*` container with `--network none`, no
ports or host mounts, and PostgreSQL data in tmpfs. The `finally` block verifies
the exact unique ownership label before removing only that container. Its
synthetic database is intentionally discarded; the local JSON evidence remains.
