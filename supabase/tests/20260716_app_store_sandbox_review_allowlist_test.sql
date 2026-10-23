begin;

do $acl_tests$
begin
  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_sandbox_review_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.apply_verified_app_store_sandbox_review_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'sandbox_review_rpc_is_client_callable';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_sandbox_review_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,integer)',
    'execute'
  ) then
    raise exception 'sandbox_review_rpc_is_not_service_role_callable';
  end if;

  if has_table_privilege(
    'authenticated',
    'public.app_store_sandbox_review_accounts',
    'select'
  ) or has_table_privilege(
    'authenticated',
    'public.app_store_sandbox_review_transactions',
    'select'
  ) or has_table_privilege(
    'anon',
    'public.app_store_sandbox_review_accounts',
    'select'
  ) or has_table_privilege(
    'anon',
    'public.app_store_sandbox_review_transactions',
    'select'
  ) then
    raise exception 'sandbox_review_tables_are_client_accessible';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_class as c
      join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in (
         'app_store_sandbox_review_accounts',
         'app_store_sandbox_review_transactions'
       )
       and c.relrowsecurity
       and c.relforcerowsecurity
     having count(*) = 2
  ) then
    raise exception 'sandbox_review_tables_do_not_force_rls';
  end if;
end;
$acl_tests$;

select set_config(
  'x5.sandbox_review_user_id',
  (
    select id::text
      from auth.users
     where lower(email) = 'appreview@x5studio.app'
     limit 1
  ),
  true
);

select set_config(
  'x5.sandbox_review_other_user_id',
  (
    select profile.id::text
      from public.profiles as profile
     where profile.id <>
       nullif(current_setting('x5.sandbox_review_user_id', true), '')::uuid
     order by profile.id
     limit 1
  ),
  true
);

do $fixture_tests$
begin
  if nullif(current_setting('x5.sandbox_review_user_id', true), '') is null then
    raise exception 'dedicated_app_review_auth_user_not_found';
  end if;
  if nullif(current_setting('x5.sandbox_review_other_user_id', true), '') is null then
    raise exception 'sandbox_review_second_test_user_not_found';
  end if;
  if not exists (
    select 1
      from public.app_store_sandbox_review_accounts
     where user_id = current_setting('x5.sandbox_review_user_id')::uuid
       and enabled
       and max_credit_balance = 10000
  ) then
    raise exception 'dedicated_app_review_user_is_not_exactly_allowlisted';
  end if;
  if (
    select count(*)
      from public.app_store_sandbox_review_accounts
     where enabled
  ) <> 1 then
    raise exception 'sandbox_review_allowlist_is_not_exact';
  end if;
end;
$fixture_tests$;

-- All fixture writes and purchase grants are rolled back below.
update public.profiles
   set credits = 0,
       is_verified = false,
       verified_until = null
 where id = current_setting('x5.sandbox_review_user_id')::uuid;

set local role service_role;

do $service_tests$
declare
  v_uid uuid := current_setting('x5.sandbox_review_user_id')::uuid;
  v_other_uid uuid := current_setting('x5.sandbox_review_other_user_id')::uuid;
  v_purchase_date timestamptz := now() - interval '1 minute';
  v_signed_date timestamptz := now();
  v_expires_date timestamptz := now() + interval '30 minutes';
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
  v_response jsonb;
  v_rejected boolean;
