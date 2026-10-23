begin;

do $acl$
begin
  if has_table_privilege(
    'authenticated', 'public.voice_generation_requests', 'select'
  ) or has_table_privilege(
    'service_role', 'public.voice_generation_requests', 'select'
  ) or has_table_privilege(
    'authenticated', 'public.account_deletion_jobs', 'select'
  ) or has_table_privilege(
    'service_role', 'public.account_deletion_jobs', 'select'
  ) then
    raise exception 'voice_private_tables_are_directly_readable';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.claim_voice_generation_request(uuid,text,text,integer,text)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.claim_voice_generation_request(uuid,text,text,integer,text)',
    'execute'
  ) then
    raise exception 'voice_claim_rpc_acl_invalid';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.x5_delete_eq_if_exists(text,text,uuid)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'public.x5_delete_eq_if_exists(text,text,uuid)',
    'execute'
  ) then
    raise exception 'account_deletion_helper_is_externally_callable';
  end if;

  if not has_function_privilege(
    'authenticated', 'public.delete_own_account()', 'execute'
  ) or has_function_privilege(
    'anon', 'public.delete_own_account()', 'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.finalize_queued_account_deletion(uuid,text)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.finalize_queued_account_deletion(uuid,text)',
    'execute'
  ) then
    raise exception 'account_deletion_rpc_acl_invalid';
  end if;
end;
$acl$;

select pg_catalog.set_config(
  'x5.voice_test_user',
  (
    select profile.id::text
      from public.profiles as profile
     order by profile.id
     limit 1
  ),
  true
);

do $fixtures$
declare
  v_user_id uuid := nullif(
    current_setting('x5.voice_test_user', true), ''
  )::uuid;
  v_existing_debt integer;
begin
  if v_user_id is null then
    raise exception 'voice_test_profile_required';
  end if;

  delete from public.account_deletion_jobs where user_id = v_user_id;
  delete from public.voice_generation_requests
   where user_id = v_user_id
     and request_key in (
       'explicit:' || repeat('1', 64),
       'explicit:' || repeat('2', 64),
       'explicit:' || repeat('3', 64),
       'explicit:' || repeat('4', 64),
       'explicit:' || repeat('5', 64),
       'explicit:' || repeat('6', 64)
     );

  update public.profiles set credits = 0 where id = v_user_id;
  select greatest(coalesce(permanent_credit_debt, 0), 0)
    into v_existing_debt
    from public.profiles
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', v_user_id::text, true
  );
  update public.profiles
     set credits = v_existing_debt + 600
   where id = v_user_id;
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', '', true
  );
  update public.profiles
     set credits = 600,
         credits_expires_at = null
   where id = v_user_id;
end;
$fixtures$;

do $exact_once_completion$
declare
  v_user_id uuid := current_setting('x5.voice_test_user')::uuid;
  v_key text := 'explicit:' || repeat('1', 64);
  v_fingerprint text := repeat('a', 64);
  v_token text := repeat('A', 64);
  v_provider text := 'fal_voice_request_0001';
  v_result jsonb;
  v_manifest jsonb;
  v_credits integer;
