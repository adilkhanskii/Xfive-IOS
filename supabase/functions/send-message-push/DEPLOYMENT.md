# Signed push dispatcher deployment

Do not deploy or apply the push migration from an unreviewed workstation. The
function intentionally uses `verify_jwt = false` because `pg_net` sends a
dedicated secret instead of a user JWT. The handler rejects every request that
does not carry the exact secret and accepts only an event type plus immutable
database UUID. It derives recipients, actors, text, chat, message, notification,
and task targets from stored rows.

## Server-only configuration

Required for the dispatcher:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `X5_PUSH_WEBHOOK_SECRET`: a fresh random value with at least 32 bytes of
  entropy; store the same value in Supabase Vault under the exact name
  `x5_push_webhook_secret`

Required for iOS delivery:

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_BUNDLE_ID`
- `APNS_PRIVATE_KEY`
- `APNS_ENV=production` or `APNS_ENV=sandbox`; use the old `APNS_USE_SANDBOX`
  switch only during migration

Required if Android or web push tokens exist:

- `FCM_SERVICE_ACCOUNT_JSON`: a server-only Firebase service-account JSON for
  the target Firebase project
- the Firebase Cloud Messaging HTTP v1 API enabled for that project
- the service account granted the minimum role that permits FCM sends
- `WEB_APP_URL`: reviewed HTTPS application URL used as the FCM web click link;
  required only when `push_tokens.platform = 'web'` exists

The Android/web path uses a one-hour OAuth token scoped only to
`https://www.googleapis.com/auth/firebase.messaging` and the HTTP v1 endpoint.
The removed legacy `FCM_SERVER_KEY` contract is not supported. Never store any
secret, service-account JSON, APNs key, or service-role credential in a
migration, mobile build, log, response, or analytics event.

## Mandatory order

1. Generate the dedicated webhook secret and set `X5_PUSH_WEBHOOK_SECRET` in the
   Edge Function environment.
2. Deploy `send-message-push` with gateway JWT verification disabled:

   ```sh
   supabase functions deploy send-message-push --no-verify-jwt
   ```

3. POST `/functions/v1/send-message-push?health=1` with the
   `X-X5-Push-Webhook-Secret` header. Require `{"ok":true,"healthy":true}`. A
   missing or wrong secret must return 401.
4. Store the same secret in Vault as `x5_push_webhook_secret`. Confirm exactly
   one non-empty value exists; do not print the value.
5. Apply `20260801115000_push_tokens_contract.sql`. Its preflight aborts on an
   incompatible schema, duplicate `(user_id, platform)` pairs, or unknown
   platform labels; verify owner-only upsert and exact-token logout deletion.
6. Apply `20260801120000_secure_push_dispatch.sql`. Its preflight aborts if the
   Vault secret is missing, duplicated, blank, or shorter than 32 bytes.
7. Confirm `messages_push_notify` posts only
   `{"event_type":"message_inserted","event_id":"..."}` and social notification
   triggers post only `notification_created` plus the inserted notification
   UUID.
8. In staging, send one message and one task notification. Confirm one ledger
   claim per recipient, exact message/chat/task deep-link fields, a duplicate
   webhook replay with no second provider call, and a forged legacy body
   rejected with 400.
9. Exercise APNs sandbox and production tokens separately. Verify Android and
   web through HTTP v1 with real staging registration tokens. The web target
   must receive an HTTPS click link and must never enter the APNs path.
10. Exercise a recipient with two targets: success plus a transient failure must
    return non-2xx so the outbox retries the same event/APNs/collapse ids.
    Success plus an explicit `Unregistered` verdict may complete only after the
    exact owned invalid token is deleted. Confirm logs contain no token value.
11. Follow the backup, client compatibility, observation, and rollback gates in
    `../../ROLLBACK_20260801.md` before production.

The dispatch ledger limits each recipient to 30 attempts per minute and 500 per
UTC day, caps retries at five, and retains rows for 30 days. It suppresses
ordinary duplicate webhooks, but APNs/FCM remain external at-least-once systems:
a process crash after provider acceptance and before ledger completion can still
produce a duplicate. Mobile routing must therefore remain idempotent. The
durable outbox treats any non-2xx handler response as retryable. Mixed
multi-recipient responses therefore stay non-2xx while any recipient is rate
limited, in progress, or transiently failed; a successful recipient cannot cause
another recipient's event to be marked delivered.
