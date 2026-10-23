begin;

-- Consumable purchases have no subscription chain or expiry. Keep their
-- exact-once ledger separate from the renewable App Store transaction ledger.
create table public.app_store_consumable_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  environment text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  signed_date timestamptz not null,
  revocation_date timestamptz,
  quantity integer not null,
  credits_granted integer not null,
  created_at timestamptz not null default now(),
  constraint app_store_consumable_transactions_transaction_id_nonempty
    check (btrim(transaction_id) <> ''),
  constraint app_store_consumable_transactions_original_id_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_consumable_transactions_known_product
    check (product_id in (
      'com.x5studio.app.credits.1000',
      'com.x5studio.app.credits.2000',
      'com.x5studio.app.credits.5000'
    )),
  constraint app_store_consumable_transactions_production_environment
    check (environment = 'Production'),
  constraint app_store_consumable_transactions_account_matches_user
    check (app_account_token = user_id),
  constraint app_store_consumable_transactions_quantity_one
    check (quantity = 1),
  constraint app_store_consumable_transactions_dates_valid
    check (signed_date >= purchase_date - interval '5 minutes'),
  constraint app_store_consumable_transactions_not_revoked
    check (revocation_date is null),
  constraint app_store_consumable_transactions_server_price
    check (
      (product_id = 'com.x5studio.app.credits.1000' and credits_granted = 1000)
      or (product_id = 'com.x5studio.app.credits.2000' and credits_granted = 2000)
      or (product_id = 'com.x5studio.app.credits.5000' and credits_granted = 5000)
    )
);

create index app_store_consumable_transactions_user_id_idx
  on public.app_store_consumable_transactions (user_id, purchase_date desc);

alter table public.app_store_consumable_transactions enable row level security;
alter table public.app_store_consumable_transactions force row level security;

revoke all privileges on table public.app_store_consumable_transactions
  from public, anon, authenticated;
revoke all privileges on table public.app_store_consumable_transactions
  from service_role;
grant select, insert
  on table public.app_store_consumable_transactions
  to service_role;

create or replace function public.apply_verified_app_store_consumable(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_quantity integer
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
    when 'sandbox' then 'Sandbox'
    when 'production' then 'Production'
    else null
  end;
  v_credits integer;
  v_existing public.app_store_consumable_transactions%rowtype;
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
  if v_environment <> 'Production' then
    raise exception using errcode = '22023', message = 'sandbox_not_allowed';
  end if;

  v_credits := case v_product_id
    when 'com.x5studio.app.credits.1000' then 1000
    when 'com.x5studio.app.credits.2000' then 2000
    when 'com.x5studio.app.credits.5000' then 5000
    else null
  end;
  if v_credits is null then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;

  if p_quantity is distinct from 1 then
    raise exception using errcode = '22023', message = 'invalid_quantity';
  end if;
  if p_revocation_date is not null then
    raise exception using errcode = '22023', message = 'transaction_revoked';
  end if;
  if p_purchase_date is null or p_signed_date is null then
    raise exception using errcode = '22023', message = 'missing_transaction_dates';
  end if;
  if p_signed_date < p_purchase_date - interval '5 minutes'
     or p_signed_date > clock_timestamp() + interval '10 minutes'
     or p_purchase_date > clock_timestamp() + interval '10 minutes' then
    raise exception using errcode = '22023', message = 'invalid_transaction_dates';
  end if;

  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'account_token_mismatch';
  end if;

  perform 1
    from public.profiles
   where id = p_user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-consumable:' || v_transaction_id,
      0
    )
  );

  select *
    into v_existing
    from public.app_store_consumable_transactions
   where transaction_id = v_transaction_id
   for update;

  if found then
    if v_existing.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_existing.original_transaction_id <> v_original_transaction_id
       or v_existing.product_id <> v_product_id
       or v_existing.environment <> v_environment
       or v_existing.app_account_token <> p_app_account_token
       or v_existing.purchase_date <> p_purchase_date
       or v_existing.quantity <> p_quantity then
      raise exception using errcode = '22023', message = 'transaction_id_conflict';
    end if;

    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', null,
      'is_verified', false
    );
  end if;

  insert into public.app_store_consumable_transactions (
    transaction_id,
    original_transaction_id,
    user_id,
    product_id,
    environment,
    app_account_token,
    purchase_date,
    signed_date,
    revocation_date,
    quantity,
    credits_granted
  ) values (
    v_transaction_id,
    v_original_transaction_id,
    p_user_id,
    v_product_id,
    v_environment,
    p_app_account_token,
    p_purchase_date,
    p_signed_date,
    null,
    p_quantity,
    v_credits
  );

  -- Deliberately touch only the shared balance. Existing profile triggers keep
  -- the configured retention policy; plan, subscription, and verification stay
  -- exactly as they were.
  update public.profiles
     set credits = coalesce(credits, 0) + v_credits
   where id = p_user_id;

  return jsonb_build_object(
    'status', 'applied',
    'credits_granted', v_credits,
    'subscription_end_date', null,
    'is_verified', false
  );
end;
$function$;

comment on table public.app_store_consumable_transactions is
  'Private exact-once ledger for server-verified App Store consumables. Each transaction is permanently bound to one account.';

comment on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) is
  'Credits one production App Store consumable exactly once using a server-side product-to-credit mapping. Service role only.';

revoke execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated;

grant execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) to service_role;

commit;
