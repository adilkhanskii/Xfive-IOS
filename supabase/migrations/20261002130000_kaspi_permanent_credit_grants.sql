-- Kaspi credit packs are bought credits and must never expire.
--
-- profiles_credit_retention (public.x5_prepare_credit_retention) treats every
-- credit increase as timed credits that expire in 1-3 months, unless the code
-- that grants them names the buyer in the transaction-local setting
-- x5.permanent_credit_grant_user. apply_verified_app_store_consumable and
-- apply_android_purchase_entitlement_v2 do that; apply_kaspi_provider_command
-- (20260813150000, live in production) did not, so a paid Kaspi pack would have
-- silently expired. No Kaspi payment has been confirmed in production yet
-- (kaspi_credit_payments was empty on 2026-10-02), so no balance needs repair.
--
-- Both bodies below are the production definitions (pg_get_functiondef,
-- 2026-10-02) with only the set_config lines added. The refund mirrors the grant:
-- with x5.permanent_credit_adjustment_user it takes the refunded pack off the
-- permanent floor, as the App Store consumable refund path does.
--
-- Safe to run more than once. Grants and comments are restated unchanged.

begin;

CREATE OR REPLACE FUNCTION public.apply_kaspi_provider_command(p_command text, p_txn_id text, p_txn_date text, p_account text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- Bought credits never expire: name the buyer so profiles_credit_retention
  -- records this increase as permanent, exactly like the App Store and Google
  -- Play grant paths. The setting is transaction-local and cleared right after.
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user', v_payment.buyer_id::text, true
  );
  update public.profiles
  set credits = coalesce(credits, 0) + v_payment.credits
  where id = v_payment.buyer_id;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'kaspi_buyer_profile_not_found';
  end if;
  perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);

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

CREATE OR REPLACE FUNCTION public.refund_kaspi_credit_payment(p_payment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- The pack was granted as permanent credits, so its refund must come off the
  -- permanent floor (and record debt for anything already spent) instead of
  -- eating the buyer's expiring credits first. Same flag the App Store
  -- consumable refund path sets.
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', v_payment.buyer_id::text, true
  );
  update public.profiles
  set credits = coalesce(credits, 0) - v_payment.credits
  where id = v_payment.buyer_id;
  perform pg_catalog.set_config('x5.permanent_credit_adjustment_user', '', true);

  update public.kaspi_credit_payments
  set status = 'refunded', refunded_at = now(), updated_at = now()
  where id = v_payment.id;

  return jsonb_build_object('ok', true, 'status', 'refunded');
end;
$function$;

revoke all on function
  public.apply_kaspi_provider_command(text, text, text, text, numeric)
from public, anon, authenticated;
revoke all on function public.refund_kaspi_credit_payment(uuid)
from public, anon, authenticated;

grant execute on function
  public.apply_kaspi_provider_command(text, text, text, text, numeric)
to service_role;
grant execute on function public.refund_kaspi_credit_payment(uuid)
to service_role;

comment on function public.apply_kaspi_provider_command(text, text, text, text, numeric) is
  'Applies official Kaspi check/pay callbacks exactly once; service role only.';

commit;
