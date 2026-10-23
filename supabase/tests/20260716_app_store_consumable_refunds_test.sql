begin;

do $acl_tests$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_consumable_refund(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_verified_app_store_consumable_refund(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'consumable_refund_rpc_is_client_callable';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_consumable_refund(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'consumable_refund_rpc_is_not_service_callable';
  end if;

  if has_table_privilege(
    'service_role', 'public.app_store_consumable_refunds', 'select'
  ) or has_table_privilege(
    'service_role', 'public.app_store_consumable_refunds', 'insert'
  ) or has_table_privilege(
    'authenticated', 'public.app_store_consumable_refunds', 'select'
  ) or has_table_privilege(
    'anon', 'public.app_store_consumable_refunds', 'select'
  ) then
    raise exception 'consumable_refund_ledger_is_not_private';
  end if;
end;
$acl_tests$;

select set_config(
  'x5.consumable_refund_user_id',
  (select id::text from public.profiles order by id limit 1),
  true
);
select set_config(
  'x5.consumable_refund_other_user_id',
  (select id::text from public.profiles order by id offset 1 limit 1),
  true
);
select set_config(
  'x5.consumable_refund_sandbox_user_id',
  (
    select review.user_id::text
      from public.app_store_sandbox_review_accounts as review
      join auth.users as account on account.id = review.user_id
     where review.enabled
       and lower(account.email) = 'appreview@x5studio.app'
     limit 1
  ),
  true
);

do $fixture_tests$
declare
  v_uid uuid := nullif(
    current_setting('x5.consumable_refund_user_id', true), ''
  )::uuid;
  v_purchase_date timestamptz := now() - interval '10 minutes';
begin
  if v_uid is null then
    raise exception 'consumable_refund_test_user_not_found';
  end if;
  if nullif(
    current_setting('x5.consumable_refund_other_user_id', true), ''
  ) is null then
    raise exception 'consumable_refund_other_user_not_found';
  end if;
  if nullif(
    current_setting('x5.consumable_refund_sandbox_user_id', true), ''
  ) is null then
    raise exception 'consumable_refund_sandbox_user_not_found';
  end if;

  update public.profiles set credits = 100 where id = v_uid;

  insert into public.app_store_consumable_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, signed_date,
    revocation_date, quantity, credits_granted
  ) values (
    'codex-production-consumable-refund',
    'codex-production-consumable-refund',
    v_uid,
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    v_purchase_date + interval '1 minute',
    null,
    1,
    1000
  );

  insert into public.app_store_sandbox_review_transactions (
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, expires_date,
    signed_date, revocation_date, quantity, credits_granted,
    is_verified_product
  ) values (
    'codex-sandbox-consumable-refund',
    'codex-sandbox-consumable-refund',
    v_uid,
    'com.x5studio.app.credits.2000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    null,
    v_purchase_date + interval '1 minute',
    null,
    1,
    2000,
    false
  );
end;
$fixture_tests$;

set local role service_role;

do $service_tests$
declare
  v_uid uuid := current_setting('x5.consumable_refund_user_id')::uuid;
  v_other_uid uuid := current_setting('x5.consumable_refund_other_user_id')::uuid;
  v_sandbox_uid uuid :=
    current_setting('x5.consumable_refund_sandbox_user_id')::uuid;
  v_purchase_date timestamptz;
  v_revocation_date timestamptz := now() - interval '1 minute';
  v_response jsonb;
  v_credits integer;
  v_credits_before integer;
  v_rejected boolean;
begin
  select purchase_date
    into v_purchase_date
    from public.app_store_consumable_transactions
   where transaction_id = 'codex-production-consumable-refund';

  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid,
    'codex-production-consumable-refund',
    'codex-production-consumable-refund',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    now(),
    v_revocation_date,
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> -900 then
    raise exception 'production_consumable_refund_failed:%:%',
      v_response, v_credits;
  end if;
  if v_credits >= 0 then
    raise exception 'consumable_refund_did_not_create_debt:%', v_credits;
  end if;

  if exists (
    select 1 from public.spend_generation_credits(v_uid, 1)
  ) then
    raise exception 'consumable_refund_debt_was_reused';
  end if;

  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid,
    'codex-production-consumable-refund',
    'codex-production-consumable-refund',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    now() + interval '1 second',
    v_revocation_date,
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'already_applied' or v_credits <> -900 then
    raise exception 'consumable_refund_replay_was_not_exact_once:%:%',
      v_response, v_credits;
  end if;

  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid,
    'codex-sandbox-consumable-refund',
    'codex-sandbox-consumable-refund',
    'com.x5studio.app.credits.2000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    now(),
    v_revocation_date,
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_credits <> -2900 then
    raise exception 'sandbox_consumable_refund_failed:%:%',
      v_response, v_credits;
  end if;

  -- Apple can deliver the refund JWS before StoreKit replays the purchase JWS.
  -- The legacy migration suppresses the grant entirely. The later canonical
  -- notification migration may instead record the immutable purchase and
  -- apply an equal pending hold; both paths must grant zero net credits.
  select credits into v_credits_before
    from public.profiles where id = v_uid;
  v_response := public.apply_verified_app_store_consumable_refund(
    v_uid,
    'codex-production-refund-before-grant',
    'codex-production-refund-before-grant',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    now(),
    v_revocation_date,
    1
  );
  if v_response ->> 'status' <> 'applied' then
    raise exception 'production_refund_before_grant_tombstone_failed:%',
      v_response;
  end if;
  v_response := public.apply_verified_app_store_consumable(
    v_uid,
    'codex-production-refund-before-grant',
    'codex-production-refund-before-grant',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    v_purchase_date + interval '1 minute',
    null,
    1
  );
  select credits into v_credits from public.profiles where id = v_uid;
  if v_response ->> 'status' not in ('already_applied', 'applied')
     or v_response ->> 'credits_granted' <> '0'
     or v_credits <> v_credits_before
     or (
       (v_response ->> 'status' = 'already_applied') = exists (
         select 1 from public.app_store_consumable_transactions
          where transaction_id = 'codex-production-refund-before-grant'
       )
     ) then
    raise exception 'production_refund_before_grant_was_credited:%:%:%',
      v_response, v_credits_before, v_credits;
  end if;

  select credits into v_credits_before
    from public.profiles where id = v_sandbox_uid;
  v_response := public.apply_verified_app_store_consumable_refund(
    v_sandbox_uid,
    'codex-sandbox-refund-before-grant',
    'codex-sandbox-refund-before-grant',
    'com.x5studio.app.credits.2000',
    'Sandbox',
    v_sandbox_uid,
    v_purchase_date,
    now(),
    v_revocation_date,
    1
  );
  if v_response ->> 'status' <> 'applied' then
    raise exception 'sandbox_refund_before_grant_tombstone_failed:%',
      v_response;
  end if;
  v_response := public.apply_verified_app_store_sandbox_review_transaction(
    v_sandbox_uid,
    'codex-sandbox-refund-before-grant',
    'codex-sandbox-refund-before-grant',
    'com.x5studio.app.credits.2000',
    'Sandbox',
    v_sandbox_uid,
    v_purchase_date,
    null,
    v_purchase_date + interval '1 minute',
    null,
    1
  );
  select credits into v_credits
    from public.profiles where id = v_sandbox_uid;
  if v_response ->> 'status' not in ('already_applied', 'applied')
     or v_response ->> 'credits_granted' <> '0'
     or v_credits <> v_credits_before
     or (
       (v_response ->> 'status' = 'already_applied') = exists (
         select 1 from public.app_store_sandbox_review_transactions
          where transaction_id = 'codex-sandbox-refund-before-grant'
       )
     ) then
    raise exception 'sandbox_refund_before_grant_was_credited:%:%:%',
      v_response, v_credits_before, v_credits;
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-production-refund-before-grant',
      'codex-production-refund-before-grant',
      'com.x5studio.app.credits.2000',
      'Production',
      v_uid,
      v_purchase_date,
      v_purchase_date + interval '1 minute',
      null,
      1
    );
  exception when sqlstate '22023' then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'refund_before_grant_identity_conflict_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_other_uid,
      'codex-production-refund-before-grant',
      'codex-production-refund-before-grant',
      'com.x5studio.app.credits.1000',
      'Production',
      v_other_uid,
      v_purchase_date,
      v_purchase_date + interval '1 minute',
      null,
      1
    );
  exception when sqlstate '22023' then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'refund_before_grant_cross_account_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable_refund(
      v_uid,
      'codex-production-consumable-refund',
      'codex-production-consumable-refund',
      'com.x5studio.app.credits.2000',
      'Production',
      v_uid,
      v_purchase_date,
      now(),
      v_revocation_date,
      1
    );
  exception when sqlstate '22023' then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'consumable_refund_identity_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable_refund(
      v_other_uid,
      'codex-production-consumable-refund',
      'codex-production-consumable-refund',
      'com.x5studio.app.credits.1000',
      'Production',
      v_other_uid,
      v_purchase_date,
      now(),
      v_revocation_date,
      1
    );
  exception when sqlstate '22023' then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'consumable_refund_cross_account_was_accepted';
  end if;
end;
$service_tests$;

reset role;
rollback;

select 'app_store_consumable_refunds_validated_with_rollback' as status;