begin
  select * into v_before
    from public.profiles
   where id = v_uid;

  v_response := public.apply_verified_app_store_sandbox_review_transaction(
    v_uid,
    'codex-sandbox-review-credits-1000',
    'codex-sandbox-review-credits-1000',
    'com.x5studio.app.credits.1000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    null,
    v_signed_date + interval '1 second',
    null,
    1
  );

  select * into v_after from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_after.credits <> 1000 then
    raise exception 'sandbox_review_initial_credit_failed:%:%',
      v_response, v_after.credits;
  end if;

  v_response := public.apply_verified_app_store_sandbox_review_transaction(
    v_uid,
    'codex-sandbox-review-credits-1000',
    'codex-sandbox-review-credits-1000',
    'com.x5studio.app.credits.1000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    null,
    v_signed_date,
    null,
    1
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'already_applied'
     or (v_response ->> 'credits_granted')::integer <> 0
     or v_after.credits <> 1000 then
    raise exception 'sandbox_review_replay_was_not_exact_once:%:%',
      v_response, v_after.credits;
  end if;

  perform public.apply_verified_app_store_sandbox_review_transaction(
    v_uid,
    'codex-sandbox-review-credits-2000',
    'codex-sandbox-review-credits-2000',
    'com.x5studio.app.credits.2000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    null,
    v_signed_date,
    null,
    1
  );
  perform public.apply_verified_app_store_sandbox_review_transaction(
    v_uid,
    'codex-sandbox-review-credits-5000',
    'codex-sandbox-review-credits-5000',
    'com.x5studio.app.credits.5000',
    'Sandbox',
    v_uid,
    v_purchase_date,
    null,
    v_signed_date,
    null,
    1
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_after.credits <> 8000 then
    raise exception 'sandbox_review_pack_mapping_failed:%', v_after.credits;
  end if;

  v_response := public.apply_verified_app_store_sandbox_review_transaction(
    v_uid,
    'codex-sandbox-review-verified',
    'codex-sandbox-review-verified-original',
    'com.x5studio.app.verified.monthly',
    'Sandbox',
    v_uid,
    v_purchase_date,
    v_expires_date,
    v_signed_date,
    null,
    null
  );
  select * into v_after from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or not (v_response ->> 'is_verified')::boolean
     or not v_after.is_verified
     or v_after.verified_until <> v_expires_date then
    raise exception 'sandbox_review_verified_subscription_failed:%:%:%',
      v_response, v_after.is_verified, v_after.verified_until;
  end if;

  -- Both product classes must leave all plan/subscription fields untouched.
  if v_after.plan is distinct from v_before.plan
     or v_after.subscription_type is distinct from v_before.subscription_type
     or v_after.subscription_date is distinct from v_before.subscription_date
     or v_after.subscription_end_date is distinct from v_before.subscription_end_date then
    raise exception 'sandbox_review_changed_plan_or_subscription_fields';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      v_uid,
      'codex-sandbox-review-over-cap',
      'codex-sandbox-review-over-cap',
      'com.x5studio.app.credits.5000',
      'Sandbox',
      v_uid,
      v_purchase_date,
      null,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_review_credit_cap_exceeded' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'sandbox_review_credit_cap_was_not_enforced';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      v_other_uid,
      'codex-sandbox-review-non-allowlisted',
      'codex-sandbox-review-non-allowlisted',
      'com.x5studio.app.credits.1000',
      'Sandbox',
      v_other_uid,
      v_purchase_date,
      null,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_review_account_not_allowed' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'non_allowlisted_sandbox_user_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      v_uid,
      'codex-sandbox-review-token-mismatch',
      'codex-sandbox-review-token-mismatch',
      'com.x5studio.app.credits.1000',
      'Sandbox',
      v_other_uid,
      v_purchase_date,
      null,
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
    raise exception 'sandbox_review_token_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      v_uid,
      'codex-sandbox-review-production',
      'codex-sandbox-review-production',
      'com.x5studio.app.credits.1000',
      'Production',
      v_uid,
      v_purchase_date,
      null,
      v_signed_date,
      null,
      1
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_review_environment_required' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'production_transaction_entered_sandbox_review_ledger';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_sandbox_review_transaction(
      v_uid,
      'codex-sandbox-review-legacy-plan',
      'codex-sandbox-review-legacy-plan',
      'com.x5studio.app.pro.monthly',
      'Sandbox',
      v_uid,
      v_purchase_date,
      v_expires_date,
      v_signed_date,
      null,
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'unknown_product' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'legacy_plan_product_entered_sandbox_review_ledger';
  end if;
end;
$service_tests$;

reset role;
rollback;

select 'app_store_sandbox_review_allowlist_validated_with_rollback' as status;
