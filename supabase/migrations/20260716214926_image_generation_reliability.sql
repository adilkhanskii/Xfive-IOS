-- Crash-safe, idempotent accounting for image generation. The ledger stores
-- only hashed request identity and private Storage object paths; prompts,
-- reference image bytes, and provider output blobs never enter Postgres.

create table public.image_generation_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_key text not null,
  request_fingerprint text not null,
  is_legacy boolean not null,
  status text not null default 'processing',
  cost_credits integer not null,
  credits_after_debit integer,
  permanent_credits_debited integer not null default 0,
  permanent_credit_debt_at_claim integer not null default 0,
  credits_expires_at_before_debit timestamptz,
  credits_expires_at_after_debit timestamptz,
  attempt integer not null default 1,
  claim_token_hash text not null,
  result_manifest jsonb,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  refunded_at timestamptz,
  constraint image_generation_requests_user_key_unique
    unique (user_id, request_key),
  constraint image_generation_requests_key_valid check (
    request_key ~ '^(legacy|explicit):[0-9a-f]{64}$'
  ),
  constraint image_generation_requests_fingerprint_valid check (
    request_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint image_generation_requests_key_kind_valid check (
    (is_legacy and request_key like 'legacy:%')
    or (not is_legacy and request_key like 'explicit:%')
  ),
  constraint image_generation_requests_status_valid check (
    status in ('processing', 'succeeded', 'refunded')
  ),
  constraint image_generation_requests_cost_valid check (
    cost_credits > 0
    and cost_credits <= 240
    and permanent_credits_debited between 0 and cost_credits
    and permanent_credit_debt_at_claim >= 0
  ),
  constraint image_generation_requests_attempt_valid check (attempt > 0),
  constraint image_generation_requests_claim_token_hash_valid check (
    claim_token_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint image_generation_requests_terminal_state_valid check (
    (status = 'processing' and completed_at is null and refunded_at is null)
    or (status = 'succeeded' and completed_at is not null and refunded_at is null)
    or (status = 'refunded' and completed_at is null and refunded_at is not null)
  )
);

create index image_generation_requests_stale_idx
  on public.image_generation_requests (updated_at)
  where status = 'processing';

comment on table public.image_generation_requests is
  'Private service ledger for exactly-once image generation debits, refunds, and replay.';
comment on column public.image_generation_requests.request_fingerprint is
  'SHA-256 of normalized semantic inputs; never a raw prompt or reference image.';
comment on column public.image_generation_requests.result_manifest is
  'Minimal private Storage object manifest; never inline image bytes or raw provider output.';

alter table public.image_generation_requests enable row level security;
alter table public.image_generation_requests force row level security;
revoke all on table public.image_generation_requests
  from public, anon, authenticated, service_role;

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'image-generation-results',
  'image-generation-results',
  false,
  33554432,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.claim_image_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_is_legacy boolean,
  p_cost_credits integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.image_generation_requests%rowtype;
  v_inserted boolean := false;
  v_credits integer;
  v_permanent_before integer;
  v_permanent_after integer;
  v_permanent_debited integer;
  v_debt_at_claim integer;
  v_expiry_before timestamptz;
  v_expiry_after timestamptz;
  v_claim_token_hash text;
  v_previous_manifest jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_user_id is null
     or p_request_key is null
     or p_request_fingerprint is null
     or p_is_legacy is null
     or p_cost_credits is null
     or p_cost_credits <= 0
     or p_cost_credits > 240
     or p_request_key !~ '^(legacy|explicit):[0-9a-f]{64}$'
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or (p_is_legacy and p_request_key not like 'legacy:%')
     or (not p_is_legacy and p_request_key not like 'explicit:%') then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  v_claim_token_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
    'hex'
  );

  begin
    insert into public.image_generation_requests as ledger (
      user_id, request_key, request_fingerprint, is_legacy,
      status, cost_credits, claim_token_hash
    )
    values (
      p_user_id, p_request_key, p_request_fingerprint, p_is_legacy,
      'processing', p_cost_credits, v_claim_token_hash
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
      from public.image_generation_requests as ledger
     where ledger.user_id = p_user_id
       and ledger.request_key = p_request_key
     for update;

    if not found then
      return jsonb_build_object('status', 'credit_service_unavailable');
    end if;
    if request.request_fingerprint <> p_request_fingerprint
       or request.is_legacy <> p_is_legacy
       or request.cost_credits <> p_cost_credits then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if request.status = 'processing' then
      return jsonb_build_object(
        'status', 'in_progress',
        'request_key', request.request_key,
        'attempt', request.attempt
      );
    end if;
    if request.status = 'succeeded'
       and (
         not request.is_legacy
         -- Legacy callers have no explicit request ID: replay just long enough
         -- to absorb transport retries, then allow intentional regeneration.
         or request.completed_at >= now() - interval '2 minutes'
       ) then
      return jsonb_build_object(
        'status', 'replay',
        'request_key', request.request_key,
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;

    v_previous_manifest := request.result_manifest;
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
      delete from public.image_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object('status', 'profile_not_found');
  end if;

  if v_credits < p_cost_credits then
    if v_inserted then
      delete from public.image_generation_requests as ledger
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
    update public.image_generation_requests as ledger
       set credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           updated_at = now()
     where ledger.id = request.id
    returning ledger.* into request;
  else
    update public.image_generation_requests as ledger
       set status = 'processing',
           credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           claim_token_hash = v_claim_token_hash,
           attempt = request.attempt + 1,
           result_manifest = null,
           error_code = null,
           updated_at = now(),
           completed_at = null,
           refunded_at = null
     where ledger.id = request.id
    returning ledger.* into request;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'claimed',
    'request_key', request.request_key,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'previous_result_manifest', v_previous_manifest
  ));
