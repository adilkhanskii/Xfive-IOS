-- Queue account deletion so private Storage bytes are removed through the
-- Storage API before and after deleting auth/profile rows. The durable job is
-- intentionally not foreign-keyed and doubles as a generation tombstone.

create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault with schema vault;

-- Release gate: the same random secret must already exist in Edge Function
-- secrets and Vault before this migration changes delete_own_account().
do $preflight$
declare
  v_secret_count bigint;
  v_cleanup_secret text;
begin
  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_cleanup_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_account_deletion_cleanup_secret';

  if v_secret_count <> 1
     or v_cleanup_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_cleanup_secret)) < 32 then
    raise exception using
      errcode = '55000',
      message = 'account_deletion_cleanup_vault_secret_required';
  end if;
end;
$preflight$;

revoke all on function public.x5_delete_eq_if_exists(text, text, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception using errcode = '42501', message = 'not_authenticated';
  end if;

  -- Serialize against a voice credit claim that is about to debit.
  perform 1
    from public.profiles as profile
   where profile.id = uid
   for update;

  insert into public.account_deletion_jobs as job (
    user_id,
    status,
    requested_at,
    not_before
  )
  values (uid, 'pending', now(), now())
  on conflict (user_id) do update
     set requested_at = least(job.requested_at, excluded.requested_at),
         not_before = least(job.not_before, excluded.not_before)
   where job.status <> 'completed';
end;
$function$;

revoke all on function public.delete_own_account()
  from public, anon, authenticated, service_role;
grant execute on function public.delete_own_account() to authenticated;

create or replace function public.claim_account_deletion_job(
  p_lease_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.account_deletion_jobs%rowtype;
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_lease');
  end if;
  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );

  select queued.*
    into job
    from public.account_deletion_jobs as queued
   where queued.status <> 'completed'
     and queued.not_before <= now()
     and (
       queued.lease_until is null
       or queued.lease_until <= now()
     )
   order by queued.requested_at
   for update skip locked
   limit 1;
  if not found then
    return jsonb_build_object('status', 'empty');
  end if;

  update public.account_deletion_jobs as queued
     set status = case
           when queued.status = 'pending' then 'pre_cleanup'
           else queued.status
         end,
         lease_token_hash = v_hash,
         lease_until = now() + interval '2 minutes',
         attempts = queued.attempts + 1,
         last_error = null
   where queued.user_id = job.user_id
  returning queued.* into job;

  return jsonb_build_object(
    'status', 'claimed',
    'user_id', job.user_id,
    'phase', job.status,
    'attempts', job.attempts
  );
end;
$function$;

create or replace function public.list_account_deletion_voice_paths(
  p_user_id uuid,
  p_after_name text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_paths jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_limit is null
     or p_limit < 1
     or p_limit > 1000
     or length(coalesce(p_after_name, '')) > 1024 then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  select coalesce(jsonb_agg(candidate.name order by candidate.name), '[]'::jsonb)
    into v_paths
    from (
      select object.name
        from storage.objects as object
       where object.bucket_id = 'voice-generation-results'
         and object.name like p_user_id::text || '/%'
         and object.name > coalesce(p_after_name, '')
       order by object.name
       limit p_limit
    ) as candidate;
  return jsonb_build_object('status', 'ok', 'paths', v_paths);
end;
$function$;

create or replace function public.finalize_queued_account_deletion(
  p_user_id uuid,
  p_lease_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.account_deletion_jobs%rowtype;
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );
  select queued.*
    into job
    from public.account_deletion_jobs as queued
   where queued.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if job.status <> 'pre_cleanup'
     or job.lease_token_hash is distinct from v_hash
     or job.lease_until is null
     or job.lease_until <= now() then
    return jsonb_build_object('status', 'lease_mismatch');
  end if;

  perform public.x5_delete_eq_if_exists('messages', 'sender_id', p_user_id);
  perform public.x5_delete_eq_if_exists(
    'task_responses', 'specialist_id', p_user_id
  );
  perform public.x5_delete_eq_if_exists(
    'task_responses', 'client_id', p_user_id
  );
  perform public.x5_delete_eq_if_exists('tasks', 'author_id', p_user_id);
  perform public.x5_delete_eq_if_exists(
    'portfolio_items', 'user_id', p_user_id
  );
  perform public.x5_delete_eq_if_exists('specialists', 'user_id', p_user_id);
  perform public.x5_delete_eq_if_exists('push_tokens', 'user_id', p_user_id);
  perform public.x5_delete_eq_if_exists(
    'notification_queue', 'to_user_id', p_user_id
  );
  perform public.x5_delete_eq_if_exists(
    'notification_queue', 'user_id', p_user_id
  );
  perform public.x5_delete_eq_if_exists(
    'course_submissions', 'authorId', p_user_id
  );
  perform public.x5_delete_eq_if_exists('courses', 'author_id', p_user_id);
  perform public.x5_delete_eq_if_exists('courses', 'user_id', p_user_id);

  begin
    delete from public.followers
     where follower_id = p_user_id or following_id = p_user_id;
  exception
    when undefined_table or undefined_column or undefined_function
      or datatype_mismatch or invalid_text_representation
      or foreign_key_violation then null;
  end;

  begin
    delete from public.chats where p_user_id = any(participants);
  exception
    when undefined_table or undefined_column or undefined_function
      or datatype_mismatch or invalid_text_representation
      or foreign_key_violation then
        begin
          delete from public.chats
           where p_user_id::text = any(participants);
        exception
          when undefined_table or undefined_column or undefined_function
            or datatype_mismatch or invalid_text_representation
            or foreign_key_violation then null;
        end;
  end;

  perform public.x5_delete_eq_if_exists('profiles', 'id', p_user_id);
  delete from auth.users as account where account.id = p_user_id;

  update public.account_deletion_jobs as queued
     set status = 'post_cleanup',
         not_before = now() + interval '15 minutes',
         lease_token_hash = null,
         lease_until = null,
         empty_passes = 0,
         last_error = null
   where queued.user_id = p_user_id;
  return jsonb_build_object('status', 'post_cleanup_scheduled');
end;
$function$;

-- If Storage succeeded but the final ledger RPC never became durable, the
-- four-hour ledger expiry refunds the request. Return only exact deterministic
-- object names for a currently refunded attempt or for an older attempt
-- superseded by a retry, so the worker can remove them via the Storage API
-- rather than mutating storage.objects with SQL.
create or replace function public.list_refunded_voice_orphan_paths(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_paths jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select coalesce(jsonb_agg(candidate.name order by candidate.name), '[]'::jsonb)
    into v_paths
    from (
      select object.name
        from public.voice_generation_requests as ledger
        join storage.objects as object
          on object.bucket_id = 'voice-generation-results'
         and object.name like
           ledger.user_id::text || '/explicit/' ||
           split_part(ledger.request_key, ':', 2) || '/%/audio.mp3'
       where (
         (
           ledger.status = 'refunded'
           and object.name =
             ledger.user_id::text || '/explicit/' ||
             split_part(ledger.request_key, ':', 2) || '/' ||
             ledger.attempt::text || '/audio.mp3'
         )
         or case
           when split_part(object.name, '/', 4) ~ '^[1-9][0-9]{0,8}$'
             then split_part(object.name, '/', 4)::integer < ledger.attempt
           else false
         end
       )
       order by object.name
       limit p_limit
    ) as candidate;
  return jsonb_build_object('status', 'ok', 'paths', v_paths);
end;
$function$;

create or replace function public.record_account_deletion_cleanup_pass(
  p_user_id uuid,
  p_lease_token text,
  p_deleted_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.account_deletion_jobs%rowtype;
  v_hash text;
  v_empty_passes integer;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or p_deleted_count is null
     or p_deleted_count < 0 then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );
  select queued.*
    into job
    from public.account_deletion_jobs as queued
   where queued.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if job.status <> 'post_cleanup'
     or job.lease_token_hash is distinct from v_hash
     or job.lease_until is null
     or job.lease_until <= now() then
    return jsonb_build_object('status', 'lease_mismatch');
  end if;

  v_empty_passes := case
    when p_deleted_count = 0 then job.empty_passes + 1
    else 0
  end;
  update public.account_deletion_jobs as queued
     set status = case
           when v_empty_passes >= 2 then 'completed'
           else 'post_cleanup'
         end,
         not_before = case
           when v_empty_passes >= 2 then queued.not_before
           else now() + interval '5 minutes'
         end,
         empty_passes = v_empty_passes,
         lease_token_hash = null,
         lease_until = null,
         completed_at = case
           when v_empty_passes >= 2 then now()
           else null
         end,
         last_error = null
   where queued.user_id = p_user_id;
  return jsonb_build_object(
    'status',
      case when v_empty_passes >= 2 then 'completed' else 'scheduled' end,
    'empty_passes', v_empty_passes
  );
end;
$function$;

create or replace function public.release_account_deletion_job(
  p_user_id uuid,
  p_lease_token text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );
  update public.account_deletion_jobs as queued
     set not_before = now() + case
           when p_error_code = 'cleanup_continuing' then interval '1 minute'
           else interval '5 minutes'
         end,
         lease_token_hash = null,
         lease_until = null,
         last_error = case
           when p_error_code = 'cleanup_continuing' then null
           else left(
             lower(coalesce(nullif(btrim(p_error_code), ''), 'worker_failed')),
             120
           )
         end
   where queued.user_id = p_user_id
     and queued.status <> 'completed'
     and queued.lease_token_hash = v_hash;
  return jsonb_build_object(
    'status', case when found then 'released' else 'lease_mismatch' end
  );
end;
$function$;

revoke all on function public.claim_account_deletion_job(text)
  from public, anon, authenticated, service_role;
revoke all on function public.list_account_deletion_voice_paths(
  uuid, text, integer
) from public, anon, authenticated, service_role;
revoke all on function public.finalize_queued_account_deletion(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.list_refunded_voice_orphan_paths(integer)
  from public, anon, authenticated, service_role;
revoke all on function public.record_account_deletion_cleanup_pass(
  uuid, text, integer
) from public, anon, authenticated, service_role;
revoke all on function public.release_account_deletion_job(uuid, text, text)
  from public, anon, authenticated, service_role;

grant execute on function public.claim_account_deletion_job(text)
  to service_role;
grant execute on function public.list_account_deletion_voice_paths(
  uuid, text, integer
) to service_role;
grant execute on function public.finalize_queued_account_deletion(uuid, text)
  to service_role;
grant execute on function public.list_refunded_voice_orphan_paths(integer)
  to service_role;
grant execute on function public.record_account_deletion_cleanup_pass(
  uuid, text, integer
) to service_role;
grant execute on function public.release_account_deletion_job(uuid, text, text)
  to service_role;

create or replace function public.enqueue_account_deletion_cleanup()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_cleanup_secret text;
  v_secret_count bigint;
  v_request_id bigint;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_cleanup_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_account_deletion_cleanup_secret';

  if v_secret_count <> 1
     or v_cleanup_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_cleanup_secret)) < 32 then
    raise exception using
      errcode = '55000',
      message = 'account_deletion_cleanup_vault_secret_required';
  end if;

  select net.http_post(
    url :=
      'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/account-deletion-cleanup',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Account-Deletion-Secret', v_cleanup_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) into v_request_id;
  return v_request_id;
end;
$function$;

revoke all on function public.enqueue_account_deletion_cleanup()
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_account_deletion_cleanup()
  to postgres;

do $cron$
begin
  begin
    perform cron.unschedule('x5-account-deletion-cleanup');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-account-deletion-cleanup',
    '* * * * *',
    'select public.enqueue_account_deletion_cleanup();'
  );
end;
$cron$;
