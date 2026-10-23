create extension if not exists pg_cron;

create table public.fruit_story_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  request_fingerprint text not null,
  status text not null default 'processing',
  lease_token uuid,
  lease_generation bigint not null default 0,
  lease_expires_at timestamptz,
  story jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  replay_until timestamptz,
  ambiguous_at timestamptz,
  constraint fruit_story_requests_owner_request_unique
    unique (user_id, request_id),
  constraint fruit_story_requests_fingerprint_valid check (
    request_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint fruit_story_requests_status_valid check (
    status in ('processing', 'retryable', 'completed', 'ambiguous')
  ),
  constraint fruit_story_requests_payload_valid check (
    (
      status = 'processing'
      and lease_token is not null
      and lease_generation > 0
      and lease_expires_at is not null
      and story is null
      and completed_at is null
      and replay_until is null
      and ambiguous_at is null
    )
    or (
      status = 'retryable'
      and lease_token is null
      and lease_generation > 0
      and lease_expires_at is null
      and story is null
      and completed_at is null
      and replay_until is null
      and ambiguous_at is null
    )
    or (
      status = 'completed'
      and lease_token is not null
      and lease_generation > 0
      and lease_expires_at is null
      and jsonb_typeof(story) = 'object'
      and octet_length(story::text) between 2 and 40000
      and completed_at is not null
      and replay_until is not null
      and ambiguous_at is null
    )
    or (
      status = 'ambiguous'
      and lease_token is not null
      and lease_generation > 0
      and lease_expires_at is null
      and story is null
      and completed_at is null
      and replay_until is null
      and ambiguous_at is not null
    )
  )
);

create index fruit_story_requests_owner_created_idx
  on public.fruit_story_requests (user_id, created_at desc);
create index fruit_story_requests_cleanup_idx
  on public.fruit_story_requests (updated_at);

create table public.fruit_story_request_attempts (
  user_id uuid not null,
  request_id uuid not null,
  lease_generation bigint not null,
  attempted_at timestamptz not null default now(),
  constraint fruit_story_request_attempts_primary_key
    primary key (user_id, request_id, lease_generation),
  constraint fruit_story_request_attempts_request_foreign_key
    foreign key (user_id, request_id)
    references public.fruit_story_requests (user_id, request_id)
    on delete cascade,
  constraint fruit_story_request_attempts_generation_valid check (
    lease_generation > 0
  )
);

create index fruit_story_request_attempts_owner_time_idx
  on public.fruit_story_request_attempts (user_id, attempted_at desc);

comment on table public.fruit_story_requests is
  'Private authenticated idempotency, durable replay, and ambiguous-outcome ledger for Fruit Story.';
comment on column public.fruit_story_requests.request_fingerprint is
  'SHA-256 of the normalized questionnaire. Raw questionnaire fields are never stored.';
comment on table public.fruit_story_request_attempts is
  'Private provider-attempt ledger used for per-user burst and daily limits.';

alter table public.fruit_story_requests enable row level security;
alter table public.fruit_story_requests force row level security;
revoke all on table public.fruit_story_requests
  from public, anon, authenticated, service_role;
alter table public.fruit_story_request_attempts enable row level security;
alter table public.fruit_story_request_attempts force row level security;
revoke all on table public.fruit_story_request_attempts
  from public, anon, authenticated, service_role;

