-- Early-billed App Store auto-renewals (2026-10-02 incident).
-- Apple bills a renewal up to 24 hours before the current period ends and
-- signs the transaction, renewal info and DID_RENEW notification then, while
-- purchase_date is the start of the new period. Before migration
-- 20261002150000 every such renewal failed with invalid_signed_date (webhook)
-- or invalid_transaction_dates (app path).
-- Run only against a disposable database with three profiles that have no
-- App Store history. Every change is rolled back.
begin;

create temporary table x5_renewal_test_users on commit drop as
select profile.id, row_number() over (order by profile.id) as slot
  from public.profiles as profile
 where not exists (
         select 1 from public.app_store_entitlement_owners as owner
          where owner.user_id = profile.id
       )
   and not exists (
         select 1 from public.iap_entitlements as legacy
          where legacy.user_id = profile.id
       )
   and not exists (
         select 1 from public.app_store_verified_lifecycle_events as event
          where event.user_id = profile.id
       )
 order by profile.id
 limit 3;

create function pg_temp.x5_expect_rejection(p_sql text, p_expected text)
returns void
language plpgsql
as $function$
declare
  v_message text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_message = message_text;
    if position(p_expected in v_message) = 0 then
      raise exception 'expected %, got %', p_expected, v_message;
    end if;
    return;
  end;
  raise exception 'expected rejection %', p_expected;
end;
$function$;

-- 1. Apple's first DID_RENEW delivery arrives 23h before the period starts.
do $first_delivery$
declare
  v_user uuid := (select id from x5_renewal_test_users where slot = 1);
  v_period_start timestamptz :=
    date_trunc('second', clock_timestamp()) + interval '2 hours';
  v_initial timestamptz := v_period_start - interval '30 days';
  v_period_end timestamptz := v_period_start + interval '30 days';
  v_billed timestamptz := v_period_start - interval '23 hours';
  v_result jsonb;
  v_profile public.profiles%rowtype;
begin
  if (select count(*) from x5_renewal_test_users) < 3 then
    raise exception 'renewal_test_needs_three_clean_profiles';
  end if;

  v_result := public.apply_verified_app_store_subscription_lifecycle(
    '00000000-0000-4000-8000-000000000101', 'SUBSCRIBED', 'INITIAL_BUY',
    v_initial + interval '2 seconds', v_user, '2000000900000101',
    '2000000900000100', 'com.x5studio.app.verified.monthly', 'Production',
    v_user, v_initial, v_period_start, v_initial + interval '1 second',
    v_initial + interval '1 second', null, null, 1
  );
  if v_result ->> 'status' <> 'applied' then
    raise exception 'initial_buy_not_applied: %', v_result;
  end if;

  v_result := public.apply_verified_app_store_subscription_lifecycle(
    '00000000-0000-4000-8000-000000000102', 'DID_RENEW', null,
    v_billed + interval '1 second', v_user, '2000000900000102',
    '2000000900000100', 'com.x5studio.app.verified.monthly', 'Production',
    v_user, v_period_start, v_period_end, v_billed, v_billed, null, null, 1
  );
  if v_result ->> 'status' <> 'applied' then
    raise exception 'early_renewal_first_delivery_not_applied: %', v_result;
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if not v_profile.is_verified
     or v_profile.verified_until is distinct from v_period_end then
    raise exception 'early_renewal_did_not_extend_badge: % %',
      v_profile.is_verified, v_profile.verified_until;
  end if;
  if not exists (
    select 1 from public.app_store_transactions as renewal
     where renewal.transaction_id = '2000000900000102'
       and renewal.user_id = v_user
       and renewal.purchase_date = v_period_start
       and renewal.expires_date = v_period_end
       and renewal.signed_date = v_billed
       and renewal.credits_granted = 0
       and renewal.is_verified_product
  ) or not exists (
    select 1 from public.app_store_verified_lifecycle_events as event
     where event.event_id = '00000000-0000-4000-8000-000000000102'
       and event.result_status = 'applied'
       and event.transaction_signed_date = v_billed
  ) then
    raise exception 'early_renewal_ledger_rows_missing';
  end if;

  -- Apple retries the identical notification: exact, idempotent replay.
  v_result := public.apply_verified_app_store_subscription_lifecycle(
    '00000000-0000-4000-8000-000000000102', 'DID_RENEW', null,
    v_billed + interval '1 second', v_user, '2000000900000102',
    '2000000900000100', 'com.x5studio.app.verified.monthly', 'Production',
    v_user, v_period_start, v_period_end, v_billed, v_billed, null, null, 1
  );
  if v_result ->> 'status' <> 'already_applied' then
    raise exception 'early_renewal_retry_not_idempotent: %', v_result;
  end if;

  -- The 15-minute reconciliation keeps the renewed badge.
  if public.x5_rebuild_app_store_verified_profile(v_user)
     is distinct from v_period_end then
    raise exception 'reconciliation_removed_renewed_badge';
  end if;
