-- Private exact-once ledger and Storage bucket for ElevenLabs speech results.
-- Raw text and provider URLs are never stored in Postgres.

create table if not exists public.account_deletion_jobs (
  user_id uuid primary key,
  status text not null default 'pending',
  requested_at timestamptz not null default now(),
  not_before timestamptz not null default now(),
  lease_token_hash text,
  lease_until timestamptz,
  attempts integer not null default 0,
  empty_passes integer not null default 0,
  last_error text,
  completed_at timestamptz,
  constraint account_deletion_jobs_status_valid check (
    status in ('pending', 'pre_cleanup', 'post_cleanup', 'completed')
  ),
  constraint account_deletion_jobs_lease_valid check (
    (lease_token_hash is null and lease_until is null)
    or (
      lease_token_hash ~ '^[0-9a-f]{64}$'
      and lease_until is not null
    )
  )
);

alter table public.account_deletion_jobs enable row level security;
alter table public.account_deletion_jobs force row level security;
revoke all on table public.account_deletion_jobs
  from public, anon, authenticated, service_role;

create table public.voice_generation_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_key text not null,
  request_fingerprint text not null,
  status text not null default 'processing',
  cost_credits integer not null,
  credits_after_debit integer,
  permanent_credits_debited integer not null default 0,
  permanent_credit_debt_at_claim integer not null default 0,
  credits_expires_at_before_debit timestamptz,
  credits_expires_at_after_debit timestamptz,
  attempt integer not null default 1,
  claim_token_hash text not null,
  provider_request_id text,
  provider_submitted_at timestamptz,
  submission_ambiguous_at timestamptz,
  submission_rejected_at timestamptz,
  result_manifest jsonb,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  refunded_at timestamptz,
  constraint voice_generation_requests_user_key_unique
    unique (user_id, request_key),
  constraint voice_generation_requests_provider_request_unique
    unique (provider_request_id),
  constraint voice_generation_requests_key_valid check (
    request_key ~ '^explicit:[0-9a-f]{64}$'
  ),
  constraint voice_generation_requests_fingerprint_valid check (
    request_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint voice_generation_requests_status_valid check (
    status in ('processing', 'succeeded', 'refunded')
  ),
  constraint voice_generation_requests_cost_valid check (
    cost_credits between 60 and 300
    and cost_credits % 60 = 0
    and permanent_credits_debited between 0 and cost_credits
    and permanent_credit_debt_at_claim >= 0
  ),
  constraint voice_generation_requests_attempt_valid check (attempt > 0),
  constraint voice_generation_requests_claim_token_hash_valid check (
    claim_token_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint voice_generation_requests_provider_request_valid check (
    provider_request_id is null
    or provider_request_id ~ '^[A-Za-z0-9_-]{8,200}$'
  ),
  constraint voice_generation_requests_terminal_state_valid check (
    (status = 'processing' and completed_at is null and refunded_at is null)
    or (status = 'succeeded' and completed_at is not null and refunded_at is null)
    or (status = 'refunded' and completed_at is null and refunded_at is not null)
  )
);

create index voice_generation_requests_stale_idx
  on public.voice_generation_requests (updated_at)
  where status = 'processing';

comment on table public.voice_generation_requests is
  'Private service ledger for exactly-once voice generation debits, replay, and refunds.';
comment on column public.voice_generation_requests.request_fingerprint is
  'SHA-256 of normalized speech inputs; never raw text.';
comment on column public.voice_generation_requests.result_manifest is
  'Minimal private Storage object manifest; never a provider URL or audio bytes.';

alter table public.voice_generation_requests enable row level security;
alter table public.voice_generation_requests force row level security;
revoke all on table public.voice_generation_requests
  from public, anon, authenticated, service_role;

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'voice-generation-results',
  'voice-generation-results',
  false,
  20971520,
  array['audio/mpeg']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.claim_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_cost_credits integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
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
     or p_request_fingerprint is null
     or p_cost_credits is null
     or p_cost_credits not between 60 and 300
     or p_cost_credits % 60 <> 0
     or p_request_key !~ '^explicit:[0-9a-f]{64}$'
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;

  v_claim_token_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
    'hex'
  );

  begin
    insert into public.voice_generation_requests as ledger (
      user_id,
      request_key,
      request_fingerprint,
      status,
      cost_credits,
      claim_token_hash
    )
    values (
      p_user_id,
      p_request_key,
      p_request_fingerprint,
      'processing',
      p_cost_credits,
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
      from public.voice_generation_requests as ledger
     where ledger.user_id = p_user_id
       and ledger.request_key = p_request_key
     for update;

    if not found then
      return jsonb_build_object('status', 'credit_service_unavailable');
    end if;
    if request.request_fingerprint <> p_request_fingerprint
       or request.cost_credits <> p_cost_credits then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if request.status = 'processing' then
      return jsonb_build_object(
        'status', 'in_progress',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'provider_request_id', request.provider_request_id,
        'submission_ambiguous',
          request.submission_ambiguous_at is not null
      );
    end if;
    if request.status = 'succeeded' then
      return jsonb_build_object(
        'status', 'replay',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
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
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object('status', 'profile_not_found');
  end if;

  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object('status', 'account_deleting');
  end if;

  if v_credits < p_cost_credits then
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
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

  if v_inserted then
    update public.voice_generation_requests as ledger
       set credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           updated_at = now()
     where ledger.id = request.id
    returning ledger.* into request;
  else
    update public.voice_generation_requests as ledger
       set status = 'processing',
           credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           claim_token_hash = v_claim_token_hash,
           attempt = request.attempt + 1,
           provider_request_id = null,
           provider_submitted_at = null,
           submission_ambiguous_at = null,
           submission_rejected_at = null,
           result_manifest = null,
           error_code = null,
           updated_at = now(),
           completed_at = null,
           refunded_at = null
     where ledger.id = request.id
    returning ledger.* into request;
  end if;

  return jsonb_build_object(
    'status', 'claimed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit
  );
end;
$function$;

create or replace function public.complete_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text,
  p_result_manifest jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_expected_path text;
  v_object jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if p_attempt is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.attempt <> p_attempt
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object(
      'status', 'stale_attempt',
      'attempt', request.attempt
    );
  end if;

  v_expected_path := p_user_id::text || '/explicit/' ||
    split_part(request.request_key, ':', 2) || '/' ||
    request.attempt::text || '/audio.mp3';
  v_object := p_result_manifest -> 'object';

  if p_result_manifest is null
     or jsonb_typeof(p_result_manifest) <> 'object'
     or not (p_result_manifest ?& array[
       'version', 'provider', 'model', 'object'
     ]::text[])
     or p_result_manifest - array[
       'version', 'provider', 'model', 'object'
     ]::text[] <> '{}'::jsonb
     or p_result_manifest ->> 'version' <> '1'
     or p_result_manifest ->> 'provider' <> 'fal'
     or p_result_manifest ->> 'model' <>
       'fal-ai/elevenlabs/tts/eleven-v3'
     or coalesce(jsonb_typeof(v_object), '') <> 'object'
     or not (v_object ?& array['path', 'mimeType', 'sha256']::text[])
     or v_object - array['path', 'mimeType', 'sha256']::text[] <> '{}'::jsonb
     or v_object ->> 'path' <> v_expected_path
     or v_object ->> 'mimeType' <> 'audio/mpeg'
     or v_object ->> 'sha256' !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;

  if request.status = 'succeeded' then
    if request.result_manifest = p_result_manifest then
      return jsonb_build_object(
        'status', 'already_completed',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
    return jsonb_build_object('status', 'completion_conflict');
  end if;
  if request.status <> 'processing' then
    return jsonb_build_object('status', 'not_processing');
  end if;

  update public.voice_generation_requests as ledger
     set status = 'succeeded',
         result_manifest = p_result_manifest,
         error_code = null,
         updated_at = now(),
         completed_at = now(),
         refunded_at = null
   where ledger.id = request.id
  returning ledger.* into request;

  return jsonb_build_object(
    'status', 'completed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest
  );
end;
$function$;

create or replace function public.get_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if p_attempt is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.attempt <> p_attempt
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object(
      'status', 'stale_attempt',
      'attempt', request.attempt
    );
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', request.status,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest,
    'error_code', request.error_code
  ));
end;
$function$;

-- Restore the same expiring/permanent split that the matching speech debit
-- consumed, without changing newer entitlement updates.
create or replace function public.x5_apply_voice_generation_credit_restoration()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_marker text := nullif(
    current_setting('x5.voice_generation_restore_request', true),
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
    from public.voice_generation_requests as ledger
   where ledger.id = v_marker::uuid
     and ledger.user_id = new.id
     and ledger.status = 'processing';
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
  public.x5_apply_voice_generation_credit_restoration()
  from public, anon, authenticated, service_role;

drop trigger if exists zz_x5_restore_voice_generation_credits
  on public.profiles;
create trigger zz_x5_restore_voice_generation_credits
before update of
  credits, permanent_credits, permanent_credit_debt, credits_expires_at
on public.profiles
for each row
execute function public.x5_apply_voice_generation_credit_restoration();

create or replace function public.x5_restore_voice_generation_credits(
  p_request_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_credits integer;
  v_profile_updated boolean;
begin
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.id = p_request_id
   for update;

  if not found or request.status <> 'processing' then
    raise exception using
      errcode = 'P0001', message = 'voice_generation_request_not_processing';
  end if;

  perform pg_catalog.set_config(
    'x5.voice_generation_restore_request',
    request.id::text,
    true
  );
  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) + request.cost_credits
   where profile.id = request.user_id
  returning profile.credits into v_credits;
  v_profile_updated := found;
  perform pg_catalog.set_config(
    'x5.voice_generation_restore_request',
    '',
    true
  );

  if not v_profile_updated then
    raise exception using
      errcode = 'P0001', message = 'voice_generation_profile_missing';
  end if;
  return v_credits;
exception when others then
  perform pg_catalog.set_config(
    'x5.voice_generation_restore_request',
    '',
    true
  );
  raise;
end;
$function$;

revoke execute on function public.x5_restore_voice_generation_credits(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.fail_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_credits integer;
  v_error_code text := lower(
    coalesce(nullif(btrim(p_error_code), ''), 'voice_generation_failed')
  );
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if v_error_code !~ '^[a-z0-9_:-]{1,80}$' then
    v_error_code := 'voice_generation_failed';
  end if;

  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if p_attempt is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.attempt <> p_attempt
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object(
      'status', 'stale_attempt',
      'attempt', request.attempt
    );
  end if;
  if request.status = 'succeeded' then
    return jsonb_build_object(
      'status', 'already_completed',
      'credits_remaining', request.credits_after_debit,
      'result_manifest', request.result_manifest
    );
  end if;
  if request.status = 'refunded' then
    select coalesce(profile.credits, 0)
      into v_credits
      from public.profiles as profile
     where profile.id = p_user_id;
    return jsonb_build_object(
      'status', 'already_refunded',
      'credits_remaining', coalesce(v_credits, 0)
    );
  end if;

  v_credits := public.x5_restore_voice_generation_credits(request.id);

  update public.voice_generation_requests as ledger
     set status = 'refunded',
         result_manifest = null,
         error_code = v_error_code,
         updated_at = now(),
         completed_at = null,
         refunded_at = now()
   where ledger.id = request.id;

  return jsonb_build_object(
    'status', 'refunded',
    'credits_remaining', v_credits
  );
end;
$function$;

create or replace function public.reconcile_stale_voice_generation_requests(
  p_stale_after interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_reconciled integer := 0;
begin
  if p_stale_after is null
     or p_stale_after < interval '5 minutes'
     or p_stale_after > interval '24 hours' then
    raise exception using errcode = '22023', message = 'invalid_stale_interval';
  end if;

  for request in
    select ledger.*
     from public.voice_generation_requests as ledger
     where ledger.status = 'processing'
       and (
         (
           ledger.submission_rejected_at is not null
           and ledger.provider_request_id is null
           and ledger.submission_ambiguous_at is null
           and ledger.updated_at <= now() - p_stale_after
         )
         or ledger.updated_at <= now() - greatest(
           p_stale_after,
           interval '4 hours'
         )
       )
     order by ledger.updated_at
     for update skip locked
  loop
    perform public.x5_restore_voice_generation_credits(request.id);
    update public.voice_generation_requests as ledger
       set status = 'refunded',
           result_manifest = null,
            error_code = case
              when request.submission_rejected_at is not null
                and request.provider_request_id is null
                and request.submission_ambiguous_at is null
                then 'stale_reconciled'
              else 'generation_expired'
            end,
           updated_at = now(),
           completed_at = null,
           refunded_at = now()
     where ledger.id = request.id
       and ledger.status = 'processing';
    if found then
      v_reconciled := v_reconciled + 1;
    end if;
  end loop;
  return v_reconciled;
end;
$function$;

revoke execute on function public.claim_voice_generation_request(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.complete_voice_generation_request(
  uuid, text, text, integer, text, jsonb
) from public, anon, authenticated, service_role;
revoke execute on function public.get_voice_generation_request(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.fail_voice_generation_request(
  uuid, text, text, integer, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.reconcile_stale_voice_generation_requests(
  interval
) from public, anon, authenticated, service_role;

grant execute on function public.claim_voice_generation_request(
  uuid, text, text, integer, text
) to service_role;
grant execute on function public.complete_voice_generation_request(
  uuid, text, text, integer, text, jsonb
) to service_role;
grant execute on function public.get_voice_generation_request(
  uuid, text, text, integer, text
) to service_role;
grant execute on function public.fail_voice_generation_request(
  uuid, text, text, integer, text, text
) to service_role;
grant execute on function public.reconcile_stale_voice_generation_requests(
  interval
) to postgres;

do $cron$
begin
  begin
    perform cron.unschedule('x5-reconcile-voice-generations');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-reconcile-voice-generations',
    '*/5 * * * *',
    'select public.reconcile_stale_voice_generation_requests(interval ''15 minutes'');'
  );
end;
$cron$;

create or replace function public.lookup_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'status', request.status,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'provider_request_id', request.provider_request_id,
    'submission_ambiguous', request.submission_ambiguous_at is not null,
    'result_manifest', request.result_manifest
  ));
end;
$function$;

-- Bind the fal queue ID returned by a normal submit response. A lost response
-- is recovered by the callback-specific claim token function below.
create or replace function public.bind_voice_generation_provider_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text,
  p_provider_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_provider_request_id is null
     or p_provider_request_id !~ '^[A-Za-z0-9_-]{8,200}$' then
    return jsonb_build_object('status', 'invalid_provider_request');
  end if;

  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if p_attempt is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.attempt <> p_attempt
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_attempt');
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = request.user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  if request.status = 'succeeded' then
    return jsonb_build_object(
      'status', 'already_completed',
      'result_manifest', request.result_manifest,
      'credits_remaining', request.credits_after_debit
    );
  end if;
  if request.status = 'refunded' then
    return jsonb_build_object('status', 'already_refunded');
  end if;
  if request.provider_request_id is not null
     and request.provider_request_id <> p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;

  update public.voice_generation_requests as ledger
     set provider_request_id = p_provider_request_id,
         provider_submitted_at = coalesce(
           ledger.provider_submitted_at, now()
         ),
         submission_ambiguous_at = null,
         submission_rejected_at = null,
         updated_at = now()
   where ledger.id = request.id;
  return jsonb_build_object(
    'status',
      case when request.provider_request_id is null
        then 'bound' else 'already_bound' end,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit
  );
exception when unique_violation then
  return jsonb_build_object('status', 'provider_request_conflict');
end;
$function$;

create or replace function public.mark_voice_generation_submission_ambiguous(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.attempt <> p_attempt
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_attempt');
  end if;
  if request.status <> 'processing' then
    return jsonb_build_object('status', request.status);
  end if;
  if request.provider_request_id is not null then
    return jsonb_build_object(
      'status', 'already_bound',
      'provider_request_id', request.provider_request_id
    );
  end if;
  update public.voice_generation_requests as ledger
     set submission_ambiguous_at = coalesce(
           ledger.submission_ambiguous_at, now()
         ),
         updated_at = now()
   where ledger.id = request.id;
  return jsonb_build_object('status', 'marked');
end;
$function$;

create or replace function public.mark_voice_generation_submission_rejected(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.attempt <> p_attempt
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_attempt');
  end if;
  if request.status <> 'processing' then
    return jsonb_build_object('status', request.status);
  end if;
  if request.provider_request_id is not null
     or request.submission_ambiguous_at is not null then
    return jsonb_build_object('status', 'not_definitively_rejected');
  end if;
  update public.voice_generation_requests as ledger
     set submission_rejected_at = coalesce(
           ledger.submission_rejected_at, now()
         ),
         error_code = 'provider_submit_rejected',
         updated_at = now()
   where ledger.id = request.id;
  return jsonb_build_object('status', 'marked');
end;
$function$;

-- fal may call this even when the submit response never reached X5. The
-- callback URL carries only the opaque claim token; Postgres stores its hash.
create or replace function public.bind_voice_generation_webhook(
  p_claim_token text,
  p_attempt integer,
  p_provider_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or p_attempt is null
     or p_attempt <= 0
     or p_provider_request_id is null
     or p_provider_request_id !~ '^[A-Za-z0-9_-]{8,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.claim_token_hash = pg_catalog.encode(
           pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
           'hex'
         )
     and ledger.attempt = p_attempt
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = request.user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  if request.status = 'succeeded' then
    return jsonb_build_object(
      'status', 'already_completed',
      'result_manifest', request.result_manifest
    );
  end if;
  if request.status = 'refunded' then
    return jsonb_build_object('status', 'already_refunded');
  end if;
  if request.provider_request_id is not null
     and request.provider_request_id <> p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;

  update public.voice_generation_requests as ledger
     set provider_request_id = p_provider_request_id,
         provider_submitted_at = coalesce(
           ledger.provider_submitted_at, now()
         ),
         submission_ambiguous_at = null,
         submission_rejected_at = null,
         updated_at = now()
   where ledger.id = request.id;

  return jsonb_build_object(
    'status',
      case when request.provider_request_id is null
        then 'bound' else 'already_bound' end,
    'user_id', request.user_id,
    'request_key', request.request_key,
    'request_fingerprint', request.request_fingerprint,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit
  );
exception when unique_violation then
  return jsonb_build_object('status', 'provider_request_conflict');
end;
$function$;

create or replace function public.get_voice_generation_by_provider(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_provider_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'status', request.status,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest,
    'error_code', request.error_code
  ));
end;
$function$;

create or replace function public.complete_voice_generation_by_provider(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_provider_request_id text,
  p_result_manifest jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_expected_path text;
  v_object jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = request.user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;

  v_expected_path := p_user_id::text || '/explicit/' ||
    split_part(request.request_key, ':', 2) || '/' ||
    request.attempt::text || '/audio.mp3';
  v_object := p_result_manifest -> 'object';
  if p_result_manifest is null
     or jsonb_typeof(p_result_manifest) <> 'object'
     or not (p_result_manifest ?& array[
       'version', 'provider', 'model', 'object'
     ]::text[])
     or p_result_manifest - array[
       'version', 'provider', 'model', 'object'
     ]::text[] <> '{}'::jsonb
     or p_result_manifest ->> 'version' <> '1'
     or p_result_manifest ->> 'provider' <> 'fal'
     or p_result_manifest ->> 'model' <>
       'fal-ai/elevenlabs/tts/eleven-v3'
     or coalesce(jsonb_typeof(v_object), '') <> 'object'
     or not (v_object ?& array['path', 'mimeType', 'sha256']::text[])
     or v_object - array['path', 'mimeType', 'sha256']::text[] <> '{}'::jsonb
     or v_object ->> 'path' <> v_expected_path
     or v_object ->> 'mimeType' <> 'audio/mpeg'
     or v_object ->> 'sha256' !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;
  if request.status = 'succeeded' then
    if request.result_manifest = p_result_manifest then
      return jsonb_build_object(
        'status', 'already_completed',
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
    return jsonb_build_object('status', 'completion_conflict');
  end if;
  if request.status = 'refunded' then
    return jsonb_build_object('status', 'already_refunded');
  end if;

  update public.voice_generation_requests as ledger
     set status = 'succeeded',
         result_manifest = p_result_manifest,
         error_code = null,
         updated_at = now(),
         completed_at = now(),
         refunded_at = null
   where ledger.id = request.id;
  return jsonb_build_object(
    'status', 'completed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', p_result_manifest
  );
end;
$function$;

create or replace function public.fail_voice_generation_by_provider(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_provider_request_id text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_credits integer;
  v_error_code text := lower(
    coalesce(nullif(btrim(p_error_code), ''), 'provider_terminal_failure')
  );
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select ledger.*
    into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = request.user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;
  if request.status = 'succeeded' then
    return jsonb_build_object(
      'status', 'already_completed',
      'result_manifest', request.result_manifest
    );
  end if;
  if request.status = 'refunded' then
    select coalesce(profile.credits, 0)
      into v_credits
      from public.profiles as profile
     where profile.id = p_user_id;
    return jsonb_build_object(
      'status', 'already_refunded',
      'credits_remaining', coalesce(v_credits, 0)
    );
  end if;
  v_credits := public.x5_restore_voice_generation_credits(request.id);
  update public.voice_generation_requests as ledger
     set status = 'refunded',
         result_manifest = null,
         error_code = case
           when v_error_code ~ '^[a-z0-9_:-]{1,80}$'
             then v_error_code
           else 'provider_terminal_failure'
         end,
         updated_at = now(),
         completed_at = null,
         refunded_at = now()
   where ledger.id = request.id;
  return jsonb_build_object(
    'status', 'refunded',
    'credits_remaining', v_credits
  );
end;
$function$;

revoke execute on function public.bind_voice_generation_provider_request(
  uuid, text, text, integer, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.lookup_voice_generation_request(
  uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_voice_generation_submission_ambiguous(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_voice_generation_submission_rejected(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.bind_voice_generation_webhook(
  text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.get_voice_generation_by_provider(
  uuid, text, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.complete_voice_generation_by_provider(
  uuid, text, text, text, jsonb
) from public, anon, authenticated, service_role;
revoke execute on function public.fail_voice_generation_by_provider(
  uuid, text, text, text, text
) from public, anon, authenticated, service_role;

grant execute on function public.bind_voice_generation_provider_request(
  uuid, text, text, integer, text, text
) to service_role;
grant execute on function public.lookup_voice_generation_request(
  uuid, text, text
) to service_role;
grant execute on function public.mark_voice_generation_submission_ambiguous(
  uuid, text, text, integer, text
) to service_role;
grant execute on function public.mark_voice_generation_submission_rejected(
  uuid, text, text, integer, text
) to service_role;
grant execute on function public.bind_voice_generation_webhook(
  text, integer, text
) to service_role;
grant execute on function public.get_voice_generation_by_provider(
  uuid, text, text, text
) to service_role;
grant execute on function public.complete_voice_generation_by_provider(
  uuid, text, text, text, jsonb
) to service_role;
grant execute on function public.fail_voice_generation_by_provider(
  uuid, text, text, text, text
) to service_role;
