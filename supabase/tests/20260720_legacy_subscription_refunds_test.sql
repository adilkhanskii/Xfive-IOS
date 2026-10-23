begin;

do $acl$
begin
  if has_function_privilege(
    'service_role',
    'public.x5_apply_verified_app_store_legacy_plan_refund(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.x5_apply_verified_app_store_legacy_plan_refund(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.x5_apply_verified_app_store_legacy_plan_refund(uuid,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer,integer)',
    'execute'
  ) then
    raise exception 'legacy_plan_refund_internal_helper_is_callable';
  end if;
end;
$acl$;

do $source_economics$
declare
  v_uid uuid;
  v_other_uid uuid;
  v_purchase timestamptz := clock_timestamp() - interval '2 minutes';
  v_expires timestamptz := clock_timestamp() + interval '1 month';
  v_grant_signed timestamptz := clock_timestamp() - interval '90 seconds';
  v_refund_signed timestamptz := clock_timestamp() - interval '50 seconds';
  v_revocation timestamptz := clock_timestamp() - interval '1 minute';
  v_notification_signed timestamptz := clock_timestamp() - interval '40 seconds';
  v_response jsonb;
  v_after_grant integer;
  v_rejected boolean := false;
begin
  select profile.id into v_uid
    from public.profiles as profile
   where lower(coalesce(profile.plan, 'free')) <> 'black'
     and not exists (
       select 1 from public.app_store_transactions as apple
        where apple.user_id = profile.id and apple.expires_date > now()
     )
     and not exists (
       select 1 from public.iap_entitlements as entitlement
        where entitlement.user_id = profile.id
          and coalesce(entitlement.expires_at,
                       entitlement.subscription_end_date) > now()
     )
   order by profile.id
   limit 1;
  select profile.id into v_other_uid
    from public.profiles as profile
   where profile.id <> v_uid
     and lower(coalesce(profile.plan, 'free')) <> 'black'
     and not exists (
       select 1 from public.app_store_transactions as apple
        where apple.user_id = profile.id and apple.expires_date > now()
     )
     and not exists (
       select 1 from public.iap_entitlements as entitlement
        where entitlement.user_id = profile.id
          and coalesce(entitlement.expires_at,
                       entitlement.subscription_end_date) > now()
     )
   order by profile.id
   limit 1;
  if v_uid is null or v_other_uid is null then
    raise exception 'legacy_plan_refund_profile_fixtures_required';
  end if;

  update public.profiles
     set credits = 10000,
         plan = 'free',
         subscription_type = null,
         subscription_date = null,
         subscription_end_date = null
   where id = v_uid;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    'd7210000-0000-4000-8000-000000000101'::uuid,
    'SUBSCRIBED', 'INITIAL_BUY', clock_timestamp() - interval '80 seconds',
    v_uid, 'codex-legacy-refund-source-tx',
    'codex-legacy-refund-source-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, v_grant_signed,
    clock_timestamp() - interval '85 seconds', null, null, 1
  );
  select credits into v_after_grant from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or v_after_grant <> 12000
     or (select credits_granted from public.app_store_transactions
          where transaction_id = 'codex-legacy-refund-source-tx') <> 2000 then
    raise exception 'legacy_plan_refund_source_grant_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000102'::uuid,
    'REFUND', v_notification_signed, v_uid,
    'codex-legacy-refund-source-tx',
    'codex-legacy-refund-source-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, v_refund_signed, v_revocation, 40000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_affected')::integer <> 800
     or (v_response ->> 'credits_delta')::integer <> -800
     or (select credits from public.profiles where id = v_uid) <> 11200 then
    raise exception 'legacy_plan_partial_refund_failed:%', v_response;
  end if;
  if (select plan from public.profiles where id = v_uid) <> 'free'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'legacy_plan_refund_did_not_reconcile_plan';
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000102'::uuid,
    'REFUND', v_notification_signed, v_uid,
    'codex-legacy-refund-source-tx',
    'codex-legacy-refund-source-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, v_refund_signed, v_revocation, 40000, 1
  );
  if v_response ->> 'status' <> 'already_applied'
     or (select credits from public.profiles where id = v_uid) <> 11200 then
    raise exception 'legacy_plan_refund_replay_was_not_exact_once:%',
      v_response;
  end if;

  begin
    perform public.apply_verified_app_store_server_notification(
      'd7210000-0000-4000-8000-000000000103'::uuid,
      'REFUND', clock_timestamp(), v_uid,
      'codex-legacy-refund-source-tx',
      'codex-legacy-refund-wrong-chain',
      'com.x5studio.app.pro.monthly', 'Production', v_uid,
      v_purchase, v_expires, clock_timestamp(), v_revocation, 100000, 1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'notification_source_mismatch' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'legacy_plan_refund_source_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_server_notification(
      'd7210000-0000-4000-8000-000000000104'::uuid,
      'REFUND', clock_timestamp(), v_other_uid,
      'codex-legacy-refund-source-tx',
      'codex-legacy-refund-source-chain',
      'com.x5studio.app.pro.monthly', 'Production', v_other_uid,
      v_purchase, v_expires, clock_timestamp(), v_revocation, 100000, 1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'notification_source_mismatch' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'legacy_plan_refund_cross_account_was_accepted';
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000105'::uuid,
    'REFUND', clock_timestamp() - interval '20 seconds', v_uid,
    'codex-legacy-refund-source-tx',
    'codex-legacy-refund-source-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp() - interval '30 seconds',
    v_revocation, 100000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_affected')::integer <> 2000
     or (v_response ->> 'credits_delta')::integer <> -1200
     or (select credits from public.profiles where id = v_uid) <> 10000 then
    raise exception 'legacy_plan_full_refund_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000106'::uuid,
    'REFUND_REVERSED', clock_timestamp(), v_uid,
    'codex-legacy-refund-source-tx',
    'codex-legacy-refund-source-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp() - interval '5 seconds',
    null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_delta')::integer <> 2000
     or (select credits from public.profiles where id = v_uid) <> 12000 then
    raise exception 'legacy_plan_refund_reversal_failed:%', v_response;
  end if;
  if (select plan from public.profiles where id = v_uid) <> 'pro'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_expires then
    raise exception 'legacy_plan_refund_reversal_did_not_restore_plan';
  end if;
end;
$source_economics$;

do $grandfather_refund_before_grant$
declare
  v_uid uuid;
  v_token constant uuid :=
    'd7210000-0000-4000-8000-000000000301'::uuid;
  v_purchase timestamptz := clock_timestamp() - interval '20 days';
  v_expires timestamptz := clock_timestamp() + interval '10 days';
  v_created timestamptz := clock_timestamp() - interval '20 days';
  v_later_purchase timestamptz := clock_timestamp() - interval '2 minutes';
  v_later_expires timestamptz := clock_timestamp() + interval '40 days';
  v_revocation timestamptz := clock_timestamp() - interval '1 minute';
  v_response jsonb;
begin
  select profile.id into v_uid
    from public.profiles as profile
   where lower(coalesce(profile.plan, 'free')) <> 'black'
     and not exists (
       select 1 from public.app_store_transactions as apple
        where apple.user_id = profile.id and apple.expires_date > now()
     )
     and not exists (
       select 1 from public.iap_entitlements as entitlement
        where entitlement.user_id = profile.id
          and coalesce(entitlement.expires_at,
                       entitlement.subscription_end_date) > now()
     )
   order by profile.id
   limit 1;
  if v_uid is null then
    raise exception 'legacy_plan_grandfather_refund_profile_fixture_required';
  end if;

  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-legacy-grandfather-refund-chain', v_uid,
    'com.x5studio.app.lite.monthly', 'ios', v_token,
    v_purchase, 1000, v_expires, v_created, null
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at,
    legacy_credits_granted
  ) values (
    'codex-legacy-grandfather-refund-chain', v_uid, v_token,
    'com.x5studio.app.lite.monthly', v_purchase, v_expires, v_created, 1000
  );
  update public.profiles
     set credits = 7000,
         plan = 'pro',
         subscription_type = 'lite_monthly',
         subscription_date = v_purchase,
         subscription_end_date = v_expires
   where id = v_uid;

  -- A later period on the same chain is not the frozen grandfather period.
  -- Before either period reaches the canonical ledger it remains pending and
  -- must not remove the still-valid older plan.
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000310'::uuid,
    'REFUND', clock_timestamp() - interval '40 seconds', v_uid,
    'codex-legacy-grandfather-later-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_later_purchase, v_later_expires,
    clock_timestamp() - interval '50 seconds', v_revocation, 100000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_delta')::integer <> 0
     or (select credits from public.profiles where id = v_uid) <> 7000
     or (select pending_credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id =
                'codex-legacy-grandfather-later-refund-tx') <> 1000
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_expires then
    raise exception
      'legacy_plan_later_period_refund_used_grandfather_credits:%', v_response;
  end if;
  perform public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000311'::uuid,
    'REFUND_REVERSED', clock_timestamp() - interval '30 seconds', v_uid,
    'codex-legacy-grandfather-later-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_later_purchase, v_later_expires,
    clock_timestamp() - interval '35 seconds', null, null, 1
  );

  -- Apple may send the refund before this period has been copied into the
  -- canonical app_store_transactions ledger. The exact grandfather row must
  -- not re-enable the paid plan while the signed refund state is active.
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000302'::uuid,
    'REFUND', clock_timestamp() - interval '40 seconds', v_uid,
    'codex-legacy-grandfather-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_purchase, v_expires, clock_timestamp() - interval '50 seconds',
    v_revocation, 100000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_affected')::integer <> 1000
     or (v_response ->> 'credits_delta')::integer <> -1000
     or (select credits from public.profiles where id = v_uid) <> 6000
     or (select pending_credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id =
                'codex-legacy-grandfather-refund-tx') <> 0 then
    raise exception
      'legacy_plan_grandfather_refund_did_not_withhold_credits:%', v_response;
  end if;
  if (select plan from public.profiles where id = v_uid) <> 'free'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'legacy_plan_grandfather_refund_did_not_reconcile_plan:%',
      v_response;
  end if;

  -- Migrating the exact old period writes a canonical row with zero newly
  -- granted credits. The already-applied frozen withholding must not run a
  -- second time.
  v_response := public.apply_verified_app_store_transaction(
    v_uid, 'codex-legacy-grandfather-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_purchase, v_expires, clock_timestamp() - interval '30 seconds', null
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or (select credits_granted from public.app_store_transactions
          where transaction_id =
                'codex-legacy-grandfather-refund-tx') <> 0
     or (select credits from public.profiles where id = v_uid) <> 6000
     or (select credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id =
                'codex-legacy-grandfather-refund-tx') <> 1000 then
    raise exception 'legacy_plan_grandfather_late_grant_double_deducted:%',
      v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000303'::uuid,
    'REFUND_REVERSED', clock_timestamp(), v_uid,
    'codex-legacy-grandfather-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_purchase, v_expires, clock_timestamp() - interval '5 seconds',
    null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (select credits from public.profiles where id = v_uid) <> 7000
     or (select plan from public.profiles where id = v_uid) <> 'pro'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_expires then
    raise exception
      'legacy_plan_grandfather_reversal_did_not_restore_plan:%', v_response;
  end if;

  -- A later renewal mutates the compatibility row, but cannot rewrite the
  -- frozen old-period economics kept on the private binding.
  update public.iap_entitlements
     set credited_at = v_later_purchase,
         credits_granted = 2000,
         subscription_end_date = v_later_expires,
         last_transaction_id =
           'codex-legacy-grandfather-later-refund-tx'
   where original_transaction_id =
         'codex-legacy-grandfather-refund-chain';

  -- Even after migration the canonical row has zero economics. A later Apple
  -- refund for the exact frozen period must still use the frozen 1000 credits.
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000304'::uuid,
    'REFUND', clock_timestamp(), v_uid,
    'codex-legacy-grandfather-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_purchase, v_expires, clock_timestamp() - interval '2 seconds',
    v_revocation, 100000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_delta')::integer <> -1000
     or (select credits from public.profiles where id = v_uid) <> 6000 then
    raise exception
      'legacy_plan_zero_ledger_refund_did_not_use_frozen_credits:%',
      v_response;
  end if;
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000305'::uuid,
    'REFUND_REVERSED', clock_timestamp(), v_uid,
    'codex-legacy-grandfather-refund-tx',
    'codex-legacy-grandfather-refund-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_token,
    v_purchase, v_expires, clock_timestamp(), null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (select credits from public.profiles where id = v_uid) <> 7000 then
    raise exception
      'legacy_plan_grandfather_reversal_did_not_restore_plan:%', v_response;
  end if;

end;
$grandfather_refund_before_grant$;

do $legacy_nil_token_direct_grant$
declare
  v_uid uuid;
  v_purchase timestamptz := clock_timestamp() - interval '1 day';
  v_expires timestamptz := clock_timestamp() + interval '12 days';
  v_before integer;
  v_response jsonb;
begin
  select profile.id into v_uid
    from public.profiles as profile
   where lower(coalesce(profile.plan, 'free')) <> 'black'
   order by profile.id desc
   limit 1;
  if v_uid is null then
    raise exception 'legacy_plan_nil_token_profile_fixture_required';
  end if;
  select credits into v_before from public.profiles where id = v_uid;
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-legacy-nil-token-direct-chain', v_uid,
    'com.x5studio.app.lite.monthly', 'ios', null,
    v_purchase, 1000, v_expires, v_purchase, null
  );

  v_response := public.apply_verified_app_store_transaction(
    v_uid, 'codex-legacy-nil-token-direct-tx',
    'codex-legacy-nil-token-direct-chain',
    'com.x5studio.app.lite.monthly', 'Production', null,
    v_purchase, v_expires, clock_timestamp(), null
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or (select credits from public.profiles where id = v_uid) <> v_before
     or (select credits_granted from public.app_store_transactions
          where transaction_id = 'codex-legacy-nil-token-direct-tx') <> 0
     or (select app_account_token from public.app_store_transactions
          where transaction_id = 'codex-legacy-nil-token-direct-tx')
        is not null then
    raise exception 'legacy_plan_nil_token_direct_grant_failed:%', v_response;
  end if;
end;
$legacy_nil_token_direct_grant$;

do $legacy_nil_token_bound_flow$
declare
  v_uid uuid;
  v_purchase timestamptz := clock_timestamp() - interval '20 days';
  v_expires timestamptz := clock_timestamp() + interval '10 days';
  v_later_purchase timestamptz := clock_timestamp() - interval '1 minute';
  v_later_expires timestamptz := clock_timestamp() + interval '40 days';
  v_lifecycle_notification_signed timestamptz :=
    clock_timestamp() - interval '20 seconds';
  v_lifecycle_transaction_signed timestamptz :=
    clock_timestamp() - interval '40 seconds';
  v_lifecycle_renewal_signed timestamptz :=
    clock_timestamp() - interval '30 seconds';
  v_response jsonb;
begin
  select profile.id into v_uid
    from public.profiles as profile
   where lower(coalesce(profile.plan, 'free')) <> 'black'
   order by profile.id
   limit 1;
  if v_uid is null then
    raise exception 'legacy_plan_nil_token_bound_profile_fixture_required';
  end if;
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, legacy_app_account_token, credited_at,
    credits_granted, subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-legacy-nil-token-bound-chain', v_uid,
    'com.x5studio.app.pro.monthly', 'ios', null, null, v_purchase,
    2000, v_expires, v_purchase, null
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at,
    legacy_credits_granted
  ) values (
    'codex-legacy-nil-token-bound-chain', v_uid, v_uid,
    'com.x5studio.app.pro.monthly', v_purchase, v_expires, v_purchase, 2000
  );
  update public.profiles set credits = 9000 where id = v_uid;

  -- Direct restore keeps the signed NULL in the canonical purchase row and
  -- atomically transitions the exact sentinel binding to bound.
  v_response := public.apply_verified_app_store_transaction(
    v_uid, 'codex-legacy-nil-token-bound-tx-1',
    'codex-legacy-nil-token-bound-chain',
    'com.x5studio.app.pro.monthly', 'Production', null,
    v_purchase, v_expires, clock_timestamp() - interval '2 minutes', null
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or (select credits from public.profiles where id = v_uid) <> 9000
     or (select app_account_token from public.app_store_transactions
          where transaction_id =
                'codex-legacy-nil-token-bound-tx-1') is not null
     or not exists (
       select 1 from public.app_store_legacy_bindings as binding
        where binding.original_transaction_id =
              'codex-legacy-nil-token-bound-chain'
          and binding.bound_at is not null
     ) then
    raise exception 'legacy_plan_nil_token_bound_grant_failed:%', v_response;
  end if;

  -- Edge canonicalizes the next missing token to user_id for non-null event
  -- ledgers. The grant bridge converts only this exact sentinel back to NULL.
  v_response := public.apply_verified_app_store_subscription_lifecycle(
    'd7210000-0000-4000-8000-000000000321'::uuid,
    'DID_RENEW', null, v_lifecycle_notification_signed, v_uid,
    'codex-legacy-nil-token-bound-tx-2',
    'codex-legacy-nil-token-bound-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_later_purchase, v_later_expires,
    v_lifecycle_transaction_signed,
    v_lifecycle_renewal_signed, null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 2000
     or (select credits from public.profiles where id = v_uid) <> 11000
     or (select app_account_token from public.app_store_transactions
          where transaction_id =
                'codex-legacy-nil-token-bound-tx-2') is not null
     or exists (
       select 1 from public.iap_entitlements as legacy
        where legacy.original_transaction_id =
              'codex-legacy-nil-token-bound-chain'
          and (legacy.app_account_token is not null
               or legacy.legacy_app_account_token is not null)
     ) then
    raise exception 'legacy_plan_nil_token_second_renewal_failed:%', v_response;
  end if;
  v_response := public.apply_verified_app_store_subscription_lifecycle(
    'd7210000-0000-4000-8000-000000000321'::uuid,
    'DID_RENEW', null, v_lifecycle_notification_signed, v_uid,
    'codex-legacy-nil-token-bound-tx-2',
    'codex-legacy-nil-token-bound-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_later_purchase, v_later_expires,
    v_lifecycle_transaction_signed,
    v_lifecycle_renewal_signed, null, null, 1
  );
  if v_response ->> 'status' <> 'already_applied'
     or (select credits from public.profiles where id = v_uid) <> 11000 then
    raise exception 'legacy_plan_nil_token_renewal_replay_failed:%', v_response;
  end if;

  -- The current iap row now describes the later renewal. Refund of the old
  -- migrated zero-credit transaction still uses the old frozen 2000 exactly.
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000322'::uuid,
    'REFUND', clock_timestamp(), v_uid,
    'codex-legacy-nil-token-bound-tx-1',
    'codex-legacy-nil-token-bound-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp() - interval '5 seconds',
    clock_timestamp() - interval '10 seconds', 100000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_delta')::integer <> -2000
     or (select credits from public.profiles where id = v_uid) <> 9000 then
    raise exception 'legacy_plan_nil_token_refund_failed:%', v_response;
  end if;
  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000323'::uuid,
    'REFUND_REVERSED', clock_timestamp(), v_uid,
    'codex-legacy-nil-token-bound-tx-1',
    'codex-legacy-nil-token-bound-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp(), null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (select credits from public.profiles where id = v_uid) <> 11000 then
    raise exception 'legacy_plan_nil_token_refund_reversal_failed:%',
      v_response;
  end if;
end;
$legacy_nil_token_bound_flow$;

do $refund_before_grant$
declare
  v_uid uuid;
  v_purchase timestamptz := clock_timestamp() - interval '2 minutes';
  v_expires timestamptz := clock_timestamp() + interval '1 month';
  v_revocation timestamptz := clock_timestamp() - interval '1 minute';
  v_refund_signed timestamptz := clock_timestamp() - interval '50 seconds';
  v_response jsonb;
begin
  select profile.id into v_uid
    from public.profiles as profile
   where lower(coalesce(profile.plan, 'free')) <> 'black'
     and not exists (
       select 1 from public.app_store_transactions as apple
        where apple.user_id = profile.id and apple.expires_date > now()
     )
     and not exists (
       select 1 from public.iap_entitlements as entitlement
        where entitlement.user_id = profile.id
          and coalesce(entitlement.expires_at,
                       entitlement.subscription_end_date) > now()
     )
   order by profile.id desc
   limit 1;
  if v_uid is null then
    raise exception 'legacy_plan_pending_refund_profile_fixture_required';
  end if;
  update public.profiles
     set credits = 7000,
         plan = 'free',
         subscription_type = null,
         subscription_date = null,
         subscription_end_date = null
   where id = v_uid;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000201'::uuid,
    'REFUND', clock_timestamp() - interval '40 seconds', v_uid,
    'codex-legacy-refund-pending-tx',
    'codex-legacy-refund-pending-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_uid,
    v_purchase, v_expires, v_refund_signed, v_revocation, 50000, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (select credits from public.profiles where id = v_uid) <> 7000
     or (select pending_credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id = 'codex-legacy-refund-pending-tx') <> 500 then
    raise exception 'legacy_plan_refund_before_grant_pending_failed:%',
      v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    'd7210000-0000-4000-8000-000000000202'::uuid,
    'SUBSCRIBED', 'INITIAL_BUY', clock_timestamp(), v_uid,
    'codex-legacy-refund-pending-tx',
    'codex-legacy-refund-pending-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp() - interval '20 seconds',
    clock_timestamp() - interval '10 seconds', null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 500
     or (select credits from public.profiles where id = v_uid) <> 7500
     or (select credits_granted from public.app_store_transactions
          where transaction_id = 'codex-legacy-refund-pending-tx') <> 1000
     or (select credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id = 'codex-legacy-refund-pending-tx') <> 500
     or (select pending_credits_withheld
           from public.app_store_server_notification_state
          where environment = 'Production'
            and transaction_id = 'codex-legacy-refund-pending-tx') <> 0 then
    raise exception 'legacy_plan_refund_before_grant_withholding_failed:%',
      v_response;
  end if;
  if (select plan from public.profiles where id = v_uid) <> 'free' then
    raise exception 'legacy_plan_refund_did_not_reconcile_plan';
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    'd7210000-0000-4000-8000-000000000203'::uuid,
    'REFUND_REVERSED', clock_timestamp(), v_uid,
    'codex-legacy-refund-pending-tx',
    'codex-legacy-refund-pending-chain',
    'com.x5studio.app.lite.monthly', 'Production', v_uid,
    v_purchase, v_expires, clock_timestamp() - interval '5 seconds',
    null, null, 1
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_delta')::integer <> 500
     or (select credits from public.profiles where id = v_uid) <> 8000 then
    raise exception 'legacy_plan_refund_before_grant_reversal_failed:%',
      v_response;
  end if;
  if (select plan from public.profiles where id = v_uid) <> 'pro'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_expires then
    raise exception 'legacy_plan_refund_reversal_did_not_restore_plan';
  end if;
end;
$refund_before_grant$;

rollback;
