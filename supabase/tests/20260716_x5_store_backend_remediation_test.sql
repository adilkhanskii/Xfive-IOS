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
    raise exception 'lifecycle_rpc_is_client_callable';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_subscription_lifecycle(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'lifecycle_rpc_is_not_service_callable';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.resolve_verified_app_store_notification_user(text,text,text,uuid)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.resolve_verified_app_store_notification_user(text,text,text,uuid)',
    'execute'
  ) then
    raise exception 'notification_user_resolver_acl_invalid';
  end if;
  if has_table_privilege(
    'service_role', 'public.app_store_verified_lifecycle_events', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.app_store_verified_lifecycle_events', 'select'
  ) then
    raise exception 'lifecycle_ledger_is_directly_accessible';
  end if;
end;
$acl$;

select set_config(
  'x5.remediation_user_1',
  (select id::text from public.profiles order by id limit 1),
  true
);
select set_config(
  'x5.remediation_user_2',
  (
    select profile.id::text
      from public.profiles as profile
     where profile.id <>
           current_setting('x5.remediation_user_1')::uuid
       and not exists (
         select 1 from public.app_store_transactions as apple
          where apple.user_id = profile.id
            and apple.product_id in (
              'com.x5studio.app.lite.monthly',
              'com.x5studio.app.pro.monthly',
              'com.x5studio.app.max.monthly'
            )
            and apple.expires_date > now()
       )
       and not exists (
         select 1 from public.iap_entitlements as entitlement
          where entitlement.user_id = profile.id
            and entitlement.product_id in (
              'com.x5studio.app.lite.monthly',
              'com.x5studio.app.pro.monthly',
              'com.x5studio.app.max.monthly',
              'x5_lite_monthly_v2', 'x5_pro_monthly_v2',
              'x5_max_monthly_v2', 'x5_pro_monthly', 'x5_pro_yearly'
            )
            and entitlement.subscription_end_date > now()
       )
     order by profile.id
     limit 1
  ),
  true
);
select set_config(
  'x5.remediation_user_3',
  (
    select profile.id::text
      from public.profiles as profile
     where profile.id not in (
       current_setting('x5.remediation_user_1')::uuid,
       current_setting('x5.remediation_user_2')::uuid
     )
       and not exists (
         select 1
           from public.app_store_sandbox_review_accounts as allowed
          where allowed.user_id = profile.id
            and allowed.enabled
       )
       and not exists (
         select 1 from public.app_store_transactions as apple
          where apple.user_id = profile.id
            and apple.product_id = 'com.x5studio.app.verified.monthly'
            and apple.expires_date > now()
       )
       and not exists (
         select 1 from public.app_store_sandbox_review_transactions as sandbox
          where sandbox.user_id = profile.id
            and sandbox.product_id = 'com.x5studio.app.verified.monthly'
            and sandbox.expires_date > now()
       )
       and not exists (
         select 1 from public.iap_entitlements as entitlement
          where entitlement.user_id = profile.id
            and entitlement.product_id in (
              'com.x5studio.app.verified.monthly',
              'x5_verified_monthly_v2', 'x5_verified_monthly'
            )
            and entitlement.subscription_end_date > now()
       )
     order by profile.id
     limit 1
  ),
  true
);

do $fixtures$
begin
  if nullif(current_setting('x5.remediation_user_1', true), '') is null
     or nullif(current_setting('x5.remediation_user_2', true), '') is null
     or nullif(current_setting('x5.remediation_user_3', true), '') is null then
    raise exception 'three_profile_fixtures_required';
  end if;
end;
$fixtures$;

do $existing_owner_legacy_binding$
declare
  v_uid constant uuid :=
    'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid;
  v_chain constant text := '2000001163575812';
  v_expected_end constant timestamptz :=
    '2026-07-30 10:44:39.862088+00'::timestamptz;
  v_before_credits integer;
begin
  if exists (
    select 1 from public.iap_entitlements
     where original_transaction_id = v_chain
  ) then
    if not exists (
      select 1
        from public.iap_entitlements as legacy
        join public.app_store_legacy_bindings as binding
          on binding.original_transaction_id = legacy.original_transaction_id
         and binding.user_id = legacy.user_id
         and binding.product_id = legacy.product_id
         and binding.legacy_credited_at is not distinct from
             legacy.credited_at
         and binding.legacy_subscription_end_date is not distinct from
             legacy.subscription_end_date
         and binding.legacy_created_at is not distinct from legacy.created_at
         and binding.app_account_token = coalesce(
           legacy.legacy_app_account_token,
           legacy.app_account_token,
           legacy.user_id
         )
       where legacy.original_transaction_id = v_chain
         and legacy.user_id = v_uid
         and legacy.subscription_end_date = v_expected_end
    ) then
      raise exception 'existing_owner_chain_not_exactly_bound';
    end if;

    select credits into v_before_credits
      from public.profiles where id = v_uid;
    perform public.x5_reconcile_paid_plan_profile(v_uid);
    if (select plan from public.profiles where id = v_uid) <> 'pro'
       or (select subscription_end_date from public.profiles where id = v_uid)
          is distinct from v_expected_end then
      raise exception 'existing_owner_plan_was_not_advanced';
    end if;
    if (select credits from public.profiles where id = v_uid)
       is distinct from v_before_credits then
      raise exception 'existing_owner_reconciliation_changed_credits';
    end if;
    if public.resolve_verified_app_store_notification_user(
      'Production', v_chain, 'com.x5studio.app.pro.monthly', v_uid
    ) is distinct from v_uid then
      raise exception 'owner_legacy_notification_resolver_failed';
    end if;
  end if;
