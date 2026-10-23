-- Private, idempotent accounting and state for asynchronous video jobs.
-- Raw prompts, reference bytes, provider response URLs, and signed URLs never
-- enter Postgres. The Edge Function is the only writer and returns a bounded
-- public projection to the authenticated owner.

create extension if not exists pg_net;
create extension if not exists supabase_vault with schema vault;

create table public.video_generation_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_key text not null,
  request_fingerprint text not null,
  status text not null default 'queued',
  progress numeric(4, 3) not null default 0,
  cost_credits integer not null,
  credits_after_reserve integer,
  permanent_credits_debited integer not null default 0,
  permanent_credit_debt_at_claim integer not null default 0,
  credits_expires_at_before_debit timestamptz,
  credits_expires_at_after_debit timestamptz,
  has_start_image boolean not null default false,
  provider_name text not null,
  provider_kind text not null,
  provider_request_id text,
  claim_token_hash text not null,
  input_object_path text,
  result_object_path text,
  result_sha256 text,
  result_mime_type text,
  error_code text,
  submission_rejected_at timestamptz,
  submission_rejection_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  reconcile_attempted_at timestamptz,
  completed_at timestamptz,
  refunded_at timestamptz,
  constraint video_generation_jobs_user_request_unique
    unique (user_id, request_key),
  constraint video_generation_jobs_provider_request_unique
    unique (provider_request_id),
  constraint video_generation_jobs_request_key_valid check (
    request_key ~ '^explicit:[0-9a-f]{64}$'
  ),
  constraint video_generation_jobs_fingerprint_valid check (
    request_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint video_generation_jobs_status_valid check (
    status in ('queued', 'rendering', 'completed', 'failed')
  ),
  constraint video_generation_jobs_progress_valid check (
    progress between 0 and 1
  ),
  constraint video_generation_jobs_cost_valid check (
    cost_credits in (650, 1200)
    and permanent_credits_debited between 0 and cost_credits
    and permanent_credit_debt_at_claim >= 0
  ),
  constraint video_generation_jobs_provider_kind_valid check (
    provider_name in ('fal', 'google')
    and provider_kind in ('text', 'image')
    and (has_start_image = (provider_kind = 'image'))
  ),
  constraint video_generation_jobs_provider_request_valid check (
    provider_request_id is null
    or provider_request_id ~ '^[A-Za-z0-9_-]{8,200}$'
  ),
  constraint video_generation_jobs_claim_token_hash_valid check (
    claim_token_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint video_generation_jobs_error_code_valid check (
    error_code is null or error_code ~ '^[a-z0-9_:-]{1,80}$'
  ),
  constraint video_generation_jobs_submission_rejection_valid check (
    (
      submission_rejected_at is null
      and submission_rejection_code is null
    )
    or (
      submission_rejected_at is not null
      and submission_rejection_code ~ '^[a-z0-9_:-]{1,80}$'
    )
  ),
  constraint video_generation_jobs_result_valid check (
    (
      status = 'completed'
      and progress = 1
      and completed_at is not null
      and refunded_at is null
      and result_object_path is not null
      and result_sha256 ~ '^[0-9a-f]{64}$'
      and result_mime_type = 'video/mp4'
      and error_code is null
    )
    or (
      status = 'failed'
      and progress = 1
      and completed_at is null
      and refunded_at is not null
      and result_object_path is null
      and result_sha256 is null
      and result_mime_type is null
      and error_code is not null
    )
    or (
      status in ('queued', 'rendering')
      and progress < 1
      and completed_at is null
      and refunded_at is null
      and result_object_path is null
      and result_sha256 is null
      and result_mime_type is null
      and error_code is null
    )
  )
);

create index video_generation_jobs_owner_updated_idx
  on public.video_generation_jobs (user_id, updated_at desc);
create index video_generation_jobs_orphaned_queue_idx
  on public.video_generation_jobs (updated_at)
  where status = 'queued' and provider_request_id is null;
create index video_generation_jobs_rejected_queue_idx
  on public.video_generation_jobs (submission_rejected_at)
  where status = 'queued'
    and provider_request_id is null
    and submission_rejected_at is not null;
create index video_generation_jobs_google_reconcile_idx
  on public.video_generation_jobs (
    coalesce(reconcile_attempted_at, submitted_at, updated_at)
  )
  where provider_name = 'google'
    and status in ('queued', 'rendering');

comment on table public.video_generation_jobs is
  'Private service ledger for asynchronous video generation, exactly-once debit/refund, and owner status.';
comment on column public.video_generation_jobs.request_fingerprint is
  'SHA-256 of normalized semantic inputs; never raw prompt or image bytes.';
comment on column public.video_generation_jobs.result_object_path is
  'Private Storage path. Clients receive only a short-lived signed URL.';

alter table public.video_generation_jobs enable row level security;
alter table public.video_generation_jobs force row level security;
revoke all on table public.video_generation_jobs
  from public, anon, authenticated, service_role;

create policy video_generation_jobs_owner_select_policy
on public.video_generation_jobs
for select
to authenticated
using ((select auth.uid()) = user_id);

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values
  (
    'video-generation-inputs',
    'video-generation-inputs',
    false,
    8388608,
    array['image/jpeg', 'image/png', 'image/webp']::text[]
  ),
  (
    'video-generation-results',
    'video-generation-results',
    false,
    52428800,
    array['video/mp4']::text[]
  )
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

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
     or p_provider_name not in ('fal', 'google')
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

create or replace function public.switch_video_generation_provider(
  p_job_id uuid,
  p_user_id uuid,
  p_claim_token text,
  p_expected_provider_name text,
  p_new_provider_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
     and ledger.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.provider_request_id is not null then
    return jsonb_build_object('status', 'already_submitted');
  end if;
  if p_expected_provider_name <> 'fal'
     or p_new_provider_name <> 'google'
     or p_expected_provider_name = p_new_provider_name then
    return jsonb_build_object('status', 'invalid_provider_switch');
  end if;
  if p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_claim');
  end if;
  if request.submission_rejected_at is not null then
    return jsonb_build_object('status', 'submission_rejected');
  end if;
  if request.status <> 'queued' then
    return jsonb_build_object('status', 'not_queued');
  end if;
  if request.provider_name = p_new_provider_name then
    return jsonb_build_object('status', 'already_switched');
  end if;
  if request.provider_name <> p_expected_provider_name then
    return jsonb_build_object('status', 'provider_conflict');
  end if;

  update public.video_generation_jobs as ledger
     set provider_name = p_new_provider_name,
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'switched');
end;
$function$;

create or replace function public.record_video_generation_input(
  p_job_id uuid,
  p_user_id uuid,
  p_claim_token text,
  p_input_object_path text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_expected_input text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
     and ledger.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_claim');
  end if;

  v_expected_input := request.user_id::text || '/' ||
    request.id::text || '/start.' ||
    case
      when p_input_object_path like '%.jpg' then 'jpg'
      when p_input_object_path like '%.png' then 'png'
      when p_input_object_path like '%.webp' then 'webp'
      else 'invalid'
    end;
  if not request.has_start_image
     or p_input_object_path is null
     or p_input_object_path <> v_expected_input
     or p_input_object_path like '%..%'
     or p_input_object_path like E'%\\%' then
    return jsonb_build_object('status', 'invalid_input_object');
  end if;

  if request.input_object_path is not null then
    if request.input_object_path = p_input_object_path then
      return jsonb_build_object('status', 'already_recorded');
    end if;
    return jsonb_build_object('status', 'input_object_conflict');
  end if;
  if request.status <> 'queued'
     or request.provider_request_id is not null then
    return jsonb_build_object('status', 'not_queued');
  end if;

  update public.video_generation_jobs as ledger
     set input_object_path = p_input_object_path,
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'recorded');
end;
$function$;

create or replace function public.mark_video_generation_submitted(
  p_job_id uuid,
  p_user_id uuid,
  p_claim_token text,
  p_provider_request_id text,
  p_input_object_path text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_expected_input text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
     and ledger.user_id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_claim');
  end if;
  if p_provider_request_id is null
     or p_provider_request_id !~ '^[A-Za-z0-9_-]{8,200}$' then
    return jsonb_build_object('status', 'invalid_provider_request');
  end if;

  v_expected_input := request.user_id::text || '/' ||
    request.id::text || '/start.' ||
    case
      when p_input_object_path like '%.jpg' then 'jpg'
      when p_input_object_path like '%.png' then 'png'
      when p_input_object_path like '%.webp' then 'webp'
      else 'invalid'
    end;
  if (
    request.has_start_image
    and (
      p_input_object_path is null
      or p_input_object_path <> v_expected_input
      or p_input_object_path like '%..%'
      or p_input_object_path like E'%\\%'
    )
  ) or (
    not request.has_start_image and p_input_object_path is not null
  ) then
    return jsonb_build_object('status', 'invalid_input_object');
  end if;
  if request.input_object_path is not null
     and request.input_object_path is distinct from p_input_object_path then
    return jsonb_build_object('status', 'input_object_conflict');
  end if;

  if request.provider_request_id is not null then
    if request.provider_request_id = p_provider_request_id then
      return jsonb_build_object('status', 'already_submitted');
    end if;
    return jsonb_build_object('status', 'submission_conflict');
  end if;
  if request.submission_rejected_at is not null then
    return jsonb_build_object('status', 'submission_rejected');
  end if;
  if request.status <> 'queued' then
    return jsonb_build_object('status', 'not_queued');
  end if;

  update public.video_generation_jobs as ledger
     set provider_request_id = p_provider_request_id,
         input_object_path = coalesce(
           ledger.input_object_path,
           p_input_object_path
         ),
         progress = greatest(ledger.progress, 0.05),
         submitted_at = now(),
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'submitted');
exception when unique_violation then
  return jsonb_build_object('status', 'provider_request_conflict');
end;
$function$;

create or replace function public.bind_google_video_generation_webhook(
  p_job_id uuid,
  p_claim_token text,
  p_provider_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_job_id is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or p_provider_request_id is null
     or p_provider_request_id !~ '^[A-Za-z0-9_-]{8,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_claim');
  end if;
  if request.provider_name <> 'google' then
    return jsonb_build_object('status', 'provider_conflict');
  end if;
  if request.provider_request_id is not null then
    if request.provider_request_id <> p_provider_request_id then
      return jsonb_build_object('status', 'submission_conflict');
    end if;
    if request.status in ('completed', 'failed') then
      return jsonb_build_object('status', 'already_terminal');
    end if;
    return jsonb_build_object('status', 'already_bound');
  end if;
  if request.submission_rejected_at is not null then
    return jsonb_build_object('status', 'submission_rejected');
  end if;
  if request.status in ('completed', 'failed') then
    return jsonb_build_object('status', 'terminal_conflict');
  end if;

  update public.video_generation_jobs as ledger
     set provider_request_id = p_provider_request_id,
         progress = greatest(ledger.progress, 0.05),
         submitted_at = coalesce(ledger.submitted_at, now()),
         reconcile_attempted_at = null,
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'bound');
exception when unique_violation then
  return jsonb_build_object('status', 'provider_request_conflict');
