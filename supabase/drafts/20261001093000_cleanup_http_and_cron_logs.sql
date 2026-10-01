-- DRAFT — NOT APPLIED. Daily cleanup of pg_net responses and pg_cron run
-- history older than 1 day.
--
-- Measured 2026-10-01: net._http_response 108 MB for only 434 rows (dead
-- tuples/TOAST bloat), cron.job_run_details 68 MB / ~334k rows — together
-- ~176 MB of the 204 MB database. Several jobs run every minute, so the run
-- history grows by ~5k rows/day.
--
-- This job keeps the tables small from now on. It does NOT give back disk
-- already used: after the first cleanup run, an operator should run once,
-- in a quiet window (takes an exclusive lock for a few seconds):
--   vacuum (full, analyze) net._http_response;
--   vacuum (full, analyze) cron.job_run_details;
-- (Supabase SQL editor as postgres; not inside a transaction.)

begin;

create or replace function public.x5_cleanup_http_and_cron_logs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_http bigint := 0;
  v_cron bigint := 0;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  delete from net._http_response
   where created < pg_catalog.now() - interval '1 day';
  get diagnostics v_http = row_count;

  delete from cron.job_run_details
   where end_time < pg_catalog.now() - interval '1 day'
      or (end_time is null and start_time < pg_catalog.now() - interval '1 day');
  get diagnostics v_cron = row_count;

  return jsonb_build_object('http_responses', v_http, 'cron_runs', v_cron);
end;
$function$;

revoke execute on function public.x5_cleanup_http_and_cron_logs()
  from public, anon, authenticated, service_role;
grant execute on function public.x5_cleanup_http_and_cron_logs()
  to postgres;

do $$
begin
  begin
    perform cron.unschedule('x5-cleanup-http-and-cron-logs');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-cleanup-http-and-cron-logs',
    '41 3 * * *',
    'select public.x5_cleanup_http_and_cron_logs();'
  );
end $$;

commit;

-- Rollback:
--   select cron.unschedule('x5-cleanup-http-and-cron-logs');
--   drop function if exists public.x5_cleanup_http_and_cron_logs();
