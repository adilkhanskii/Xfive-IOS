begin;

do $acl_tests$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_server_notification(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_verified_app_store_server_notification(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) then
    raise exception 'server_notification_rpc_is_client_callable';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_server_notification(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) then
    raise exception 'server_notification_rpc_is_not_service_callable';
  end if;

  if has_table_privilege(
    'service_role', 'public.app_store_server_notification_events', 'select'
  ) or has_table_privilege(
    'service_role', 'public.app_store_server_notification_events', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.app_store_server_notification_events', 'select'
  ) or has_table_privilege(
    'anon', 'public.app_store_server_notification_events', 'select'
  ) or has_table_privilege(
    'service_role',
    'public.app_store_server_notification_grant_adjustments', 'select'
  ) or has_table_privilege(
    'authenticated',
    'public.app_store_server_notification_grant_adjustments', 'select'
  ) then
    raise exception 'server_notification_ledger_is_not_private';
  end if;
end;
$acl_tests$;

select set_config(
  'x5.server_notification_user_id',
  (select id::text from public.profiles order by id limit 1),
  true
);

do $server_notification_tests$
declare
  v_uid uuid := nullif(
    current_setting('x5.server_notification_user_id', true), ''
  )::uuid;
  v_purchase timestamptz := clock_timestamp() - interval '20 minutes';
  v_base_signed timestamptz := clock_timestamp() - interval '10 minutes';
  v_subscription_expires timestamptz :=
    clock_timestamp() + interval '20 days';
  v_response jsonb;
  v_credits integer;
  v_pending integer;
  v_rejected boolean;
begin
  if v_uid is null then
    raise exception 'server_notification_test_user_not_found';
  end if;

  -- Isolate the rollback-only fixture from any real active verification source
  -- belonging to the selected profile.
  delete from public.app_store_verified_revocations where user_id = v_uid;
  delete from public.app_store_transactions
   where user_id = v_uid
     and product_id = 'com.x5studio.app.verified.monthly';
  delete from public.app_store_sandbox_review_transactions
   where user_id = v_uid
     and product_id = 'com.x5studio.app.verified.monthly';
  delete from public.iap_entitlements
   where user_id = v_uid
     and product_id in (
       'com.x5studio.app.verified.monthly',
       'x5_verified_monthly_v2',
       'x5_verified_monthly'
     );
  update public.profiles
     set credits = 0, is_verified = false, verified_until = null
   where id = v_uid;

  insert into public.app_store_consumable_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, signed_date,
    revocation_date, quantity, credits_granted
  ) values (
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund', v_uid,
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, v_purchase + interval '1 minute', null, 1, 1000
  );

  -- prorated_refund: 40%, then cumulative 60%, subtracts only the extra 20%.
  v_response := public.apply_verified_app_store_server_notification(
    '10000000-0000-4000-8000-000000000001', 'REFUND',
    v_base_signed + interval '1 minute', v_uid,
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed,
    v_base_signed - interval '1 minute', 40000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> -400 then
    raise exception 'prorated_refund_40_failed:%:%', v_response, v_credits;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '10000000-0000-4000-8000-000000000002', 'REFUND',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '2 minutes',
    v_base_signed + interval '1 minute', 60000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> -600 then
    raise exception 'prorated_refund_60_failed:%:%', v_response, v_credits;
  end if;

  -- duplicate_notification UUID and exact payload are idempotent.
  v_response := public.apply_verified_app_store_server_notification(
    '10000000-0000-4000-8000-000000000002', 'REFUND',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '2 minutes',
    v_base_signed + interval '1 minute', 60000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'already_applied' or v_credits <> -600 then
    raise exception 'duplicate_notification_was_not_idempotent:%:%',
      v_response, v_credits;
  end if;

  -- An older delivery is logged, but cannot roll the projection forward.
  v_response := public.apply_verified_app_store_server_notification(
    '10000000-0000-4000-8000-000000000003', 'REFUND',
    v_base_signed + interval '4 minutes', v_uid,
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '1 minute',
    v_base_signed, 80000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'ignored_stale' or v_credits <> -600 then
    raise exception 'stale_refund_changed_balance:%:%', v_response, v_credits;
  end if;

  -- StoreKit's on-device reconciliation does not carry Apple's cumulative
  -- refund percentage. Once a server projection exists it must remain
  -- authoritative, even if the device JWS is re-signed later.
  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid,
    'codex-assn-prorated-refund',
    'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase,
    v_base_signed + interval '4 minutes',
    v_base_signed + interval '3 minutes',
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'already_applied' or v_credits <> -600 then
    raise exception 'device_bridge_overrode_server_projection:%:%',
      v_response, v_credits;
  end if;

  -- REFUND_REVERSED restores the exact amount withheld across partial events.
  v_response := public.apply_verified_app_store_server_notification(
    '10000000-0000-4000-8000-000000000004', 'REFUND_REVERSED',
    v_base_signed + interval '6 minutes', v_uid,
    'codex-assn-prorated-refund', 'codex-assn-prorated-refund',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '5 minutes',
    null, null, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> 0 then
    raise exception 'refund_reversal_exact_restore_failed:%:%',
      v_response, v_credits;
  end if;

  -- refund_before_grant creates an active zero-credit projection and the
  -- direct-insert trigger must reject the late grant.
  v_response := public.apply_verified_app_store_server_notification(
    '20000000-0000-4000-8000-000000000001', 'REFUND',
    v_base_signed + interval '1 minute', v_uid,
    'codex-assn-refund-before-grant', 'codex-assn-refund-before-grant',
    'com.x5studio.app.credits.2000', 'Production', v_uid,
    v_purchase, null, v_base_signed,
    v_base_signed - interval '1 minute', 100000, 1
  );
  if v_response ->> 'status' <> 'applied' then
    raise exception 'refund_before_grant_projection_failed:%', v_response;
  end if;
  select credits into v_credits from public.profiles where id = v_uid;
  select pending_credits_withheld into v_pending
    from public.app_store_server_notification_state
   where environment = 'Production'
     and transaction_id = 'codex-assn-refund-before-grant';
  if v_credits <> 0 or v_pending <> 2000 then
    raise exception 'refund_before_grant_debited_ungranted_pack:%:%',
      v_credits, v_pending;
  end if;

  v_rejected := false;
  begin
    insert into public.app_store_consumable_transactions (
      transaction_id, original_transaction_id, user_id, product_id,
      environment, app_account_token, purchase_date, signed_date,
      revocation_date, quantity, credits_granted
    ) values (
      'codex-assn-refund-before-grant', 'codex-assn-refund-before-grant',
      v_uid, 'com.x5studio.app.credits.2000', 'Production', v_uid,
      v_purchase, v_base_signed + interval '2 minutes', null, 1, 2000
    );
  exception when sqlstate '22023' then
    v_rejected := sqlerrm = 'app_store_notification_refund_active';
  end;
  if not v_rejected then
    raise exception 'refund_before_grant_direct_insert_was_not_blocked';
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '20000000-0000-4000-8000-000000000002', 'REFUND_REVERSED',
    v_base_signed + interval '4 minutes', v_uid,
    'codex-assn-refund-before-grant', 'codex-assn-refund-before-grant',
    'com.x5studio.app.credits.2000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '3 minutes',
    null, null, 1
  );
  insert into public.app_store_consumable_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, signed_date,
    revocation_date, quantity, credits_granted
  ) values (
    'codex-assn-refund-before-grant', 'codex-assn-refund-before-grant',
    v_uid, 'com.x5studio.app.credits.2000', 'Production', v_uid,
    v_purchase, v_base_signed + interval '4 minutes', null, 1, 2000
  );

  -- reversal_before_refund: the newer reversal wins and the delayed old
  -- refund remains an audit event with zero delta.
  v_response := public.apply_verified_app_store_server_notification(
    '30000000-0000-4000-8000-000000000001', 'REFUND_REVERSED',
    v_base_signed + interval '6 minutes', v_uid,
    'codex-assn-reversal-before-refund',
    'codex-assn-reversal-before-refund',
    'com.x5studio.app.credits.5000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '5 minutes',
    null, null, 1
  );
  v_response := public.apply_verified_app_store_server_notification(
    '30000000-0000-4000-8000-000000000002', 'REFUND',
    v_base_signed + interval '7 minutes', v_uid,
    'codex-assn-reversal-before-refund',
    'codex-assn-reversal-before-refund',
    'com.x5studio.app.credits.5000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '4 minutes',
    v_base_signed + interval '3 minutes', 100000, 1
  );
  if v_response ->> 'status' <> 'ignored_stale' then
    raise exception 'reversal_before_refund_ordering_failed:%', v_response;
  end if;

  -- A partial refund can arrive before StoreKit replays the purchase. The
  -- verified grant must still record the purchase and credit only the
  -- unrefunded remainder (1000 - 40% = 600).
  v_response := public.apply_verified_app_store_server_notification(
    '35000000-0000-4000-8000-000000000001', 'REFUND',
    v_base_signed + interval '1 minute', v_uid,
    'codex-assn-partial-before-grant',
    'codex-assn-partial-before-grant',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed,
    v_base_signed - interval '1 minute', 40000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  select pending_credits_withheld into v_pending
    from public.app_store_server_notification_state
   where environment = 'Production'
     and transaction_id = 'codex-assn-partial-before-grant';
  if v_credits <> 0 or v_pending <> 400 then
    raise exception 'partial_refund_before_grant_was_not_pending:%:%',
      v_credits, v_pending;
  end if;
  v_response := public.apply_verified_app_store_consumable(
    v_uid,
    'codex-assn-partial-before-grant',
    'codex-assn-partial-before-grant',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase,
    v_purchase + interval '1 minute',
    null,
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_credits <> 600 or not exists (
    select 1 from public.app_store_consumable_transactions
     where transaction_id = 'codex-assn-partial-before-grant'
  ) then
    raise exception 'partial_refund_before_grant_lost_remainder:%:%',
      v_response, v_credits;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '35000000-0000-4000-8000-000000000002', 'REFUND_REVERSED',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-partial-before-grant',
    'codex-assn-partial-before-grant',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '2 minutes',
    null, null, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_credits <> 1000 then
    raise exception 'partial_refund_before_grant_reversal_failed:%:%',
      v_response, v_credits;
  end if;

  update public.profiles set credits = 0 where id = v_uid;

  -- If the percentage-free device bridge arrives first, an official server
  -- notification with the same transaction signedDate must correct the
  -- conservative 100% hold to Apple's exact cumulative percentage.
  insert into public.app_store_consumable_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, signed_date,
    revocation_date, quantity, credits_granted
  ) values (
    'codex-assn-device-first', 'codex-assn-device-first', v_uid,
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, v_purchase + interval '1 minute', null, 1, 1000
  );
  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid, 'codex-assn-device-first', 'codex-assn-device-first',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, v_base_signed, v_base_signed - interval '1 minute', 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_credits <> -1000 then
    raise exception 'device_first_refund_did_not_apply:%:%',
      v_response, v_credits;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '35500000-0000-4000-8000-000000000001', 'REFUND',
    v_base_signed + interval '1 minute', v_uid,
    'codex-assn-device-first', 'codex-assn-device-first',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed,
    v_base_signed - interval '1 minute', 40000, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> -400 then
    raise exception 'server_percentage_did_not_correct_device_refund:%:%',
      v_response, v_credits;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '35500000-0000-4000-8000-000000000002', 'REFUND_REVERSED',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-device-first', 'codex-assn-device-first',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '2 minutes',
    null, null, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_credits <> 0 then
    raise exception 'device_first_refund_reversal_failed:%:%',
      v_response, v_credits;
  end if;

  update public.profiles set credits = 0 where id = v_uid;

  -- A refund row created by the pre-webhook device path remains authoritative
  -- until a newer canonical reversal arrives. The reversal must then override
  -- (but never delete) that immutable legacy audit row and allow the grant.
  insert into public.app_store_consumable_refunds (
    environment, transaction_id, original_transaction_id, user_id,
    product_id, app_account_token, purchase_date, signed_date,
    revocation_date, quantity, credits_reversed
  ) values (
    'Production', 'codex-assn-legacy-reversal',
    'codex-assn-legacy-reversal', v_uid,
    'com.x5studio.app.credits.1000', v_uid, v_purchase,
    v_base_signed, v_base_signed - interval '1 minute', 1, 0
  );
  v_response := public.apply_verified_app_store_consumable(
    v_uid, 'codex-assn-legacy-reversal',
    'codex-assn-legacy-reversal',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, v_purchase + interval '1 minute', null, 1
  );
  if v_response ->> 'status' <> 'already_applied' or exists (
    select 1 from public.app_store_consumable_transactions
     where transaction_id = 'codex-assn-legacy-reversal'
  ) then
    raise exception 'legacy_refund_did_not_block_grant:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '36000000-0000-4000-8000-000000000001', 'REFUND_REVERSED',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-legacy-reversal', 'codex-assn-legacy-reversal',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, null, v_base_signed + interval '2 minutes',
    null, null, 1
  );
  v_response := public.apply_verified_app_store_consumable(
    v_uid, 'codex-assn-legacy-reversal',
    'codex-assn-legacy-reversal',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, v_purchase + interval '1 minute', null, 1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_credits <> 1000 or not exists (
    select 1 from public.app_store_consumable_refunds
     where environment = 'Production'
       and transaction_id = 'codex-assn-legacy-reversal'
  ) then
    raise exception 'canonical_reversal_did_not_override_legacy:%:%',
      v_response, v_credits;
  end if;

  update public.profiles set credits = 0 where id = v_uid;

  -- A subscription refund may arrive before the StoreKit purchase is copied
  -- into the new ledger. It must suppress the matching legacy iOS entitlement;
  -- a later reversal restores it without affecting Android sources.
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, last_transaction_id
  ) values (
    'codex-assn-sub-refund-before-grant', v_uid,
    'com.x5studio.app.verified.monthly', 'ios', v_uid,
    v_purchase, 0, v_subscription_expires,
    'codex-assn-sub-refund-before-grant'
  );
  update public.profiles
     set is_verified = true,
         verified_until = v_subscription_expires
   where id = v_uid;

  v_response := public.apply_verified_app_store_server_notification(
    '40000000-0000-4000-8000-000000000001', 'REFUND',
    v_base_signed + interval '1 minute', v_uid,
    'codex-assn-sub-refund-before-grant',
    'codex-assn-sub-refund-before-grant',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_subscription_expires, v_base_signed,
    v_base_signed - interval '1 minute', 50000, null
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'subscription_refund_before_grant_remained_verified:%',
      v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '40000000-0000-4000-8000-000000000002', 'REFUND_REVERSED',
    v_base_signed + interval '3 minutes', v_uid,
    'codex-assn-sub-refund-before-grant',
    'codex-assn-sub-refund-before-grant',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_subscription_expires,
    v_base_signed + interval '2 minutes', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid) then
    raise exception 'subscription_reversal_did_not_restore_legacy_source:%',
      v_response;
  end if;
end;
$server_notification_tests$;

do $ledger_tests$
begin
  if (
    select credits_delta
      from public.app_store_server_notification_events
     where event_id = '10000000-0000-4000-8000-000000000002'
  ) <> -200 then
    raise exception 'partial_refund_delta_was_not_exact';
  end if;
  if (
    select credits_delta
      from public.app_store_server_notification_events
     where event_id = '10000000-0000-4000-8000-000000000004'
  ) <> 600 then
    raise exception 'reversal_restore_was_not_recorded_exactly';
  end if;
  if (
    select credits_delta
      from public.app_store_server_notification_events
     where event_id = '30000000-0000-4000-8000-000000000002'
  ) <> 0 then
    raise exception 'stale_refund_was_not_credit_neutral';
  end if;
  if not exists (
    select 1
      from public.app_store_server_notification_events
     where event_id = '35000000-0000-4000-8000-000000000001'
       and credits_affected = 0
       and pending_credits_affected = 400
       and credits_delta = 0
  ) then
    raise exception 'pending_refund_event_was_not_recorded';
  end if;
  if not exists (
    select 1
      from public.app_store_server_notification_grant_adjustments
     where environment = 'Production'
       and transaction_id = 'codex-assn-partial-before-grant'
       and credits_withheld = 400
       and credits_delta = -400
  ) then
    raise exception 'pending_refund_grant_adjustment_was_not_recorded';
  end if;
end;
$ledger_tests$;

rollback;

select 'app_store_server_notifications_validated_with_rollback' as result;
