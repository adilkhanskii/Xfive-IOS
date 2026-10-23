-- Rotate video reconciliation away from a copied service-role credential.
-- The dedicated secret is provisioned independently in Vault and the Edge
-- Function environment; its value never appears in this migration or logs.

create or replace function public.enqueue_video_generation_reconciliation()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_reconcile_secret text;
  v_secret_count bigint;
  v_request_id bigint;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  select
    pg_catalog.count(*),
    pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_reconcile_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_video_reconcile_cron_secret';

  if v_secret_count <> 1
     or v_reconcile_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_reconcile_secret)) < 32 then
    raise exception using
      errcode = 'P0001', message = 'video_reconcile_cron_secret_unavailable';
  end if;

  select net.http_post(
    url :=
      'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/generate-video?reconcile=google',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-X5-Reconcile-Secret', v_reconcile_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  ) into v_request_id;
  return v_request_id;
end;
$function$;

revoke execute on function public.enqueue_video_generation_reconciliation()
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_video_generation_reconciliation()
  to postgres;
