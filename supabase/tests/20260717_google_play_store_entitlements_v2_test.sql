begin;

do $acl$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_android_purchase_entitlement_v2(uuid,text,text,text,text,text,timestamptz,integer,integer,integer,text,text,boolean)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_android_purchase_entitlement_v2(uuid,text,text,text,text,text,timestamptz,integer,integer,integer,text,text,boolean)',
    'execute'
  ) then
    raise exception 'android_v2_rpc_is_client_callable';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.apply_android_purchase_entitlement_v2(uuid,text,text,text,text,text,timestamptz,integer,integer,integer,text,text,boolean)',
    'execute'
  ) then
    raise exception 'android_v2_rpc_is_not_service_callable';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.close_android_linked_subscription(uuid,text,text,timestamptz)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.close_android_linked_subscription(uuid,text,text,timestamptz)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.close_android_linked_subscription(uuid,text,text,timestamptz)',
    'execute'
  ) then
    raise exception 'android_linked_subscription_rpc_acl_invalid';
  end if;
end;
$acl$;

select set_config(
  'x5.google_play_v2_user',
  (
    select id::text from public.profiles
     where coalesce(permanent_credit_debt, 0) = 0
     order by id limit 1
  ),
  true
);
select set_config(
  'x5.google_play_v2_other_user',
  (
    select id::text from public.profiles
     where id <> current_setting('x5.google_play_v2_user')::uuid
     order by id limit 1
  ),
  true
);

set local role service_role;

