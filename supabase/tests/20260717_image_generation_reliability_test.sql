begin;

do $acl$
begin
  if has_table_privilege(
    'authenticated', 'public.image_generation_requests', 'select'
  ) or has_table_privilege(
    'service_role', 'public.image_generation_requests', 'select'
  ) then
    raise exception 'generation_ledger_is_directly_readable';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.claim_image_generation_request(uuid,text,text,boolean,integer,text)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.claim_image_generation_request(uuid,text,text,boolean,integer,text)',
    'execute'
  ) then
    raise exception 'generation_claim_rpc_acl_invalid';
  end if;

  if has_function_privilege(
    'service_role',
    'public.reconcile_stale_image_generation_requests(interval)',
    'execute'
  ) or not has_function_privilege(
    'postgres',
    'public.reconcile_stale_image_generation_requests(interval)',
    'execute'
  ) then
    raise exception 'generation_reconciliation_rpc_acl_invalid';
  end if;

  if has_function_privilege(
    'service_role',
    'public.x5_restore_image_generation_credits(uuid)',
    'execute'
  ) then
    raise exception 'generation_refund_helper_is_externally_callable';
  end if;
end;
$acl$;

do $missing_profile_claim$
declare
  v_missing_user uuid := pg_catalog.gen_random_uuid();
  v_key text := 'explicit:' || repeat('0', 64);
  v_result jsonb;
begin
  v_result := public.claim_image_generation_request(
    v_missing_user,
    v_key,
    repeat('0', 64),
    false,
    60,
    repeat('0', 64)
  );
  if v_result ->> 'status' <> 'profile_not_found'
     or exists (
       select 1
         from public.image_generation_requests as ledger
        where ledger.user_id = v_missing_user
          and ledger.request_key = v_key
     ) then
    raise exception 'missing_profile_claim_not_translated:%', v_result;
  end if;
end;
$missing_profile_claim$;

select pg_catalog.set_config(
  'x5.generation_test_user',
  (select profile.id::text from public.profiles as profile order by profile.id limit 1),
  true
);

do $fixtures$
declare
  v_user_id uuid := nullif(
    current_setting('x5.generation_test_user', true), ''
  )::uuid;
  v_existing_debt integer;
  v_profile public.profiles%rowtype;
begin
  if v_user_id is null then
    raise exception 'generation_test_profile_required';
  end if;

  delete from public.image_generation_requests
   where user_id = v_user_id
     and request_key in (
       'explicit:' || repeat('1', 64),
       'explicit:' || repeat('2', 64),
        'explicit:' || repeat('3', 64),
        'explicit:' || repeat('5', 64),
        'explicit:' || repeat('6', 64),
        'legacy:' || repeat('4', 64)
      );

  update public.profiles
     set credits = 0
   where id = v_user_id;
  select permanent_credit_debt
    into v_existing_debt
    from public.profiles
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', v_user_id::text, true
  );
  update public.profiles
     set credits = v_existing_debt + 1000
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', '', true
  );
  update public.profiles
     set credits = 1120
   where id = v_user_id;
  update public.profiles
     set credits_expires_at = '2035-01-02 03:04:05+00'::timestamptz
   where id = v_user_id;

  select * into v_profile from public.profiles where id = v_user_id;
  if v_profile.credits <> 1120
     or v_profile.permanent_credits <> 1000
     or v_profile.permanent_credit_debt <> 0
     or v_profile.credits_expires_at is distinct from
       '2035-01-02 03:04:05+00'::timestamptz then
    raise exception 'generation_fixture_classification_failed:%',
      row_to_json(v_profile);
  end if;
end;
$fixtures$;

do $mixed_credit_refund$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'explicit:' || repeat('5', 64);
  v_fingerprint text := repeat('5', 64);
  v_token text := repeat('5', 64);
  v_result jsonb;
  v_profile public.profiles%rowtype;
