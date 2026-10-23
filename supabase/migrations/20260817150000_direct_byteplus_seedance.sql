-- Route explicit Seedance jobs through ByteDance's official international
-- ModelArk endpoint. Existing fal jobs stay immutable and remain reconcilable.

begin;

alter table public.video_generation_jobs
  drop constraint if exists video_generation_jobs_provider_kind_valid;

alter table public.video_generation_jobs
  add constraint video_generation_jobs_provider_kind_valid check (
    provider_name in ('byteplus', 'fal', 'google', 'openai')
    and provider_kind in ('text', 'image')
    and (has_start_image = (provider_kind = 'image'))
  ) not valid;

alter table public.video_generation_jobs
  validate constraint video_generation_jobs_provider_kind_valid;

drop index if exists public.video_generation_jobs_async_reconcile_idx;
create index video_generation_jobs_async_reconcile_idx
  on public.video_generation_jobs (
    coalesce(reconcile_attempted_at, submitted_at, updated_at)
  )
  where provider_name in ('byteplus', 'google', 'openai')
    and status in ('queued', 'rendering');

create or replace function public.claim_video_generation_job(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_cost_credits integer,
  p_has_start_image boolean,
  p_provider_name text,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_inserted boolean := false;
  v_credits integer;
  v_permanent_before integer;
  v_permanent_after integer;
  v_permanent_debited integer;
  v_debt_at_claim integer;
  v_expiry_before timestamptz;
  v_expiry_after timestamptz;
  v_claim_token_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_user_id is null
     or p_request_key is null
     or p_request_key !~ '^explicit:[0-9a-f]{64}$'
     or p_request_fingerprint is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_cost_credits not in (650, 1200)
     or p_has_start_image is null
     or p_provider_name not in ('byteplus', 'fal', 'google', 'openai')
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  v_claim_token_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
    'hex'
  );

  begin
    insert into public.video_generation_jobs as ledger (
      user_id, request_key, request_fingerprint, status, progress,
      cost_credits, has_start_image, provider_name, provider_kind,
      claim_token_hash
    )
    values (
      p_user_id, p_request_key, p_request_fingerprint, 'queued', 0,
      p_cost_credits, p_has_start_image, p_provider_name,
      case when p_has_start_image then 'image' else 'text' end,
      v_claim_token_hash
    )
    on conflict (user_id, request_key) do nothing
    returning ledger.* into request;
    v_inserted := found;
  exception when foreign_key_violation then
    return jsonb_build_object('status', 'profile_not_found');
  end;

  if not v_inserted then
    select ledger.*
      into request
      from public.video_generation_jobs as ledger
     where ledger.user_id = p_user_id
       and ledger.request_key = p_request_key
     for update;

    if not found then
      return jsonb_build_object('status', 'credit_service_unavailable');
    end if;
    if request.request_fingerprint <> p_request_fingerprint
       or request.cost_credits <> p_cost_credits
       or request.has_start_image <> p_has_start_image then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    return jsonb_build_object(
      'status', 'replay',
      'job_id', request.id,
      'job_status', request.status,
      'progress', request.progress,
      'credits_remaining', request.credits_after_reserve,
      'refunded', request.refunded_at is not null
    );
  end if;

  select
    coalesce(profile.credits, 0),
    greatest(coalesce(profile.permanent_credits, 0), 0),
    greatest(coalesce(profile.permanent_credit_debt, 0), 0),
    profile.credits_expires_at
    into v_credits, v_permanent_before, v_debt_at_claim, v_expiry_before
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    delete from public.video_generation_jobs as ledger
     where ledger.id = request.id;
    return jsonb_build_object('status', 'profile_not_found');
  end if;

  if v_credits < p_cost_credits then
    delete from public.video_generation_jobs as ledger
     where ledger.id = request.id;
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'credits_remaining', v_credits
    );
  end if;

  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) - p_cost_credits
   where profile.id = p_user_id
  returning
    profile.credits,
    profile.permanent_credits,
    profile.credits_expires_at
    into v_credits, v_permanent_after, v_expiry_after;

  v_permanent_debited := greatest(
    v_permanent_before - greatest(coalesce(v_permanent_after, 0), 0),
    0
  );

  update public.video_generation_jobs as ledger
     set credits_after_reserve = v_credits,
         permanent_credits_debited = v_permanent_debited,
         permanent_credit_debt_at_claim = v_debt_at_claim,
         credits_expires_at_before_debit = v_expiry_before,
         credits_expires_at_after_debit = v_expiry_after,
         updated_at = now()
   where ledger.id = request.id
  returning ledger.* into request;

  return jsonb_build_object(
    'status', 'claimed',
    'job_id', request.id,
    'job_status', request.status,
    'progress', request.progress,
    'credits_remaining', request.credits_after_reserve,
    'refunded', false
  );
