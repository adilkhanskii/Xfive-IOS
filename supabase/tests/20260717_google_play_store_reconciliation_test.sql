begin;

do $acl$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_google_play_reversal(text,text,text,text,timestamptz,integer,boolean,text,timestamptz)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_google_play_reversal(text,text,text,text,timestamptz,integer,boolean,text,timestamptz)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.apply_google_play_reversal(text,text,text,text,timestamptz,integer,boolean,text,timestamptz)',
    'execute'
  ) then
    raise exception 'google_play_reversal_rpc_acl_invalid';
  end if;
  if has_table_privilege(
    'service_role', 'public.google_play_reconciliation_events', 'select'
  ) or has_table_privilege(
    'authenticated', 'public.google_play_reconciliation_events', 'select'
  ) then
    raise exception 'google_play_reconciliation_ledger_is_directly_accessible';
  end if;
end;
$acl$;

select set_config(
  'x5.google_play_reversal_user',
  (
    select id::text from public.profiles
     where coalesce(permanent_credit_debt, 0) = 0
       and coalesce(permanent_credits, 0) = 0
     order by id limit 1
  ),
  true
);
select set_config(
  'x5.google_play_reversal_verified_user',
  (
    select id::text from public.profiles
     where not coalesce(is_verified, false)
     order by id limit 1
  ),
  true
);

set local role service_role;

do $unknown_source_is_skippable$
declare
  v_response jsonb;
begin
  v_response := public.apply_google_play_reversal(
    'voided:codex-unknown-source', 'voided_full',
    'codex-token-with-no-ledger', 'GPA.unknown', now(), 0, true,
    null, null
  );
  if v_response ->> 'status' <> 'source_not_found' then
    raise exception 'unknown_voided_source_was_not_skippable:%', v_response;
  end if;
end;
$unknown_source_is_skippable$;

do $stale_subscription_event$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_user')::uuid;
  v_event_time timestamptz := now() - interval '1 day';
  v_renewal_expiry timestamptz := now() + interval '60 days';
  v_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where purchase_token_hash = 'codex-stale-rtdn-token';
  update public.profiles
     set subscription_end_date = null
   where id = v_uid;

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-stale-rtdn-token:GPA.old-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-stale-rtdn-token',
    'GPA.old-order', now() + interval '30 days',
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  update public.iap_entitlements
     set created_at = now() - interval '2 days',
         updated_at = now() - interval '2 days'
   where original_transaction_id =
         'x5_lite_monthly_v2:codex-stale-rtdn-token:GPA.old-order';

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_lite_monthly_v2:codex-stale-rtdn-token:GPA.new-order',
    'x5_lite_monthly_v2', 'subscription', 'codex-stale-rtdn-token',
    'GPA.new-order', v_renewal_expiry,
    1, 1, 1000, 'lite_monthly', 'pro', false
  );
  select credits into v_credits from public.profiles where id = v_uid;

  v_response := public.apply_google_play_reversal(
    'rtdn:codex-google-stale-terminal', 'subscription_expired',
    'codex-stale-rtdn-token', 'GPA.new-order', v_event_time, 0, false,
    'SUBSCRIPTION_STATE_ACTIVE', v_renewal_expiry
  );
  if v_response ->> 'status' <> 'ignored_stale'
     or (select credits from public.profiles where id = v_uid) <> v_credits
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_renewal_expiry
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_lite_monthly_v2:codex-stale-rtdn-token:GPA.new-order')
        is distinct from v_renewal_expiry then
    raise exception 'stale_terminal_event_truncated_renewal:%', v_response;
  end if;

  v_response := public.apply_google_play_reversal(
    'rtdn:codex-google-stale-terminal', 'subscription_expired',
    'codex-stale-rtdn-token', 'GPA.old-order', v_event_time, 0, false,
    'SUBSCRIPTION_STATE_EXPIRED', v_event_time
  );
  if v_response ->> 'status' <> 'ignored_stale'
     or (select credits from public.profiles where id = v_uid) <> v_credits
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_renewal_expiry then
    raise exception 'stale_terminal_replay_changed_renewal:%', v_response;
  end if;

  v_response := public.apply_google_play_reversal(
    'codex-google-old-order-refund', 'voided_full',
    'codex-stale-rtdn-token', 'GPA.old-order', clock_timestamp(), 0, true,
    null, null
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_reversed')::integer <> 1000
     or (select credits from public.profiles where id = v_uid) <>
        v_credits - 1000
     or (select subscription_end_date from public.profiles where id = v_uid)
        is distinct from v_renewal_expiry
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_lite_monthly_v2:codex-stale-rtdn-token:GPA.new-order')
        is distinct from v_renewal_expiry then
    raise exception 'old_order_refund_truncated_newer_access:%', v_response;
  end if;
end;
$stale_subscription_event$;

do $delayed_old_revoke_must_not_attach_to_later_order$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_user')::uuid;
  v_event_time timestamptz := now() - interval '2 days';
  v_latest_expiry timestamptz := now() + interval '25 days';
  v_before_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where purchase_token_hash = 'codex-delayed-revoke-token';
  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_pro_monthly_v2:codex-delayed-revoke-token:GPA.latest-order',
    'x5_pro_monthly_v2', 'subscription', 'codex-delayed-revoke-token',
    'GPA.latest-order', v_latest_expiry,
    1, 1, 2000, 'pro_monthly', 'pro', false
  );
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_google_play_reversal(
    'rtdn:codex-google-delayed-old-revoke', 'subscription_revoked',
    'codex-delayed-revoke-token', 'GPA.latest-order',
    v_event_time, 0, true,
    'SUBSCRIPTION_STATE_EXPIRED', v_latest_expiry
  );
  if v_response ->> 'status' <> 'ignored_stale'
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits
     or (select credits_revoked from public.iap_entitlements
          where original_transaction_id =
            'x5_pro_monthly_v2:codex-delayed-revoke-token:GPA.latest-order')
        <> 0
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_pro_monthly_v2:codex-delayed-revoke-token:GPA.latest-order')
        is distinct from v_latest_expiry then
    raise exception 'delayed_revoke_attached_to_later_order:%', v_response;
  end if;