end;
$existing_owner_legacy_binding$;

do $credit_neutral_reconciliation$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_credits integer;
  v_permanent integer;
  v_debt integer;
  v_expiry timestamptz := now() + interval '9 days';
  v_retention integer;
begin
  update public.profiles
     set credits = 123,
         is_verified = true,
         verified_until = now() - interval '1 day'
   where id = v_uid;
  update public.profiles
     set credits_expires_at = v_expiry
   where id = v_uid;
  select credits, permanent_credits, permanent_credit_debt,
         credits_retention_months
    into v_credits, v_permanent, v_debt, v_retention
    from public.profiles where id = v_uid;

  perform public.x5_reconcile_store_profiles(10000);
  if (select is_verified from public.profiles where id = v_uid)
     or (select credits from public.profiles where id = v_uid) <> v_credits
     or (select permanent_credits from public.profiles where id = v_uid)
        <> v_permanent
     or (select permanent_credit_debt from public.profiles where id = v_uid)
        <> v_debt
     or (select credits_expires_at from public.profiles where id = v_uid)
        is distinct from v_expiry
     or (select credits_retention_months from public.profiles where id = v_uid)
        <> v_retention then
    raise exception 'reconciliation_changed_credit_metadata';
  end if;
end;
$credit_neutral_reconciliation$;

set local role service_role;

do $permanent_credit_packs$
declare
  v_uid uuid := current_setting('x5.remediation_user_1')::uuid;
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
  v_response jsonb;
  v_purchase timestamptz := now() - interval '1 minute';
