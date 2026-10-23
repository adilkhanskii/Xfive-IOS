# Backend release readiness

Audit date: 2026-08-01. This file describes source readiness and required
release gates. It is not evidence that a migration, function, secret, provider
account, or production health check is currently live.

## Push notifications

Source status: ready for staging review, not deployed by this change.

- The webhook is database-only, signed with a dedicated secret, and accepts only
  an event type plus UUID. Message, notification, recipient, actor, and
  task/chat targets are loaded from the database.
- `20260801120000_secure_push_dispatch.sql` fixes message-insert membership,
  replaces legacy webhook bodies, and adds private idempotency/rate-limit state.
- `20260801115000_push_tokens_contract.sql` makes the token table reproducible,
  preflights the `(user_id, platform)` upsert key, separates owner-only RLS by
  operation, removes anonymous/table-admin grants, and retains legacy `expo`
  rows without routing them to APNs or FCM.
- A read-only live schema audit on 2026-08-01 found the existing
  `push_tokens_user_id_platform_key UNIQUE (user_id, platform)` constraint, RLS
  enabled, no exact/normalized duplicate pairs, and 11 rows (7 `ios`, 4 legacy
  `expo`). No row or schema was changed by that audit. Android logout must
  delete the exact `(user_id, platform, token)` tuple before sign-out.
- APNs requires its four credentials plus an explicit environment. Android and
  web use a dedicated `FCM_SERVICE_ACCOUNT_JSON`, the FCM HTTP v1 API, and
  suitable project IAM; web also requires the reviewed HTTPS `WEB_APP_URL`. The
  legacy FCM server-key API is unsupported.
- Delivery is evaluated per target. A transient failure on any device keeps the
  recipient dispatch retryable even when another target succeeded; explicit
  APNs/FCM invalid-token verdicts remove only the exact user-owned token. Tokens
  are never logged. `platform=web` stays on FCM and is never mapped to APNs.
- Exact secret names, order, health request, and staging checks are in
  `functions/send-message-push/DEPLOYMENT.md`.

## Voice generation and credits

Source status: implementation and local contract tests pass; production is not
claimed ready without live staging evidence.

- The exact-once ledger owns price, debit, replay, provider binding, terminal
  refund, stale reconciliation, private result storage, and account-deletion
  cleanup.
- The fal callback is public only at the gateway. It verifies fal's current
  Ed25519 signature contract before any service-role RPC or Storage access.
- Required credentials are `FAL_KEY`, the Supabase URL/anon/service keys, and
  the separate account-cleanup secret shared with its Vault entry. None are
  present in source.
- Apply the ACL hotfix, voice ledger, and queued-cleanup migration only in the
  order documented in `functions/generate-voice/DEPLOYMENT.md`.
- Image, generated-video, and voice debit/refund/idempotency contract suites
  pass locally. Their transactional SQL regressions still require an isolated
  migrated Supabase/Postgres database; source-only tests are not a substitute.

## CourseUP video path status

Standard Supabase/TUS status: supported for the exact client video, with
production upload-preparation acceptance passed. That acceptance performed no
new remote upload, Storage mutation, or production database write.

- The exact 17,656,264-byte MP4 is below the current 47,000,000-byte direct
  upload boundary. Production preparation accepted it unchanged, playable and
  untruncated at 371.1667 seconds (6:11.17), retaining its H.264 video and AAC
  audio. The standard `SupabaseResumableVideoUploader`/TUSKit path remains the
  active route for this file.
- Existing Supabase `videos` and `course-media` bucket metadata allows up to 5
  GiB but currently marks both buckets public. That setting is not a secure
  managed playback contract and does not prove end-to-end upload limits across
  client, gateway, project quota, timeout, or resumable recovery.
- Read-only Storage inventory found the client's only approximately six-minute
  object at
  `videos/courses/497f610e-8612-4b08-8f21-67f91ec93501/lesson_C96CD1EF-DBE4-42DC-AA50-B9018B36C880-8c44513dbe2db9b3.mp4`:
  371.1667 seconds (6:11.17), 17,656,264 bytes, created 2026-07-28 21:26:42 UTC.
  Its current public Storage URL is
  `https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/courses/497f610e-8612-4b08-8f21-67f91ec93501/lesson_C96CD1EF-DBE4-42DC-AA50-B9018B36C880-8c44513dbe2db9b3.mp4`.
  The object was not copied, modified, or attached by this change; this is
  inventory evidence plus local preparation acceptance, not evidence of a new
  remote upload.

### Bunny Stream course videos (branch feature/bunny-stream-course-video)

