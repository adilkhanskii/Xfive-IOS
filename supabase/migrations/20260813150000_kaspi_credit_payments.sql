begin;

create table if not exists public.kaspi_payment_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  service_name text not null default '',
  service_id text not null default '',
  account_parameter_id text not null default '',
  provider_callback_url text,
  updated_at timestamptz not null default now(),
  constraint kaspi_service_name_safe
    check (service_name = '' or service_name ~ '^[A-Za-z0-9_-]{1,100}$'),
  constraint kaspi_service_id_safe
    check (service_id = '' or service_id ~ '^[A-Za-z0-9_-]{1,100}$'),
  constraint kaspi_account_parameter_safe
    check (account_parameter_id = '' or account_parameter_id ~ '^[A-Za-z0-9_-]{1,100}$'),
  constraint kaspi_callback_https
    check (provider_callback_url is null or provider_callback_url ~ '^https://')
);

insert into public.kaspi_payment_settings (singleton, enabled)
values (true, false)
on conflict (singleton) do nothing;

create table if not exists public.kaspi_credit_payments (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references auth.users(id) on delete restrict,
  product_id text not null check (product_id in (
    'x5_credits_1000_v2', 'x5_credits_2000_v2', 'x5_credits_5000_v2'
  )),
  credits integer not null check (credits in (1000, 2000, 5000)),
  amount_kzt numeric(14,2) not null check (amount_kzt in (1000, 2000, 5000)),
  account_code text not null unique check (account_code ~ '^X5[A-F0-9]{18}$'),
  payment_url text not null check (payment_url like 'https://kaspi.kz/pay/%'),
  status text not null default 'pending' check (status in (
    'pending', 'confirmed', 'refunded', 'expired', 'cancelled'
  )),
  kaspi_txn_id text unique,
  kaspi_txn_date text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  confirmed_at timestamptz,
  credited_at timestamptz,
  refunded_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint kaspi_credit_catalog_match check (
    (product_id = 'x5_credits_1000_v2' and credits = 1000 and amount_kzt = 1000) or
    (product_id = 'x5_credits_2000_v2' and credits = 2000 and amount_kzt = 2000) or
    (product_id = 'x5_credits_5000_v2' and credits = 5000 and amount_kzt = 5000)
  )
);

create table if not exists public.kaspi_provider_transactions (
  id bigserial primary key,
  txn_id text not null unique check (txn_id ~ '^[0-9]{1,18}$'),
  payment_id uuid not null unique
    references public.kaspi_credit_payments(id) on delete restrict,
  txn_date text not null check (txn_date ~ '^[0-9]{14}$'),
  amount_kzt numeric(14,2) not null,
  created_at timestamptz not null default now()
);

create index if not exists kaspi_credit_payments_buyer_created_idx
  on public.kaspi_credit_payments (buyer_id, created_at desc);
create index if not exists kaspi_credit_payments_status_idx
  on public.kaspi_credit_payments (status, created_at desc);

alter table public.kaspi_payment_settings enable row level security;
alter table public.kaspi_payment_settings force row level security;
alter table public.kaspi_credit_payments enable row level security;
alter table public.kaspi_credit_payments force row level security;
alter table public.kaspi_provider_transactions enable row level security;
alter table public.kaspi_provider_transactions force row level security;

revoke all on table
  public.kaspi_payment_settings,
  public.kaspi_credit_payments,
  public.kaspi_provider_transactions
from public, anon, authenticated;
grant all on table
  public.kaspi_payment_settings,
  public.kaspi_credit_payments,
  public.kaspi_provider_transactions
to service_role;
grant usage, select on sequence public.kaspi_provider_transactions_id_seq
to service_role;

