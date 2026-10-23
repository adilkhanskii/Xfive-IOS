begin;

-- On a pre-migration database this fixture is rolled back with the test. Once
-- the production migration exists, IF NOT EXISTS leaves the real private
-- allowlist untouched.
create table if not exists public.app_store_legacy_bindings (
  original_transaction_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  app_account_token uuid not null,
  product_id text not null,
  legacy_credited_at timestamptz not null,
  legacy_subscription_end_date timestamptz,
  legacy_created_at timestamptz,
  bound_at timestamptz
);

select set_config(
  'x5.test_user_id',
  (
    select author_id::text
      from public.courses
     where id = '892fc2d1-f521-48a2-800f-a90eb9e1a852'::uuid
  ),
  true
);

select set_config(
  'x5.test_other_user_id',
  (
    select id::text
      from public.profiles
     where id <> current_setting('x5.test_user_id')::uuid
     order by id
     limit 1
  ),
  true
);

do $setup$
begin
  if nullif(current_setting('x5.test_user_id', true), '') is null then
    raise exception 'test_user_not_found';
  end if;

  if nullif(current_setting('x5.test_other_user_id', true), '') is null then
    raise exception 'second_test_user_not_found';
  end if;

  update public.profiles
     set plan = 'free',
         credits = 100000,
         purchased_course_ids = array[]::text[]
   where id = current_setting('x5.test_user_id')::uuid;

  if not found then
    raise exception 'test_profile_not_found';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_trigger as t
      join pg_catalog.pg_class as c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = 'profiles'
       and t.tgname = 'a_x5_protect_profile_entitlements'
       and not t.tgisinternal
  ) or exists (
    select 1
      from pg_catalog.pg_trigger as t
      join pg_catalog.pg_class as c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = 'profiles'
       and t.tgname = 'x5_protect_profile_entitlements'
       and not t.tgisinternal
  ) then
    raise exception 'profile_entitlement_trigger_order_not_hardened';
  end if;
end;
$setup$;

insert into public.courses (
  id,
  title,
  price,
  is_free,
  is_public,
  categories
) values (
  '22222222-2222-4222-8222-222222222222'::uuid,
  'Atomic purchase test',
  50000,
  false,
  true,
  '[]'::jsonb
)
on conflict (id) do update
   set title = excluded.title,
       price = excluded.price,
       is_free = excluded.is_free,
       is_public = excluded.is_public,
       categories = excluded.categories;

create temporary table x5_profile_insert_probe
on commit drop
as select * from public.profiles with no data;

create trigger a_x5_protect_profile_entitlements
before insert on x5_profile_insert_probe
for each row execute function public.x5_protect_profile_entitlements();

create function public.x5_test_assign_signup_number_20260714()
returns trigger
language plpgsql
as $$
begin
  if new.signup_number is null then
    new.signup_number := 424242;
  end if;
  return new;
end;
$$;

create trigger trg_assign_signup_number
before insert on x5_profile_insert_probe
for each row execute function public.x5_test_assign_signup_number_20260714();

grant insert, select on table x5_profile_insert_probe to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  current_setting('x5.test_user_id'),
  true
);

do $authenticated_tests$
declare
  v_profile public.profiles%rowtype;
  v_response jsonb;