end;
$function$;

create or replace function public.claim_video_generation_reconciliation_batch(
  p_limit integer default 20,
  p_stale_after interval default interval '2 minutes',
  p_max_age interval default interval '24 hours'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_jobs jsonb := '[]'::jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null
     or p_limit < 1
     or p_limit > 20
     or p_stale_after is null
     or p_stale_after < interval '1 minute'
     or p_stale_after > interval '1 hour'
     or p_max_age is null
     or p_max_age < interval '1 hour'
     or p_max_age > interval '48 hours' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  for request in
    select ledger.*
      from public.video_generation_jobs as ledger
     where ledger.provider_name in ('byteplus', 'google', 'openai')
       and ledger.status in ('queued', 'rendering')
       and (
         (
           ledger.provider_request_id is not null
           and coalesce(
             ledger.reconcile_attempted_at,
             ledger.submitted_at,
             ledger.updated_at
           ) <= now() - p_stale_after
         )
         or (
           ledger.provider_request_id is null
           and ledger.created_at <= now() - p_max_age
         )
       )
     order by
       (ledger.created_at <= now() - p_max_age) desc,
       coalesce(
         ledger.reconcile_attempted_at,
         ledger.submitted_at,
         ledger.updated_at
       )
     limit p_limit
     for update skip locked
  loop
    update public.video_generation_jobs as ledger
       set reconcile_attempted_at = now()
     where ledger.id = request.id;

    v_jobs := v_jobs || jsonb_build_array(jsonb_strip_nulls(
      jsonb_build_object(
        'id', request.id,
        'user_id', request.user_id,
        'job_status', request.status,
        'status', request.status,
        'progress', request.progress,
        'provider_name', request.provider_name,
        'provider_kind', request.provider_kind,
        'provider_request_id', request.provider_request_id,
        'input_object_path', request.input_object_path,
        'created_at', request.created_at,
        'updated_at', request.updated_at,
        'max_age_exceeded', request.created_at <= now() - p_max_age
      )
    ));
  end loop;

  return jsonb_build_object('status', 'claimed', 'jobs', v_jobs);
end;
$function$;

create or replace function public.reconcile_stale_video_generation_jobs(
  p_stale_after interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_reconciled integer := 0;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;
  if p_stale_after is null
     or p_stale_after < interval '5 minutes'
     or p_stale_after > interval '24 hours' then
    raise exception using errcode = '22023', message = 'invalid_stale_interval';
  end if;

  for request in
    select ledger.*
      from public.video_generation_jobs as ledger
     where ledger.status = 'queued'
       and ledger.provider_request_id is null
       and (
         ledger.submission_rejected_at is not null
         or (
           ledger.submission_rejected_at is null
           and ledger.provider_name not in ('byteplus', 'google', 'openai')
           and ledger.updated_at <= now() - p_stale_after
         )
       )
     order by coalesce(ledger.submission_rejected_at, ledger.updated_at)
     for update skip locked
  loop
    perform public.x5_restore_video_generation_credits(request.id);
    update public.video_generation_jobs as ledger
       set status = 'failed',
           progress = 1,
           error_code = coalesce(
             ledger.submission_rejection_code,
             'submission_orphan_reconciled'
           ),
           refunded_at = now(),
           updated_at = now()
     where ledger.id = request.id
       and ledger.status = 'queued'
       and ledger.provider_request_id is null
       and (
         ledger.submission_rejected_at is not null
         or (
           ledger.submission_rejected_at is null
           and ledger.provider_name not in ('byteplus', 'google', 'openai')
           and ledger.updated_at <= now() - p_stale_after
         )
       )
       and ledger.refunded_at is null;
    if found then
      v_reconciled := v_reconciled + 1;
    end if;
  end loop;

  return v_reconciled;
end;
$function$;

revoke execute on function public.claim_video_generation_job(
  uuid, text, text, integer, boolean, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.claim_video_generation_reconciliation_batch(
  integer, interval, interval
) from public, anon, authenticated, service_role;
revoke execute on function public.reconcile_stale_video_generation_jobs(
  interval
) from public, anon, authenticated, service_role;

grant execute on function public.claim_video_generation_job(
  uuid, text, text, integer, boolean, text, text
) to service_role;
grant execute on function public.claim_video_generation_reconciliation_batch(
  integer, interval, interval
) to service_role;

commit;
