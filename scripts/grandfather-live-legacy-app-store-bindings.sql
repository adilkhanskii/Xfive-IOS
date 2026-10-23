begin;

do $validation$
declare
  v_candidate_count integer;
  v_user_count integer;
  v_token_count integer;
  v_product_count integer;
  v_existing_bindings integer;
  v_existing_owners integer;
begin
  select
    count(*),
    count(distinct i.user_id),
    count(distinct coalesce(
      i.legacy_app_account_token,
      i.app_account_token
    )),
    count(distinct i.product_id)
  into
    v_candidate_count,
    v_user_count,
    v_token_count,
    v_product_count
  from public.iap_entitlements as i
  where lower(coalesce(i.platform, '')) = 'ios'
    and coalesce(i.legacy_app_account_token, i.app_account_token) is not null
    and coalesce(i.legacy_app_account_token, i.app_account_token) <> i.user_id
    and i.credited_at is not null
    and i.last_transaction_id is null
    and i.created_at >= '2026-06-20T13:28:00Z'::timestamptz
    and i.created_at < '2026-06-20T13:29:00Z'::timestamptz
    and i.subscription_end_date >= '2026-07-20T13:28:00Z'::timestamptz
    and i.subscription_end_date < '2026-07-20T13:29:00Z'::timestamptz
    and i.product_id in (
      'com.x5studio.app.pro.monthly',
      'com.x5studio.app.verified.monthly'
    )
    and not exists (
      select 1
        from auth.users as candidate_token_owner
       where candidate_token_owner.id = coalesce(
         i.legacy_app_account_token,
         i.app_account_token
       )
    );

  if v_candidate_count <> 2
     or v_user_count <> 1
     or v_token_count <> 2
     or v_product_count <> 2 then
    raise exception
      'legacy_binding_candidate_shape_changed:rows=%,users=%,tokens=%,products=%',
      v_candidate_count, v_user_count, v_token_count, v_product_count;
  end if;

  select count(*)
    into v_existing_bindings
    from public.app_store_legacy_bindings;

  select count(*)
    into v_existing_owners
    from public.app_store_entitlement_owners as owner
    join public.iap_entitlements as i
      on i.original_transaction_id = owner.original_transaction_id
   where lower(coalesce(i.platform, '')) = 'ios'
     and coalesce(i.legacy_app_account_token, i.app_account_token) is not null
     and coalesce(i.legacy_app_account_token, i.app_account_token) <> i.user_id
     and i.created_at >= '2026-06-20T13:28:00Z'::timestamptz
     and i.created_at < '2026-06-20T13:29:00Z'::timestamptz;

  if v_existing_bindings = 0 and v_existing_owners <> 0 then
    raise exception 'legacy_binding_owner_preexists:%', v_existing_owners;
  end if;
end;
$validation$;

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
  i.original_transaction_id,
  i.user_id,
  coalesce(i.legacy_app_account_token, i.app_account_token),
  i.product_id,
  i.credited_at,
  i.subscription_end_date,
  i.created_at
from public.iap_entitlements as i
where lower(coalesce(i.platform, '')) = 'ios'
  and coalesce(i.legacy_app_account_token, i.app_account_token) is not null
  and coalesce(i.legacy_app_account_token, i.app_account_token) <> i.user_id
  and i.credited_at is not null
  and i.last_transaction_id is null
  and i.created_at >= '2026-06-20T13:28:00Z'::timestamptz
  and i.created_at < '2026-06-20T13:29:00Z'::timestamptz
  and i.subscription_end_date >= '2026-07-20T13:28:00Z'::timestamptz
  and i.subscription_end_date < '2026-07-20T13:29:00Z'::timestamptz
  and i.product_id in (
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.verified.monthly'
  )
on conflict (original_transaction_id) do update
set user_id = excluded.user_id,
    app_account_token = excluded.app_account_token,
    product_id = excluded.product_id,
    legacy_credited_at = excluded.legacy_credited_at,
    legacy_subscription_end_date = excluded.legacy_subscription_end_date,
    legacy_created_at = excluded.legacy_created_at
where public.app_store_legacy_bindings.user_id = excluded.user_id
  and public.app_store_legacy_bindings.app_account_token = excluded.app_account_token
  and public.app_store_legacy_bindings.product_id = excluded.product_id;

do $postcondition$
declare
  v_count integer;
begin
  select count(*) into v_count
    from public.app_store_legacy_bindings;
  if v_count <> 2 then
    raise exception 'legacy_binding_allowlist_not_exact:%', v_count;
  end if;
end;
$postcondition$;

commit;

select
  count(*) as exact_legacy_bindings,
  count(*) filter (where bound_at is not null) as bound_by_verified_jws
from public.app_store_legacy_bindings;