begin
  insert into pg_temp.x5_profile_insert_probe (
    id,
    plan,
    credits,
    purchased_course_ids,
    purchased_lesson_ids,
    subscription_type,
    is_verified,
    credits_retention_months,
    signup_number
  ) values (
    '44444444-4444-4444-8444-444444444444'::uuid,
    'pro',
    999999,
    array['bypass-course'],
    array['bypass-lesson'],
    'max_monthly',
    true,
    999,
    999999
  )
  returning * into v_profile;

  if v_profile.credits <> 0
     or v_profile.plan <> 'free'
     or v_profile.purchased_course_ids is not null
     or v_profile.purchased_lesson_ids is not null
     or v_profile.subscription_type is not null
     or coalesce(v_profile.is_verified, false)
     or v_profile.credits_retention_months <> 1
     or v_profile.signup_number is null
     or v_profile.signup_number = 999999
     or v_profile.signup_number <> 424242 then
    raise exception 'direct_profile_entitlement_insert_was_not_sanitized';
  end if;

  update public.profiles
     set credits = 999999,
         purchased_course_ids = array['bypass'],
         plan = 'pro',
         credits_retention_months = 999,
         signup_number = 999999
   where id = auth.uid()
  returning * into v_profile;

  if v_profile.credits <> 100000
     or v_profile.plan <> 'free'
     or coalesce(cardinality(v_profile.purchased_course_ids), 0) <> 0
     or v_profile.credits_retention_months = 999
     or v_profile.signup_number = 999999 then
    raise exception 'direct_profile_entitlement_write_was_not_blocked';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.apply_verified_app_store_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz)',
    'execute'
  ) then
    raise exception 'verified_app_store_rpc_is_client_callable';
  end if;

  if has_function_privilege(
    'anon',
    'public.apply_verified_app_store_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz)',
    'execute'
  ) then
    raise exception 'verified_app_store_rpc_is_anon_callable';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.claim_iap_entitlement_v2(text,text,text,text,text,timestamptz)',
    'execute'
  ) then
    raise exception 'unverified_iap_claim_v2_is_client_callable';
  end if;

  if to_regprocedure('public.claim_iap_entitlement(text,text,text,text)') is not null
     and has_function_privilege(
       'authenticated',
       'public.claim_iap_entitlement(text,text,text,text)',
       'execute'
     ) then
    raise exception 'unverified_legacy_iap_claim_is_client_callable';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.add_credits(uuid,integer)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.deduct_credits(uuid,integer)',
    'execute'
  ) then
    raise exception 'credit_mutation_rpc_is_client_callable';
  end if;

  if has_table_privilege('authenticated', 'public.app_store_transactions', 'select')
     or has_table_privilege('authenticated', 'public.app_store_transactions', 'insert')
     or has_table_privilege('authenticated', 'public.app_store_entitlement_owners', 'select')
     or has_table_privilege('authenticated', 'public.app_store_entitlement_owners', 'insert')
     or has_table_privilege('anon', 'public.app_store_transactions', 'select')
     or has_table_privilege('anon', 'public.app_store_transactions', 'insert')
     or has_table_privilege('anon', 'public.app_store_entitlement_owners', 'select')
     or has_table_privilege('anon', 'public.app_store_entitlement_owners', 'insert') then
    raise exception 'app_store_ledger_is_client_accessible';
  end if;

  v_response := public.purchase_course(
    '22222222-2222-4222-8222-222222222222',
    40000
  );
  if v_response ->> 'status' <> 'price_changed'
     or (v_response ->> 'charged_amount')::integer <> 0 then
    raise exception 'price_change_guard_failed:%', v_response;
  end if;

  v_response := public.purchase_course(
    '22222222-2222-4222-8222-222222222222',
    50000
  );
  if v_response ->> 'status' <> 'purchased'
     or (v_response ->> 'credits_remaining')::integer <> 50000
     or (v_response ->> 'charged_amount')::integer <> 50000 then
    raise exception 'atomic_purchase_failed:%', v_response;
  end if;

  v_response := public.purchase_course(
    '22222222-2222-4222-8222-222222222222',
    50000
  );
  if v_response ->> 'status' <> 'already_owned'
     or (v_response ->> 'credits_remaining')::integer <> 50000 then
    raise exception 'idempotent_purchase_retry_failed:%', v_response;
  end if;

  if to_regprocedure('public.purchase_lesson(text,text,integer)') is not null
     and has_function_privilege(
       'authenticated',
       'public.purchase_lesson(text,text,integer)',
       'execute'
     ) then
    raise exception 'legacy_lesson_purchase_is_still_client_callable';
  end if;
end;
$authenticated_tests$;

reset role;
set local role service_role;

do $service_tests$
declare
  v_uid uuid := current_setting('x5.test_user_id')::uuid;
  v_other_uid uuid := current_setting('x5.test_other_user_id')::uuid;
  v_profile public.profiles%rowtype;
  v_response jsonb;
  v_rejected boolean;
  v_count integer;
  v_subscription_end_before timestamptz;
  v_badge_purchase_date timestamptz;
  v_badge_expires_date timestamptz;
  v_badge_signed_date timestamptz;
  v_badge_resigned_date timestamptz;
  v_verified_until_before timestamptz;
  v_legacy_purchase_date timestamptz;
  v_legacy_expires_date timestamptz;
  v_legacy_signed_date timestamptz;
  v_legacy_resigned_date timestamptz;