do $successful_order_replay$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_initial_expiry timestamptz := now() + interval '30 days';
  v_refreshed_expiry timestamptz := now() + interval '35 days';
  v_stale_expiry timestamptz := now() + interval '32 days';
  v_renewal_expiry timestamptz := now() + interval '65 days';
  v_before_credits integer;
  v_after_first integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id like
         'x5_lite_monthly_v2:codex-v2-token:%';
  update public.profiles
     set subscription_end_date = null
   where id = v_uid;
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-v2-token:GPA.codex-paid-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
    'GPA.codex-paid-order', v_initial_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  select credits into v_after_first
    from public.profiles where id = v_uid;
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_after_first <> v_before_credits + 1000 then
    raise exception 'initial_successful_order_grant_failed:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-v2-token:GPA.codex-paid-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
    'GPA.codex-paid-order', v_refreshed_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  if not (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or not (v_response ->> 'access_refreshed')::boolean
     or (select credits from public.profiles where id = v_uid) <> v_after_first
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_refreshed_expiry then
    raise exception 'same_order_expiry_refresh_failed:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-v2-token:GPA.codex-paid-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
    'GPA.codex-paid-order', v_stale_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  if (v_response ->> 'access_refreshed')::boolean
     or (select credits from public.profiles where id = v_uid) <> v_after_first
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_refreshed_expiry then
    raise exception 'stale_same_order_snapshot_changed_access:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-v2-token:GPA.codex-renewal-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
    'GPA.codex-renewal-order', v_renewal_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 1000
     or (select credits from public.profiles where id = v_uid) <>
        v_after_first + 1000
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_renewal_expiry then
    raise exception 'new_successful_order_renewal_failed:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-v2-token:GPA.codex-renewal-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
    'GPA.codex-renewal-order', v_renewal_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  if not (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or (select credits from public.profiles where id = v_uid) <>
        v_after_first + 1000 then
    raise exception 'renewal_order_replay_minted_twice:%', v_response;
  end if;
end;
$successful_order_replay$;

do $paid_order_credit_is_independent_of_global_access_expiry$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_global_expiry timestamptz := now() + interval '180 days';
  v_order_expiry timestamptz := now() + interval '30 days';
  v_before_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_pro_monthly_v2:codex-overlap-token:GPA.overlap-paid';
  update public.profiles
     set plan = 'pro',
         subscription_type = 'pro_monthly',
         subscription_end_date = v_global_expiry
   where id = v_uid;
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_pro_monthly_v2:codex-overlap-token:GPA.overlap-paid',
    'x5_pro_monthly_v2', 'subscription', 'codex-overlap-token',
    'GPA.overlap-paid', v_order_expiry,
    1, 1, 2000, 'pro_monthly', 'pro', false
  );
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 2000
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits + 2000
     or (select credits_granted from public.iap_entitlements
          where original_transaction_id =
            'x5_pro_monthly_v2:codex-overlap-token:GPA.overlap-paid') <> 2000
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_global_expiry then
    raise exception 'paid_order_was_suppressed_by_global_access:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_pro_monthly_v2:codex-overlap-token:GPA.overlap-paid',
    'x5_pro_monthly_v2', 'subscription', 'codex-overlap-token',
    'GPA.overlap-paid', v_order_expiry,
    1, 1, 2000, 'pro_monthly', 'pro', false
  );
  if not (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits + 2000 then
    raise exception 'overlap_order_replay_minted_twice:%', v_response;
  end if;
end;
$paid_order_credit_is_independent_of_global_access_expiry$;

do $permanent_access_survives_google_orders_and_refreshes$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_black_expiry timestamptz := now() + interval '30 days';
  v_black_refresh timestamptz := now() + interval '35 days';
  v_manual_expiry timestamptz := now() + interval '40 days';
  v_manual_refresh timestamptz := now() + interval '45 days';
  v_before_credits integer;
  v_after_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id in (
     'x5_max_monthly_v2:codex-permanent-black:GPA.black',
     'x5_lite_monthly_v2:codex-permanent-manual:GPA.manual'
   );

  update public.profiles
     set plan = 'black',
         subscription_type = 'max_monthly',
         subscription_end_date = null
   where id = v_uid;
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_max_monthly_v2:codex-permanent-black:GPA.black',
    'x5_max_monthly_v2', 'subscription', 'codex-permanent-black',
    'GPA.black', v_black_expiry,
    1, 1, 5000, 'max_monthly', 'pro', false
  );
  select credits into v_after_credits
    from public.profiles where id = v_uid;
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 5000
     or v_after_credits <> v_before_credits + 5000
     or (select plan from public.profiles where id = v_uid) <> 'black'
     or (select subscription_type from public.profiles where id = v_uid)
        <> 'max_monthly'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'black_access_changed_by_new_google_order:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_max_monthly_v2:codex-permanent-black:GPA.black',
    'x5_max_monthly_v2', 'subscription', 'codex-permanent-black',
    'GPA.black', v_black_refresh,
    1, 1, 5000, 'max_monthly', 'pro', false
  );
  if not (v_response ->> 'already_claimed')::boolean
     or not (v_response ->> 'access_refreshed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or (select credits from public.profiles where id = v_uid)
        <> v_after_credits
     or (select plan from public.profiles where id = v_uid) <> 'black'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'black_access_changed_by_google_refresh:%', v_response;
  end if;

  update public.profiles
     set plan = 'pro',
         subscription_type = 'yearly',
         subscription_end_date = null
   where id = v_uid;
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-permanent-manual:GPA.manual',
    'x5_lite_monthly_v2', 'subscription', 'codex-permanent-manual',
    'GPA.manual', v_manual_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  select credits into v_after_credits
    from public.profiles where id = v_uid;
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_after_credits <> v_before_credits + 1000
     or (select plan from public.profiles where id = v_uid) <> 'pro'
     or (select subscription_type from public.profiles where id = v_uid)
        <> 'yearly'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'manual_access_changed_by_new_google_order:%', v_response;
  end if;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-permanent-manual:GPA.manual',
    'x5_lite_monthly_v2', 'subscription', 'codex-permanent-manual',
    'GPA.manual', v_manual_refresh,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  if not (v_response ->> 'already_claimed')::boolean
     or not (v_response ->> 'access_refreshed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or (select credits from public.profiles where id = v_uid)
        <> v_after_credits
     or (select plan from public.profiles where id = v_uid) <> 'pro'
     or (select subscription_type from public.profiles where id = v_uid)
        <> 'yearly'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'manual_access_changed_by_google_refresh:%', v_response;
  end if;
end;
$permanent_access_survives_google_orders_and_refreshes$;

do $linked_replacement_closes_old_future_access$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_effective_time timestamptz := clock_timestamp();
  v_old_expiry timestamptz := v_effective_time + interval '90 days';
  v_new_expiry timestamptz := v_effective_time + interval '30 days';
  v_before_credits integer;
  v_closed integer;
begin
  update public.iap_entitlements
     set expires_at = v_effective_time - interval '1 day',
         subscription_end_date = v_effective_time - interval '1 day'
   where user_id = v_uid
     and purchase_type = 'subscription';
  delete from public.iap_entitlements
   where original_transaction_id in (
     'x5_max_monthly_v2:codex-linked-old:GPA.linked-old',
     'x5_lite_monthly_v2:codex-linked-new:GPA.linked-new'
   );
  update public.profiles
     set plan = 'free',
         subscription_type = null,
         subscription_end_date = null
   where id = v_uid;
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_max_monthly_v2:codex-linked-old:GPA.linked-old',
    'x5_max_monthly_v2', 'subscription', 'codex-linked-old',
    'GPA.linked-old', v_old_expiry,
    1, 1, 5000, 'max_monthly', 'pro', false
  );
  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-linked-new:GPA.linked-new',
    'x5_lite_monthly_v2', 'subscription', 'codex-linked-new',
    'GPA.linked-new', v_new_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );

  v_closed := public.close_android_linked_subscription(
    v_uid, 'codex-linked-old', 'codex-linked-new', v_effective_time
  );
  if v_closed <> 1
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_max_monthly_v2:codex-linked-old:GPA.linked-old')
        is distinct from v_effective_time
     or (select revocation_reason from public.iap_entitlements
          where original_transaction_id =
            'x5_max_monthly_v2:codex-linked-old:GPA.linked-old')
        <> 'subscription_replaced'
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_lite_monthly_v2:codex-linked-new:GPA.linked-new')
        is distinct from v_new_expiry
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_new_expiry
     or (select subscription_type from public.profiles where id = v_uid)
        <> 'lite_monthly'
     or (select credits from public.profiles where id = v_uid)
        <> v_before_credits + 6000 then
    raise exception 'linked_replacement_kept_old_future_access:%', v_closed;
  end if;

  v_closed := public.close_android_linked_subscription(
    v_uid, 'codex-linked-old', 'codex-linked-new', v_effective_time
  );
  if v_closed <> 0
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_new_expiry then
    raise exception 'linked_replacement_close_was_not_idempotent:%', v_closed;
  end if;
