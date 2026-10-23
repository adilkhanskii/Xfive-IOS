begin;

-- Kaspi has still not issued the provider identifiers that would confirm a
-- payment automatically, so x5marketing.com currently cannot take money at all.
-- This adds the route that works today: the buyer transfers the exact amount to
-- the merchant's own Kaspi account with a unique reference code, marks it paid,
-- and an X5 developer confirms it. Credits are granted exactly once, inside the
-- same transaction that closes the order.
--
-- It is deliberately a separate table from kaspi_credit_payments: the provider
-- flow already works end to end and must keep its NOT NULL payment_url and its
-- idempotent callback untouched. When Kaspi answers, both routes coexist and
-- the manual one can simply be switched off.

alter table public.kaspi_payment_settings
  add column if not exists manual_enabled boolean not null default false,
  add column if not exists recipient_name text not null default '',
  add column if not exists recipient_phone text not null default '',
  add column if not exists recipient_iban text not null default '';

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'kaspi_recipient_phone_safe'
  ) then
    alter table public.kaspi_payment_settings
      add constraint kaspi_recipient_phone_safe
      check (recipient_phone = '' or recipient_phone ~ '^\+?[0-9 ()-]{6,32}$');
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'kaspi_recipient_iban_safe'
  ) then
    alter table public.kaspi_payment_settings
      add constraint kaspi_recipient_iban_safe
      check (recipient_iban = '' or recipient_iban ~ '^[A-Z]{2}[0-9A-Z]{10,32}$');
  end if;
end;
$constraints$;

create table if not exists public.kaspi_manual_payments (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references auth.users(id) on delete restrict,
  product_id text not null check (product_id in (
    'x5_credits_1000_v2', 'x5_credits_2000_v2', 'x5_credits_5000_v2'
  )),
  credits integer not null check (credits in (1000, 2000, 5000)),
  amount_kzt numeric(14,2) not null check (amount_kzt in (1000, 2000, 5000)),
  payment_code text not null unique check (payment_code ~ '^X5-[A-F0-9]{10}$'),
  status text not null default 'created' check (status in (
    'created', 'awaiting_review', 'confirmed', 'rejected', 'expired', 'cancelled'
  )),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  review_note text check (review_note is null or char_length(review_note) <= 500),
  credited_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint kaspi_manual_catalog_match check (
    (product_id = 'x5_credits_1000_v2' and credits = 1000 and amount_kzt = 1000) or
    (product_id = 'x5_credits_2000_v2' and credits = 2000 and amount_kzt = 2000) or
    (product_id = 'x5_credits_5000_v2' and credits = 5000 and amount_kzt = 5000)
  )
);

create index if not exists kaspi_manual_payments_buyer_idx
  on public.kaspi_manual_payments (buyer_id, created_at desc);
create index if not exists kaspi_manual_payments_review_idx
  on public.kaspi_manual_payments (status, submitted_at)
  where status = 'awaiting_review';

alter table public.kaspi_manual_payments enable row level security;
alter table public.kaspi_manual_payments force row level security;
revoke all on table public.kaspi_manual_payments from public, anon, authenticated;
grant all on table public.kaspi_manual_payments to service_role;

-- Opens (or reuses) an order. Amount and credits come from the server catalog,
-- never from the caller.
create or replace function public.create_kaspi_manual_payment(p_product_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_settings public.kaspi_payment_settings%rowtype;
  v_payment public.kaspi_manual_payments%rowtype;
  v_credits integer;
  v_amount numeric(14,2);
  v_code text;
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

  if not found or not v_settings.manual_enabled or v_settings.recipient_phone = '' then
    raise exception using errcode = '55000', message = 'kaspi_manual_not_configured';
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

  update public.kaspi_manual_payments
  set status = 'expired', updated_at = now()
  where buyer_id = v_uid
    and status in ('created', 'awaiting_review')
    and expires_at <= now();

  select * into v_payment
  from public.kaspi_manual_payments
  where buyer_id = v_uid
    and product_id = p_product_id
    and status in ('created', 'awaiting_review')
    and expires_at > now()
  order by created_at desc
  limit 1;

  if not found then
    v_code := 'X5-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    insert into public.kaspi_manual_payments (
      buyer_id, product_id, credits, amount_kzt, payment_code
    ) values (
      v_uid, p_product_id, v_credits, v_amount, v_code
    ) returning * into v_payment;
  end if;

  return jsonb_build_object(
    'id', v_payment.id,
    'productId', v_payment.product_id,
    'credits', v_payment.credits,
    'amountKzt', v_payment.amount_kzt,
    'paymentCode', v_payment.payment_code,
    'status', v_payment.status,
    'expiresAt', v_payment.expires_at,
    'recipientName', v_settings.recipient_name,
    'recipientPhone', v_settings.recipient_phone,
    'recipientIban', nullif(v_settings.recipient_iban, '')
  );
