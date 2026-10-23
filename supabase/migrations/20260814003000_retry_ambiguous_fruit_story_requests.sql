-- A Fruit Story provider submission always uses a deterministic OpenAI
-- idempotency key derived from the user and request UUID. An ambiguous ledger
-- row can therefore be reclaimed safely: the provider resumes or replays the
-- same submission instead of charging for a second one.

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
      v_reclaim_existing := true;
    elsif request.status = 'processing'
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
    elsif request.status = 'processing'
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
    elsif request.status = 'retryable' then
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

comment on function public.claim_fruit_story_request(uuid, text) is
  'Claims new, retryable, or ambiguous Fruit Story requests. Ambiguous retries are safe because the Edge Function reuses the exact provider idempotency key.';