begin
  select * into v_before from public.profiles where id = v_uid;
  update public.profiles
     set credits = 0,
         permanent_credits = 0,
         permanent_credit_debt = 0,
         credits_expires_at = null
   where id = v_uid;

  v_response := public.apply_verified_app_store_consumable(
    v_uid, 'codex-remediation-apple-pack',
    'codex-remediation-apple-pack',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, now(), null, 1
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or v_after.credits <> 1000
     or v_after.permanent_credits <> 1000
     or v_after.credits_expires_at is not null then
    raise exception 'apple_pack_not_permanent:%', v_response;
  end if;
  if v_after.plan is distinct from v_before.plan
     or v_after.subscription_type is distinct from v_before.subscription_type
     or v_after.subscription_end_date is distinct from
        v_before.subscription_end_date
     or v_after.purchased_course_ids is distinct from
        v_before.purchased_course_ids then
    raise exception 'apple_pack_changed_entitlements';
  end if;

  update public.profiles set credits = credits - 200 where id = v_uid;
  if (select credits_expires_at from public.profiles where id = v_uid)
     is not null then
    raise exception 'spending_started_timer_for_permanent_pack';
  end if;
  if (select permanent_credits from public.profiles where id = v_uid) <> 800 then
    raise exception 'permanent_spend_did_not_reduce_floor';
  end if;

  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid, 'codex-remediation-apple-pack',
    'codex-remediation-apple-pack',
    'com.x5studio.app.credits.1000', 'Production', v_uid,
    v_purchase, now(), now(), 1
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_after.credits <> -200
     or v_after.permanent_credits <> 0
     or v_after.permanent_credit_debt <> 200 then
    raise exception 'permanent_refund_after_spend_left_a_floor:%', v_response;
  end if;

  -- A monthly credit grant is intentionally still expiring and independent
  -- from both the refunded pack debt and a later permanent one-time pack.
  v_response := public.apply_android_purchase_entitlement(
    v_uid, 'codex-remediation-android-monthly', 'x5_lite_monthly_v2',
    'subscription', 'codex-remediation-android-monthly-token',
    'codex-remediation-monthly-order', now() + interval '1 month',
    1000, 'lite_monthly', 'pro', false
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_after.credits_expires_at is null
     or v_after.subscription_end_date is null
     or v_after.credits <> 800
     or v_after.permanent_credits <> 0
     or v_after.permanent_credit_debt <> 200 then
    raise exception 'monthly_credit_expiry_was_removed:%', v_response;
  end if;

  -- Refunded permanent credits that were already spent are fungible user
  -- debt. A new paid pack first clears that debt, then grows the floor.
  v_before := v_after;
  v_response := public.apply_android_purchase_entitlement(
    v_uid, 'codex-remediation-android-pack', 'x5_credits_1000_v2',
    'inapp', 'codex-remediation-android-token',
    'codex-remediation-order', null, 1000, null, null, false
  );
  select * into v_after from public.profiles where id = v_uid;
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_after.credits <> 1800
     or v_after.permanent_credits <> 800
     or v_after.permanent_credit_debt <> 0
     or v_after.credits_expires_at is null then
    raise exception 'new_permanent_pack_did_not_repay_fungible_debt:%',
      v_response;
  end if;
  if v_after.plan is distinct from v_before.plan
     or v_after.subscription_type is distinct from v_before.subscription_type
     or v_after.subscription_end_date is distinct from
        v_before.subscription_end_date
     or v_after.purchased_course_ids is distinct from
        v_before.purchased_course_ids then
    raise exception 'android_pack_changed_entitlements';
  end if;

  update public.profiles set credits = credits - 500 where id = v_uid;
  select * into v_after from public.profiles where id = v_uid;
  if v_after.credits <> 1300
     or v_after.permanent_credits <> 800
     or v_after.permanent_credit_debt <> 0 then
    raise exception 'mixed_permanent_floor_was_not_preserved';
  end if;
  update public.profiles
     set credits_expires_at = now() - interval '1 minute'
   where id = v_uid;
end;
$permanent_credit_packs$;

reset role;

do $permanent_credit_expiry$
declare
  v_uid uuid := current_setting('x5.remediation_user_1')::uuid;
begin
  perform public.x5_expire_old_credits();
  if (select credits from public.profiles where id = v_uid) <> 800
     or (select permanent_credits from public.profiles where id = v_uid) <> 800
     or (select credits_expires_at from public.profiles where id = v_uid)
        is not null then
    raise exception 'mixed_subscription_expiry_erased_permanent_floor';
  end if;

  update public.profiles
     set is_verified = true,
         verified_until = now() + interval '1 month'
   where id = v_uid;
  if (select credits_expires_at from public.profiles where id = v_uid)
     is not null
     or (select permanent_credits from public.profiles where id = v_uid)
        <> 800 then
    raise exception 'badge_change_expired_permanent_only_balance';
  end if;
end;
$permanent_credit_expiry$;

set local role service_role;

do $sandbox_scope$
declare
  developer_id uuid;
  outsider_id uuid;
  v_rejected boolean := false;
  v_index integer := 0;
begin
  for developer_id in
    select id from public.profiles
     where id in (
       'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
       'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
     )
     order by id
  loop
    v_index := v_index + 1;
    perform public.apply_verified_app_store_sandbox_review_transaction(
      developer_id,
      'codex-remediation-sandbox-dev-' || v_index,
      'codex-remediation-sandbox-dev-' || v_index,
      'com.x5studio.app.verified.monthly', 'Sandbox', developer_id,
      now() - interval '1 minute', now() + interval '1 month',
      now(), null, null
    );
  end loop;
  if v_index <> 2 then
    raise exception 'two_developer_profiles_required:%', v_index;
  end if;

  select id into outsider_id
    from public.profiles
   where id not in (
     'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
     'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
   )
     and not exists (
       select 1
         from public.app_store_sandbox_review_accounts as allowed
        where allowed.user_id = public.profiles.id
          and allowed.enabled
     )
   order by id
   limit 1;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      outsider_id, 'codex-remediation-sandbox-outsider',
      'codex-remediation-sandbox-outsider',
      'com.x5studio.app.verified.monthly', 'Sandbox', outsider_id,
      now() - interval '1 minute', now() + interval '1 month',
      now(), null, null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_review_account_not_allowed' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'arbitrary_sandbox_account_was_allowed';
  end if;
end;
$sandbox_scope$;

reset role;

do $profile_reconciliation$
declare
  v_uid uuid := current_setting('x5.remediation_user_2')::uuid;
  v_before_credits integer;
  v_end timestamptz := now() + interval '20 days';
  v_credited timestamptz := now() - interval '10 days';
  v_created timestamptz := now() - interval '10 days';
begin
  select credits into v_before_credits from public.profiles where id = v_uid;
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-remediation-plan-chain', v_uid,
    'com.x5studio.app.pro.monthly', 'ios', v_uid,
    v_credited, 2000, v_end, v_created, 'codex-remediation-plan-tx'
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at
  ) values (
    'codex-remediation-plan-chain', v_uid, v_uid,
    'com.x5studio.app.pro.monthly', v_credited, v_end, v_created
  );

  update public.profiles
     set plan = 'pro', subscription_type = 'yearly',
         subscription_end_date = null
   where id = v_uid;
  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select subscription_end_date from public.profiles where id = v_uid)
     is not null
     or (select subscription_type from public.profiles where id = v_uid)
        <> 'yearly' then
    raise exception 'permanent_null_end_plan_was_overwritten';
  end if;

  update public.profiles
     set plan = 'pro', subscription_type = 'pro_monthly',
         subscription_end_date = now() - interval '1 day'
   where id = v_uid;

  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select subscription_end_date from public.profiles where id = v_uid)
     is distinct from v_end then
    raise exception 'trusted_plan_expiry_was_not_advanced';
  end if;

  update public.iap_entitlements
     set credited_at = v_credited + interval '1 second'
   where original_transaction_id = 'codex-remediation-plan-chain';
  update public.profiles
     set plan = 'pro', subscription_end_date = now() - interval '1 day'
   where id = v_uid;
  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select plan from public.profiles where id = v_uid) <> 'free' then
    raise exception 'mismatched_legacy_tuple_was_trusted';
  end if;

  delete from public.app_store_legacy_bindings
   where original_transaction_id = 'codex-remediation-plan-chain';
  delete from public.iap_entitlements
   where original_transaction_id = 'codex-remediation-plan-chain';
  update public.profiles
     set plan = 'pro', subscription_end_date = now() - interval '1 day'
   where id = v_uid;
  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select plan from public.profiles where id = v_uid) <> 'free' then
    raise exception 'expired_untrusted_plan_was_not_cleared';
  end if;

  update public.profiles
     set plan = 'black', subscription_end_date = now() - interval '1 day'
   where id = v_uid;
  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select plan from public.profiles where id = v_uid) <> 'black' then
    raise exception 'black_plan_was_downgraded';
  end if;

  update public.profiles
     set plan = 'pro', subscription_end_date = null
   where id = v_uid;
  perform public.x5_reconcile_paid_plan_profile(v_uid);
  if (select plan from public.profiles where id = v_uid) <> 'pro' then
    raise exception 'permanent_null_end_plan_was_downgraded';
  end if;
  if (select credits from public.profiles where id = v_uid)
     is distinct from v_before_credits then
    raise exception 'plan_reconciliation_changed_credits';
  end if;