begin
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 180, v_token
  );
  select * into v_profile from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'claimed'
     or v_profile.credits <> 940
     or v_profile.permanent_credits <> 940 then
    raise exception 'mixed_credit_claim_classification_failed:%:%',
      v_result, row_to_json(v_profile);
  end if;
  if not exists (
    select 1
      from public.image_generation_requests as ledger
     where ledger.user_id = v_user_id
       and ledger.request_key = v_key
       and ledger.permanent_credits_debited = 60
       and ledger.permanent_credit_debt_at_claim = 0
       and ledger.credits_expires_at_before_debit is not distinct from
         '2035-01-02 03:04:05+00'::timestamptz
       and ledger.credits_expires_at_after_debit is null
  ) then
    raise exception 'mixed_credit_claim_snapshot_failed';
  end if;

  v_result := public.fail_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token, 'provider_error'
  );
  select * into v_profile from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'refunded'
     or v_profile.credits <> 1120
     or v_profile.permanent_credits <> 1000
     or v_profile.permanent_credit_debt <> 0
     or v_profile.credits_expires_at is distinct from
       '2035-01-02 03:04:05+00'::timestamptz then
    raise exception 'mixed_credit_refund_classification_failed:%:%',
      v_result, row_to_json(v_profile);
  end if;
end;
$mixed_credit_refund$;

do $refund_reconciles_new_permanent_debt$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'explicit:' || repeat('6', 64);
  v_fingerprint text := repeat('6', 64);
  v_token text := repeat('6', 64);
  v_result jsonb;
  v_profile public.profiles%rowtype;
begin
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 180, v_token
  );
  if v_result ->> 'status' <> 'claimed' then
    raise exception 'permanent_debt_fixture_claim_failed:%', v_result;
  end if;

  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', v_user_id::text, true
  );
  update public.profiles
     set credits = credits - 1000
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', '', true
  );
  select * into v_profile from public.profiles where id = v_user_id;
  if v_profile.credits <> -60
     or v_profile.permanent_credits <> 0
     or v_profile.permanent_credit_debt <> 60 then
    raise exception 'permanent_debt_fixture_adjustment_failed:%',
      row_to_json(v_profile);
  end if;

  v_result := public.fail_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token, 'provider_error'
  );
  select * into v_profile from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'refunded'
     or v_profile.credits <> 120
     or v_profile.permanent_credits <> 0
     or v_profile.permanent_credit_debt <> 0
     or v_profile.credits_expires_at is distinct from
       '2035-01-02 03:04:05+00'::timestamptz then
    raise exception 'permanent_debt_refund_reconciliation_failed:%:%',
      v_result, row_to_json(v_profile);
  end if;
end;
$refund_reconciles_new_permanent_debt$;

do $normalize_after_mixed_refund$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_profile public.profiles%rowtype;
begin
  update public.profiles
     set credits = 0
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', v_user_id::text, true
  );
  update public.profiles
     set credits = 1000
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', '', true
  );
  select * into v_profile from public.profiles where id = v_user_id;
  if v_profile.credits <> 1000
     or v_profile.permanent_credits <> 1000
     or v_profile.permanent_credit_debt <> 0
     or v_profile.credits_expires_at is not null then
    raise exception 'generation_fixture_normalization_failed:%',
      row_to_json(v_profile);
  end if;
end;
$normalize_after_mixed_refund$;

do $claim_complete_replay$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'explicit:' || repeat('1', 64);
  v_fingerprint text := repeat('a', 64);
  v_token text := repeat('1', 64);
  v_result jsonb;
  v_manifest jsonb := jsonb_build_object(
    'version', 1,
    'provider', 'gpt',
    'model', 'gpt-image-2',
    'objects', jsonb_build_array(jsonb_build_object(
      'path', v_user_id::text || '/explicit/' || repeat('1', 64) || '/1/0.png',
      'mimeType', 'image/png',
      'sha256', repeat('b', 64)
    ))
  );
  v_credits integer;