create or replace function public.configure_kaspi_pay_integration(
  p_service_name text,
  p_service_id text,
  p_account_parameter_id text,
  p_provider_callback_url text default null,
  p_enabled boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_service_name is null or p_service_name !~ '^[A-Za-z0-9_-]{1,100}$'
     or p_service_id is null or p_service_id !~ '^[A-Za-z0-9_-]{1,100}$'
     or p_account_parameter_id is null
     or p_account_parameter_id !~ '^[A-Za-z0-9_-]{1,100}$'
     or (p_provider_callback_url is not null
         and p_provider_callback_url !~ '^https://') then
    raise exception using errcode = '22023',
      message = 'invalid_kaspi_integration_settings';
  end if;

  insert into public.kaspi_payment_settings (
    singleton, enabled, service_name, service_id, account_parameter_id,
    provider_callback_url, updated_at
  ) values (
    true, coalesce(p_enabled, true), p_service_name, p_service_id,
    p_account_parameter_id, p_provider_callback_url, now()
  )
  on conflict (singleton) do update set
    enabled = excluded.enabled,
    service_name = excluded.service_name,
    service_id = excluded.service_id,
    account_parameter_id = excluded.account_parameter_id,
    provider_callback_url = excluded.provider_callback_url,
    updated_at = now();

  return true;
end;
$function$;

create or replace function public.create_kaspi_credit_payment(p_product_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_settings public.kaspi_payment_settings%rowtype;
  v_payment public.kaspi_credit_payments%rowtype;
  v_credits integer;
  v_amount numeric(14,2);
  v_account text;
  v_url text;
begin
  if v_uid is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception using errcode = '42501', message = 'registered_account_required';
  end if;

  select * into v_settings
  from public.kaspi_payment_settings
  where singleton = true;

  if not found or not v_settings.enabled
     or v_settings.service_name = ''
     or v_settings.service_id = ''
     or v_settings.account_parameter_id = '' then
    raise exception using errcode = '55000', message = 'kaspi_pay_not_configured';
  end if;

  select credits, price into v_credits, v_amount
  from (values
    ('x5_credits_1000_v2'::text, 1000::integer, 1000::numeric),
    ('x5_credits_2000_v2'::text, 2000::integer, 2000::numeric),
    ('x5_credits_5000_v2'::text, 5000::integer, 5000::numeric)
  ) as catalog(product_id, credits, price)
  where product_id = p_product_id;

  if v_credits is null then
    raise exception using errcode = '22023', message = 'invalid_kaspi_product';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_uid::text), hashtext(p_product_id));

  update public.kaspi_credit_payments
  set status = 'expired', updated_at = now()
  where buyer_id = v_uid and status = 'pending' and expires_at <= now();

  select * into v_payment
  from public.kaspi_credit_payments
  where buyer_id = v_uid
    and product_id = p_product_id
    and status = 'pending'
    and expires_at > now()
  order by created_at desc
  limit 1;

  if not found then
    v_account := 'X5' || upper(substr(
      replace(gen_random_uuid()::text, '-', ''), 1, 18
    ));
    v_url := 'https://kaspi.kz/pay/' || v_settings.service_name
      || '?service_id=' || v_settings.service_id
      || '&' || v_settings.account_parameter_id || '=' || v_account
      || '&amount=' || trunc(v_amount, 2)::text;

    insert into public.kaspi_credit_payments (
      buyer_id, product_id, credits, amount_kzt, account_code, payment_url
    ) values (
      v_uid, p_product_id, v_credits, v_amount, v_account, v_url
    ) returning * into v_payment;
  end if;

  return jsonb_build_object(
    'id', v_payment.id,
    'productId', v_payment.product_id,
    'credits', v_payment.credits,
    'amountKzt', v_payment.amount_kzt,
    'status', v_payment.status,
    'paymentUrl', v_payment.payment_url,
    'expiresAt', v_payment.expires_at,
    'confirmedAt', v_payment.confirmed_at
  );
end;
$function$;

create or replace function public.get_kaspi_credit_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_payment public.kaspi_credit_payments%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  update public.kaspi_credit_payments
  set status = 'expired', updated_at = now()
  where id = p_payment_id and buyer_id = v_uid
    and status = 'pending' and expires_at <= now();

  select * into v_payment
  from public.kaspi_credit_payments
  where id = p_payment_id and buyer_id = v_uid;

  if not found then
    raise exception using errcode = 'P0002', message = 'kaspi_payment_not_found';
  end if;

  return jsonb_build_object(
    'id', v_payment.id,
    'productId', v_payment.product_id,
    'credits', v_payment.credits,
    'amountKzt', v_payment.amount_kzt,
    'status', v_payment.status,
    'paymentUrl', v_payment.payment_url,
    'expiresAt', v_payment.expires_at,
    'confirmedAt', v_payment.confirmed_at
  );
end;
$function$;