end;
$profile_reconciliation$;

set local role service_role;

do $verified_lifecycle$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_before_credits integer;
  v_purchase timestamptz := now() - interval '1 day';
  v_expiry timestamptz := now() + interval '1 month';
  v_response jsonb;
begin
  select credits into v_before_credits from public.profiles where id = v_uid;
  update public.profiles
     set is_verified = false, verified_until = now() - interval '1 day'
   where id = v_uid;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '94000000-0000-4000-8000-000000000000', 'REVOKE', null, now(),
    v_uid, 'codex-remediation-revoke-first-tx',
    'codex-remediation-revoke-first-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now(), now(), now(), null, 0
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or (select is_verified from public.profiles where id = v_uid)
     or (select credits from public.profiles where id = v_uid)
        is distinct from v_before_credits then
    raise exception 'revoke_first_lifecycle_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '94000000-0000-4000-8000-000000000001', 'SUBSCRIBED', null, now(),
    v_uid, 'codex-remediation-lifecycle-tx',
    'codex-remediation-lifecycle-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() - interval '1 minute',
    now() - interval '1 minute', null, null, 1
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_expiry then
    raise exception 'subscription_lifecycle_grant_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '94000000-0000-4000-8000-000000000001', 'SUBSCRIBED', null, now(),
    v_uid, 'codex-remediation-lifecycle-tx',
    'codex-remediation-lifecycle-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() - interval '1 minute',
    now() - interval '1 minute', null, null, 1
  );
  if v_response ->> 'status' <> 'already_applied' then
    raise exception 'lifecycle_replay_was_not_exact_once:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '94000000-0000-4000-8000-000000000002', 'REVOKE', null, now(),
    v_uid, 'codex-remediation-lifecycle-tx',
    'codex-remediation-lifecycle-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now(), now(), now(), null, 0
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'subscription_lifecycle_revoke_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '94000000-0000-4000-8000-000000000003', 'REFUND_REVERSED',
    now() + interval '2 seconds', v_uid,
    'codex-remediation-lifecycle-tx',
    'codex-remediation-lifecycle-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() + interval '1 second', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_expiry then
    raise exception 'revoke_refund_reversal_did_not_restore:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '94000000-0000-4000-8000-000000000004', 'REFUND',
    now() + interval '4 seconds', v_uid,
    'codex-remediation-lifecycle-tx',
    'codex-remediation-lifecycle-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() + interval '3 seconds', now(), 100000, null
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'normal_refund_after_reversal_did_not_clear:%', v_response;
  end if;
  if (select credits from public.profiles where id = v_uid)
     is distinct from v_before_credits then
    raise exception 'verified_lifecycle_changed_credits';
  end if;