end;
$delayed_old_revoke_must_not_attach_to_later_order$;

do $paused_subscription_loses_paid_access_at_event_time$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_user')::uuid;
  v_event_time timestamptz := clock_timestamp();
  v_expiry timestamptz := v_event_time + interval '30 days';
  v_before_credits integer;
  v_response jsonb;
begin
  update public.iap_entitlements
     set expires_at = v_event_time - interval '1 day',
         subscription_end_date = v_event_time - interval '1 day'
   where user_id = v_uid
     and purchase_type = 'subscription';
  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_pro_monthly_v2:codex-paused-token:GPA.paused';
  update public.profiles
     set plan = 'free',
         subscription_type = null,
         subscription_end_date = null
   where id = v_uid;

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_pro_monthly_v2:codex-paused-token:GPA.paused',
    'x5_pro_monthly_v2', 'subscription', 'codex-paused-token',
    'GPA.paused', v_expiry,
    1, 1, 2000, 'pro_monthly', 'pro', false
  );
  select credits into v_before_credits
    from public.profiles where id = v_uid;

  v_response := public.apply_google_play_reversal(
    'rtdn:codex-google-paused', 'subscription_paused',
    'codex-paused-token', 'GPA.paused',
    v_event_time, 0, false,
    'SUBSCRIPTION_STATE_PAUSED', v_expiry
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_reversed')::integer <> 0
     or (select credits from public.profiles where id = v_uid)
        <> v_before_credits
     or (select expires_at from public.iap_entitlements
          where original_transaction_id =
            'x5_pro_monthly_v2:codex-paused-token:GPA.paused')
        is distinct from v_event_time
     or (select revocation_reason from public.iap_entitlements
          where original_transaction_id =
            'x5_pro_monthly_v2:codex-paused-token:GPA.paused')
        <> 'subscription_paused'
     or (select plan from public.profiles where id = v_uid) <> 'free'
     or (select subscription_end_date from public.profiles where id = v_uid)
        is not null then
    raise exception 'paused_subscription_kept_paid_access:%', v_response;
  end if;
end;
$paused_subscription_loses_paid_access_at_event_time$;

do $partial_and_full_void$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_user')::uuid;
  v_before_credits integer;
  v_before_permanent integer;
  v_after_grant_credits integer;
  v_after_grant_permanent integer;
  v_event_time timestamptz := now();
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_credits_1000_v2:codex-reversal-token:GPA.codex-reversal';
  select credits, permanent_credits
    into v_before_credits, v_before_permanent
    from public.profiles where id = v_uid;

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_credits_1000_v2:codex-reversal-token:GPA.codex-reversal',
    'x5_credits_1000_v2', 'inapp', 'codex-reversal-token',
    'GPA.codex-reversal', null,
    2, 2, 1000, null, null, false
  );
  select credits, permanent_credits
    into v_after_grant_credits, v_after_grant_permanent
    from public.profiles where id = v_uid;
  if v_after_grant_credits <> v_before_credits + 2000
     or v_after_grant_permanent <> v_before_permanent + 2000 then
    raise exception 'google_pack_setup_failed';
  end if;

  v_response := public.apply_google_play_reversal(
    'codex-google-void-partial', 'voided_partial',
    'codex-reversal-token', 'GPA.codex-reversal',
    v_event_time, 1, true, null, null
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'quantity_reversed')::integer <> 1
     or (v_response ->> 'credits_reversed')::integer <> 1000
     or (select credits from public.profiles where id = v_uid) <>
        v_after_grant_credits - 1000
     or (select permanent_credits from public.profiles where id = v_uid) <>
        v_after_grant_permanent - 1000
     or (select refundable_quantity from public.iap_entitlements
          where original_transaction_id =
            'x5_credits_1000_v2:codex-reversal-token:GPA.codex-reversal') <> 1 then
    raise exception 'google_partial_void_failed:%', v_response;
  end if;

  v_response := public.apply_google_play_reversal(
    'codex-google-void-partial', 'voided_partial',
    'codex-reversal-token', 'GPA.codex-reversal',
    v_event_time, 1, true, null, null
  );
  if v_response ->> 'status' <> 'already_applied'
     or (select credits from public.profiles where id = v_uid) <>
        v_after_grant_credits - 1000 then
    raise exception 'google_partial_void_replay_was_not_exact_once:%',
      v_response;
  end if;

  v_response := public.apply_google_play_reversal(
    'codex-google-void-full', 'voided_full',
    'codex-reversal-token', 'GPA.codex-reversal',
    v_event_time + interval '1 second', 0, true, null, null
  );
  if (v_response ->> 'credits_reversed')::integer <> 1000
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits
     or (select permanent_credits from public.profiles where id = v_uid) <>
        v_before_permanent
     or (select refundable_quantity from public.iap_entitlements
          where original_transaction_id =
            'x5_credits_1000_v2:codex-reversal-token:GPA.codex-reversal') <> 0
     or (select credits_revoked from public.iap_entitlements
          where original_transaction_id =
            'x5_credits_1000_v2:codex-reversal-token:GPA.codex-reversal') <> 2000 then
    raise exception 'google_full_void_failed:%', v_response;
  end if;