begin
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, v_token
  );
  if v_result ->> 'status' <> 'claimed'
     or (v_result ->> 'credits_remaining')::integer <> 940 then
    raise exception 'first_claim_failed:%', v_result;
  end if;

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, repeat('9', 64)
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'in_progress' or v_credits <> 940 then
    raise exception 'duplicate_claim_debited_twice:%:%', v_result, v_credits;
  end if;

  v_result := public.complete_image_generation_request(
    v_user_id,
    v_key,
    v_fingerprint,
    1,
    v_token,
    '{"provider":"gpt","model":"gpt-image-2"}'::jsonb
  );
  if v_result ->> 'status' <> 'invalid_result_manifest' then
    raise exception 'missing_manifest_keys_were_accepted:%', v_result;
  end if;

  v_result := public.complete_image_generation_request(
    v_user_id,
    v_key,
    v_fingerprint,
    1,
    v_token,
    jsonb_set(
      v_manifest,
      '{objects,0,path}',
      to_jsonb(v_user_id::text || '/explicit/' || repeat('9', 64) || '/1/0.png')
    )
  );
  if v_result ->> 'status' <> 'invalid_result_manifest' then
    raise exception 'cross_request_manifest_was_accepted:%', v_result;
  end if;

  v_result := public.complete_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token, v_manifest
  );
  if v_result ->> 'status' <> 'completed' then
    raise exception 'completion_failed:%', v_result;
  end if;

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, repeat('8', 64)
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'replay'
     or v_result -> 'result_manifest' <> v_manifest
     or v_credits <> 940 then
    raise exception 'completed_replay_failed:%:%', v_result, v_credits;
  end if;
end;
$claim_complete_replay$;

do $failure_refund_and_retry$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'explicit:' || repeat('2', 64);
  v_fingerprint text := repeat('c', 64);
  v_token_1 text := repeat('2', 64);
  v_token_2 text := repeat('7', 64);
  v_result jsonb;
  v_credits integer;
begin
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, v_token_1
  );
  if v_result ->> 'status' <> 'claimed' then
    raise exception 'failure_fixture_claim_failed:%', v_result;
  end if;

  v_result := public.fail_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1, 'provider_error'
  );
  if v_result ->> 'status' <> 'refunded' then
    raise exception 'failure_refund_failed:%', v_result;
  end if;

  v_result := public.fail_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1, 'provider_error'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'already_refunded' or v_credits <> 940 then
    raise exception 'failure_double_refunded:%:%', v_result, v_credits;
  end if;

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, v_token_2
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'claimed'
     or (v_result ->> 'attempt')::integer <> 2
     or v_credits <> 880 then
    raise exception 'failed_request_retry_failed:%:%', v_result, v_credits;
  end if;
end;
$failure_refund_and_retry$;