end;
$verified_lifecycle$;

do $legacy_notification_chains$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_pro_token constant uuid :=
    'b6580000-0000-4000-8000-000000000002'::uuid;
  v_verified_token constant uuid :=
    'b6580000-0000-4000-8000-000000000003'::uuid;
  v_null_last_token constant uuid :=
    'b6580000-0000-4000-8000-000000000004'::uuid;
  v_pro_credited timestamptz := now() - interval '20 days';
  v_pro_created timestamptz := now() - interval '20 days';
  v_pro_first_end timestamptz := now() + interval '10 days';
  v_pro_second_end timestamptz := now() + interval '40 days';
  v_verified_credited timestamptz := now() - interval '20 days';
  v_verified_created timestamptz := now() - interval '20 days';
  v_verified_first_end timestamptz := now() + interval '1 minute';
  v_verified_second_end timestamptz := now() + interval '31 days';
  v_verified_grace_end timestamptz := now() + interval '36 days';
  v_null_credited timestamptz := now() - interval '12 days';
  v_null_created timestamptz := now() - interval '12 days';
  v_null_end timestamptz := now() + interval '24 days';
  v_response jsonb;
  v_after_pro_credits integer;
begin
  -- The legacy resolver covers paid plans as well as the verified badge. The
  -- first exact Apple JWS binds the immutable snapshot; later renewals may
  -- advance mutable expiry without losing the original audit token.
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-remediation-legacy-pro-chain', v_uid,
    'com.x5studio.app.pro.monthly', 'ios', v_pro_token,
    v_pro_credited, 2000, v_pro_first_end, v_pro_created, null
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at
  ) values (
    'codex-remediation-legacy-pro-chain', v_uid, v_pro_token,
    'com.x5studio.app.pro.monthly', v_pro_credited,
    v_pro_first_end, v_pro_created
  );

  v_response := public.apply_verified_app_store_transaction(
    v_uid, 'codex-remediation-legacy-pro-tx-1',
    'codex-remediation-legacy-pro-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_pro_token,
    now() - interval '1 day', v_pro_first_end,
    now() - interval '2 minutes', null
  );
  if v_response ->> 'status' not in ('applied', 'already_applied') then
    raise exception 'legacy_pro_initial_bind_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_transaction(
    v_uid, 'codex-remediation-legacy-pro-tx-2',
    'codex-remediation-legacy-pro-chain',
    'com.x5studio.app.pro.monthly', 'Production', v_pro_token,
    now() - interval '1 minute', v_pro_second_end, now(), null
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or not exists (
       select 1
         from public.app_store_legacy_bindings as binding
        where binding.original_transaction_id =
              'codex-remediation-legacy-pro-chain'
          and binding.user_id = v_uid
          and binding.app_account_token = v_pro_token
          and binding.bound_at is not null
     )
     or not exists (
       select 1
         from public.iap_entitlements as legacy
        where legacy.original_transaction_id =
              'codex-remediation-legacy-pro-chain'
          and legacy.user_id = v_uid
          and legacy.app_account_token is null
          and legacy.legacy_app_account_token = v_pro_token
          and legacy.last_transaction_id =
              'codex-remediation-legacy-pro-tx-2'
          and legacy.subscription_end_date = v_pro_second_end
     )
     or 2 <> (
       select count(*)
         from public.app_store_transactions as purchase
        where purchase.original_transaction_id =
              'codex-remediation-legacy-pro-chain'
          and purchase.user_id = v_uid
          and purchase.app_account_token is null
     ) then
    raise exception 'legacy_pro_second_renewal_failed:%', v_response;
  end if;
  select credits into v_after_pro_credits
    from public.profiles where id = v_uid;
  perform set_config(
    'x5.remediation_after_pro_credits',
    v_after_pro_credits::text,
    true
  );

  -- The mismatch token must survive both the immutable lifecycle ledger and
  -- the per-period refund projection. An older-period EXPIRED event must not
  -- suppress a newer active renewal in the same original transaction chain.
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-remediation-legacy-verified-chain', v_uid,
    'com.x5studio.app.verified.monthly', 'ios', v_verified_token,
    v_verified_credited, 0, v_verified_first_end,
    v_verified_created, null
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at
  ) values (
    'codex-remediation-legacy-verified-chain', v_uid, v_verified_token,
    'com.x5studio.app.verified.monthly', v_verified_credited,
    v_verified_first_end, v_verified_created
  );

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '95000000-0000-4000-8000-000000000001', 'DID_RENEW', null,
    now() - interval '1 minute', v_uid,
    'codex-remediation-legacy-verified-tx-1',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 day', v_verified_first_end,
    now() - interval '2 minutes', now() - interval '2 minutes',
    null, null, 1
  );
  if v_response ->> 'status' not in ('applied', 'already_applied') then
    raise exception 'legacy_verified_first_renewal_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '95000000-0000-4000-8000-000000000002', 'DID_RENEW', null,
    now(), v_uid, 'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() - interval '30 seconds', now() - interval '30 seconds',
    null, null, 1
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_verified_second_end
     then
    raise exception 'legacy_verified_second_renewal_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '95000000-0000-4000-8000-00000000000a',
    'DID_FAIL_TO_RENEW', 'GRACE_PERIOD', now() + interval '1 second',
    v_uid, 'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now(), now(), null, v_verified_grace_end, 0
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_verified_grace_end then
    raise exception 'legacy_bound_grace_was_not_projected:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '95000000-0000-4000-8000-000000000003', 'EXPIRED', null,
    now() + interval '2 seconds', v_uid,
    'codex-remediation-legacy-verified-tx-1',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 day', v_verified_first_end,
    now() - interval '2 minutes', now() + interval '1 second',
    null, null, 0
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_verified_second_end then
    raise exception 'old_period_expiry_killed_newer_renewal:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_verified_revocation(
    v_uid, 'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() + interval '3 seconds', now()
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'legacy_on_device_revocation_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '95000000-0000-4000-8000-000000000004', 'REFUND_REVERSED',
    now() + interval '5 seconds', v_uid,
    'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() + interval '4 seconds', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_verified_second_end then
    raise exception 'legacy_on_device_reversal_did_not_restore:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '95000000-0000-4000-8000-000000000005', 'REVOKE', null,
    now() + interval '7 seconds', v_uid,
    'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() + interval '6 seconds', now() + interval '6 seconds',
    now(), null, 0
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'legacy_verified_lifecycle_revoke_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '95000000-0000-4000-8000-000000000006', 'REFUND_REVERSED',
    now() + interval '9 seconds', v_uid,
    'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() + interval '8 seconds', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_verified_second_end then
    raise exception 'legacy_revoke_reversal_did_not_restore:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '95000000-0000-4000-8000-000000000007', 'REFUND',
    now() + interval '11 seconds', v_uid,
    'codex-remediation-legacy-verified-tx-2',
    'codex-remediation-legacy-verified-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_verified_token,
    now() - interval '1 minute', v_verified_second_end,
    now() + interval '10 seconds', now(), 100000, null
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'legacy_revoke_reversal_cleanup_failed:%', v_response;
  end if;

  -- A pre-verifier legacy row can have no last transaction id. Its exact
  -- binding still authorizes a real signed REFUND, and REFUND_REVERSED restores
  -- the unexpired source without replacing the signed random token with userId.
  insert into public.iap_entitlements (
    original_transaction_id, user_id, product_id, platform,
    app_account_token, credited_at, credits_granted,
    subscription_end_date, created_at, last_transaction_id
  ) values (
    'codex-remediation-legacy-null-last-chain', v_uid,
    'com.x5studio.app.verified.monthly', 'ios', v_null_last_token,
    v_null_credited, 0, v_null_end, v_null_created, null
  );
  insert into public.app_store_legacy_bindings (
    original_transaction_id, user_id, app_account_token, product_id,
    legacy_credited_at, legacy_subscription_end_date, legacy_created_at
  ) values (
    'codex-remediation-legacy-null-last-chain', v_uid, v_null_last_token,
    'com.x5studio.app.verified.monthly', v_null_credited,
    v_null_end, v_null_created
  );
