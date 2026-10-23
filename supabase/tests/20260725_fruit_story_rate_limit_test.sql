begin;

select set_config(
  'x5.fruit_story_test_user',
  (
    select profile.id::text
      from public.profiles as profile
     order by profile.id
     limit 1
  ),
  true
);

do $fixture_required$
begin
  if nullif(
    current_setting('x5.fruit_story_test_user', true),
    ''
  ) is null then
    raise exception 'fruit_story_test_profile_required';
  end if;
end;
$fixture_required$;

delete from public.fruit_story_requests
 where user_id = current_setting('x5.fruit_story_test_user')::uuid;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  current_setting('x5.fruit_story_test_user'),
  true
);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('x5.fruit_story_test_user'),
    'role', 'authenticated'
  )::text,
  true
);

do $attempt_ledger_private$
declare
  v_direct_read_allowed boolean := false;
begin
  begin
    perform 1
      from public.fruit_story_request_attempts
     limit 1;
    v_direct_read_allowed := true;
  exception
    when insufficient_privilege then
      null;
  end;

  if v_direct_read_allowed then
    raise exception 'fruit_story_attempt_ledger_is_directly_readable';
  end if;
end;
$attempt_ledger_private$;

do $retry_burst_limit$
declare
  v_request_id constant uuid :=
    '81111111-1111-4111-8111-111111111111'::uuid;
  v_fingerprint constant text := repeat('a', 64);
  v_claim jsonb;
  v_duplicate_claim jsonb;
  v_release jsonb;
begin
  v_claim := public.claim_fruit_story_request(
    v_request_id,
    v_fingerprint
  );
  if v_claim ->> 'status' <> 'claimed' then
    raise exception 'fruit_story_initial_claim_failed:%', v_claim;
  end if;

  v_duplicate_claim := public.claim_fruit_story_request(
    v_request_id,
    v_fingerprint
  );
  if v_duplicate_claim ->> 'status' <> 'in_progress'
     or (v_duplicate_claim ->> 'retry_after')::integer < 70 then
    raise exception
      'active_lease_allowed_duplicate_provider_attempt:%',
      v_duplicate_claim;
  end if;

  v_release := public.release_fruit_story_request(
    v_request_id,
    v_fingerprint,
    (v_claim ->> 'lease_token')::uuid
  );
  if v_release ->> 'status' <> 'released' then
    raise exception 'fruit_story_initial_release_failed:%', v_release;
  end if;

  v_claim := public.claim_fruit_story_request(
    v_request_id,
    v_fingerprint
  );
  if v_claim ->> 'status' <> 'rate_limited' then
    raise exception 'retry_burst_limit_was_bypassed:%', v_claim;
  end if;
end;
$retry_burst_limit$;

reset role;

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
  current_setting('x5.fruit_story_test_user')::uuid,
  '84444444-4444-4444-8444-444444444444'::uuid,
  repeat('d', 64),
  'processing',
  '84444444-4444-4444-8444-444444444445'::uuid,
  1,
  now() - interval '1 second'
);
insert into public.fruit_story_request_attempts (
  user_id,
  request_id,
  lease_generation,
  attempted_at
)
values (
  current_setting('x5.fruit_story_test_user')::uuid,
  '84444444-4444-4444-8444-444444444444'::uuid,
  1,
  now() - interval '4 seconds'
);

insert into public.fruit_story_requests (
  user_id,
  request_id,
  request_fingerprint,
  status,
  lease_token,
  lease_generation,
  story,
  completed_at,
  replay_until
)
values (
  current_setting('x5.fruit_story_test_user')::uuid,
  '85555555-5555-4555-8555-555555555555'::uuid,
  repeat('e', 64),
  'completed',
  '85555555-5555-4555-8555-555555555556'::uuid,
  1,
  '{"retained":true}'::jsonb,
  now() - interval '1 hour',
  now() - interval '1 second'
);

set local role authenticated;

do $expired_processing_is_ambiguous$
declare
  v_request_id constant uuid :=
    '84444444-4444-4444-8444-444444444444'::uuid;
  v_fingerprint constant text := repeat('d', 64);
  v_claim jsonb;
  v_completion jsonb;
begin
  v_claim := public.claim_fruit_story_request(
    v_request_id,
    v_fingerprint
  );
  if v_claim ->> 'status' <> 'ambiguous' then
    raise exception 'expired_lease_was_reclaimed:%', v_claim;
  end if;

  v_completion := public.complete_fruit_story_request(
    v_request_id,
    v_fingerprint,
    '84444444-4444-4444-8444-444444444445'::uuid,
    '{"delayed":true}'::jsonb
  );
  if v_completion ->> 'status' <> 'completed' then
    raise exception
      'delayed_provider_result_was_not_recovered:%',
      v_completion;
  end if;

  v_claim := public.claim_fruit_story_request(
    v_request_id,
    v_fingerprint
  );
  if v_claim ->> 'status' <> 'replay'
     or v_claim -> 'story' <> '{"delayed":true}'::jsonb then
    raise exception 'delayed_completion_was_not_replayed:%', v_claim;
  end if;