end;
$function$;

create or replace function public.get_kaspi_manual_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_settings public.kaspi_payment_settings%rowtype;
  v_payment public.kaspi_manual_payments%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select * into v_payment
  from public.kaspi_manual_payments
  where id = p_payment_id and buyer_id = v_uid;

  if not found then
    raise exception using errcode = '22023', message = 'payment_not_found';
  end if;

  if v_payment.status in ('created', 'awaiting_review')
     and v_payment.expires_at <= now() then
    update public.kaspi_manual_payments
    set status = 'expired', updated_at = now()
    where id = v_payment.id
    returning * into v_payment;
  end if;

  select * into v_settings
  from public.kaspi_payment_settings
  where singleton = true;

  return jsonb_build_object(
    'id', v_payment.id,
    'productId', v_payment.product_id,
    'credits', v_payment.credits,
    'amountKzt', v_payment.amount_kzt,
    'paymentCode', v_payment.payment_code,
    'status', v_payment.status,
    'expiresAt', v_payment.expires_at,
    'reviewNote', v_payment.review_note,
    'recipientName', coalesce(v_settings.recipient_name, ''),
    'recipientPhone', coalesce(v_settings.recipient_phone, ''),
    'recipientIban', nullif(coalesce(v_settings.recipient_iban, ''), '')
  );
end;
$function$;

-- The buyer states they transferred the money. This only queues the order for
-- review; it never grants anything.
create or replace function public.submit_kaspi_manual_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_payment public.kaspi_manual_payments%rowtype;
begin
  if v_uid is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select * into v_payment
  from public.kaspi_manual_payments
  where id = p_payment_id and buyer_id = v_uid
  for update;

  if not found then
    raise exception using errcode = '22023', message = 'payment_not_found';
  end if;

  if v_payment.status = 'awaiting_review' then
    return jsonb_build_object('id', v_payment.id, 'status', v_payment.status);
  end if;

  if v_payment.status <> 'created' or v_payment.expires_at <= now() then
    raise exception using errcode = '55000', message = 'payment_not_submittable';
  end if;

  update public.kaspi_manual_payments
  set status = 'awaiting_review',
      submitted_at = now(),
      updated_at = now()
  where id = v_payment.id
  returning * into v_payment;

  return jsonb_build_object('id', v_payment.id, 'status', v_payment.status);
end;
$function$;

-- Review queue for the two X5 developer accounts.
create or replace function public.list_kaspi_manual_payments(p_status text default 'awaiting_review')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rows jsonb;
begin
  if not public.is_x5_developer() then
    raise exception using errcode = '42501', message = 'developer_only';
  end if;
  if p_status not in ('awaiting_review', 'confirmed', 'rejected', 'expired', 'created') then
    raise exception using errcode = '22023', message = 'invalid_status';
  end if;

  select coalesce(jsonb_agg(row_to_json(entry)::jsonb order by entry.created_at desc), '[]'::jsonb)
  into v_rows
  from (
    select p.id,
           p.payment_code as "paymentCode",
           p.product_id as "productId",
           p.credits,
           p.amount_kzt as "amountKzt",
           p.status,
           p.created_at,
           p.submitted_at as "submittedAt",
           coalesce(pr.nickname, pr.name, '') as "buyerName",
           p.buyer_id as "buyerId"
    from public.kaspi_manual_payments as p
    left join public.profiles as pr on pr.id = p.buyer_id
    where p.status = p_status
    order by p.created_at desc
    limit 200
  ) as entry;

  return v_rows;
end;
$function$;