Implemented 2026-10-01, not deployed. The quarantined prototype
(`20260726233000_course_video_upload_slots.sql`, never applied) was replaced by
`supabase/drafts/bunny-stream/` and three functions
(`create-course-video-upload`, `course-video-playback`,
`course-video-status`). Deploy order, the Bunny token-authentication switch and
rollback: `docs/BUNNY-STREAM-HANDOFF.md`.

- Uploads: runtime flag `app_feature_flags.bunny_course_video_upload` (seeded
  off), server-only broker RPCs, course author/developer check.
- Playback: `course_video_playback_grant` entitlement check, short-lived
  token-signed HLS. Old Supabase lessons keep their URLs until migrated.
- Readiness and cleanup: Bunny webhook + pg_cron reconciler; only ledger-owned
  Bunny videos are ever deleted.
- Do not make the existing buckets private in isolation: every iOS/web/Android
  playback URL, entitlement check, sharing flow, cleanup job, and migration
  rollback must be designed and tested together. Until then, no release note or
  UI should claim Bunny-managed/private large-file delivery.

## Combined migration order for these features

1. `20260726222900_revoke_account_delete_helper_acl.sql`
2. Deploy and health-check `account-deletion-cleanup` with its Edge secret.
3. `20260726223000_voice_generation_exact_once.sql`
4. Provision the matching account-cleanup Vault secret, then apply
   `20260726224500_account_deletion_voice_cleanup.sql`.
5. Deploy and stage-test `voice-generation-webhook`, then `generate-voice`.
6. Apply `20260801115000_push_tokens_contract.sql`; verify the preflight sees no
   duplicate `(user_id, platform)` pairs, deterministically resolves any legacy
   duplicate `(platform, token)` ownership and `profiles.push_token` mirrors,
   and installs canonical plus legacy-mirror uniqueness keys.
   Deploy `register-push-token`; POST/DELETE writes are service-role RPCs after
   JWT authentication. In staging, switch one exact token from account A to B:
   A's row and exact legacy `profiles.push_token` must clear atomically, B must
   own the token, and A's stale DELETE must not remove B's registration.
7. Deploy and health-check `send-message-push` with `X5_PUSH_WEBHOOK_SECRET`.
8. Provision the matching `x5_push_webhook_secret` Vault entry, then apply
   `20260801120000_secure_push_dispatch.sql`.
9. Provision one new random value of at least 32 characters in the Edge
   environment as `X5_PORTFOLIO_MODERATION_SWEEP_SECRET` and the same value in
   Vault as `x5_portfolio_moderation_sweep_secret`. Verify there is exactly one
   Vault row with that name and never print either value. Deploy
   `moderate-portfolio`; its normal user route validates JWT itself and its
   `?sweep=1` route accepts only the dedicated secret.
10. Deploy clients that sign private chat-media and portfolio reads and upload only
   `<chat_id>/<user_id>/<filename>`; retain read-only support for legacy
   `chats/<chat_id>/...` identifiers. Installed legacy chat writers have only
   the server-enforced window ending `2026-09-01 00:00 UTC`.
11. Apply `20260801121000_portfolio_automatic_moderation_enforcement.sql`, then
    verify automatic safe/unsafe/provider-failure decisions, five-attempt
    bounded retry and the minute sweep in staging.
12. Apply `20260801122000_secure_chat_attachments.sql` and verify image, web
    audio and rotating-JWT TUS video across every released client. The canonical
    chat video ceiling is 47,000,000 bytes, below the Supabase Free 50 MB
    project limit.
13. Apply `20260801123000_private_portfolio_media.sql` only after every active
    client signs portfolio paths. Confirm pending/rejected/orphan URLs return no
    public bytes, approved and owner reads sign successfully, and rejected plus
    24-hour orphan cleanup runs through the Storage API.
14. Bunny Stream course videos ship only through
    `docs/BUNNY-STREAM-HANDOFF.md` (drafts in `supabase/drafts/bunny-stream/`,
    staging first, token authentication before any paid lesson uses Bunny).

The backup, staged checks, and non-destructive operational rollback are in
`ROLLBACK_20260801.md`. Production application is prohibited until that runbook
has a reviewed restore drill and compatible client evidence.

Never reuse the Supabase service-role key as a cron/webhook secret, print Vault
values, or add provider JSON/private keys to the repository or mobile builds.

### Moderation sweep secret rotation

Rotate without printing the value: unschedule `x5-portfolio-moderation-sweep`,
generate a new random value of at least 32 characters in an operator-controlled
secret surface, update the Edge secret, replace the single matching Vault entry,
redeploy `moderate-portfolio`, invoke one signed staging sweep, then reschedule
the minute job. During the pause, jobs remain private and durable in
`portfolio_moderation_jobs`; no item is automatically approved and the next
sweep resumes due work idempotently.
