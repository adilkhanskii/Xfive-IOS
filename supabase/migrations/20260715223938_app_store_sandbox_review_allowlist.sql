begin;

-- TestFlight and App Review purchases are signed by Apple's Sandbox. Keep
-- those free transactions isolated from every production App Store ledger and
-- permit them only for the dedicated review account.
create table public.app_store_sandbox_review_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  canonical_email text not null,
  enabled boolean not null default true,
  max_credit_balance integer not null default 10000,
  created_at timestamptz not null default now(),
  constraint app_store_sandbox_review_accounts_exact_email
    check (lower(canonical_email) = 'appreview@x5studio.app'),
  constraint app_store_sandbox_review_accounts_credit_cap
    check (max_credit_balance between 8000 and 10000)
);

-- Resolve the generated auth id at migration time. An absent account creates
-- no allowlist entry, which safely disables Sandbox grants until the dedicated
-- App Review login exists.
insert into public.app_store_sandbox_review_accounts (
  user_id,
  canonical_email,
  enabled,
  max_credit_balance
)
select
  id,
  'appreview@x5studio.app',
  true,
  10000
from auth.users
where lower(email) = 'appreview@x5studio.app'
on conflict (user_id) do update
set canonical_email = excluded.canonical_email,
    enabled = excluded.enabled,
    max_credit_balance = excluded.max_credit_balance;

create table public.app_store_sandbox_review_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  environment text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz,
  signed_date timestamptz not null,
  revocation_date timestamptz,
  quantity integer,
  credits_granted integer not null,
  is_verified_product boolean not null,
  created_at timestamptz not null default now(),
  constraint app_store_sandbox_review_transactions_transaction_nonempty
    check (btrim(transaction_id) <> ''),
  constraint app_store_sandbox_review_transactions_original_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_sandbox_review_transactions_known_product
    check (product_id in (
      'com.x5studio.app.credits.1000',
      'com.x5studio.app.credits.2000',
      'com.x5studio.app.credits.5000',
      'com.x5studio.app.verified.monthly'
    )),
  constraint app_store_sandbox_review_transactions_sandbox_environment
    check (environment = 'Sandbox'),
  constraint app_store_sandbox_review_transactions_account_matches_user
    check (app_account_token = user_id),
  constraint app_store_sandbox_review_transactions_dates_valid
    check (
      signed_date >= purchase_date - interval '5 minutes'
      and (expires_date is null or expires_date > purchase_date)
    ),
  constraint app_store_sandbox_review_transactions_not_revoked
    check (revocation_date is null),
  constraint app_store_sandbox_review_transactions_product_shape
    check (
      (
        product_id = 'com.x5studio.app.credits.1000'
        and expires_date is null
        and quantity = 1
        and credits_granted = 1000
        and not is_verified_product
      )
      or (
        product_id = 'com.x5studio.app.credits.2000'
        and expires_date is null
        and quantity = 1
        and credits_granted = 2000
        and not is_verified_product
      )
      or (
        product_id = 'com.x5studio.app.credits.5000'
        and expires_date is null
        and quantity = 1
        and credits_granted = 5000
        and not is_verified_product
      )
      or (
        product_id = 'com.x5studio.app.verified.monthly'
        and expires_date is not null
        and quantity is null
        and credits_granted = 0
        and is_verified_product
      )
    )
);

create index app_store_sandbox_review_transactions_user_id_idx
  on public.app_store_sandbox_review_transactions (user_id, purchase_date desc);

alter table public.app_store_sandbox_review_accounts enable row level security;
alter table public.app_store_sandbox_review_accounts force row level security;
alter table public.app_store_sandbox_review_transactions enable row level security;
alter table public.app_store_sandbox_review_transactions force row level security;

revoke all privileges on table public.app_store_sandbox_review_accounts
  from public, anon, authenticated;
revoke all privileges on table public.app_store_sandbox_review_transactions
  from public, anon, authenticated;
revoke all privileges on table public.app_store_sandbox_review_accounts
  from service_role;
revoke all privileges on table public.app_store_sandbox_review_transactions
  from service_role;
grant select on table public.app_store_sandbox_review_accounts to service_role;
grant select, insert on table public.app_store_sandbox_review_transactions
  to service_role;