do $stale_reconciliation$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'explicit:' || repeat('3', 64);
  v_fingerprint text := repeat('d', 64);
  v_token_1 text := repeat('3', 64);
  v_token_2 text := repeat('8', 64);
  v_result jsonb;
  v_stale_manifest jsonb := jsonb_build_object(
    'version', 1,
    'provider', 'gpt',
    'model', 'gpt-image-2',
    'objects', jsonb_build_array(jsonb_build_object(
      'path', v_user_id::text || '/explicit/' || repeat('3', 64) || '/1/0.png',
      'mimeType', 'image/png',
      'sha256', repeat('3', 64)
    ))
  );
  v_credits integer;
  v_reconciled integer;
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
begin
  select * into v_before from public.profiles where id = v_user_id;
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, v_token_1
  );
  if v_result ->> 'status' <> 'claimed' then
    raise exception 'stale_fixture_claim_failed:%', v_result;
  end if;

  update public.image_generation_requests
     set updated_at = now() - interval '16 minutes'
   where user_id = v_user_id and request_key = v_key;

  v_reconciled := public.reconcile_stale_image_generation_requests(
    interval '15 minutes'
  );
  select * into v_after from public.profiles where id = v_user_id;
  v_credits := v_after.credits;
  if v_reconciled <> 1
     or v_after.credits <> v_before.credits
     or v_after.permanent_credits <> v_before.permanent_credits
     or v_after.permanent_credit_debt <> v_before.permanent_credit_debt
     or v_after.credits_expires_at is distinct from
       v_before.credits_expires_at then
    raise exception 'stale_refund_failed:%:%:%',
      v_reconciled, row_to_json(v_before), row_to_json(v_after);
  end if;

  v_reconciled := public.reconcile_stale_image_generation_requests(
    interval '15 minutes'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_reconciled <> 0 or v_credits <> 880 then
    raise exception 'stale_refund_was_not_idempotent:%:%', v_reconciled, v_credits;
  end if;

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, false, 60, v_token_2
  );
  if v_result ->> 'status' <> 'claimed'
     or (v_result ->> 'attempt')::integer <> 2 then
    raise exception 'stale_retry_claim_failed:%', v_result;
  end if;

  v_result := public.get_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1
  );
  if v_result ->> 'status' <> 'stale_attempt' then
    raise exception 'stale_worker_observed_new_attempt:%', v_result;
  end if;

  v_result := public.complete_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1, v_stale_manifest
  );
  if v_result ->> 'status' <> 'stale_attempt' then
    raise exception 'stale_worker_completed_new_attempt:%', v_result;
  end if;

  v_result := public.fail_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1, 'provider_error'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'stale_attempt'
     or v_credits <> v_before.credits - 60
     or not exists (
       select 1
         from public.image_generation_requests as ledger
        where ledger.user_id = v_user_id
          and ledger.request_key = v_key
          and ledger.status = 'processing'
          and ledger.attempt = 2
          and ledger.result_manifest is null
     ) then
    raise exception 'stale_worker_refunded_new_attempt:%:%',
      v_result, v_credits;
  end if;
end;
$stale_reconciliation$;

do $legacy_replay_window$
declare
  v_user_id uuid := current_setting('x5.generation_test_user')::uuid;
  v_key text := 'legacy:' || repeat('4', 64);
  v_fingerprint text := repeat('4', 64);
  v_token_1 text := repeat('4', 64);
  v_token_2 text := repeat('7', 64);
  v_result jsonb;
  v_manifest jsonb := jsonb_build_object(
    'version', 1,
    'provider', 'gpt',
    'model', 'gpt-image-2',
    'objects', jsonb_build_array(jsonb_build_object(
      'path', v_user_id::text || '/legacy/' || repeat('4', 64) || '/1/0.jpg',
      'mimeType', 'image/jpeg',
      'sha256', repeat('e', 64)
    ))
  );
begin
  -- Legacy clients have no explicit request ID. The short window absorbs a
  -- network retry, then the same prompt becomes an intentional new generation.
  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, true, 60, v_token_1
  );
  perform public.complete_image_generation_request(
    v_user_id, v_key, v_fingerprint, 1, v_token_1, v_manifest
  );

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, true, 60, repeat('9', 64)
  );
  if v_result ->> 'status' <> 'replay' then
    raise exception 'legacy_short_window_did_not_replay:%', v_result;
  end if;

  update public.image_generation_requests
     set completed_at = now() - interval '3 minutes'
   where user_id = v_user_id and request_key = v_key;

  v_result := public.claim_image_generation_request(
    v_user_id, v_key, v_fingerprint, true, 60, v_token_2
  );
  if v_result ->> 'status' <> 'claimed'
     or (v_result ->> 'attempt')::integer <> 2 then
    raise exception 'legacy_window_did_not_allow_new_generation:%', v_result;
  end if;
end;
$legacy_replay_window$;

rollback;

select 'image_generation_debit_refund_and_replay_are_idempotent' as status;