begin
  if not has_function_privilege(
    'service_role',
    'public.apply_verified_app_store_transaction(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz)',
    'execute'
  ) then
    raise exception 'verified_app_store_rpc_is_not_service_callable';
  end if;

  if not has_table_privilege(
    'service_role', 'public.app_store_transactions', 'select'
  ) or not has_table_privilege(
    'service_role', 'public.app_store_transactions', 'insert'
  ) or has_table_privilege(
    'service_role', 'public.app_store_transactions', 'update'
  ) or has_table_privilege(
    'service_role', 'public.app_store_transactions', 'delete'
  ) or has_table_privilege(
    'service_role', 'public.app_store_transactions', 'truncate'
  ) then
    raise exception 'app_store_transactions_is_not_append_only_for_service_role';
  end if;

  if not has_table_privilege(
    'service_role', 'public.app_store_entitlement_owners', 'select'
  ) or not has_table_privilege(
    'service_role', 'public.app_store_entitlement_owners', 'insert'
  ) or has_table_privilege(
    'service_role', 'public.app_store_entitlement_owners', 'update'
  ) or has_table_privilege(
    'service_role', 'public.app_store_entitlement_owners', 'delete'
  ) or has_table_privilege(
    'service_role', 'public.app_store_entitlement_owners', 'truncate'
  ) then
    raise exception 'app_store_entitlement_owners_is_not_append_only_for_service_role';
  end if;

  if not has_table_privilege(
    'service_role', 'public.app_store_legacy_bindings', 'select'
  ) or not has_table_privilege(
    'service_role', 'public.app_store_legacy_bindings', 'insert'
  ) or has_table_privilege(
    'service_role', 'public.app_store_legacy_bindings', 'update'
  ) or has_table_privilege(
    'service_role', 'public.app_store_legacy_bindings', 'delete'
  ) or has_table_privilege(
    'service_role', 'public.app_store_legacy_bindings', 'truncate'
  ) then
    raise exception 'app_store_legacy_bindings_is_not_append_only_for_service_role';
  end if;

  if exists (
    select 1
      from pg_catalog.pg_class as c
      join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname in (
         'app_store_transactions',
         'app_store_entitlement_owners',
         'app_store_legacy_bindings'
       )
       and pg_catalog.pg_get_userbyid(c.relowner) = 'service_role'
  ) then
    raise exception 'service_role_owns_a_production_app_store_ledger';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-sandbox-transaction',
      'codex-sandbox-original',
      'com.x5studio.app.pro.monthly',
      'Sandbox',
      v_uid,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'sandbox_not_allowed' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'sandbox_transaction_minted_production_entitlement';
  end if;

  if exists (
    select 1
      from public.app_store_transactions
     where transaction_id = 'codex-sandbox-transaction'
  ) then
    raise exception 'sandbox_transaction_reached_production_ledger';
  end if;

  -- Simulate the upgrade from the old exact-once table. Restoring the current
  -- already-credited period must backfill the new ledger without minting again.
  insert into public.iap_entitlements (
    original_transaction_id,
    user_id,
    product_id,
    platform,
    app_account_token,
    credited_at,
    credits_granted,
    subscription_end_date,
    last_transaction_id
  ) values (
    'codex-verified-original-1',
    v_uid,
    'com.x5studio.app.pro.monthly',
    'ios',
    v_uid,
    now() - interval '1 minute',
    2000,
    now() + interval '1 month',
    'codex-legacy-current-period-transaction'
  )
  on conflict (original_transaction_id) do update
     set user_id = excluded.user_id,
         product_id = excluded.product_id,
         platform = excluded.platform,
         app_account_token = excluded.app_account_token,
         credits_granted = excluded.credits_granted,
         subscription_end_date = excluded.subscription_end_date,
         last_transaction_id = excluded.last_transaction_id;

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-verified-transaction-1',
    'codex-verified-original-1',
    'com.x5studio.app.pro.monthly',
    'Production',
    v_uid,
    now() - interval '1 minute',
    now() + interval '1 month',
    now(),
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  select count(*) into v_count
    from public.app_store_transactions
   where transaction_id = 'codex-verified-transaction-1'
     and credits_granted = 0;
  if v_response ->> 'status' <> 'already_applied'
     or (v_response ->> 'credits_granted')::integer <> 0
     or v_profile.credits <> 50000
     or v_profile.plan <> 'pro' then
    raise exception 'legacy_current_period_was_double_credited:%:%',
      v_response, v_profile.credits;
  end if;
  if v_count <> 1 then
    raise exception 'legacy_current_period_was_not_backfilled_to_ledger';
  end if;

  -- A genuinely later expiry is a new renewal and must still grant its tier.
  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-verified-transaction-2',
    'codex-verified-original-1',
    'com.x5studio.app.pro.monthly',
    'Production',
    v_uid,
    now() - interval '1 minute',
    now() + interval '2 months',
    now(),
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 2000
     or v_profile.credits <> 52000 then
    raise exception 'later_renewal_was_suppressed:%:%', v_response, v_profile.credits;
  end if;

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-verified-transaction-2',
    'codex-verified-original-1',
    'com.x5studio.app.pro.monthly',
    'Production',
    v_uid,
    now() - interval '1 minute',
    now() + interval '2 months',
    now(),
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  select count(*) into v_count
    from public.app_store_transactions
   where transaction_id = 'codex-verified-transaction-2';
  if v_response ->> 'status' <> 'already_applied'
     or v_profile.credits <> 52000
     or v_count <> 1 then
    raise exception 'verified_transaction_retry_was_not_exactly_once:%:%:%',
      v_response, v_profile.credits, v_count;
  end if;

  -- Neither a globally reused transaction id nor an already-bound original
  -- transaction may be replayed onto another X5 account.
  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_other_uid,
      'codex-verified-transaction-2',
      'codex-verified-original-1',
      'com.x5studio.app.pro.monthly',
      'Production',
      v_other_uid,
      now() - interval '1 minute',
      now() + interval '2 months',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_id_conflict' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'cross_user_transaction_replay_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_other_uid,
      'codex-cross-user-original-transaction',
      'codex-verified-original-1',
      'com.x5studio.app.pro.monthly',
      'Production',
      v_other_uid,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'owned_by_other' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'cross_user_original_transaction_replay_was_accepted';
  end if;

  v_badge_purchase_date := now() - interval '1 minute';
  v_badge_expires_date := now() + interval '1 month';
  v_badge_signed_date := clock_timestamp() - interval '30 seconds';
  v_badge_resigned_date := clock_timestamp();

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-verified-badge-transaction-1',
    'codex-verified-badge-original-1',
    'com.x5studio.app.verified.monthly',
    'Production',
    v_uid,
    v_badge_purchase_date,
    v_badge_expires_date,
    v_badge_signed_date,
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 0
     or not coalesce(v_profile.is_verified, false)
     or v_profile.credits <> 52000 then
    raise exception 'verified_badge_product_mapping_failed:%:%', v_response, v_profile.credits;
  end if;

  v_verified_until_before := v_profile.verified_until;
  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-verified-badge-transaction-1',
    'codex-verified-badge-original-1',
    'com.x5studio.app.verified.monthly',
    'Production',
    v_uid,
    v_badge_purchase_date,
    v_badge_expires_date,
    v_badge_resigned_date,
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  select count(*) into v_count
    from public.app_store_transactions
   where transaction_id = 'codex-verified-badge-transaction-1';
  if v_response ->> 'status' <> 'already_applied'
     or (v_response ->> 'credits_granted')::integer <> 0
     or v_profile.credits <> 52000
     or v_profile.verified_until is distinct from v_verified_until_before
     or v_count <> 1 then
    raise exception 'verified_badge_resigned_replay_was_not_idempotent:%:%:%',
      v_response, v_profile.credits, v_count;
  end if;

  -- Re-signing changes only signedDate. Every immutable transaction/account
  -- identity field must still be rejected when the transaction id is reused.
  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-verified-badge-transaction-1',
      'codex-resigned-wrong-original',
      'com.x5studio.app.verified.monthly',
      'Production',
      v_uid,
      v_badge_purchase_date,
      v_badge_expires_date,
      v_badge_resigned_date,
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_id_conflict' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'resigned_replay_original_id_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_other_uid,
      'codex-verified-badge-transaction-1',
      'codex-verified-badge-original-1',
      'com.x5studio.app.verified.monthly',
      'Production',
      v_other_uid,
      v_badge_purchase_date,
      v_badge_expires_date,
      v_badge_resigned_date,
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_id_conflict' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'resigned_replay_user_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-verified-badge-transaction-1',
      'codex-verified-badge-original-1',
      'com.x5studio.app.pro.monthly',
      'Production',
      v_uid,
      v_badge_purchase_date,
      v_badge_expires_date,
      v_badge_resigned_date,
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_id_conflict' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'resigned_replay_product_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-verified-badge-transaction-1',
      'codex-verified-badge-original-1',
      'com.x5studio.app.verified.monthly',
      'Production',
      null,
      v_badge_purchase_date,
      v_badge_expires_date,
      v_badge_resigned_date,
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_id_conflict' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'resigned_replay_account_token_mismatch_was_accepted';
  end if;

  -- A new transaction without appAccountToken must never create an owner.
  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-missing-token-transaction',
      'codex-missing-token-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      null,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'missing_account_token' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'missing_account_token_was_accepted';
  end if;

  insert into public.iap_entitlements (
    original_transaction_id,
    user_id,
    product_id,
    platform,
    app_account_token,
    credited_at,
    credits_granted,
    subscription_end_date,
    last_transaction_id
  ) values (
    'codex-android-original',
    v_uid,
    'com.x5studio.app.lite.monthly',
    'android',
    null,
    now(),
    1000,
    now() + interval '1 month',
    'codex-android-transaction'
  )
  on conflict (original_transaction_id) do update
     set user_id = excluded.user_id,
         platform = excluded.platform,
         app_account_token = null;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-android-restore-transaction',
      'codex-android-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      null,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'missing_account_token' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'non_ios_legacy_owner_was_trusted';
  end if;

  -- A legacy owner already recorded server-side may restore without a token.
  insert into public.iap_entitlements (
    original_transaction_id,
    user_id,
    product_id,
    platform,
    app_account_token,
    credited_at,
    credits_granted,
    subscription_end_date,
    last_transaction_id
  ) values (
    'codex-legacy-original-1',
    v_uid,
    'com.x5studio.app.lite.monthly',
    'ios',
    null,
    now() - interval '2 months',
    1000,
    now() - interval '1 month',
    'codex-old-legacy-transaction'
  )
  on conflict (original_transaction_id) do update
     set user_id = excluded.user_id,
         app_account_token = null;

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-legacy-renewal-transaction',
    'codex-legacy-original-1',
    'com.x5studio.app.lite.monthly',
    'Production',
    null,
    now() - interval '1 minute',
    now() + interval '1 month',
    now(),
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied' or v_profile.credits <> 53000 then
    raise exception 'legacy_nil_token_restore_failed:%:%', v_response, v_profile.credits;
  end if;

  -- Two production subscriptions were created by the retired client-claim
  -- flow with a stable random appAccountToken. They may bind only after a
  -- genuine Apple JWS exactly matches a closed server-side allowlist.
  insert into public.iap_entitlements (
    original_transaction_id,
    user_id,
    product_id,
    platform,
    app_account_token,
    credited_at,
    credits_granted,
    subscription_end_date,
    last_transaction_id
  ) values (
    'codex-legacy-mismatched-original',
    v_uid,
    'com.x5studio.app.lite.monthly',
    'ios',
    '66666666-6666-4666-8666-666666666666'::uuid,
    now() - interval '2 months',
    1000,
    now() - interval '1 month',
    null
  )
  on conflict (original_transaction_id) do update
     set user_id = excluded.user_id,
         product_id = excluded.product_id,
         platform = excluded.platform,
         app_account_token = excluded.app_account_token,
         credited_at = excluded.credited_at,
         credits_granted = excluded.credits_granted,
         subscription_end_date = excluded.subscription_end_date,
         last_transaction_id = excluded.last_transaction_id;

  insert into public.app_store_legacy_bindings (
    original_transaction_id,
    user_id,
    app_account_token,
    product_id,
    legacy_credited_at,
    legacy_subscription_end_date,
    legacy_created_at
  )
  select
    original_transaction_id,
    user_id,
    app_account_token,
    product_id,
    credited_at,
    subscription_end_date,
    created_at
  from public.iap_entitlements
  where original_transaction_id = 'codex-legacy-mismatched-original';

  v_legacy_purchase_date := now() - interval '1 minute';
  v_legacy_expires_date := now() + interval '1 month';
  v_legacy_signed_date := clock_timestamp() - interval '30 seconds';
  v_legacy_resigned_date := clock_timestamp();

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-legacy-mismatched-renewal',
    'codex-legacy-mismatched-original',
    'com.x5studio.app.lite.monthly',
    'Production',
    '66666666-6666-4666-8666-666666666666'::uuid,
    v_legacy_purchase_date,
    v_legacy_expires_date,
    v_legacy_signed_date,
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  if v_response ->> 'status' <> 'applied'
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_profile.credits <> 54000 then
    raise exception 'exact_legacy_mismatch_binding_failed:%:%',
      v_response, v_profile.credits;
  end if;

  v_response := public.apply_verified_app_store_transaction(
    v_uid,
    'codex-legacy-mismatched-renewal',
    'codex-legacy-mismatched-original',
    'com.x5studio.app.lite.monthly',
    'Production',
    '66666666-6666-4666-8666-666666666666'::uuid,
    v_legacy_purchase_date,
    v_legacy_expires_date,
    v_legacy_resigned_date,
    null
  );

  select * into v_profile from public.profiles where id = v_uid;
  select count(*) into v_count
    from public.app_store_transactions
   where transaction_id = 'codex-legacy-mismatched-renewal';
  if v_response ->> 'status' <> 'already_applied'
     or (v_response ->> 'credits_granted')::integer <> 1000
     or v_profile.credits <> 54000
     or v_count <> 1 then
    raise exception 'legacy_resigned_replay_was_not_idempotent:%:%:%',
      v_response, v_profile.credits, v_count;
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_other_uid,
      'codex-legacy-mismatched-cross-user',
      'codex-legacy-mismatched-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      '66666666-6666-4666-8666-666666666666'::uuid,
      now() - interval '1 minute',
      now() + interval '2 months',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'owned_by_other' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'legacy_mismatch_cross_user_replay_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-account-mismatch-transaction',
      'codex-account-mismatch-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      '33333333-3333-4333-8333-333333333333'::uuid,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'account_token_mismatch' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'account_token_mismatch_was_accepted';
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-legacy-product-alias-transaction',
      'codex-legacy-product-alias-original',
      'x5_pro_monthly',
      'Production',
      v_uid,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'unknown_product' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'non_apple_product_alias_was_accepted';
  end if;

  select subscription_end_date
    into v_subscription_end_before
    from public.profiles
   where id = v_uid;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-expired-transaction',
      'codex-expired-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      v_uid,
      now() - interval '2 months',
      now() - interval '1 month',
      now(),
      null
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_expired' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'expired_transaction_was_accepted';
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.subscription_end_date is distinct from v_subscription_end_before then
    raise exception 'expired_transaction_shortened_subscription:%:%',
      v_subscription_end_before, v_profile.subscription_end_date;
  end if;

  v_rejected := false;
  begin
    perform public.apply_verified_app_store_transaction(
      v_uid,
      'codex-revoked-transaction',
      'codex-revoked-original',
      'com.x5studio.app.lite.monthly',
      'Production',
      v_uid,
      now() - interval '1 minute',
      now() + interval '1 month',
      now(),
      now()
    );
  exception when sqlstate '22023' then
    if sqlerrm <> 'transaction_revoked' then
      raise;
    end if;
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'revoked_transaction_was_accepted';
  end if;
end;
$service_tests$;

reset role;
rollback;

select 'entitlement_and_verified_app_store_ledger_validated_with_rollback' as status;
