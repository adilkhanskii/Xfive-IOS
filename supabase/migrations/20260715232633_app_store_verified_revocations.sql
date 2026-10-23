begin;

-- Apple returns a newly signed view of the original subscription transaction
-- when a refund or Family Sharing revocation occurs. Keep that event separate
-- from the immutable purchase ledger and reconcile only verified-badge state.
create table public.app_store_verified_revocations (
  environment text not null,
  transaction_id text not null,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz not null,
  signed_date timestamptz not null,
  revocation_date timestamptz not null,
  credits_granted integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (environment, transaction_id),
  constraint app_store_verified_revocations_environment
    check (environment in ('Production', 'Sandbox')),
  constraint app_store_verified_revocations_transaction_nonempty
    check (btrim(transaction_id) <> ''),
  constraint app_store_verified_revocations_original_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_verified_revocations_exact_product
    check (product_id = 'com.x5studio.app.verified.monthly'),
  constraint app_store_verified_revocations_account_matches_user
    check (app_account_token = user_id),
  constraint app_store_verified_revocations_dates_valid
    check (
      expires_date > purchase_date
      and signed_date >= purchase_date - interval '5 minutes'
      and revocation_date >= purchase_date
      and signed_date >= revocation_date - interval '5 minutes'
    ),
  constraint app_store_verified_revocations_credit_neutral
    check (credits_granted = 0)
);

create index app_store_verified_revocations_user_id_idx
  on public.app_store_verified_revocations (user_id, revocation_date desc);

alter table public.app_store_verified_revocations owner to postgres;
alter table public.app_store_verified_revocations enable row level security;
alter table public.app_store_verified_revocations force row level security;

-- This ledger is reachable only through the narrow postgres-owned RPC below.
-- Even service_role receives no direct UPDATE/DELETE (or direct table access).
revoke all privileges on table public.app_store_verified_revocations
  from public, anon, authenticated;
revoke all privileges on table public.app_store_verified_revocations
  from service_role;

