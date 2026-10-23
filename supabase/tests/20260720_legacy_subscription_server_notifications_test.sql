begin;

do $acl$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_subscription_lifecycle(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_verified_app_store_subscription_lifecycle(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'legacy_plan_lifecycle_is_client_callable';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_subscription_lifecycle(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'legacy_plan_lifecycle_is_not_service_callable';
  end if;
  if has_function_privilege(
    'service_role',
    'public.x5_apply_verified_app_store_legacy_plan_lifecycle(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'legacy_plan_internal_helper_is_public';
  end if;
end;
$acl$;

do $exact_once$
declare
  v_user_id uuid;
  v_other_user_id uuid;
  v_products constant text[] := array[
    'com.x5studio.app.lite.monthly',
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.max.monthly'
  ];
  v_credits constant integer[] := array[1000, 2000, 5000];
  v_event_ids constant uuid[] := array[
    'a7210000-0000-4000-8000-000000000001'::uuid,
    'a7210000-0000-4000-8000-000000000002'::uuid,
    'a7210000-0000-4000-8000-000000000003'::uuid
  ];
  v_second_event_ids constant uuid[] := array[
    'a7210000-0000-4000-8000-000000000011'::uuid,
    'a7210000-0000-4000-8000-000000000012'::uuid,
    'a7210000-0000-4000-8000-000000000013'::uuid
  ];
  v_index integer;
  v_before integer;
  v_after integer;
  v_purchase timestamptz;
  v_transaction_signed timestamptz;
  v_renewal_signed timestamptz;
  v_notification_signed timestamptz;
  v_expires timestamptz;
  v_transaction_id text;
  v_original_transaction_id text;
  v_response jsonb;
  v_rejected boolean := false;
begin
  select id into v_user_id from public.profiles order by id limit 1;
  select id into v_other_user_id
    from public.profiles
   where id <> v_user_id
   order by id
   limit 1;
  if v_user_id is null then
    raise exception 'legacy_plan_profile_fixture_required';
  end if;

  for v_index in 1..3 loop
    v_purchase := clock_timestamp() - interval '1 minute';
    v_transaction_signed := clock_timestamp() - interval '30 seconds';
    v_renewal_signed := clock_timestamp() - interval '20 seconds';
    v_notification_signed := clock_timestamp() - interval '10 seconds';
    v_expires := clock_timestamp() + make_interval(months => v_index);
    v_transaction_id := 'codex-legacy-plan-v2-tx-' || v_index;
    v_original_transaction_id := 'codex-legacy-plan-v2-chain-' || v_index;
    select credits into v_before
      from public.profiles where id = v_user_id;

    v_response := public.apply_verified_app_store_subscription_lifecycle(
      v_event_ids[v_index],
      case when v_index = 1 then 'SUBSCRIBED' else 'DID_RENEW' end,
      case when v_index = 1 then 'INITIAL_BUY' else null end,
      v_notification_signed, v_user_id, v_transaction_id,
      v_original_transaction_id, v_products[v_index], 'Production',
      v_user_id, v_purchase, v_expires, v_transaction_signed,
      v_renewal_signed, null, null, 1
    );
    select credits into v_after
      from public.profiles where id = v_user_id;
    if v_response ->> 'status' <> 'applied'
       or (v_response ->> 'credits_granted')::integer <> v_credits[v_index]
       or v_after <> v_before + v_credits[v_index] then
      raise exception 'legacy_plan_initial_grant_failed:%', v_response;
    end if;

    v_response := public.apply_verified_app_store_subscription_lifecycle(
      v_event_ids[v_index],
      case when v_index = 1 then 'SUBSCRIBED' else 'DID_RENEW' end,
      case when v_index = 1 then 'INITIAL_BUY' else null end,
      v_notification_signed, v_user_id, v_transaction_id,
      v_original_transaction_id, v_products[v_index], 'Production',
      v_user_id, v_purchase, v_expires, v_transaction_signed,
      v_renewal_signed, null, null, 1
    );
    if v_response ->> 'status' <> 'already_applied'
       or (select credits from public.profiles where id = v_user_id)
          <> v_after then
      raise exception 'legacy_plan_event_replay_was_not_exact_once:%',
        v_response;
    end if;

    -- A second genuine Apple notification UUID for the same signed StoreKit
    -- transaction is also harmless because transaction_id is the grant key.
    v_response := public.apply_verified_app_store_subscription_lifecycle(
      v_second_event_ids[v_index],
      case when v_index = 1 then 'SUBSCRIBED' else 'DID_RENEW' end,
      case when v_index = 1 then 'INITIAL_BUY' else null end,
      v_notification_signed, v_user_id, v_transaction_id,
      v_original_transaction_id, v_products[v_index], 'Production',
      v_user_id, v_purchase, v_expires, v_transaction_signed,
      v_renewal_signed, null, null, 1
    );
    if v_response ->> 'status' <> 'already_applied'
       or (select credits from public.profiles where id = v_user_id)
          <> v_after then
      raise exception 'legacy_plan_transaction_replay_was_not_exact_once:%',
        v_response;
    end if;
  end loop;

  begin
    perform public.apply_verified_app_store_subscription_lifecycle(
      'a7210000-0000-4000-8000-000000000021'::uuid,
      'EXPIRED', null, clock_timestamp(), v_user_id,
      'codex-legacy-plan-terminal-tx', 'codex-legacy-plan-terminal-chain',
      v_products[1], 'Production', v_user_id,
      clock_timestamp() - interval '1 month', clock_timestamp(),
      clock_timestamp(), clock_timestamp(), null, null, 0
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'legacy_plan_unsupported_notification_type' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'legacy_plan_terminal_event_was_accepted';
  end if;

  if v_other_user_id is not null then
    v_rejected := false;
    begin
      perform public.apply_verified_app_store_subscription_lifecycle(
        'a7210000-0000-4000-8000-000000000022'::uuid,
        'SUBSCRIBED', 'INITIAL_BUY', clock_timestamp(), v_user_id,
        'codex-legacy-plan-owner-tx', 'codex-legacy-plan-owner-chain',
        v_products[1], 'Production', v_other_user_id,
        clock_timestamp() - interval '1 minute',
        clock_timestamp() + interval '1 month',
        clock_timestamp(), clock_timestamp(), null, null, 1
      );
    exception when sqlstate '22023' then
      if sqlerrm <> 'owned_by_other' then raise; end if;
      v_rejected := true;
    end;
    if not v_rejected then
      raise exception 'legacy_plan_cross_account_grant_was_accepted';
    end if;
  end if;
end;
$exact_once$;

rollback;