create or replace function public.apply_verified_app_store_sandbox_review_transaction(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
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
  v_is_verified_product boolean;
  v_max_credit_balance integer;
  v_current_credits integer;
  v_existing public.app_store_sandbox_review_transactions%rowtype;
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
  if v_environment <> 'Sandbox' then
    raise exception using errcode = '22023', message = 'sandbox_review_environment_required';
  end if;

  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'account_token_mismatch';
  end if;

  v_credits := case v_product_id
    when 'com.x5studio.app.credits.1000' then 1000
    when 'com.x5studio.app.credits.2000' then 2000
    when 'com.x5studio.app.credits.5000' then 5000
    when 'com.x5studio.app.verified.monthly' then 0
    else null
  end;
  if v_credits is null then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  v_is_verified_product :=
    v_product_id = 'com.x5studio.app.verified.monthly';

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

  if v_is_verified_product then
    if p_quantity is not null then
      raise exception using errcode = '22023', message = 'invalid_quantity';
    end if;
    if p_expires_date is null or p_expires_date <= p_purchase_date then
      raise exception using errcode = '22023', message = 'invalid_expiration_date';
    end if;
    if p_expires_date <= clock_timestamp() then
      raise exception using errcode = '22023', message = 'transaction_expired';
    end if;
  else
    if p_quantity is distinct from 1 then
      raise exception using errcode = '22023', message = 'invalid_quantity';
    end if;
    if p_expires_date is not null then
      raise exception using errcode = '22023', message = 'invalid_expiration_date';
    end if;
  end if;

  -- The row exists only for the canonical App Review auth account. Rechecking
  -- auth.users prevents a renamed/recycled login from retaining access.
  select review.max_credit_balance
    into v_max_credit_balance
    from public.app_store_sandbox_review_accounts as review
    join auth.users as account on account.id = review.user_id
   where review.user_id = p_user_id
     and review.enabled
     and lower(account.email) = 'appreview@x5studio.app'
   for update of review;
  if not found then
    raise exception using errcode = '22023', message = 'sandbox_review_account_not_allowed';
  end if;

  select coalesce(profile.credits, 0)
    into v_current_credits
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-sandbox-review:' || v_transaction_id,
      0
    )
  );

  select *
    into v_existing
    from public.app_store_sandbox_review_transactions
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
       or v_existing.expires_date is distinct from p_expires_date
       or v_existing.quantity is distinct from p_quantity then
      raise exception using errcode = '22023', message = 'transaction_id_conflict';
    end if;

    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', v_existing.expires_date,
      'is_verified', v_existing.is_verified_product
    );
  end if;

  if not v_is_verified_product
     and v_current_credits + v_credits > v_max_credit_balance then
    raise exception using errcode = '22023', message = 'sandbox_review_credit_cap_exceeded';
  end if;

  insert into public.app_store_sandbox_review_transactions (
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
    quantity,
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
    p_quantity,
    v_credits,
    v_is_verified_product
  );

  if v_is_verified_product then
    -- Deliberately leave plan and every subscription field unchanged.
    update public.profiles
       set is_verified = true,
           verified_until = greatest(
             coalesce(verified_until, '-infinity'::timestamptz),
             p_expires_date
           )
     where id = p_user_id;
  else
    -- Sandbox can only raise the dedicated review account to its hard cap.
    update public.profiles
       set credits = v_current_credits + v_credits
     where id = p_user_id;
  end if;

  return jsonb_build_object(
    'status', 'applied',
    'credits_granted', v_credits,
    'subscription_end_date', p_expires_date,
    'is_verified', v_is_verified_product
  );
end;
$function$;

comment on table public.app_store_sandbox_review_accounts is
  'Private exact allowlist for the dedicated App Store review auth account.';
comment on table public.app_store_sandbox_review_transactions is
  'Private exact-once ledger for Apple-verified Sandbox transactions used during App Review.';
comment on function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) is
  'Applies an Apple-verified Sandbox credit pack or verified subscription only for the dedicated App Review account. Service role only.';

revoke execute on function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated;

grant execute on function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) to service_role;

commit;