end;
$legacy_notification_chains$;

reset role;

do $legacy_null_last_rebuild$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_null_end timestamptz;
begin
  select legacy.subscription_end_date
    into strict v_null_end
    from public.iap_entitlements as legacy
   where legacy.original_transaction_id =
         'codex-remediation-legacy-null-last-chain'
     and legacy.user_id = v_uid;
  perform public.x5_rebuild_app_store_verified_profile(v_uid);
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_null_end then
    raise exception 'legacy_null_last_source_was_not_active';
  end if;
end;
$legacy_null_last_rebuild$;

set local role service_role;

do $legacy_null_last_notifications$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_null_last_token constant uuid :=
    'b6580000-0000-4000-8000-000000000004'::uuid;
  v_null_end timestamptz;
  v_response jsonb;
  v_after_pro_credits integer :=
    current_setting('x5.remediation_after_pro_credits')::integer;
begin
  select legacy.subscription_end_date
    into strict v_null_end
    from public.iap_entitlements as legacy
   where legacy.original_transaction_id =
         'codex-remediation-legacy-null-last-chain'
     and legacy.user_id = v_uid;

  v_response := public.apply_verified_app_store_server_notification(
    '96000000-0000-4000-8000-000000000001', 'REFUND', now(),
    v_uid, 'codex-remediation-legacy-null-last-refund-tx',
    'codex-remediation-legacy-null-last-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_null_last_token,
    now() - interval '12 days', v_null_end,
    now() - interval '1 minute', now() - interval '2 minutes', 100000, null
  );
  if (select is_verified from public.profiles where id = v_uid)
     or (select last_transaction_id from public.iap_entitlements
          where original_transaction_id =
                'codex-remediation-legacy-null-last-chain') is not null then
    raise exception 'legacy_null_last_refund_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '96000000-0000-4000-8000-000000000002', 'REFUND_REVERSED',
    now() + interval '2 seconds', v_uid,
    'codex-remediation-legacy-null-last-refund-tx',
    'codex-remediation-legacy-null-last-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_null_last_token,
    now() - interval '12 days', v_null_end,
    now() + interval '1 second', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_null_end then
    raise exception 'legacy_null_last_reversal_failed:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '96000000-0000-4000-8000-000000000003', 'REFUND',
    now() + interval '4 seconds', v_uid,
    'codex-remediation-legacy-null-last-refund-tx',
    'codex-remediation-legacy-null-last-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_null_last_token,
    now() - interval '12 days', v_null_end,
    now() + interval '3 seconds', now(), 100000, null
  );
  if (select is_verified from public.profiles where id = v_uid)
     or (select credits from public.profiles where id = v_uid)
        is distinct from v_after_pro_credits then
    raise exception 'legacy_null_last_cleanup_or_credit_neutrality_failed:%',
      v_response;
  end if;