end;
$partial_and_full_void$;

do $refund_after_spend$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_user')::uuid;
  v_event_time timestamptz := now();
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_credits_1000_v2:codex-spent-token:GPA.codex-spent';
  update public.profiles
     set credits = 0,
         permanent_credits = 0,
         permanent_credit_debt = 0
   where id = v_uid;

  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_credits_1000_v2:codex-spent-token:GPA.codex-spent',
    'x5_credits_1000_v2', 'inapp', 'codex-spent-token',
    'GPA.codex-spent', null,
    1, 1, 1000, null, null, false
  );
  update public.profiles set credits = 0 where id = v_uid;

  v_response := public.apply_google_play_reversal(
    'codex-google-spent-refund', 'voided_full',
    'codex-spent-token', 'GPA.codex-spent',
    v_event_time, 0, true, null, null
  );
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_reversed')::integer <> 1000
     or (select credits from public.profiles where id = v_uid) <> -1000
     or (select permanent_credits from public.profiles where id = v_uid) <> 0
     or (select permanent_credit_debt from public.profiles where id = v_uid)
        <> 1000 then
    raise exception 'google_refund_after_spend_debt_failed:%', v_response;
  end if;

  v_response := public.apply_google_play_reversal(
    'codex-google-spent-refund', 'voided_full',
    'codex-spent-token', 'GPA.codex-spent',
    v_event_time, 0, true, null, null
  );
  if v_response ->> 'status' <> 'already_applied'
     or (select credits from public.profiles where id = v_uid) <> -1000
     or (select permanent_credit_debt from public.profiles where id = v_uid)
        <> 1000 then
    raise exception 'spent_refund_replay_was_not_exact_once:%', v_response;
  end if;
end;
$refund_after_spend$;

do $verified_revocation$
declare
  v_uid uuid := current_setting('x5.google_play_reversal_verified_user')::uuid;
  v_expiry timestamptz := now() + interval '1 month';
  v_event_time timestamptz := now();
  v_before_credits integer;
  v_response jsonb;
begin
  delete from public.iap_entitlements
   where original_transaction_id =
         'x5_verified_monthly_v2:codex-verified-revoke-token:GPA.verified';
  select credits into v_before_credits
    from public.profiles where id = v_uid;
  perform public.apply_android_purchase_entitlement_v2(
    v_uid,
    'x5_verified_monthly_v2:codex-verified-revoke-token:GPA.verified',
    'x5_verified_monthly_v2', 'subscription',
    'codex-verified-revoke-token', 'GPA.verified', v_expiry,
    1, 1, 0, 'verified_monthly', null, true
  );
  v_response := public.apply_google_play_reversal(
    'codex-google-verified-revoke', 'subscription_revoked',
    'codex-verified-revoke-token', 'GPA.verified',
    v_event_time, 0, true,
    'SUBSCRIPTION_STATE_EXPIRED', v_expiry
  );
  if v_response ->> 'status' <> 'applied'
     or (select credits from public.profiles where id = v_uid) <>
        v_before_credits
     or (select is_verified from public.profiles where id = v_uid)
     or (select verified_until from public.profiles where id = v_uid) >
        v_event_time then
    raise exception 'google_verified_revocation_failed:%', v_response;
  end if;
end;
$verified_revocation$;

reset role;
rollback;

select 'google_play_store_reconciliation_validated_with_rollback' as result;