end;
$function$;

create or replace function public.complete_image_generation_request(
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
  request public.image_generation_requests%rowtype;
  v_expected_prefix text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.image_generation_requests as ledger
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

  v_expected_prefix := p_user_id::text || '/' ||
    case when request.is_legacy then 'legacy' else 'explicit' end || '/' ||
    split_part(request.request_key, ':', 2) || '/' ||
    request.attempt::text || '/';

  if p_result_manifest is null
     or jsonb_typeof(p_result_manifest) <> 'object'
     or not (p_result_manifest ?& array[
       'version', 'provider', 'model', 'objects'
     ]::text[])
     or p_result_manifest - array[
       'version', 'provider', 'model', 'fallbackFrom', 'objects'
      ]::text[] <> '{}'::jsonb
     or coalesce(jsonb_typeof(p_result_manifest -> 'version'), '') <> 'number'
     or p_result_manifest ->> 'version' <> '1'
     or coalesce(jsonb_typeof(p_result_manifest -> 'provider'), '') <> 'string'
     or nullif(btrim(p_result_manifest ->> 'provider'), '') is null
     or length(p_result_manifest ->> 'provider') > 40
     or coalesce(jsonb_typeof(p_result_manifest -> 'model'), '') <> 'string'
     or nullif(btrim(p_result_manifest ->> 'model'), '') is null
     or length(p_result_manifest ->> 'model') > 100
     or (
       p_result_manifest ? 'fallbackFrom'
       and (
         coalesce(jsonb_typeof(p_result_manifest -> 'fallbackFrom'), '') <>
           'string'
         or nullif(btrim(p_result_manifest ->> 'fallbackFrom'), '') is null
         or length(p_result_manifest ->> 'fallbackFrom') > 40
       )
     )
     or coalesce(jsonb_typeof(p_result_manifest -> 'objects'), '') <>
       'array' then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;

  if jsonb_array_length(p_result_manifest -> 'objects') not between 1 and 4 then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;

  if exists (
       select 1
         from jsonb_array_elements(p_result_manifest -> 'objects') as item(value)
        where jsonb_typeof(item.value) <> 'object'
           or not (item.value ?& array['path', 'mimeType', 'sha256']::text[])
           or item.value - array['path', 'mimeType', 'sha256']::text[] <>
              '{}'::jsonb
           or coalesce(jsonb_typeof(item.value -> 'path'), '') <> 'string'
           or coalesce(jsonb_typeof(item.value -> 'mimeType'), '') <> 'string'
           or coalesce(jsonb_typeof(item.value -> 'sha256'), '') <> 'string'
           or item.value ->> 'path' not like v_expected_prefix || '%'
           or item.value ->> 'path' like '%..%'
           or item.value ->> 'path' like E'%\\%'
           or length(item.value ->> 'path') > 500
           or substring(
             item.value ->> 'path' from length(v_expected_prefix) + 1
           ) !~ '^[0-3]\.(png|jpg|webp)$'
           or item.value ->> 'mimeType' not in (
             'image/jpeg', 'image/png', 'image/webp'
           )
           or (
             (item.value ->> 'mimeType' = 'image/jpeg'
               and item.value ->> 'path' not like '%.jpg')
             or (item.value ->> 'mimeType' = 'image/png'
               and item.value ->> 'path' not like '%.png')
             or (item.value ->> 'mimeType' = 'image/webp'
               and item.value ->> 'path' not like '%.webp')
           )
           or item.value ->> 'sha256' !~ '^[0-9a-f]{64}$'
     ) or (
       select count(*) <> count(distinct item.value ->> 'path')
         from jsonb_array_elements(p_result_manifest -> 'objects') as item(value)
     ) then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;
  if request.status = 'succeeded' then
    if request.result_manifest = p_result_manifest then
      return jsonb_build_object(
        'status', 'already_completed',
        'request_key', request.request_key,
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

  update public.image_generation_requests as ledger
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
    'request_key', request.request_key,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest
  );
end;
$function$;

create or replace function public.get_image_generation_request(
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
  request public.image_generation_requests%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.*
    into request
    from public.image_generation_requests as ledger
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
    'request_key', request.request_key,
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest,
    'error_code', request.error_code
  ));