end;
$function$;

create or replace function public.mark_video_generation_rendering(
  p_job_id uuid,
  p_provider_request_id text,
  p_progress numeric default 0.5
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_progress numeric := least(greatest(coalesce(p_progress, 0.5), 0.05), 0.95);
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'stale_provider_request');
  end if;
  if request.status in ('completed', 'failed') then
    return jsonb_build_object('status', 'already_terminal');
  end if;

  update public.video_generation_jobs as ledger
     set status = 'rendering',
         progress = greatest(ledger.progress, v_progress),
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'rendering');
end;
$function$;

create or replace function public.complete_video_generation_job(
  p_job_id uuid,
  p_provider_request_id text,
  p_result_object_path text,
  p_result_sha256 text,
  p_result_mime_type text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_expected_path text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'stale_provider_request');
  end if;

  v_expected_path := request.user_id::text || '/' ||
    request.id::text || '/result.mp4';
  if p_result_object_path is null
     or p_result_object_path <> v_expected_path
     or p_result_object_path like '%..%'
     or p_result_object_path like E'%\\%'
     or p_result_sha256 is null
     or p_result_sha256 !~ '^[0-9a-f]{64}$'
     or p_result_mime_type <> 'video/mp4' then
    return jsonb_build_object('status', 'invalid_result');
  end if;

  if request.status = 'completed' then
    if request.result_object_path = p_result_object_path
       and request.result_sha256 = p_result_sha256
       and request.result_mime_type = p_result_mime_type then
      return jsonb_build_object('status', 'already_completed');
    end if;
    return jsonb_build_object('status', 'completion_conflict');
  end if;
  if request.status = 'failed' then
    return jsonb_build_object('status', 'already_failed');
  end if;

  update public.video_generation_jobs as ledger
     set status = 'completed',
         progress = 1,
         result_object_path = p_result_object_path,
         result_sha256 = p_result_sha256,
         result_mime_type = p_result_mime_type,
         error_code = null,
         completed_at = now(),
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'completed');
end;
$function$;