end;
$first_delivery$;

-- 2. Apple's retry is delivered after the new period has already started.
do $retry_after_start$
declare
  v_user uuid := (select id from x5_renewal_test_users where slot = 2);
  v_period_start timestamptz :=
    date_trunc('second', clock_timestamp()) - interval '1 hour';
  v_period_end timestamptz := v_period_start + interval '30 days';
  v_billed timestamptz := v_period_start - interval '23 hours';
  v_result jsonb;
begin
  insert into public.app_store_entitlement_owners (
    original_transaction_id, user_id, app_account_token
  ) values ('2000000900000200', v_user, v_user);
  insert into public.app_store_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, expires_date,
    signed_date, credits_granted, is_verified_product
  ) values (
    '2000000900000201', '2000000900000200', v_user,
    'com.x5studio.app.verified.monthly', 'Production', v_user,
    v_period_start - interval '30 days', v_period_start,
    v_period_start - interval '30 days' + interval '1 second', 0, true
  );
  if public.x5_rebuild_app_store_verified_profile(v_user) is not null then
    raise exception 'expired_period_still_verified';
  end if;

  v_result := public.apply_verified_app_store_subscription_lifecycle(
    '00000000-0000-4000-8000-000000000202', 'DID_RENEW', null,
    v_billed + interval '1 second', v_user, '2000000900000202',
    '2000000900000200', 'com.x5studio.app.verified.monthly', 'Production',
    v_user, v_period_start, v_period_end, v_billed, v_billed, null, null, 1
  );
  if v_result ->> 'status' <> 'applied'
     or (v_result ->> 'subscription_end_date')::timestamptz
        is distinct from v_period_end
     or not (
       select is_verified and verified_until = v_period_end
         from public.profiles where id = v_user
     ) then
    raise exception 'early_renewal_retry_not_applied: %', v_result;
  end if;
end;
$retry_after_start$;

-- 3. The app sends the renewal from StoreKit after the period started, then
--    Apple's re-signed notification for the same transaction arrives.
do $app_path$
declare
  v_user uuid := (select id from x5_renewal_test_users where slot = 3);
  v_period_start timestamptz :=
    date_trunc('second', clock_timestamp()) - interval '1 hour';
  v_period_end timestamptz := v_period_start + interval '30 days';
  v_billed timestamptz := v_period_start - interval '23 hours';
  v_result jsonb;
