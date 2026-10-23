-- Record only App Store transactions whose JWS has already been verified by
-- the trusted Edge Function. The client cannot read or write either table and
-- cannot execute the credit-granting RPC.

begin;

-- 20260714154000 was already applied to production before these two INSERT
-- fields were added. Repeat the complete trigger definition in this new
-- migration so both upgraded and freshly replayed databases receive the fix.
create or replace function public.x5_protect_profile_entitlements()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.plan := 'free';
    new.credits := 0;
    new.purchased_course_ids := null;
    new.purchased_lesson_ids := null;
    new.subscription_type := null;
    new.subscription_date := null;
    new.subscription_end_date := null;
    new.is_verified := false;
    new.verified_until := null;
    new.purchase_history := null;
    new.credits_expires_at := null;
    new.credits_retention_months := 1;
    new.signup_number := null;
  else
    new.plan := old.plan;
    new.credits := old.credits;
    new.purchased_course_ids := old.purchased_course_ids;
    new.purchased_lesson_ids := old.purchased_lesson_ids;
    new.subscription_type := old.subscription_type;
    new.subscription_date := old.subscription_date;
    new.subscription_end_date := old.subscription_end_date;
    new.is_verified := old.is_verified;
    new.verified_until := old.verified_until;
    new.purchase_history := old.purchase_history;
    new.credits_expires_at := old.credits_expires_at;
    new.credits_retention_months := old.credits_retention_months;
    new.signup_number := old.signup_number;
  end if;

  return new;
end;
$$;

-- Clear an untrusted client number before the existing
-- trg_assign_signup_number trigger assigns its server sequence value.
drop trigger if exists x5_protect_profile_entitlements on public.profiles;
drop trigger if exists a_x5_protect_profile_entitlements on public.profiles;
create trigger a_x5_protect_profile_entitlements
before insert or update on public.profiles
for each row execute function public.x5_protect_profile_entitlements();

revoke execute on function public.x5_protect_profile_entitlements()
  from public, anon, authenticated;

create table if not exists public.app_store_entitlement_owners (
  original_transaction_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  app_account_token uuid,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint app_store_entitlement_owners_original_id_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_entitlement_owners_account_matches_user
    check (app_account_token is null or app_account_token = user_id),
  constraint app_store_entitlement_owners_original_user_unique
    unique (original_transaction_id, user_id)
);

create table if not exists public.app_store_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  environment text not null,
  app_account_token uuid,
  purchase_date timestamptz not null,
  expires_date timestamptz not null,
  signed_date timestamptz not null,
  revocation_date timestamptz,
  credits_granted integer not null default 0,
  is_verified_product boolean not null default false,
  created_at timestamptz not null default now(),
  constraint app_store_transactions_owner_fk
    foreign key (original_transaction_id, user_id)
    references public.app_store_entitlement_owners (original_transaction_id, user_id)
    on delete restrict,
  constraint app_store_transactions_transaction_id_nonempty
    check (btrim(transaction_id) <> ''),
  constraint app_store_transactions_original_id_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_transactions_known_product
    check (product_id in (
      'com.x5studio.app.lite.monthly',
      'com.x5studio.app.pro.monthly',
      'com.x5studio.app.max.monthly',
      'com.x5studio.app.verified.monthly'
    )),
  constraint app_store_transactions_known_environment
    check (environment in ('Sandbox', 'Production')),
  constraint app_store_transactions_account_matches_user
    check (app_account_token is null or app_account_token = user_id),
  constraint app_store_transactions_dates_valid
    check (expires_date > purchase_date and signed_date >= purchase_date - interval '5 minutes'),
  constraint app_store_transactions_not_revoked
    check (revocation_date is null),
  constraint app_store_transactions_credits_nonnegative
    check (credits_granted >= 0)
);

create index if not exists app_store_transactions_original_id_idx
  on public.app_store_transactions (original_transaction_id, purchase_date desc);
create index if not exists app_store_transactions_user_id_idx
  on public.app_store_transactions (user_id, purchase_date desc);

alter table public.app_store_entitlement_owners enable row level security;
alter table public.app_store_entitlement_owners force row level security;
alter table public.app_store_transactions enable row level security;
alter table public.app_store_transactions force row level security;

revoke all privileges on table public.app_store_entitlement_owners
  from public, anon, authenticated;
revoke all privileges on table public.app_store_transactions
  from public, anon, authenticated;
grant select, insert, update, delete on table public.app_store_entitlement_owners
  to service_role;
grant select, insert, update, delete on table public.app_store_transactions
  to service_role;

-- A StoreKit 1 purchase can lack appAccountToken. Preserve only legacy owner
-- bindings already recorded by the server; malformed/mismatched old rows are
-- deliberately not trusted.
insert into public.app_store_entitlement_owners (
  original_transaction_id,
  user_id,
  app_account_token,
  first_seen_at,
  last_seen_at
)
select
  btrim(i.original_transaction_id),
  i.user_id,
  i.app_account_token,
  coalesce(i.credited_at, now()),
  now()