begin
  v_result := public.claim_voice_generation_request(
    v_user_id, v_key, v_fingerprint, 60, v_token
  );
  if v_result ->> 'status' <> 'claimed'
     or (v_result ->> 'credits_remaining')::integer <> 540 then
    raise exception 'voice_first_claim_failed:%', v_result;
  end if;

  v_result := public.claim_voice_generation_request(
    v_user_id, v_key, v_fingerprint, 60, v_token
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'in_progress' or v_credits <> 540 then
    raise exception 'voice_duplicate_claim_redebit:%:%', v_result, v_credits;
  end if;

  v_result := public.bind_voice_generation_provider_request(
    v_user_id, v_key, v_fingerprint, 1, v_token, v_provider
  );
  if v_result ->> 'status' <> 'bound' then
    raise exception 'voice_provider_bind_failed:%', v_result;
  end if;

  v_manifest := jsonb_build_object(
    'version', 1,
    'provider', 'fal',
    'model', 'fal-ai/elevenlabs/tts/eleven-v3',
    'object', jsonb_build_object(
      'path',
        v_user_id::text || '/explicit/' || repeat('1', 64) ||
          '/1/audio.mp3',
      'mimeType', 'audio/mpeg',
      'sha256', repeat('b', 64)
    )
  );
  v_result := public.complete_voice_generation_by_provider(
    v_user_id, v_key, v_fingerprint, v_provider, v_manifest
  );
  if v_result ->> 'status' <> 'completed' then
    raise exception 'voice_completion_failed:%', v_result;
  end if;

  v_result := public.claim_voice_generation_request(
    v_user_id, v_key, v_fingerprint, 60, v_token
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'replay' or v_credits <> 540 then
    raise exception 'voice_completion_replay_redebit:%:%',
      v_result, v_credits;
  end if;
end;
$exact_once_completion$;

do $lost_submit_webhook_recovery$
declare
  v_user_id uuid := current_setting('x5.voice_test_user')::uuid;
  v_key text := 'explicit:' || repeat('2', 64);
  v_fingerprint text := repeat('c', 64);
  v_token text := repeat('B', 64);
  v_provider text := 'fal_voice_request_0002';
  v_result jsonb;
  v_credits integer;
begin
  v_result := public.claim_voice_generation_request(
    v_user_id, v_key, v_fingerprint, 60, v_token
  );
  if v_result ->> 'status' <> 'claimed' then
    raise exception 'voice_lost_submit_claim_failed:%', v_result;
  end if;
  v_result := public.mark_voice_generation_submission_ambiguous(
    v_user_id, v_key, v_fingerprint, 1, v_token
  );
  if v_result ->> 'status' <> 'marked' then
    raise exception 'voice_ambiguous_marker_failed:%', v_result;
  end if;

  v_result := public.bind_voice_generation_webhook(
    v_token, 1, v_provider
  );
  if v_result ->> 'status' <> 'bound'
     or v_result ->> 'user_id' <> v_user_id::text then
    raise exception 'voice_webhook_recovery_failed:%', v_result;
  end if;
  if exists (
    select 1
      from public.voice_generation_requests
     where user_id = v_user_id
       and request_key = v_key
       and (
         provider_request_id is distinct from v_provider
         or submission_ambiguous_at is not null
       )
  ) then
    raise exception 'voice_webhook_binding_state_invalid';
  end if;

  v_result := public.fail_voice_generation_by_provider(
    v_user_id, v_key, v_fingerprint, v_provider, 'provider_terminal_failure'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_result ->> 'status' <> 'refunded' or v_credits <> 540 then
    raise exception 'voice_webhook_failure_refund_failed:%:%',
      v_result, v_credits;
  end if;
end;
$lost_submit_webhook_recovery$;

do $reconciliation_evidence$
declare
  v_user_id uuid := current_setting('x5.voice_test_user')::uuid;
  v_key_ambiguous text := 'explicit:' || repeat('3', 64);
  v_key_rejected text := 'explicit:' || repeat('4', 64);
  v_fingerprint_ambiguous text := repeat('d', 64);
  v_fingerprint_rejected text := repeat('e', 64);
  v_token_ambiguous text := repeat('C', 64);
  v_token_rejected text := repeat('D', 64);
  v_result jsonb;
  v_reconciled integer;
  v_credits integer;
begin
  v_result := public.claim_voice_generation_request(
    v_user_id, v_key_ambiguous, v_fingerprint_ambiguous,
    60, v_token_ambiguous
  );
  v_result := public.mark_voice_generation_submission_ambiguous(
    v_user_id, v_key_ambiguous, v_fingerprint_ambiguous,
    1, v_token_ambiguous
  );
  if v_result ->> 'status' <> 'marked' then
    raise exception 'voice_ambiguous_reconcile_fixture_failed:%', v_result;
  end if;
  update public.voice_generation_requests
     set updated_at = now() - interval '1 hour'
   where user_id = v_user_id and request_key = v_key_ambiguous;
  v_reconciled := public.reconcile_stale_voice_generation_requests(
    interval '5 minutes'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_credits <> 480
     or not exists (
       select 1 from public.voice_generation_requests
        where user_id = v_user_id
          and request_key = v_key_ambiguous
          and status = 'processing'
          and submission_ambiguous_at is not null
     ) then
    raise exception 'voice_ambiguous_submit_was_blindly_refunded:%:%',
      v_reconciled, v_credits;
  end if;
  perform public.fail_voice_generation_request(
    v_user_id, v_key_ambiguous, v_fingerprint_ambiguous,
    1, v_token_ambiguous, 'test_cleanup'
  );

  v_result := public.claim_voice_generation_request(
    v_user_id, v_key_rejected, v_fingerprint_rejected,
    60, v_token_rejected
  );
  v_result := public.mark_voice_generation_submission_rejected(
    v_user_id, v_key_rejected, v_fingerprint_rejected,
    1, v_token_rejected
  );
  if v_result ->> 'status' <> 'marked' then
    raise exception 'voice_rejected_reconcile_fixture_failed:%', v_result;
  end if;
  update public.voice_generation_requests
     set updated_at = now() - interval '1 hour'
   where user_id = v_user_id and request_key = v_key_rejected;
  v_reconciled := public.reconcile_stale_voice_generation_requests(
    interval '5 minutes'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_reconciled < 1
     or v_credits <> 540
     or not exists (
       select 1 from public.voice_generation_requests
        where user_id = v_user_id
          and request_key = v_key_rejected
          and status = 'refunded'
     ) then
    raise exception 'voice_terminal_rejection_not_reconciled:%:%',
      v_reconciled, v_credits;
  end if;
end;
$reconciliation_evidence$;

do $expired_delivery_refund$
declare
  v_user_id uuid := current_setting('x5.voice_test_user')::uuid;
  v_key text := 'explicit:' || repeat('5', 64);
  v_fingerprint text := repeat('f', 64);
  v_token text := repeat('E', 64);
  v_result jsonb;
  v_credits integer;
begin
  v_result := public.claim_voice_generation_request(
    v_user_id, v_key, v_fingerprint, 60, v_token
  );
  if v_result ->> 'status' <> 'claimed' then
    raise exception 'voice_expiry_claim_failed:%', v_result;
  end if;
  v_result := public.mark_voice_generation_submission_ambiguous(
    v_user_id, v_key, v_fingerprint, 1, v_token
  );
  if v_result ->> 'status' <> 'marked' then
    raise exception 'voice_expiry_ambiguous_fixture_failed:%', v_result;
  end if;
  update public.voice_generation_requests
     set updated_at = now() - interval '5 hours'
   where user_id = v_user_id and request_key = v_key;
  perform public.reconcile_stale_voice_generation_requests(
    interval '5 minutes'
  );
  select credits into v_credits from public.profiles where id = v_user_id;
  if v_credits <> 540
     or not exists (
       select 1 from public.voice_generation_requests
        where user_id = v_user_id
          and request_key = v_key
          and status = 'refunded'
          and error_code = 'generation_expired'
     ) then
    raise exception 'voice_expired_delivery_not_refunded:%', v_credits;
  end if;
end;
$expired_delivery_refund$;

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claim.sub',
  current_setting('x5.voice_test_user'),
  true
);
select public.delete_own_account();
reset role;

do $deletion_tombstone$
declare
  v_user_id uuid := current_setting('x5.voice_test_user')::uuid;
  v_credits integer;
  v_result jsonb;
begin
  if not exists (
    select 1 from public.account_deletion_jobs
     where user_id = v_user_id and status = 'pending'
  ) or not exists (
    select 1 from public.profiles where id = v_user_id
  ) then
    raise exception 'account_deletion_was_not_durably_queued';
  end if;

  select credits into v_credits from public.profiles where id = v_user_id;
  v_result := public.claim_voice_generation_request(
    v_user_id,
    'explicit:' || repeat('6', 64),
    repeat('0', 64),
    60,
    repeat('F', 64)
  );
  if v_result ->> 'status' <> 'account_deleting'
     or (select credits from public.profiles where id = v_user_id) <>
        v_credits then
    raise exception 'account_deletion_tombstone_did_not_block_debit:%',
      v_result;
  end if;
end;
$deletion_tombstone$;

rollback;