begin
  insert into public.app_store_entitlement_owners (
    original_transaction_id, user_id, app_account_token
  ) values ('2000000900000300', v_user, v_user);
  insert into public.app_store_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, expires_date,
    signed_date, credits_granted, is_verified_product
  ) values (
    '2000000900000301', '2000000900000300', v_user,
    'com.x5studio.app.verified.monthly', 'Production', v_user,
    v_period_start - interval '30 days', v_period_start,
    v_period_start - interval '30 days' + interval '1 second', 0, true
  );

  v_result := public.apply_verified_app_store_transaction(
    v_user, '2000000900000302', '2000000900000300',
    'com.x5studio.app.verified.monthly', 'Production', v_user,
    v_period_start, v_period_end, v_billed, null
  );
  if v_result ->> 'status' <> 'applied'
     or not (v_result ->> 'is_verified')::boolean
     or not (
       select is_verified and verified_until = v_period_end
         from public.profiles where id = v_user
     ) then
    raise exception 'early_renewal_app_path_not_applied: %', v_result;
  end if;

  v_result := public.apply_verified_app_store_subscription_lifecycle(
    '00000000-0000-4000-8000-000000000302', 'DID_RENEW', null,
    v_billed + interval '1 minute', v_user, '2000000900000302',
    '2000000900000300', 'com.x5studio.app.verified.monthly', 'Production',
    v_user, v_period_start, v_period_end, v_billed + interval '1 minute',
    v_billed + interval '1 minute', null, null, 1
  );
  if v_result ->> 'status' <> 'already_applied'
     or (
       select count(*) from public.app_store_transactions
        where transaction_id = '2000000900000302'
          and signed_date = v_billed
     ) <> 1 then
    raise exception 'early_renewal_cross_path_not_idempotent: %', v_result;
  end if;

  -- 25 hours is the inclusive limit (distinct expiry: a new paid period).
  v_result := public.apply_verified_app_store_transaction(
    v_user, '2000000900000303', '2000000900000300',
    'com.x5studio.app.verified.monthly', 'Production', v_user,
    v_period_start + interval '1 second', v_period_end + interval '1 day',
    v_period_start + interval '1 second' - interval '25 hours', null
  );
  if v_result ->> 'status' <> 'applied' then
    raise exception 'early_renewal_25h_boundary_rejected: %', v_result;
  end if;
end;
$app_path$;

-- 4. Everything outside the renewal window is still refused.
do $rejections$
declare
  v_user uuid := (select id from x5_renewal_test_users where slot = 2);
  v_now timestamptz := date_trunc('second', clock_timestamp());
  v_lifecycle text := $sql$
    select public.apply_verified_app_store_subscription_lifecycle(
      gen_random_uuid(), 'DID_RENEW', null, %L::timestamptz, %L::uuid,
      %L, '2000000900000200', 'com.x5studio.app.verified.monthly',
      'Production', %L::uuid, %L::timestamptz, %L::timestamptz,
      %L::timestamptz, %L::timestamptz, null, null, 1
    )
  $sql$;
  v_app text := $sql$
    select public.apply_verified_app_store_transaction(
      %L::uuid, %L, '2000000900000200', 'com.x5studio.app.verified.monthly',
      'Production', %L::uuid, %L::timestamptz, %L::timestamptz,
      %L::timestamptz, null
    )
  $sql$;
  v_start timestamptz := v_now - interval '1 hour';
  v_end timestamptz := v_now + interval '29 days';
  v_signed timestamptz;