from public.iap_entitlements as i
where nullif(btrim(i.original_transaction_id), '') is not null
  and i.user_id is not null
  and lower(coalesce(i.platform, '')) = 'ios'
  and (i.app_account_token is null or i.app_account_token = i.user_id)
on conflict (original_transaction_id) do nothing;

create or replace function public.apply_verified_app_store_transaction(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
  p_signed_date timestamptz,
  p_revocation_date timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text := nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text;
  v_credits integer;
  v_subscription_type text;
  v_is_verified_product boolean;
  v_existing public.app_store_transactions%rowtype;
  v_owner public.app_store_entitlement_owners%rowtype;
  v_legacy public.iap_entitlements%rowtype;
  v_has_legacy boolean := false;
  v_already_credited_legacy boolean := false;
  v_credits_to_grant integer;
  v_inserted_transaction_id text;
begin
  if p_user_id is null then
    raise exception using errcode = '22023', message = 'invalid_user_id';
  end if;

  perform 1
    from public.profiles
   where id = p_user_id
   for update;

  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  if v_transaction_id is null
     or v_original_transaction_id is null
     or length(v_transaction_id) > 255
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023', message = 'invalid_transaction_id';
  end if;

  v_environment := case lower(btrim(coalesce(p_environment, '')))
    when 'sandbox' then 'Sandbox'
    when 'production' then 'Production'
    else null
  end;

  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;

  v_credits := case v_product_id
    when 'com.x5studio.app.lite.monthly' then 1000
    when 'com.x5studio.app.pro.monthly' then 2000
    when 'com.x5studio.app.max.monthly' then 5000
    when 'com.x5studio.app.verified.monthly' then 0
    else null
  end;

  v_subscription_type := case v_product_id
    when 'com.x5studio.app.lite.monthly' then 'lite_monthly'
    when 'com.x5studio.app.pro.monthly' then 'pro_monthly'
    when 'com.x5studio.app.max.monthly' then 'max_monthly'
    else null
  end;

  v_is_verified_product := v_product_id = 'com.x5studio.app.verified.monthly';

  if v_credits is null then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;

  if p_revocation_date is not null then
    raise exception using errcode = '22023', message = 'transaction_revoked';
  end if;

  if p_purchase_date is null or p_expires_date is null or p_signed_date is null then
    raise exception using errcode = '22023', message = 'missing_transaction_dates';
  end if;

  if p_expires_date <= p_purchase_date then
    raise exception using errcode = '22023', message = 'invalid_expiration_date';
  end if;

  if p_expires_date <= clock_timestamp() then
    raise exception using errcode = '22023', message = 'transaction_expired';
  end if;

  if p_signed_date < p_purchase_date - interval '5 minutes'
     or p_signed_date > clock_timestamp() + interval '10 minutes'
     or p_purchase_date > clock_timestamp() + interval '10 minutes' then
    raise exception using errcode = '22023', message = 'invalid_transaction_dates';
  end if;

  if p_app_account_token is not null and p_app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'account_token_mismatch';
  end if;

  -- Serialize retries for the globally unique transaction id. The owner table's
  -- primary key separately serializes two transaction ids for one subscription.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('app-store-transaction:' || v_transaction_id, 0)
  );

  select *
    into v_existing
    from public.app_store_transactions
   where transaction_id = v_transaction_id
   for update;

  if found then
    if v_existing.user_id <> p_user_id
       or v_existing.original_transaction_id <> v_original_transaction_id
       or v_existing.product_id <> v_product_id
       or v_existing.environment <> v_environment
       or v_existing.app_account_token is distinct from p_app_account_token
       or v_existing.purchase_date <> p_purchase_date
       or v_existing.expires_date <> p_expires_date
       or v_existing.signed_date <> p_signed_date then
      raise exception using errcode = '22023', message = 'transaction_id_conflict';
    end if;

    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', v_existing.credits_granted,
      'subscription_end_date', v_existing.expires_date,
      'is_verified', v_existing.is_verified_product
    );
  end if;

  select *
    into v_legacy
    from public.iap_entitlements as i
   where i.original_transaction_id = v_original_transaction_id
     and lower(coalesce(i.platform, '')) = 'ios'
     and (i.app_account_token is null or i.app_account_token = i.user_id)
   for update;
  v_has_legacy := found;

  if p_app_account_token is null then
    -- Nil tokens are accepted only for an already-bound legacy transaction.
    if not v_has_legacy then
      raise exception using errcode = '22023', message = 'missing_account_token';
    end if;

    if v_legacy.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
  end if;

  insert into public.app_store_entitlement_owners (
    original_transaction_id,
    user_id,
    app_account_token,
    first_seen_at,
    last_seen_at
  ) values (
    v_original_transaction_id,
    p_user_id,
    p_app_account_token,
    now(),
    now()
  )
  on conflict (original_transaction_id) do nothing;

  select *
    into v_owner
    from public.app_store_entitlement_owners
   where original_transaction_id = v_original_transaction_id
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'entitlement_owner_missing';
  end if;

  if v_owner.user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  if v_owner.app_account_token is not null
     and v_owner.app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  -- Before this ledger existed, iap_entitlements was the exact-once record.
  -- Migrating a currently credited StoreKit period must create a ledger row but
  -- must not grant those credits again. A meaningfully later expiry remains a
  -- new renewal and is credited below.
  v_already_credited_legacy := v_has_legacy
    and v_legacy.user_id = p_user_id
    and (
      nullif(btrim(v_legacy.last_transaction_id), '') = v_transaction_id
      or (
        v_legacy.subscription_end_date is not null
        and v_legacy.subscription_end_date >= p_expires_date - interval '60 seconds'
      )
    );
  v_credits_to_grant := case
    when v_already_credited_legacy then 0
    else v_credits
  end;

  update public.app_store_entitlement_owners
     set app_account_token = coalesce(app_account_token, p_app_account_token),
         last_seen_at = now()
   where original_transaction_id = v_original_transaction_id;

  insert into public.app_store_transactions (
    transaction_id,
    original_transaction_id,
    user_id,
    product_id,
    environment,
    app_account_token,
    purchase_date,
    expires_date,
    signed_date,
    revocation_date,
    credits_granted,
    is_verified_product
  ) values (
    v_transaction_id,
    v_original_transaction_id,
    p_user_id,
    v_product_id,
    v_environment,
    p_app_account_token,
    p_purchase_date,
    p_expires_date,
    p_signed_date,
    null,
    v_credits_to_grant,
    v_is_verified_product
  )
  on conflict (transaction_id) do nothing
  returning transaction_id into v_inserted_transaction_id;

  if v_inserted_transaction_id is null then
    -- Defensive fallback for a hash collision or a concurrent retry.
    select *
      into v_existing
      from public.app_store_transactions
     where transaction_id = v_transaction_id;

    if not found
       or v_existing.user_id <> p_user_id
       or v_existing.original_transaction_id <> v_original_transaction_id
       or v_existing.product_id <> v_product_id
       or v_existing.environment <> v_environment
       or v_existing.app_account_token is distinct from p_app_account_token
       or v_existing.purchase_date <> p_purchase_date
       or v_existing.expires_date <> p_expires_date
       or v_existing.signed_date <> p_signed_date then
      raise exception using errcode = '22023', message = 'transaction_id_conflict';
    end if;

    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', v_existing.credits_granted,
      'subscription_end_date', v_existing.expires_date,
      'is_verified', v_existing.is_verified_product
    );
  end if;

  if v_is_verified_product then
    update public.profiles
       set is_verified = true,
           verified_until = greatest(
             coalesce(verified_until, '-infinity'::timestamptz),
             p_expires_date
           )
     where id = p_user_id;
  else
    update public.profiles
       set credits = coalesce(credits, 0) + v_credits_to_grant,
           plan = 'pro',
           subscription_type = v_subscription_type,
           subscription_date = coalesce(subscription_date, p_purchase_date),
           subscription_end_date = greatest(
             coalesce(subscription_end_date, '-infinity'::timestamptz),
             p_expires_date
           )
     where id = p_user_id;
  end if;

  -- Keep the legacy owner/period row in sync for diagnostics and for the
  -- narrowly allowed nil-token restore path. The new transaction ledger remains
  -- the authoritative per-transaction exact-once record.
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
    v_original_transaction_id,
    p_user_id,
    v_product_id,
    'ios',
    p_app_account_token,
    now(),
    v_credits_to_grant,
    p_expires_date,
    v_transaction_id
  )
  on conflict (original_transaction_id) do update
     set product_id = excluded.product_id,
         platform = 'ios',
         app_account_token = coalesce(
           public.iap_entitlements.app_account_token,
           excluded.app_account_token
         ),
         credited_at = case
           when v_credits_to_grant > 0 then now()
           else public.iap_entitlements.credited_at
         end,
         credits_granted = coalesce(public.iap_entitlements.credits_granted, 0)
                           + v_credits_to_grant,
         subscription_end_date = greatest(
           coalesce(public.iap_entitlements.subscription_end_date, '-infinity'::timestamptz),
           excluded.subscription_end_date
         ),
         last_transaction_id = excluded.last_transaction_id
   where public.iap_entitlements.user_id = excluded.user_id
     and lower(coalesce(public.iap_entitlements.platform, '')) = 'ios'
     and (
       public.iap_entitlements.app_account_token is null
       or public.iap_entitlements.app_account_token = public.iap_entitlements.user_id
     );

  return jsonb_build_object(
    'status', case when v_already_credited_legacy then 'already_applied' else 'applied' end,
    'credits_granted', v_credits_to_grant,
    'subscription_end_date', p_expires_date,
    'is_verified', v_is_verified_product
  );
end;
$$;

comment on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid, timestamptz, timestamptz, timestamptz, timestamptz
) is
  'Applies one server-verified App Store JWS transaction exactly once. Service role only.';

revoke execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid, timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid, timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

commit;
