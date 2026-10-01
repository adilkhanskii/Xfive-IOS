-- DRAFT — NOT APPLIED. Schedules the Bunny course-video reconciler
-- (readiness fallback when a webhook is missed + cleanup of abandoned,
-- failed and unreferenced Bunny videos registered in course_video_assets).
--
-- Prerequisites (see docs/BUNNY-STREAM-HANDOFF.md):
--   * 20261001090000_course_video_assets.sql applied;
--   * Edge Function course-video-status deployed;
--   * Vault secret 'x5_course_video_cron_secret' (>= 32 random chars) and the
--     SAME value in Edge Function secret COURSE_VIDEO_CRON_SECRET.
-- The secret value never appears in this file.

begin;

create or replace function public.enqueue_course_video_reconciliation()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_secret text;
  v_secret_count bigint;
  v_request_id bigint;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  -- Nothing to do: avoid an HTTP call every 10 minutes forever.
  if not exists (
    select 1 from public.course_video_assets
     where status in ('creating', 'awaiting_upload', 'processing',
                      'ready', 'failed', 'deleting')
  ) then
    return null;
  end if;

  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_course_video_cron_secret';

  if v_secret_count <> 1
     or v_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_secret)) < 32 then
    raise exception using
      errcode = 'P0001', message = 'course_video_cron_secret_unavailable';
  end if;

  select net.http_post(
    url :=
      'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/course-video-status?reconcile=1',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-X5-Reconcile-Secret', v_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) into v_request_id;
  return v_request_id;
end;
$function$;

revoke execute on function public.enqueue_course_video_reconciliation()
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_course_video_reconciliation()
  to postgres;

do $$
begin
  begin
    perform cron.unschedule('x5-reconcile-course-videos');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-reconcile-course-videos',
    '*/10 * * * *',
    'select public.enqueue_course_video_reconciliation();'
  );
end $$;

commit;
