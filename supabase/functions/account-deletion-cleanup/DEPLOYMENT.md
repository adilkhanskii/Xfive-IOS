# Account deletion cleanup deployment

Deploy and health-check this worker **before** applying
`20260726224500_account_deletion_voice_cleanup.sql`. The migration changes the
existing authenticated `delete_own_account()` RPC into a durable enqueue
operation so old and new app versions use the same safe path.

Required server-only environment:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `ACCOUNT_DELETION_CLEANUP_SECRET` (dedicated random value, at least 32 bytes)

Before applying the migration, store the **same** secret in Supabase Vault under
the exact name `x5_account_deletion_cleanup_secret`. The migration fails closed
when the Vault value is absent or too short, then installs the one-minute
`x5-account-deletion-cleanup` scheduler. Never put the value itself in SQL or
source control.

Deploy with gateway JWT verification disabled:

```sh
supabase functions deploy account-deletion-cleanup --no-verify-jwt
```

Release order is mandatory:

1. Generate one random secret with at least 32 bytes of entropy.
2. Set it as the Edge Function secret `ACCOUNT_DELETION_CLEANUP_SECRET`.
3. Store the same value in Vault as `x5_account_deletion_cleanup_secret`.
4. Deploy the worker, then POST
   `/functions/v1/account-deletion-cleanup?health=1` with the dedicated header
   and require `{"ok":true,"healthy":true}`. This check does not need the new
   database RPCs, so it proves the route and Edge secret before migration.
5. Apply `20260726224500_account_deletion_voice_cleanup.sql`.
6. Confirm `x5-account-deletion-cleanup` is active and a test job advances from
   `pending` to `post_cleanup`, then to `completed` after two empty passes.

The worker removes exact object names through the Supabase Storage API. It never
deletes `storage.objects` with SQL. It runs a pre-delete pass, deletes
profile/auth data through the service-only finalizer, waits beyond the maximum
in-flight function window, then requires two empty post-delete passes before
marking the tombstone complete. When there is no account job, the same scheduled
worker removes only deterministic private MP3 paths belonging to voice ledger
rows that were safely refunded after their four-hour delivery window expired.
