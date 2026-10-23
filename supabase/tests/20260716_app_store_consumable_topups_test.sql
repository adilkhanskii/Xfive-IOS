begin;

do $acl_tests$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_consumable(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_verified_app_store_consumable(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'apple_consumable_rpc_is_client_callable';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_consumable(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'apple_consumable_rpc_is_not_service_role_callable';
  end if;

  if has_table_privilege(
    'authenticated',
    'public.app_store_consumable_transactions',
    'select'
  ) or has_table_privilege(
    'authenticated',
    'public.app_store_consumable_transactions',
    'insert'
  ) or has_table_privilege(
    'anon',
    'public.app_store_consumable_transactions',
    'select'
  ) or has_table_privilege(
    'anon',
    'public.app_store_consumable_transactions',
    'insert'
  ) then
    raise exception 'apple_consumable_ledger_is_client_accessible';
  end if;

  if not has_table_privilege(
    'service_role',
    'public.app_store_consumable_transactions',
    'select'
  ) or not has_table_privilege(
    'service_role',
    'public.app_store_consumable_transactions',
    'insert'
  ) or has_table_privilege(
    'service_role',
    'public.app_store_consumable_transactions',
    'update'
  ) or has_table_privilege(
    'service_role',
    'public.app_store_consumable_transactions',
    'delete'
  ) then
    raise exception 'apple_consumable_ledger_is_not_append_only';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_class as c
      join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = 'app_store_consumable_transactions'
       and c.relrowsecurity
       and c.relforcerowsecurity
  ) then
    raise exception 'apple_consumable_ledger_rls_is_not_forced';
  end if;
end;
$acl_tests$;

select set_config(
  'x5.consumable_test_user_id',
  (select id::text from public.profiles order by id limit 1),
  true
);

select set_config(
  'x5.consumable_test_other_user_id',
  (select id::text from public.profiles order by id offset 1 limit 1),
  true
);

do $fixture_tests$
begin
  if nullif(current_setting('x5.consumable_test_user_id', true), '') is null then
    raise exception 'apple_consumable_test_user_not_found';
  end if;
  if nullif(current_setting('x5.consumable_test_other_user_id', true), '') is null then
    raise exception 'apple_consumable_second_test_user_not_found';
  end if;
end;
$fixture_tests$;

set local role service_role;

do $service_tests$
declare
  v_uid uuid := current_setting('x5.consumable_test_user_id')::uuid;
  v_other_uid uuid := current_setting('x5.consumable_test_other_user_id')::uuid;
  v_purchase_date timestamptz := now() - interval '1 minute';
  v_signed_date timestamptz := now();
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
  v_response jsonb;
  v_rejected boolean;
begin
  select * into v_before
    from public.profiles
   where id = v_uid;

  v_response := public.apply_verified_app_store_consumable(
    v_uid,
    'codex-consumable-1000-transaction',
    'codex-consumable-1000-transaction',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    v_signed_date + interval '1 second',
    null,
    1
  );

  select * into v_after
    from public.profiles
   where id = v_uid;

  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_after.credits <> coalesce(v_before.credits, 0) + 1000 then
    raise exception 'apple_consumable_initial_credit_failed:%:%:%',
      v_response, v_before.credits, v_after.credits;
  end if;

  if v_after.plan is distinct from v_before.plan
     or v_after.subscription_type is distinct from v_before.subscription_type
     or v_after.subscription_date is distinct from v_before.subscription_date
     or v_after.subscription_end_date is distinct from v_before.subscription_end_date
     or v_after.is_verified is distinct from v_before.is_verified
     or v_after.verified_until is distinct from v_before.verified_until then
    raise exception 'apple_consumable_changed_non_credit_entitlement_fields';
  end if;

  v_response := public.apply_verified_app_store_consumable(
    v_uid,
    'codex-consumable-1000-transaction',
    'codex-consumable-1000-transaction',
    'com.x5studio.app.credits.1000',
    'Production',
    v_uid,
    v_purchase_date,
    v_signed_date,
    null,
    1
  );

  select * into v_after
    from public.profiles
   where id = v_uid;

  if v_response ->> 'status' <> 'already_applied'
     or (v_response ->> 'credits_granted')::integer <> 0
     or v_after.credits <> coalesce(v_before.credits, 0) + 1000 then
    raise exception 'apple_consumable_replay_was_not_exact_once:%:%',
      v_response, v_after.credits;
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_other_uid,
      'codex-consumable-1000-transaction',
      'codex-consumable-1000-transaction',
      'com.x5studio.app.credits.1000',
      'Production',
      v_other_uid,
      v_purchase_date,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'owned_by_other' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_cross_user_replay_was_accepted';
  end if;

  perform public.apply_verified_app_store_consumable(
    v_uid,
    'codex-consumable-2000-transaction',
    'codex-consumable-2000-transaction',
    'com.x5studio.app.credits.2000',
    'Production',
    v_uid,
    v_purchase_date,
    v_signed_date,
    null,
    1
  );
  perform public.apply_verified_app_store_consumable(
    v_uid,
    'codex-consumable-5000-transaction',
    'codex-consumable-5000-transaction',
    'com.x5studio.app.credits.5000',
    'Production',
    v_uid,
    v_purchase_date,
    v_signed_date,
    null,
    1
  );

  select * into v_after
    from public.profiles
   where id = v_uid;
  if v_after.credits <> coalesce(v_before.credits, 0) + 8000 then
    raise exception 'apple_consumable_server_price_mapping_failed:%:%',
      v_before.credits, v_after.credits;
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-invalid-quantity',
      'codex-consumable-invalid-quantity',
      'com.x5studio.app.credits.1000',
      'Production',
      v_uid,
      v_purchase_date,
      v_signed_date,
      null,
      2
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'invalid_quantity' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_invalid_quantity_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-sandbox',
      'codex-consumable-sandbox',
      'com.x5studio.app.credits.1000',
      'Sandbox',
      v_uid,
      v_purchase_date,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_not_allowed' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_sandbox_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-token-mismatch',
      'codex-consumable-token-mismatch',
      'com.x5studio.app.credits.1000',
      'Production',
      v_other_uid,
      v_purchase_date,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'account_token_mismatch' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_token_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-missing-token',
      'codex-consumable-missing-token',
      'com.x5studio.app.credits.1000',
      'Production',
      null,
      v_purchase_date,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'missing_account_token' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_missing_token_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-unknown-product',
      'codex-consumable-unknown-product',
      'com.x5studio.app.credits.9999',
      'Production',
      v_uid,
      v_purchase_date,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'unknown_product' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_unknown_product_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_consumable(
      v_uid,
      'codex-consumable-revoked',
      'codex-consumable-revoked',
      'com.x5studio.app.credits.1000',
      'Production',
      v_uid,
      v_purchase_date,
      v_signed_date,
      now(),
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_revoked' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'apple_consumable_revoked_transaction_was_accepted';
  end if;
end;
$service_tests$;

reset role;
rollback;

select 'apple_consumable_credit_topups_validated_with_rollback' as status;