create or replace function public.apply_kaspi_provider_command(
  p_command text,
  p_txn_id text,
  p_txn_date text,
  p_account text,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.kaspi_credit_payments%rowtype;
  v_existing public.kaspi_provider_transactions%rowtype;
  v_provider_id bigint;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_command is null or p_command not in ('check', 'pay')
     or p_txn_id is null or p_txn_id !~ '^[0-9]{1,18}$'
     or p_account is null or p_account !~ '^X5[A-F0-9]{18}$'
     or p_amount is null or p_amount < 0
     or (p_command = 'pay'
         and (p_txn_date is null or p_txn_date !~ '^[0-9]{14}$')) then
    return jsonb_build_object(
      'txn_id', coalesce(p_txn_id, ''), 'result', 5,
      'comment', 'Invalid request'
    );
  end if;

  if p_command = 'check' then
    select * into v_payment
    from public.kaspi_credit_payments
    where account_code = p_account;

    if not found then
      return jsonb_build_object(
        'txn_id', p_txn_id, 'result', 1, 'comment', 'Order not found'
      );
    end if;
    if v_payment.status = 'confirmed' then
      return jsonb_build_object(
        'txn_id', p_txn_id, 'result', 3, 'sum', v_payment.amount_kzt,
        'comment', 'Already paid'
      );
    end if;
    if v_payment.status <> 'pending' or v_payment.expires_at <= now() then
      update public.kaspi_credit_payments
      set status = 'expired', updated_at = now()
      where id = v_payment.id and status = 'pending';
      return jsonb_build_object(
        'txn_id', p_txn_id, 'result', 2, 'sum', v_payment.amount_kzt,
        'comment', 'Order unavailable'
      );
    end if;
    return jsonb_build_object(
      'txn_id', p_txn_id,
      'result', 0,
      'sum', v_payment.amount_kzt,
      'comment', 'OK',
      'fields', jsonb_build_object(
        'product', jsonb_build_object(
          '@name', 'Пакет X5', '#text', v_payment.credits || ' кредитов'
        )
      )
    );
  end if;

  select * into v_existing
  from public.kaspi_provider_transactions
  where txn_id = p_txn_id;
  if found then
    return jsonb_build_object(
      'txn_id', p_txn_id, 'prv_txn_id', v_existing.id,
      'result', 0, 'sum', v_existing.amount_kzt, 'comment', 'OK'
    );
  end if;

  select * into v_payment
  from public.kaspi_credit_payments
  where account_code = p_account
  for update;

  if not found then
    return jsonb_build_object(
      'txn_id', p_txn_id, 'result', 1, 'comment', 'Order not found'
    );
  end if;
  if v_payment.status = 'confirmed' then
    return jsonb_build_object(
      'txn_id', p_txn_id, 'result', 3, 'sum', v_payment.amount_kzt,
      'comment', 'Already paid'
    );
  end if;
  if v_payment.status <> 'pending' or v_payment.expires_at <= now() then
    update public.kaspi_credit_payments
    set status = 'expired', updated_at = now()
    where id = v_payment.id and status = 'pending';
    return jsonb_build_object(
      'txn_id', p_txn_id, 'result', 2, 'sum', v_payment.amount_kzt,
      'comment', 'Order unavailable'
    );
  end if;
  if round(p_amount, 2) <> v_payment.amount_kzt then
    return jsonb_build_object(
      'txn_id', p_txn_id, 'result', 5, 'sum', v_payment.amount_kzt,
      'comment', 'Amount mismatch'
    );
  end if;

  update public.profiles
  set credits = coalesce(credits, 0) + v_payment.credits
  where id = v_payment.buyer_id;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'kaspi_buyer_profile_not_found';
  end if;

  update public.kaspi_credit_payments
  set status = 'confirmed',
      kaspi_txn_id = p_txn_id,
      kaspi_txn_date = p_txn_date,
      confirmed_at = now(),
      credited_at = now(),
      updated_at = now()
  where id = v_payment.id;

  insert into public.kaspi_provider_transactions (
    txn_id, payment_id, txn_date, amount_kzt
  ) values (
    p_txn_id, v_payment.id, p_txn_date, v_payment.amount_kzt
  ) returning id into v_provider_id;

  return jsonb_build_object(
    'txn_id', p_txn_id,
    'prv_txn_id', v_provider_id,
    'result', 0,
    'sum', v_payment.amount_kzt,
    'comment', 'OK'
  );
end;
$function$;

create or replace function public.refund_kaspi_credit_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.kaspi_credit_payments%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select * into v_payment
  from public.kaspi_credit_payments
  where id = p_payment_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_payment.status = 'refunded' then
    return jsonb_build_object('ok', true, 'status', 'already_refunded');
  end if;
  if v_payment.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'error', 'not_confirmed');
  end if;

  update public.profiles
  set credits = coalesce(credits, 0) - v_payment.credits
  where id = v_payment.buyer_id;

  update public.kaspi_credit_payments
  set status = 'refunded', refunded_at = now(), updated_at = now()
  where id = v_payment.id;

  return jsonb_build_object('ok', true, 'status', 'refunded');
end;
$function$;

revoke all on function
  public.configure_kaspi_pay_integration(text, text, text, text, boolean)
from public, anon, authenticated;
revoke all on function public.create_kaspi_credit_payment(text)
from public, anon;
revoke all on function public.get_kaspi_credit_payment(uuid)
from public, anon;
revoke all on function
  public.apply_kaspi_provider_command(text, text, text, text, numeric)
from public, anon, authenticated;
revoke all on function public.refund_kaspi_credit_payment(uuid)
from public, anon, authenticated;

grant execute on function
  public.configure_kaspi_pay_integration(text, text, text, text, boolean)
to service_role;
grant execute on function public.create_kaspi_credit_payment(text)
to authenticated;
grant execute on function public.get_kaspi_credit_payment(uuid)
to authenticated;
grant execute on function
  public.apply_kaspi_provider_command(text, text, text, text, numeric)
to service_role;
grant execute on function public.refund_kaspi_credit_payment(uuid)
to service_role;

comment on function public.create_kaspi_credit_payment(text) is
  'Creates one exact-amount Kaspi order from the server-owned X5 credit catalog.';
comment on function public.apply_kaspi_provider_command(text, text, text, text, numeric) is
  'Applies official Kaspi check/pay callbacks exactly once; service role only.';

commit;