-- Existing profile triggers classify positive balance deltas as new expiring
-- credits. A refund must instead reverse the exact timed/permanent split that
-- this video reservation consumed.
create or replace function public.x5_apply_video_generation_credit_restoration()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_marker text := nullif(
    current_setting('x5.video_generation_restore_job', true),
    ''
  );
  v_new_debt_since_claim integer;
  v_debt_repaid integer;
  v_permanent_restored integer;
begin
  if current_user <> 'postgres'
     or v_marker is null
     or v_marker !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    return new;
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = v_marker::uuid
     and ledger.user_id = new.id
     and ledger.status in ('queued', 'rendering')
     and ledger.refunded_at is null;
  if not found then
    return new;
  end if;

  v_new_debt_since_claim := greatest(
    greatest(coalesce(old.permanent_credit_debt, 0), 0) -
      request.permanent_credit_debt_at_claim,
    0
  );
  v_debt_repaid := least(
    request.permanent_credits_debited,
    v_new_debt_since_claim
  );
  v_permanent_restored :=
    request.permanent_credits_debited - v_debt_repaid;

  new.permanent_credit_debt := greatest(
    coalesce(old.permanent_credit_debt, 0) - v_debt_repaid,
    0
  );
  new.permanent_credits := least(
    greatest(coalesce(new.credits, 0), 0),
    greatest(coalesce(old.permanent_credits, 0), 0) +
      v_permanent_restored
  );

  if old.credits_expires_at is not distinct from
       request.credits_expires_at_after_debit then
    new.credits_expires_at := request.credits_expires_at_before_debit;
  else
    new.credits_expires_at := old.credits_expires_at;
  end if;
  if coalesce(new.credits, 0) - new.permanent_credits <= 0 then
    new.credits_expires_at := null;
  end if;

  return new;