-- Confirms or rejects one order. Credits are granted inside the same statement
-- that moves the order out of awaiting_review, so a double click, a retry or two
-- reviewers acting at once cannot grant twice.
create or replace function public.review_kaspi_manual_payment(
  p_payment_id uuid,
  p_approve boolean,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_payment public.kaspi_manual_payments%rowtype;
  v_credits integer;
begin
  if not public.is_x5_developer() then
    raise exception using errcode = '42501', message = 'developer_only';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception using errcode = '22023', message = 'note_too_long';
  end if;

  select * into v_payment
  from public.kaspi_manual_payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception using errcode = '22023', message = 'payment_not_found';
  end if;

  if v_payment.status in ('confirmed', 'rejected') then
    return jsonb_build_object(
      'id', v_payment.id,
      'status', v_payment.status,
      'creditsGranted', 0,
      'alreadyReviewed', true
    );
  end if;

  if v_payment.status <> 'awaiting_review' then
    raise exception using errcode = '55000', message = 'payment_not_reviewable';
  end if;

  if not p_approve then
    update public.kaspi_manual_payments
    set status = 'rejected',
        reviewed_at = now(),
        reviewed_by = v_uid,
        review_note = p_note,
        updated_at = now()
    where id = v_payment.id
    returning * into v_payment;

    return jsonb_build_object(
      'id', v_payment.id,
      'status', v_payment.status,
      'creditsGranted', 0,
      'alreadyReviewed', false
    );
  end if;

  update public.kaspi_manual_payments
  set status = 'confirmed',
      reviewed_at = now(),
      reviewed_by = v_uid,
      review_note = p_note,
      credited_at = now(),
      updated_at = now()
  where id = v_payment.id and status = 'awaiting_review'
  returning credits into v_credits;

  if v_credits is null then
    raise exception using errcode = '55000', message = 'payment_not_reviewable';
  end if;

  -- Bought credits never expire. profiles_credit_retention treats every credit
  -- increase as timed (1-3 months) unless the granting code names the buyer in
  -- x5.permanent_credit_grant_user for this transaction, exactly as the App
  -- Store and Google Play grant paths do.
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', v_payment.buyer_id::text, true
  );
  update public.profiles
  set credits = coalesce(credits, 0) + v_credits
  where id = v_payment.buyer_id;
  if not found then
    -- Never close an order as confirmed without the credits landing.
    raise exception using errcode = 'P0002',
      message = 'kaspi_buyer_profile_not_found';
  end if;
  perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);

  return jsonb_build_object(
    'id', v_payment.id,
    'status', 'confirmed',
    'creditsGranted', v_credits,
    'alreadyReviewed', false
  );
end;
$function$;

-- Server-only switch. The merchant details are real payment requisites, so they
-- are never writable from a browser and never returned to anyone who has not
-- opened an order.
create or replace function public.configure_kaspi_manual_transfers(
  p_recipient_name text,
  p_recipient_phone text,
  p_recipient_iban text default '',
  p_enable boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_settings public.kaspi_payment_settings%rowtype;
begin
  -- PostgREST only sets request.jwt.claims (JSON) now, and inside a SECURITY
  -- DEFINER function current_user is the owner, so the old check refused even
  -- the service role. auth.role() reads both GUC styles, like every other Kaspi
  -- admin function.
  if auth.role() is distinct from 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_enable and coalesce(btrim(p_recipient_phone), '') = '' then
    raise exception using errcode = '22023', message = 'recipient_phone_required';
  end if;

  update public.kaspi_payment_settings
  set recipient_name = coalesce(btrim(p_recipient_name), ''),
      recipient_phone = coalesce(btrim(p_recipient_phone), ''),
      recipient_iban = coalesce(btrim(p_recipient_iban), ''),
      manual_enabled = coalesce(p_enable, false),
      updated_at = now()
  where singleton = true
  returning * into v_settings;

  return jsonb_build_object(
    'manualEnabled', v_settings.manual_enabled,
    'recipientName', v_settings.recipient_name,
    'recipientPhone', v_settings.recipient_phone,
    'hasIban', v_settings.recipient_iban <> ''
  );
end;
$function$;

revoke all on function public.configure_kaspi_manual_transfers(text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.configure_kaspi_manual_transfers(text, text, text, boolean)
  to service_role;

revoke all on function public.create_kaspi_manual_payment(text) from public, anon;
revoke all on function public.get_kaspi_manual_payment(uuid) from public, anon;
revoke all on function public.submit_kaspi_manual_payment(uuid) from public, anon;
revoke all on function public.list_kaspi_manual_payments(text) from public, anon;
revoke all on function public.review_kaspi_manual_payment(uuid, boolean, text) from public, anon;

grant execute on function public.create_kaspi_manual_payment(text) to authenticated;
grant execute on function public.get_kaspi_manual_payment(uuid) to authenticated;
grant execute on function public.submit_kaspi_manual_payment(uuid) to authenticated;
grant execute on function public.list_kaspi_manual_payments(text) to authenticated;
grant execute on function public.review_kaspi_manual_payment(uuid, boolean, text) to authenticated;

comment on table public.kaspi_manual_payments is
  'Kaspi transfers confirmed by an X5 developer while the automatic provider integration is not issued.';

commit;