create or replace function public.claim_fruit_story_request(p_request_id uuid, p_request_fingerprint text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  request public.fruit_story_requests%rowtype;
  v_daily_count bigint;
  v_last_attempt_at timestamptz;
  v_retry_after integer;
  v_utc_day_start timestamptz;
  v_lease_token uuid;
  v_lease_generation bigint;
  v_reclaim_existing boolean := false;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'not_authenticated');
  end if;
  if p_request_id is null
     or p_request_fingerprint is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_uid::text, 584304)
  );

  select ledger.*
    into request
    from public.fruit_story_requests as ledger
   where ledger.user_id = v_uid
     and ledger.request_id = p_request_id
   for update;

  if found then
    if request.request_fingerprint <> p_request_fingerprint then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if request.status = 'completed' then
      return jsonb_build_object(
        'status', 'replay',
        'story', request.story
      );
    end if;
    if request.status = 'ambiguous' then
      return jsonb_build_object('status', 'ambiguous');
    end if;
    if request.status = 'processing'
       and request.lease_expires_at > now() then
      v_retry_after := greatest(
        1,
        ceil(
          extract(epoch from (
            request.lease_expires_at - now()
          ))
        )::integer
      );
      return jsonb_build_object(
        'status', 'in_progress',
        'retry_after', v_retry_after
      );
    end if;
    if request.status = 'processing'
       and request.lease_expires_at <= now() then
      update public.fruit_story_requests as ledger
         set status = 'ambiguous',
             lease_expires_at = null,
             ambiguous_at = now(),
             updated_at = now()
       where ledger.id = request.id
         and ledger.status = 'processing'
         and ledger.lease_token = request.lease_token;
      return jsonb_build_object('status', 'ambiguous');
    end if;
    if request.status = 'retryable' then
      v_reclaim_existing := true;
    else
      return jsonb_build_object('status', 'invalid_state');
    end if;
  end if;

  v_utc_day_start := (
    pg_catalog.date_trunc('day', now() at time zone 'UTC')
    at time zone 'UTC'
  );
  select count(*), max(attempt.attempted_at)
    into v_daily_count, v_last_attempt_at
    from public.fruit_story_request_attempts as attempt
   where attempt.user_id = v_uid
     and attempt.attempted_at >= v_utc_day_start;

  if v_daily_count >= 25 then
    v_retry_after := greatest(
      1,
      ceil(
        extract(epoch from (v_utc_day_start + interval '1 day' - now()))
      )::integer
    );
    return jsonb_build_object(
      'status', 'rate_limited',
      'retry_after', v_retry_after
    );
  end if;

  if v_last_attempt_at is not null
     and v_last_attempt_at > now() - interval '3 seconds' then
    v_retry_after := greatest(
      1,
      ceil(
        extract(epoch from (
          v_last_attempt_at + interval '3 seconds' - now()
        ))
      )::integer
    );
    return jsonb_build_object(
      'status', 'rate_limited',
      'retry_after', v_retry_after
    );
  end if;

  v_lease_token := gen_random_uuid();
  if v_reclaim_existing then
    v_lease_generation := request.lease_generation + 1;
    update public.fruit_story_requests as ledger
       set status = 'processing',
           lease_token = v_lease_token,
           lease_generation = v_lease_generation,
           lease_expires_at = now() + interval '75 seconds',
           ambiguous_at = null,
           updated_at = now()
     where ledger.id = request.id;
  else
    v_lease_generation := 1;
    insert into public.fruit_story_requests (
      user_id,
      request_id,
      request_fingerprint,
      status,
      lease_token,
      lease_generation,
      lease_expires_at
    )
    values (
      v_uid,
      p_request_id,
      p_request_fingerprint,
      'processing',
      v_lease_token,
      v_lease_generation,
      now() + interval '75 seconds'
    );
  end if;

  insert into public.fruit_story_request_attempts (
    user_id,
    request_id,
    lease_generation
  )
  values (
    v_uid,
    p_request_id,
    v_lease_generation
  );

  return jsonb_build_object(
    'status', 'claimed',
    'lease_token', v_lease_token,
    'lease_generation', v_lease_generation
  );
end;
$function$;

create or replace function public.complete_fruit_story_request(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid, p_story jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  request public.fruit_story_requests%rowtype;
  v_updated integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'not_authenticated');
  end if;
  if p_request_id is null
     or p_request_fingerprint is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_lease_token is null
     or p_story is null
     or jsonb_typeof(p_story) <> 'object'
     or p_story = '{}'::jsonb
     or octet_length(p_story::text) > 40000 then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select ledger.*
    into request
    from public.fruit_story_requests as ledger
   where ledger.user_id = v_uid
     and ledger.request_id = p_request_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if request.status <> 'processing'
     and request.status <> 'ambiguous'
     and request.status <> 'completed' then
    return jsonb_build_object('status', 'lease_conflict');
  end if;
  if request.lease_token <> p_lease_token then
    return jsonb_build_object('status', 'lease_conflict');
  end if;
  if request.status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'story', request.story
    );
  end if;
  update public.fruit_story_requests as ledger
     set status = 'completed',
         lease_expires_at = null,
         story = p_story,
         completed_at = now(),
         replay_until = now() + interval '30 days',
         ambiguous_at = null,
         updated_at = now()
   where ledger.id = request.id
     and ledger.status in ('processing', 'ambiguous')
     and ledger.lease_token = p_lease_token;
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    return jsonb_build_object('status', 'lease_conflict');
  end if;

  return jsonb_build_object(
    'status', 'completed',
    'story', p_story
  );