end;
$function$;

revoke execute on function
  public.x5_apply_video_generation_credit_restoration()
  from public, anon, authenticated, service_role;

drop trigger if exists zz_x5_restore_video_generation_credits
  on public.profiles;
create trigger zz_x5_restore_video_generation_credits
before update of
  credits, permanent_credits, permanent_credit_debt, credits_expires_at
on public.profiles
for each row
execute function public.x5_apply_video_generation_credit_restoration();

create or replace function public.x5_restore_video_generation_credits(
  p_job_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_credits integer;
begin
  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;

  if not found
     or request.status not in ('queued', 'rendering')
     or request.refunded_at is not null then
    raise exception using
      errcode = 'P0001', message = 'video_job_not_refundable';
  end if;

  perform pg_catalog.set_config(
    'x5.video_generation_restore_job', request.id::text, true
  );
  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) + request.cost_credits
   where profile.id = request.user_id
  returning profile.credits into v_credits;
  perform pg_catalog.set_config(
    'x5.video_generation_restore_job', '', true
  );
  if not found then
    raise exception using
      errcode = 'P0001', message = 'video_generation_profile_missing';
  end if;
  return v_credits;
exception when others then
  perform pg_catalog.set_config(
    'x5.video_generation_restore_job', '', true
  );
  raise;