end;
$function$;

-- The existing credit-retention trigger intentionally classifies ordinary
-- positive deltas as expiring credits. A generation refund must instead undo
-- the exact timed/permanent split consumed by its matching debit and restore
-- the old timed-credit deadline. This last-alphabetical BEFORE trigger applies
-- that narrow correction only while the private helper below holds a live,
-- processing ledger row and sets its transaction-local marker.
create or replace function public.x5_apply_image_generation_credit_restoration()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  request public.image_generation_requests%rowtype;
  v_marker text := nullif(
    current_setting('x5.image_generation_restore_request', true),
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
    from public.image_generation_requests as ledger
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
    -- Do not overwrite a newer deadline created by a concurrent entitlement
    -- or balance change after this generation was claimed.
    new.credits_expires_at := old.credits_expires_at;
  end if;
  if coalesce(new.credits, 0) - new.permanent_credits <= 0 then
    new.credits_expires_at := null;
  end if;

  return new;
end;
$function$;

revoke execute on function
  public.x5_apply_image_generation_credit_restoration()
  from public, anon, authenticated, service_role;

drop trigger if exists zz_x5_restore_image_generation_credits
  on public.profiles;
create trigger zz_x5_restore_image_generation_credits
before update of
  credits, permanent_credits, permanent_credit_debt, credits_expires_at
on public.profiles
for each row
execute function public.x5_apply_image_generation_credit_restoration();

create or replace function public.x5_restore_image_generation_credits(
  p_request_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.image_generation_requests%rowtype;
  v_credits integer;
  v_profile_updated boolean;
begin
  select ledger.*
    into request
    from public.image_generation_requests as ledger
   where ledger.id = p_request_id
   for update;

  if not found or request.status <> 'processing' then
    raise exception using
      errcode = 'P0001', message = 'generation_request_not_processing';
  end if;

  perform pg_catalog.set_config(
    'x5.image_generation_restore_request', request.id::text, true
  );
  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) + request.cost_credits
   where profile.id = request.user_id
  returning profile.credits into v_credits;
  v_profile_updated := found;
  perform pg_catalog.set_config(
    'x5.image_generation_restore_request', '', true
  );

  if not v_profile_updated then
    raise exception using
      errcode = 'P0001', message = 'generation_profile_missing';
  end if;
  return v_credits;
exception when others then
  perform pg_catalog.set_config(
    'x5.image_generation_restore_request', '', true
  );
  raise;
end;
$function$;

revoke execute on function public.x5_restore_image_generation_credits(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.fail_image_generation_request(
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
  request public.image_generation_requests%rowtype;
  v_credits integer;
  v_error_code text := lower(coalesce(nullif(btrim(p_error_code), ''), 'generation_failed'));
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
    from public.image_generation_requests as ledger
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
      'credits_remaining', request.credits_after_debit
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

  v_credits := public.x5_restore_image_generation_credits(request.id);

  update public.image_generation_requests as ledger
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

create or replace function public.reconcile_stale_image_generation_requests(
  p_stale_after interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.image_generation_requests%rowtype;
  v_reconciled integer := 0;
begin
  if p_stale_after is null
     or p_stale_after < interval '5 minutes'
     or p_stale_after > interval '24 hours' then
    raise exception using errcode = '22023', message = 'invalid_stale_interval';
  end if;

  for request in
    select ledger.*
      from public.image_generation_requests as ledger
     where ledger.status = 'processing'
       and ledger.updated_at <= now() - p_stale_after
     order by ledger.updated_at
     for update skip locked
  loop
    perform public.x5_restore_image_generation_credits(request.id);
    update public.image_generation_requests as ledger
       set status = 'refunded',
           result_manifest = null,
           error_code = 'stale_reconciled',
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

revoke execute on function public.claim_image_generation_request(
  uuid, text, text, boolean, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.complete_image_generation_request(
  uuid, text, text, integer, text, jsonb
) from public, anon, authenticated, service_role;
revoke execute on function public.get_image_generation_request(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.fail_image_generation_request(
  uuid, text, text, integer, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.reconcile_stale_image_generation_requests(
  interval
) from public, anon, authenticated, service_role;

grant execute on function public.claim_image_generation_request(
  uuid, text, text, boolean, integer, text
) to service_role;
grant execute on function public.complete_image_generation_request(
  uuid, text, text, integer, text, jsonb
) to service_role;
grant execute on function public.get_image_generation_request(
  uuid, text, text, integer, text
) to service_role;
grant execute on function public.fail_image_generation_request(
  uuid, text, text, integer, text, text
) to service_role;
grant execute on function public.reconcile_stale_image_generation_requests(
  interval
) to postgres;

do $cron$
begin
  begin
    perform cron.unschedule('x5-reconcile-image-generations');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-reconcile-image-generations',
    '*/5 * * * *',
    'select public.reconcile_stale_image_generation_requests(interval ''15 minutes'');'
  );
end;
$cron$;
