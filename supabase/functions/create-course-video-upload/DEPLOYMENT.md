# Bunny Stream course videos — functions

Status 2026-10-01: implemented on branch `feature/bunny-stream-course-video`,
**not deployed**. Full ordered deploy steps, the token-authentication switch and
rollback: `docs/BUNNY-STREAM-HANDOFF.md`.

| Function                     | JWT at gateway             | Purpose                                                                                                                                                   |
| ---------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `create-course-video-upload` | on                         | Course author/developer gets a TUS signature for a new Bunny video (server-only broker RPCs, runtime flag `app_feature_flags.bunny_course_video_upload`). |
| `course-video-playback`      | off (verified inside)      | Entitlement check (`course_video_playback_grant`) → short-lived token-signed HLS URL. Guests only for free lessons.                                       |
| `course-video-status`        | off (each caller verified) | Bunny webhook (re-reads Bunny API), editor polling, pg_cron reconcile + cleanup (`X-X5-Reconcile-Secret`).                                                |

Edge Function secrets (values only in Supabase → Edge Functions → Secrets, never
in Git, logs or the apps): `BUNNY_STREAM_LIBRARY_ID`, `BUNNY_STREAM_API_KEY`,
`BUNNY_STREAM_CDN_HOSTNAME`, `BUNNY_STREAM_TOKEN_KEY`,
`COURSE_VIDEO_CRON_SECRET`; optional `BUNNY_STREAM_WEBHOOK_SECRET`,
`BUNNY_STREAM_PLAYBACK_TTL_SECONDS`, `BUNNY_STREAM_TUS_TTL_SECONDS`,
`BUNNY_STREAM_PLAYBACK_SIGNING` (`token` default; `none` only during the
documented switch window).

Local checks:

```bash
node --test supabase/functions/create-course-video-upload/*.test.mjs \
  supabase/functions/course-video-playback/*.test.mjs \
  supabase/functions/course-video-status/*.test.mjs
deno check supabase/functions/course-video-playback/index.ts
```

References: https://docs.bunny.net/stream/tus-resumable-uploads ·
https://docs.bunny.net/docs/cdn-token-authentication ·
https://docs.bunny.net/docs/stream-webhook