end;
$expired_processing_is_ambiguous$;

do $completed_replay_is_retained$
declare
  v_claim jsonb;
begin
  v_claim := public.claim_fruit_story_request(
    '85555555-5555-4555-8555-555555555555'::uuid,
    repeat('e', 64)
  );
  if v_claim ->> 'status' <> 'replay'
     or v_claim -> 'story' <> '{"retained":true}'::jsonb then
    raise exception 'completed_replay_did_not_survive_cache_window:%', v_claim;
  end if;
end;
$completed_replay_is_retained$;

reset role;

do $ambiguous_attempt_evidence$
declare
  v_user_id uuid :=
    current_setting('x5.fruit_story_test_user')::uuid;
  v_attempt_count integer;
begin
  select count(*)
    into v_attempt_count
    from public.fruit_story_request_attempts as attempt
   where attempt.user_id = v_user_id
     and attempt.request_id =
       '84444444-4444-4444-8444-444444444444'::uuid;

  if v_attempt_count <> 1 then
    raise exception
      'ambiguous_request_created_duplicate_attempt:%',
      v_attempt_count;
  end if;
end;
$ambiguous_attempt_evidence$;

do $failure_evidence_preserved$
declare
  v_user_id uuid :=
    current_setting('x5.fruit_story_test_user')::uuid;
begin
  if not exists (
    select 1
      from public.fruit_story_requests as request
     where request.user_id = v_user_id
       and request.request_id =
         '81111111-1111-4111-8111-111111111111'::uuid
       and request.status = 'retryable'
  ) then
    raise exception 'released_request_evidence_was_deleted';
  end if;

  if not exists (
    select 1
      from public.fruit_story_request_attempts as attempt
     where attempt.user_id = v_user_id
       and attempt.request_id =
         '81111111-1111-4111-8111-111111111111'::uuid
       and attempt.lease_generation = 1
  ) then
    raise exception 'released_attempt_evidence_was_deleted';
  end if;
end;
$failure_evidence_preserved$;

delete from public.fruit_story_requests
 where user_id = current_setting('x5.fruit_story_test_user')::uuid
   and (
     request_id = '81111111-1111-4111-8111-111111111111'::uuid
      or request_id = '82222222-2222-4222-8222-222222222222'::uuid
      or request_id::text like '83333333-3333-4333-8333-%'
      or request_id = '84444444-4444-4444-8444-444444444444'::uuid
      or request_id = '85555555-5555-4555-8555-555555555555'::uuid
    );

do $daily_limit_fixture$
declare
  v_user_id uuid :=
    current_setting('x5.fruit_story_test_user')::uuid;
  v_target_request_id constant uuid :=
    '82222222-2222-4222-8222-222222222222'::uuid;
  v_request_id uuid;
begin
  insert into public.fruit_story_requests (
    user_id,
    request_id,
    request_fingerprint,
    status,
    lease_generation
  )
  values (
    v_user_id,
    v_target_request_id,
    repeat('b', 64),
    'retryable',
    1
  );
  insert into public.fruit_story_request_attempts (
    user_id,
    request_id,
    lease_generation,
    attempted_at
  )
  values (
    v_user_id,
    v_target_request_id,
    1,
    now()
  );

  for index in 1..24 loop
    v_request_id := (
      '83333333-3333-4333-8333-' ||
      lpad(index::text, 12, '0')
    )::uuid;
    insert into public.fruit_story_requests (
      user_id,
      request_id,
      request_fingerprint,
      status,
      lease_generation
    )
    values (
      v_user_id,
      v_request_id,
      repeat('c', 64),
      'retryable',
      1
    );
    insert into public.fruit_story_request_attempts (
      user_id,
      request_id,
      lease_generation,
      attempted_at
    )
    values (
      v_user_id,
      v_request_id,
      1,
      now()
    );
  end loop;
end;
$daily_limit_fixture$;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  current_setting('x5.fruit_story_test_user'),
  true
);
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', current_setting('x5.fruit_story_test_user'),
    'role', 'authenticated'
  )::text,
  true
);

do $retry_daily_limit$
declare
  v_claim jsonb;
begin
  v_claim := public.claim_fruit_story_request(
    '82222222-2222-4222-8222-222222222222'::uuid,
    repeat('b', 64)
  );
  if v_claim ->> 'status' <> 'rate_limited' then
    raise exception 'retry_daily_limit_was_bypassed:%', v_claim;
  end if;
end;
$retry_daily_limit$;

rollback;