end;
$legacy_null_last_notifications$;

reset role;

do $legacy_private_ledger_assertions$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_verified_token constant uuid :=
    'b6580000-0000-4000-8000-000000000003'::uuid;
  v_null_last_token constant uuid :=
    'b6580000-0000-4000-8000-000000000004'::uuid;
begin
  if 5 <> (
    select count(*)
      from public.app_store_verified_lifecycle_events as event
     where event.original_transaction_id =
           'codex-remediation-legacy-verified-chain'
       and event.user_id = v_uid
       and event.app_account_token = v_verified_token
       and event.legacy_binding_used
  ) then
    raise exception 'legacy_lifecycle_private_ledger_identity_failed';
  end if;
  if not exists (
    select 1
      from public.app_store_server_notification_state as state
     where state.environment = 'Production'
       and state.transaction_id = 'codex-remediation-legacy-verified-tx-2'
       and state.user_id = v_uid
       and state.app_account_token = v_verified_token
       and state.legacy_binding_used
       and state.active
  ) then
    raise exception 'legacy_refund_private_state_identity_failed';
  end if;
  if not exists (
    select 1
      from public.app_store_server_notification_events as event
     where event.event_id =
           '96000000-0000-4000-8000-000000000001'::uuid
       and event.user_id = v_uid
       and event.app_account_token = v_null_last_token
       and event.legacy_binding_used
  ) then
    raise exception 'legacy_null_last_private_event_identity_failed';
  end if;
end;
$legacy_private_ledger_assertions$;

do $grace_source_fixture$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
begin
  insert into public.app_store_entitlement_owners (
    original_transaction_id, user_id, app_account_token,
    first_seen_at, last_seen_at
  ) values (
    'codex-remediation-grace-chain', v_uid, v_uid,
    now() - interval '30 days', now()
  );
  insert into public.app_store_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, expires_date,
    signed_date, revocation_date, credits_granted, is_verified_product
  ) values (
    'codex-remediation-grace-tx', 'codex-remediation-grace-chain',
    v_uid, 'com.x5studio.app.verified.monthly', 'Production', v_uid,
    now() - interval '30 days', now() - interval '1 minute',
    now() - interval '2 minutes', null, 0, true
  );
end;
$grace_source_fixture$;

set local role service_role;

do $billing_grace_projection$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_purchase timestamptz := now() - interval '30 days';
  v_expiry timestamptz := now() - interval '1 minute';
  v_grace timestamptz := now() + interval '5 days';
  v_before_credits integer;
  v_response jsonb;