end;
$function$;

revoke execute on function public.x5_restore_video_generation_credits(uuid)
  from public, anon, authenticated, service_role;

-- This outbox marker is written only after a synchronous, definitive provider
-- rejection. Transport/408/5xx ambiguity never calls it, so the fast postgres
-- sweep cannot refund a request that the provider may already have accepted.
create or replace function public.mark_video_generation_submission_rejected(
  p_job_id uuid,
  p_claim_token text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_error_code text := lower(
    coalesce(nullif(btrim(p_error_code), ''), 'provider_submission_failed')
  );
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_job_id is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  if v_error_code !~ '^[a-z0-9_:-]{1,80}$' then
    v_error_code := 'provider_submission_failed';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_claim');
  end if;
  if request.status = 'completed' then
    return jsonb_build_object('status', 'already_completed');
  end if;
  if request.refunded_at is not null then
    return jsonb_build_object('status', 'already_refunded');
  end if;
  if request.provider_request_id is not null
     or request.submitted_at is not null
     or request.status = 'rendering' then
    return jsonb_build_object('status', 'submission_exists');
  end if;
  if request.status <> 'queued' then
    return jsonb_build_object('status', 'invalid_state');
  end if;
  if request.submission_rejected_at is not null then
    return jsonb_build_object('status', 'already_marked');
  end if;

  update public.video_generation_jobs as ledger
     set submission_rejected_at = now(),
         submission_rejection_code = v_error_code,
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object('status', 'marked');
end;
$function$;

create or replace function public.fail_video_generation_job(
  p_job_id uuid,
  p_provider_request_id text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
  v_error_code text := lower(
    coalesce(nullif(btrim(p_error_code), ''), 'generation_failed')
  );
  v_credits integer;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if v_error_code !~ '^[a-z0-9_:-]{1,80}$' then
    v_error_code := 'generation_failed';
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where ledger.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.provider_request_id is not null
     and request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'stale_provider_request');
  end if;
  if request.status = 'completed' then
    return jsonb_build_object('status', 'already_completed');
  end if;
  if request.refunded_at is not null then
    return jsonb_build_object(
      'status', 'already_refunded',
      'refunded', true
    );
  end if;

  v_credits := public.x5_restore_video_generation_credits(request.id);
  update public.video_generation_jobs as ledger
     set status = 'failed',
         progress = 1,
         provider_request_id = coalesce(
           ledger.provider_request_id,
           p_provider_request_id
         ),
         submitted_at = coalesce(
           ledger.submitted_at,
           case when p_provider_request_id is not null then now() end
         ),
         result_object_path = null,
         result_sha256 = null,
         result_mime_type = null,
         error_code = v_error_code,
         completed_at = null,
         refunded_at = now(),
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object(
    'status', 'failed',
    'refunded', true,
    'credits_remaining', v_credits
  );
end;
$function$;

create or replace function public.get_video_generation_job_service(
  p_job_id uuid default null,
  p_user_id uuid default null,
  p_provider_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.video_generation_jobs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_job_id is null and p_provider_request_id is null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select ledger.*
    into request
    from public.video_generation_jobs as ledger
   where (p_job_id is null or ledger.id = p_job_id)
     and (p_user_id is null or ledger.user_id = p_user_id)
     and (
       p_provider_request_id is null
       or ledger.provider_request_id = p_provider_request_id
     );
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'found',
    'id', request.id,
    'user_id', request.user_id,
    'job_status', request.status,
    'progress', request.progress,
    'cost_credits', request.cost_credits,
    'provider_name', request.provider_name,
    'provider_kind', request.provider_kind,
    'provider_request_id', request.provider_request_id,
    'input_object_path', request.input_object_path,
    'result_object_path', request.result_object_path,
    'result_sha256', request.result_sha256,
    'result_mime_type', request.result_mime_type,
    'error_code', request.error_code,
    'created_at', request.created_at,
    'updated_at', request.updated_at,
    'refunded_at', request.refunded_at
  ));
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
     where ledger.provider_name = 'google'
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
           and ledger.provider_name <> 'google'
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
           and ledger.provider_name <> 'google'
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
revoke execute on function public.switch_video_generation_provider(
  uuid, uuid, text, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_video_generation_submitted(
  uuid, uuid, text, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.record_video_generation_input(
  uuid, uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.bind_google_video_generation_webhook(
  uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_video_generation_rendering(
  uuid, text, numeric
) from public, anon, authenticated, service_role;
revoke execute on function public.complete_video_generation_job(
  uuid, text, text, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.fail_video_generation_job(
  uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_video_generation_submission_rejected(
  uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.get_video_generation_job_service(
  uuid, uuid, text
) from public, anon, authenticated, service_role;
revoke execute on function public.reconcile_stale_video_generation_jobs(
  interval
) from public, anon, authenticated, service_role;
revoke execute on function public.claim_video_generation_reconciliation_batch(
  integer, interval, interval
) from public, anon, authenticated, service_role;

grant execute on function public.claim_video_generation_job(
  uuid, text, text, integer, boolean, text, text
) to service_role;
grant execute on function public.switch_video_generation_provider(
  uuid, uuid, text, text, text
) to service_role;
grant execute on function public.mark_video_generation_submitted(
  uuid, uuid, text, text, text
) to service_role;
grant execute on function public.record_video_generation_input(
  uuid, uuid, text, text
) to service_role;
grant execute on function public.bind_google_video_generation_webhook(
  uuid, text, text
) to service_role;
grant execute on function public.mark_video_generation_rendering(
  uuid, text, numeric
) to service_role;
grant execute on function public.complete_video_generation_job(
  uuid, text, text, text, text
) to service_role;
grant execute on function public.fail_video_generation_job(
  uuid, text, text
) to service_role;
grant execute on function public.mark_video_generation_submission_rejected(
  uuid, text, text
) to service_role;
grant execute on function public.get_video_generation_job_service(
  uuid, uuid, text
) to service_role;
grant execute on function public.reconcile_stale_video_generation_jobs(
  interval
) to postgres;
grant execute on function public.claim_video_generation_reconciliation_batch(
  integer, interval, interval
) to service_role;

create or replace function public.enqueue_video_generation_reconciliation()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_service_role_key text;
  v_secret_count bigint;
  v_request_id bigint;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  select
    pg_catalog.count(*),
    pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_service_role_key
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_video_reconcile_service_role_key';

  if v_secret_count <> 1
     or v_service_role_key is null
     or pg_catalog.length(pg_catalog.btrim(v_service_role_key)) < 32 then
    raise exception using
      errcode = '55000',
      message = 'service_role_key_vault_secret_required';
  end if;

  select net.http_post(
    url :=
      'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/generate-video?reconcile=google',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key,
      'apikey', v_service_role_key
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

do $cron$
begin
  begin
    perform cron.unschedule('x5-reconcile-orphaned-video-generations');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-reconcile-orphaned-video-generations',
    '*/5 * * * *',
    'select public.reconcile_stale_video_generation_jobs(interval ''15 minutes'');'
  );
end;
$cron$;

do $google_cron$
begin
  begin
    perform cron.unschedule('x5-reconcile-google-video-generations');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-reconcile-google-video-generations',
    '*/5 * * * *',
    'select public.enqueue_video_generation_reconciliation();'
  );
end;
$google_cron$;