end;
$function$;

create or replace function public.release_fruit_story_request(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  request public.fruit_story_requests%rowtype;
  v_updated integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'not_authenticated');
  end if;
  if p_request_id is null
     or p_request_fingerprint is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_lease_token is null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select ledger.*
    into request
    from public.fruit_story_requests as ledger
   where ledger.user_id = v_uid
     and ledger.request_id = p_request_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if request.status <> 'processing'
     and request.status <> 'ambiguous'
     and request.status <> 'completed' then
    return jsonb_build_object('status', 'lease_conflict');
  end if;
  if request.lease_token <> p_lease_token then
    return jsonb_build_object('status', 'lease_conflict');
  end if;
  if request.status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'story', request.story
    );
  end if;
  update public.fruit_story_requests as ledger
     set status = 'retryable',
         lease_token = null,
         lease_expires_at = null,
         ambiguous_at = null,
         updated_at = now()
   where ledger.id = request.id
     and ledger.status in ('processing', 'ambiguous')
     and ledger.lease_token = p_lease_token;
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    return jsonb_build_object('status', 'lease_conflict');
  end if;

  return jsonb_build_object('status', 'released');
end;
$function$;

create or replace function public.hold_fruit_story_request(p_request_id uuid, p_request_fingerprint text, p_lease_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  request public.fruit_story_requests%rowtype;
  v_updated integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'not_authenticated');
  end if;
  if p_request_id is null
     or p_request_fingerprint is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_lease_token is null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select ledger.*
    into request
    from public.fruit_story_requests as ledger
   where ledger.user_id = v_uid
     and ledger.request_id = p_request_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if request.lease_token <> p_lease_token then
    return jsonb_build_object('status', 'lease_conflict');
  end if;
  if request.status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'story', request.story
    );
  end if;
  if request.status = 'ambiguous' then
    return jsonb_build_object('status', 'ambiguous');
  end if;
  if request.status <> 'processing' then
    return jsonb_build_object('status', 'lease_conflict');
  end if;

  update public.fruit_story_requests as ledger
     set status = 'ambiguous',
         lease_expires_at = null,
         ambiguous_at = now(),
         updated_at = now()
   where ledger.id = request.id
     and ledger.status = 'processing'
     and ledger.lease_token = p_lease_token;
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    return jsonb_build_object('status', 'lease_conflict');
  end if;

  return jsonb_build_object('status', 'ambiguous');
end;
$function$;

create or replace function public.cleanup_fruit_story_requests()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_deleted integer;
begin
  delete from public.fruit_story_requests as ledger
   where (
       ledger.status = 'completed'
       and ledger.updated_at < now() - interval '30 days'
     )
      or (
       ledger.status = 'retryable'
       and ledger.updated_at < now() - interval '7 days'
     )
      or (
       ledger.status in ('processing', 'ambiguous')
       and ledger.updated_at < now() - interval '90 days'
     );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

revoke execute on function public.claim_fruit_story_request(uuid, text)
  from public, anon, authenticated, service_role;
revoke execute on function public.complete_fruit_story_request(uuid, text, uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke execute on function public.release_fruit_story_request(uuid, text, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.hold_fruit_story_request(uuid, text, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.cleanup_fruit_story_requests()
  from public, anon, authenticated, service_role;

grant execute on function public.claim_fruit_story_request(uuid, text)
  to authenticated;
grant execute on function public.complete_fruit_story_request(uuid, text, uuid, jsonb)
  to authenticated;
grant execute on function public.release_fruit_story_request(uuid, text, uuid)
  to authenticated;
grant execute on function public.hold_fruit_story_request(uuid, text, uuid)
  to authenticated;
grant execute on function public.cleanup_fruit_story_requests()
  to postgres;

do $cron$
begin
  begin
    perform cron.unschedule('x5-cleanup-fruit-story-requests');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-cleanup-fruit-story-requests',
    '23 3 * * *',
    'select public.cleanup_fruit_story_requests();'
  );
end;
$cron$;