begin
  -- signed 30h before the period start
  v_signed := v_start - interval '30 hours';
  perform pg_temp.x5_expect_rejection(
    format(v_lifecycle, v_signed + interval '1 second', v_user,
      '2000000900000210', v_user, v_start, v_end, v_signed, v_signed),
    'invalid_signed_date'
  );
  perform pg_temp.x5_expect_rejection(
    format(v_app, v_user, '2000000900000211', v_user, v_start, v_end,
      v_signed),
    'invalid_transaction_dates'
  );

  -- far-future period start
  v_signed := v_now - interval '1 minute';
  perform pg_temp.x5_expect_rejection(
    format(v_lifecycle, v_signed + interval '1 second', v_user,
      '2000000900000212', v_user, v_now + interval '30 days',
      v_now + interval '60 days', v_signed, v_signed),
    'invalid_signed_date'
  );
  perform pg_temp.x5_expect_rejection(
    format(v_app, v_user, '2000000900000213', v_user,
      v_now + interval '30 days', v_now + interval '60 days', v_signed),
    'invalid_transaction_dates'
  );
  perform pg_temp.x5_expect_rejection(
    format(v_app, v_user, '2000000900000214', v_user,
      v_now + interval '26 hours', v_now + interval '31 days',
      v_now + interval '26 hours' - interval '24 hours'),
    'invalid_transaction_dates'
  );

  -- signatures from the future
  v_signed := v_now + interval '1 hour';
  perform pg_temp.x5_expect_rejection(
    format(v_lifecycle, v_signed + interval '1 second', v_user,
      '2000000900000215', v_user, v_now + interval '2 hours', v_end,
      v_signed, v_signed),
    'invalid_signed_date'
  );
  perform pg_temp.x5_expect_rejection(
    format(v_app, v_user, '2000000900000216', v_user,
      v_now + interval '2 hours', v_end, v_signed),
    'invalid_transaction_dates'
  );

  -- notification signed before the transaction it carries
  v_signed := v_start - interval '23 hours';
  perform pg_temp.x5_expect_rejection(
    format(v_lifecycle, v_signed - interval '10 minutes', v_user,
      '2000000900000217', v_user, v_start, v_end, v_signed, v_signed),
    'invalid_signed_date'
  );

  -- expiry not after purchase
  perform pg_temp.x5_expect_rejection(
    format(v_app, v_user, '2000000900000218', v_user, v_start, v_start,
      v_signed),
    'invalid_expiration_date'
  );

  -- the table constraints enforce the same window directly
  perform pg_temp.x5_expect_rejection(
    format($sql$
      insert into public.app_store_transactions (
        transaction_id, original_transaction_id, user_id, product_id,
        environment, app_account_token, purchase_date, expires_date,
        signed_date, credits_granted, is_verified_product
      ) values (
        '2000000900000219', '2000000900000200', %L::uuid,
        'com.x5studio.app.verified.monthly', 'Production', %L::uuid,
        %L::timestamptz, %L::timestamptz, %L::timestamptz, 0, true
      )
    $sql$, v_user, v_user, v_start, v_end, v_start - interval '26 hours'),
    'app_store_transactions_dates_valid'
  );
  perform pg_temp.x5_expect_rejection(
    format($sql$
      insert into public.app_store_verified_lifecycle_events (
        event_id, notification_type, notification_signed_date,
        transaction_signed_date, renewal_signed_date, environment,
        transaction_id, original_transaction_id, user_id, product_id,
        app_account_token, purchase_date, expires_date, applied,
        result_status
      ) values (
        gen_random_uuid(), 'DID_RENEW', %L::timestamptz, %L::timestamptz,
        %L::timestamptz, 'Production', '2000000900000220',
        '2000000900000200', %L::uuid, 'com.x5studio.app.verified.monthly',
        %L::uuid, %L::timestamptz, %L::timestamptz, true, 'applied'
      )
    $sql$, v_start - interval '26 hours', v_start - interval '26 hours',
      v_start - interval '26 hours', v_user, v_user, v_start, v_end),
    'app_store_verified_lifecycle_events_dates'
  );
end;
$rejections$;

-- 5. Constraints are validated and the functions keep their privileges.
do $catalog$
begin
  if exists (
    select 1 from pg_constraint
     where conname in (
             'app_store_transactions_dates_valid',
             'app_store_verified_lifecycle_events_dates'
           )
       and (
         not convalidated
         or pg_get_constraintdef(oid) not like '%25:00:00%'
       )
  ) or (
    select count(*) from pg_constraint
     where conname in (
             'app_store_transactions_dates_valid',
             'app_store_verified_lifecycle_events_dates'
           )
  ) <> 2 then
    raise exception 'renewal_date_constraints_not_replaced';
  end if;

  if exists (
    select 1 from pg_proc
     where proname in (
             'x5_apply_verified_app_store_transaction_signed_date_strict_inte',
             'x5_apply_verified_app_store_badge_lifecycle_internal'
           )
       and pronamespace = 'public'::regnamespace
       and (
         proacl::text <> '{postgres=X/postgres}'
         or not prosecdef
         or proconfig::text <> '{"search_path=\"\""}'
         or pg_get_userbyid(proowner) <> 'postgres'
       )
  ) then
    raise exception 'renewal_functions_changed_privileges';
  end if;
end;
$catalog$;

rollback;

select 'verified_renewal_early_signing_validated_with_rollback' as result;
