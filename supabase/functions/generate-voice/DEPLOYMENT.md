# Voice generation deployment

Do not deploy this feature automatically. Source and local contracts are ready;
production availability is **not confirmed** until the migration, secret,
provider-billing, staging-fault, and cleanup gates below have current evidence.
Do not advertise voice generation as live based only on these files or passing
unit tests.

Required server-only environment:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `MINIMAX_API_KEY` (standard tier, official MiniMax)
- `ELEVENLABS_API_KEY` (optional, premium tier, official ElevenLabs `eleven_v3`)
- `FAL_KEY` only while legacy queued jobs still exist

No value is supplied by this repository. Provider keys must belong to the X5
server environment. Never substitute a client key, invent a credential, or copy
any provider key into the app. Standard jobs ("Обычный", no `tier` or
`tier: "standard"`) use MiniMax Speech 2.8 Turbo directly, 30 credits per
started 1000 characters. Premium jobs (`tier: "premium"`) use the official
ElevenLabs API with `eleven_v3` and one of six premade voice IDs, 150 credits
per started 1000 characters. There is no fallback between tiers. Legacy fal
queue handling remains only so an already accepted historical request can be
reconciled safely.

## Premium voice (ElevenLabs) rollout

1. Apply `20261026120000_voice_premium_tier_pricing.sql` (ledger price range
   30..750, step 30). It must land **before** the new function code: the old
   check rejects 30 and 150..750 and returns `invalid_request`.
2. Deploy `generate-voice` and `ai-capabilities`. Without the secret, premium
   answers `premium_unavailable` (503) before any debit, and the apps show
   "Премиум · скоро".
3. To turn premium on, set the server secret and redeploy both functions:

```sh
supabase secrets set ELEVENLABS_API_KEY=<value from the ElevenLabs dashboard>
supabase functions deploy generate-voice
supabase functions deploy ai-capabilities
```

Rollback: `supabase secrets unset ELEVENLABS_API_KEY` and redeploy both
functions; premium switches back to "скоро" with no data change.

Mandatory order:

1. Apply `20260726222900_revoke_account_delete_helper_acl.sql`.
2. Provision and health-check the account cleanup worker and its dedicated Vault
   secret exactly as documented in `../account-deletion-cleanup/DEPLOYMENT.md`.
3. Apply `20260726223000_voice_generation_exact_once.sql`.
4. Apply `20260726224500_account_deletion_voice_cleanup.sql`. Its secret
   preflight must pass before it changes the account-deletion RPC.
5. Confirm the private `voice-generation-results` bucket, service-only ledger
   RPC grants, five-minute reconciliation cron, and one-minute account cleanup
   cron.
6. Deploy `voice-generation-webhook` for legacy Fal callbacks, run the signed
   callback tests in staging, and only then deploy `generate-voice` for
   authenticated client traffic.

Deploy the authenticated client function normally:

```sh
supabase functions deploy generate-voice
```

The callback function is intentionally configured with `verify_jwt = false` in
`supabase/config.toml`, because fal does not send a Supabase JWT. It rejects all
callbacks unless fal's Ed25519 signature, raw-body hash, signed request ID, and
five-minute timestamp window verify against fal's official JWKS:

```sh
supabase functions deploy voice-generation-webhook --no-verify-jwt
```

Before release, force a submit-response timeout in staging and verify:

1. one credit debit and one fal queue request;
2. the signed callback binds its request ID through the opaque claim URL;
3. a client retry polls/replays and never submits a second job;
4. duplicate callback delivery is idempotent;
5. an unbound ambiguous submission is not automatically refunded;
6. a terminal provider error refunds exactly once;
7. generated audio is copied into private X5 Storage before the fal URL expires.
8. missing `FAL_KEY` returns a bounded unavailable response without a debit,
   while a previously completed request still re-signs its stored private MP3;
9. account deletion blocks a new debit and removes owner-scoped MP3 objects
   through the Storage API, including refunded orphan cleanup;
10. the model schema, queue request/response shape, webhook signature headers,
    and JWKS URL still match the official fal references recorded in
    `THIRD_PARTY_SOURCES.md`.