create or replace function public.apply_verified_app_store_verified_revocation(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
  p_signed_date timestamptz,
  p_revocation_date timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text := nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_now timestamptz := clock_timestamp();
  v_existing public.app_store_verified_revocations%rowtype;
  v_production_source public.app_store_transactions%rowtype;
  v_sandbox_source public.app_store_sandbox_review_transactions%rowtype;
  v_owner public.app_store_entitlement_owners%rowtype;
  v_verified_until timestamptz;
  v_already_applied boolean := false;
begin
  if p_user_id is null then
    raise exception using errcode = '22023', message = 'invalid_user_id';
  end if;
  if v_transaction_id is null or length(v_transaction_id) > 255 then
    raise exception using errcode = '22023', message = 'invalid_transaction_id';
  end if;
  if v_original_transaction_id is null
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023', message = 'invalid_original_transaction_id';
  end if;
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  if v_product_id is null
     or v_product_id <> 'com.x5studio.app.verified.monthly' then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'account_token_mismatch';
  end if;
  if p_purchase_date is null
     or p_expires_date is null
     or p_signed_date is null
     or p_revocation_date is null then
    raise exception using errcode = '22023', message = 'missing_transaction_dates';
  end if;
  if p_expires_date <= p_purchase_date then
    raise exception using errcode = '22023', message = 'invalid_expiration_date';
  end if;
  if p_purchase_date > v_now + interval '10 minutes'
     or p_signed_date > v_now + interval '10 minutes'
     or p_revocation_date > v_now + interval '10 minutes'
     or p_signed_date < p_purchase_date - interval '5 minutes'
     or p_revocation_date < p_purchase_date
     or p_signed_date < p_revocation_date - interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid_revocation_date';
  end if;

  -- Match the purchase paths' lock order. It serializes reconciliation with
  -- a concurrent Apple or Android entitlement update for this same profile.
  perform 1
    from public.profiles
   where id = p_user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  if v_environment = 'Production' then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'app-store-transaction:' || v_transaction_id,
        0
      )
    );

    select *
      into v_production_source
      from public.app_store_transactions
     where transaction_id = v_transaction_id;

    if not found then
      raise exception using errcode = '22023', message = 'revocation_source_not_found';
    end if;
    if v_production_source.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_production_source.original_transaction_id <> v_original_transaction_id
       or v_production_source.product_id <> v_product_id
       or v_production_source.environment <> v_environment
       or v_production_source.app_account_token is distinct from p_app_account_token
       or v_production_source.purchase_date <> p_purchase_date
       or v_production_source.expires_date <> p_expires_date
       or v_production_source.revocation_date is not null
       or v_production_source.credits_granted <> 0
       or not v_production_source.is_verified_product then
      raise exception using errcode = '22023', message = 'revocation_source_mismatch';
    end if;

    select *
      into v_owner
      from public.app_store_entitlement_owners
     where original_transaction_id = v_original_transaction_id;

    if not found then
      raise exception using errcode = '22023', message = 'revocation_source_mismatch';
    end if;
    if v_owner.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_owner.app_account_token is distinct from p_app_account_token then
      raise exception using errcode = '22023', message = 'revocation_source_mismatch';
    end if;
  else
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'app-store-sandbox-review:' || v_transaction_id,
        0
      )
    );

    select *
      into v_sandbox_source
      from public.app_store_sandbox_review_transactions
     where transaction_id = v_transaction_id;

    if not found then
      raise exception using errcode = '22023', message = 'revocation_source_not_found';
    end if;
    if v_sandbox_source.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_sandbox_source.original_transaction_id <> v_original_transaction_id
       or v_sandbox_source.product_id <> v_product_id
       or v_sandbox_source.environment <> v_environment
       or v_sandbox_source.app_account_token <> p_app_account_token
       or v_sandbox_source.purchase_date <> p_purchase_date
       or v_sandbox_source.expires_date is distinct from p_expires_date
       or v_sandbox_source.revocation_date is not null
       or v_sandbox_source.quantity is not null
       or v_sandbox_source.credits_granted <> 0
       or not v_sandbox_source.is_verified_product then
      raise exception using errcode = '22023', message = 'revocation_source_mismatch';
    end if;
  end if;

  select *
    into v_existing
    from public.app_store_verified_revocations
   where environment = v_environment
     and transaction_id = v_transaction_id
   for update;

  if found then
    if v_existing.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_existing.original_transaction_id <> v_original_transaction_id
       or v_existing.product_id <> v_product_id
       or v_existing.app_account_token <> p_app_account_token
       or v_existing.purchase_date <> p_purchase_date
       or v_existing.expires_date <> p_expires_date
       or v_existing.revocation_date <> p_revocation_date then
      raise exception using errcode = '22023', message = 'revocation_id_conflict';
    end if;
    -- Apple may re-sign the exact same revocation. Keep the first signed_date
    -- immutable and treat a later valid JWS as an idempotent replay.
    v_already_applied := true;
  else
    insert into public.app_store_verified_revocations (
      environment,
      transaction_id,
      original_transaction_id,
      user_id,
      product_id,
      app_account_token,
      purchase_date,
      expires_date,
      signed_date,
      revocation_date,
      credits_granted
    ) values (
      v_environment,
      v_transaction_id,
      v_original_transaction_id,
      p_user_id,
      v_product_id,
      p_app_account_token,
      p_purchase_date,
      p_expires_date,
      p_signed_date,
      p_revocation_date,
      0
    );
  end if;

  -- Rebuild the verified badge from authoritative active sources. Revoking one
  -- Apple period must not erase another active Apple period, an unmigrated
  -- legacy iOS period, or the same user's active Google Play verification.
  select max(active_entitlement.expires_date)
    into v_verified_until
    from (
      select production.expires_date
        from public.app_store_transactions as production
       where production.user_id = p_user_id
         and production.product_id = 'com.x5studio.app.verified.monthly'
         and production.is_verified_product
         and production.credits_granted = 0
         and production.expires_date > v_now
         and not exists (
           select 1
             from public.app_store_verified_revocations as revoked
            where revoked.environment = 'Production'
              and revoked.transaction_id = production.transaction_id
         )
      union all
      select sandbox.expires_date
        from public.app_store_sandbox_review_transactions as sandbox
       where sandbox.user_id = p_user_id
         and sandbox.product_id = 'com.x5studio.app.verified.monthly'
         and sandbox.is_verified_product
         and sandbox.credits_granted = 0
         and sandbox.expires_date > v_now
         and not exists (
           select 1
             from public.app_store_verified_revocations as revoked
            where revoked.environment = 'Sandbox'
              and revoked.transaction_id = sandbox.transaction_id
         )
      union all
      select android.subscription_end_date as expires_date
        from public.iap_entitlements as android
       where android.user_id = p_user_id
         and lower(coalesce(android.platform, '')) = 'android'
         and android.product_id in (
           'x5_verified_monthly_v2',
           'x5_verified_monthly'
         )
         and android.subscription_end_date > v_now
      union all
      select legacy_ios.subscription_end_date as expires_date
        from public.iap_entitlements as legacy_ios
       where legacy_ios.user_id = p_user_id
         and lower(coalesce(legacy_ios.platform, '')) = 'ios'
         and legacy_ios.product_id in (
           'com.x5studio.app.verified.monthly',
           'x5_verified_monthly'
         )
         and legacy_ios.subscription_end_date > v_now
         and not exists (
           select 1
             from public.app_store_transactions as migrated
            where migrated.original_transaction_id =
              legacy_ios.original_transaction_id
              and migrated.user_id = legacy_ios.user_id
              and migrated.product_id =
                'com.x5studio.app.verified.monthly'
         )
    ) as active_entitlement;

  update public.profiles
     set is_verified = v_verified_until is not null,
         verified_until = v_verified_until
   where id = p_user_id;

  if v_already_applied then
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;

  return jsonb_build_object(
    'status', 'applied',
    'credits_granted', 0,
    'subscription_end_date', v_verified_until,
    'is_verified', v_verified_until is not null
  );
end;
$function$;

comment on table public.app_store_verified_revocations is
  'Immutable Apple-signed revocations for verified-monthly purchases. Credit-neutral and private.';
comment on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) is
  'Records an owner-bound Apple verified-monthly revocation and rebuilds verification from active Apple and Android sources. Service role only.';

alter function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) owner to postgres;

revoke execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

grant execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

commit;