end;
$linked_replacement_closes_old_future_access$;

do $token_owner_and_permanent_pack$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_other_uid uuid := current_setting('x5.google_play_v2_other_user')::uuid;
  v_before_credits integer;
  v_before_permanent integer;
  v_response jsonb;
  v_owner_denied boolean := false;
begin
  begin
    perform public.apply_android_purchase_entitlement_v2(
      v_other_uid,
      'x5_lite_monthly_v2:codex-v2-token:GPA.codex-cross-user',
      'x5_lite_monthly_v2', 'subscription', 'codex-v2-token',
      'GPA.codex-cross-user', now() + interval '70 days',
      1, 1, 1000, 'lite_monthly', 'pro', false
    );
  exception when others then
    v_owner_denied := sqlerrm = 'owned_by_other';
  end;
  if not v_owner_denied then
    raise exception 'cross_user_purchase_token_was_not_denied';
  end if;

  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_credits_1000_v2:codex-v2-pack-token:GPA.codex-pack';
  select credits, permanent_credits
    into v_before_credits, v_before_permanent
    from public.profiles where id = v_uid;
  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_credits_1000_v2:codex-v2-pack-token:GPA.codex-pack',
    'x5_credits_1000_v2', 'inapp', 'codex-v2-pack-token',
    'GPA.codex-pack', null,
    2, 2, 1000, null, null, false
  );
  if (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 2000
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits + 2000
     or (select permanent_credits from public.profiles where id = v_uid) <>
        v_before_permanent + 2000 then
    raise exception 'inapp_quantity_permanent_grant_failed:%', v_response;
  end if;
end;
$token_owner_and_permanent_pack$;

do $verified_order_replay$
declare
  v_uid uuid := current_setting('x5.google_play_v2_user')::uuid;
  v_initial_expiry timestamptz := now() + interval '40 days';
  v_refreshed_expiry timestamptz := now() + interval '45 days';
  v_before_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id like
         'x5_verified_monthly_v2:codex-v2-verified-token:%';
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_verified_monthly_v2:codex-v2-verified-token:GPA.codex-verified',
    'x5_verified_monthly_v2', 'subscription',
    'codex-v2-verified-token', 'GPA.codex-verified', v_initial_expiry,
    1, 1, 0, 'verified_monthly', null, true
  );
  v_response := public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_verified_monthly_v2:codex-v2-verified-token:GPA.codex-verified',
    'x5_verified_monthly_v2', 'subscription',
    'codex-v2-verified-token', 'GPA.codex-verified', v_refreshed_expiry,
    1, 1, 0, 'verified_monthly', null, true
  );
  if not (v_response ->> 'already_claimed')::boolean
     or (v_response ->> 'credits_granted')::integer <> 0
     or not (v_response ->> 'access_refreshed')::boolean
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits
     or (select verified_until from public.profiles where id = v_uid)
        is distinct from v_refreshed_expiry then
    raise exception 'verified_same_order_refresh_failed:%', v_response;
  end if;
end;
$verified_order_replay$;

reset role;
rollback;

select 'google_play_store_entitlements_v2_validated_with_rollback' as result;