begin
  select credits into v_before_credits
    from public.profiles where id = v_uid;
  perform set_config(
    'x5.remediation_grace_before_credits',
    v_before_credits::text,
    true
  );
  perform set_config(
    'x5.remediation_grace_purchase',
    v_purchase::text,
    true
  );
  perform set_config(
    'x5.remediation_grace_expiry',
    v_expiry::text,
    true
  );
  perform set_config(
    'x5.remediation_grace_until',
    v_grace::text,
    true
  );

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '97000000-0000-4000-8000-000000000001',
    'DID_FAIL_TO_RENEW', 'GRACE_PERIOD', now() - interval '20 seconds',
    v_uid, 'codex-remediation-grace-tx',
    'codex-remediation-grace-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() - interval '40 seconds',
    now() - interval '40 seconds', null, v_grace, 0
  );
  if v_response ->> 'status' not in ('applied', 'already_applied')
     or not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_grace then
    raise exception 'billing_grace_was_not_projected:%', v_response;
  end if;
end;
$billing_grace_projection$;

reset role;

do $billing_grace_initial_rebuild$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_grace timestamptz :=
    current_setting('x5.remediation_grace_until')::timestamptz;
begin
  perform public.x5_rebuild_app_store_verified_profile(v_uid);
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_grace then
    raise exception 'billing_grace_was_lost_during_rebuild';
  end if;
end;
$billing_grace_initial_rebuild$;

set local role service_role;

do $billing_grace_refund_terminal$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_purchase timestamptz :=
    current_setting('x5.remediation_grace_purchase')::timestamptz;
  v_expiry timestamptz :=
    current_setting('x5.remediation_grace_expiry')::timestamptz;
  v_grace timestamptz :=
    current_setting('x5.remediation_grace_until')::timestamptz;
  v_farther_stale_grace timestamptz := now() + interval '9 days';
  v_response jsonb;
begin
  v_response := public.apply_verified_app_store_server_notification(
    '97000000-0000-4000-8000-000000000002', 'REFUND', now(),
    v_uid, 'codex-remediation-grace-tx',
    'codex-remediation-grace-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() - interval '10 seconds',
    now() - interval '20 seconds', 100000, null
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'active_refund_did_not_suppress_grace:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_server_notification(
    '97000000-0000-4000-8000-000000000003', 'REFUND_REVERSED',
    now() + interval '2 seconds', v_uid,
    'codex-remediation-grace-tx',
    'codex-remediation-grace-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() + interval '1 second', null, null, null
  );
  if not (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_grace then
    raise exception 'refund_reversal_did_not_restore_latest_grace:%',
      v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '97000000-0000-4000-8000-000000000004', 'EXPIRED', null,
    now() + interval '4 seconds', v_uid,
    'codex-remediation-grace-tx', 'codex-remediation-grace-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() + interval '3 seconds',
    now() + interval '3 seconds', null, v_grace, 0
  );
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'later_expiry_did_not_supersede_grace:%', v_response;
  end if;

  v_response := public.apply_verified_app_store_subscription_lifecycle(
    '97000000-0000-4000-8000-000000000005',
    'DID_FAIL_TO_RENEW', 'GRACE_PERIOD', now() - interval '30 seconds',
    v_uid, 'codex-remediation-grace-tx',
    'codex-remediation-grace-chain',
    'com.x5studio.app.verified.monthly', 'Production', v_uid,
    v_purchase, v_expiry, now() - interval '50 seconds',
    now() - interval '50 seconds', null, v_farther_stale_grace, 0
  );
end;
$billing_grace_refund_terminal$;

reset role;

do $billing_grace_terminal_rebuild$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
begin
  perform public.x5_rebuild_app_store_verified_profile(v_uid);
  if (select is_verified from public.profiles where id = v_uid) then
    raise exception 'stale_grace_extended_after_later_terminal';
  end if;
end;
$billing_grace_terminal_rebuild$;

set local role service_role;

do $billing_grace_sandbox_scope$
declare
  v_uid uuid := current_setting('x5.remediation_user_3')::uuid;
  v_before_credits integer :=
    current_setting('x5.remediation_grace_before_credits')::integer;
  v_rejected boolean := false;
begin

  begin
    perform public.apply_verified_app_store_subscription_lifecycle(
      '97000000-0000-4000-8000-000000000006',
      'DID_FAIL_TO_RENEW', 'GRACE_PERIOD', now(),
      v_uid, 'codex-remediation-untrusted-sandbox-grace-tx',
      'codex-remediation-untrusted-sandbox-grace-chain',
      'com.x5studio.app.verified.monthly', 'Sandbox', v_uid,
      now() - interval '1 day', now() - interval '1 minute',
      now() - interval '30 seconds', now() - interval '30 seconds',
      null, now() + interval '2 days', 0
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_review_account_not_allowed' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'sandbox_grace_without_allowlisted_source_was_accepted';
  end if;

  if (select credits from public.profiles where id = v_uid)
     is distinct from v_before_credits then
    raise exception 'billing_grace_changed_credits';
  end if;
end;
$billing_grace_sandbox_scope$;

reset role;
rollback;

select 'x5_store_backend_remediation_validated_with_rollback' as result;
