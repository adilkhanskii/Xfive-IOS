# generate-video deployment

This function must not be deployed until the migration and code diff have been
reviewed together. Apply the `video_generation_jobs` migration first so credit
reservation, idempotency, refunds, private buckets, and RPC permissions exist
before the endpoint can receive traffic.

Required server-side environment:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `VIDEO_RECONCILE_CRON_SECRET`, a dedicated random server-only credential
  shared only with the Vault entry described below
- `OPENAI_API_KEY` for the primary text/image safety check before any credit
  claim and the server-side OpenAI Videos fallback. When OpenAI moderation is
  unavailable, a configured Google key performs the same fail-closed preflight.
  When those classifiers are unavailable, the activated BytePlus
  `seed-2-0-lite-260428` model performs the same structured text/image safety
  classification with `ARK_API_KEY`. If every configured classifier is
  unavailable or returns malformed output, the request fails closed before the
  credit claim. BytePlus Seedance also applies its own model safety policy and
  any definitive provider rejection is refunded exactly once.
- at least one video provider:
  - `ARK_API_KEY` for explicit Seedance 2.0 Fast and backward-compatible
    Seedance 1.5 Pro through ByteDance's official BytePlus ModelArk API
  - `FAL_KEY` for Kling V3 Standard automatic routing only
  - `GOOGLE_API_KEY` or `GEMINI_API_KEY` for Gemini Omni Flash
  - `OPENAI_API_KEY` for Sora 2
- Before applying the follow-up cron-secret migration, Supabase Vault must
  contain exactly one non-empty secret named `x5_video_reconcile_cron_secret`.
  Its value must exactly match `VIDEO_RECONCILE_CRON_SECRET`. Provision the same
  freshly generated random value securely in both places; never paste it into a
  migration or repository. The postgres-only cron function reads
  `vault.decrypted_secrets` and fails closed if that named secret is missing,
  blank, or non-unique. The service-role key is not sent through the scheduled
  HTTP request. This follows Supabase's official
  [Vault](https://supabase.com/docs/guides/database/vault) and
  [scheduled Edge Function](https://supabase.com/docs/guides/functions/schedule-functions)
  guidance.
- Optional `GOOGLE_WEBHOOK_AUDIENCE` only if the Google project explicitly
  configures a non-URI JWT audience. The secure default is the exact dynamic
  callback URI.

Never put `OPENAI_API_KEY`, `ARK_API_KEY`, `FAL_KEY`, the Google/Gemini key, or
`SUPABASE_SERVICE_ROLE_KEY` in an iOS/Android build, repository, log, response,
or analytics event.

The function validates user JWTs itself and also accepts signed fal webhooks,
which do not carry a Supabase JWT. Therefore deploy it with gateway JWT
verification disabled:

```sh
supabase functions deploy generate-video --no-verify-jwt
```

Before enabling the client:

1. Verify both Storage buckets are private.
2. Submit one 5-second test job and confirm one credit reservation.
3. Retry with the same idempotency key and confirm no second reservation.
4. Confirm an authenticated different user cannot read the job.
5. Confirm a provider failure refunds exactly once.
6. Confirm completed responses contain only a short-lived signed result URL.
7. Confirm rejected text/reference images never call the credit-claim RPC.
8. Remove one provider key in staging and confirm the remaining configured
   provider is selected without exposing either credential.
9. Confirm terminal jobs delete their private start-image object while the
   private generated result remains available through a signed URL.
10. Confirm the Google dynamic callback URI is exactly
    `${SUPABASE_URL}/functions/v1/generate-video?webhook=google`, and that its
    RS256 `Webhook-Signature` validates against Google's documented JWKS with
    that exact expected audience.
11. Confirm stale Google and OpenAI jobs with a provider request ID are claimed
    in batches of at most 20 by the five-minute cron, while accepted submissions
    without a returned ID remain reserved for the provider's 24-hour retry
    window. Verify the scheduled call succeeds only when Vault has exactly one
    non-empty `x5_video_reconcile_cron_secret` matching the Edge Function
    environment; missing, mismatched, or malformed state must fail closed with
    no batch claim.
12. Confirm a signed `video.generated` callback finalizes from its allowlisted
    HTTPS `output_file_uri`, or from a strict `files/<id>` `file_name` converted
    to Google's authenticated Files API download URL. A non-allowlisted URI must
    fall back to reconciliation and must never reach Storage.
13. Confirm the Google GET fallback accepts the documented inline base64 video
    without raising the old one-MiB JSON error: video bytes are decoded while
    streaming up to the same generated-video size limit, while all non-video
    JSON metadata remains capped at one MiB.
14. Force a Google `429 RESOURCE_EXHAUSTED` submit response and confirm the
    request switches to OpenAI before any Google provider request is accepted
    and without another credit reservation. Repeat with a definitive Google
    `403` and confirm the same result. Then fault the OpenAI submit and refund
    RPC: confirm three bounded immediate attempts occur and, if all fail, the
    service-only rejection marker is persisted and the five-minute postgres cron
    refunds it. Only transport failure, HTTP 408, and HTTP 5xx remain
    submission-ambiguous; they must never trigger another provider or receive
    this short-age rejection marker.
15. Confirm OpenAI receives only supported dimensions and duration values: X5's
    5-second option maps to a 4-second fallback clip, and the 10-second option
    maps to 8 seconds. Confirm completion is copied from the authenticated
    `/v1/videos/{id}/content` response into private X5 Storage.
16. Submit explicit Seedance 2.0 Fast text-to-video and image-to-video jobs for
    both supported aspect ratios. Confirm BytePlus receives only 5/10-second
    and 480p/720p allowlisted values, uses `content.image_url` for a private
    signed start image, and returns a `cgt-*` task whose result is copied from
    the allowlisted official `*.volces.com` host into private X5 Storage.
17. Confirm Seedance native audio follows the authenticated boolean request and
    that changing model, resolution, or audio with the same idempotency key
    returns an idempotency conflict instead of reusing a different semantic
    job.
18. Remove `ARK_API_KEY` in staging while leaving Fal/Google/OpenAI configured and
    request Seedance explicitly. Confirm the request fails before the credit
    claim. Restore `ARK_API_KEY`, force a definitive BytePlus `429`, and confirm the
    explicit Seedance job refunds exactly once without switching to another
    model.

Do not deploy from this task automatically; release only after the owning
workspace has reviewed the migration order, secrets, provider billing, and
staging evidence.
