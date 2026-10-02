-- Accept App Store auto-renewals that Apple bills and signs before the new
-- period starts (2026-10-02 incident: every production renewal of
-- com.x5studio.app.verified.monthly was rejected and the badge was removed).
--
-- Apple charges an auto-renewal up to 24 hours before the current period
-- ends. The renewal's purchase_date is the start of the new period (the
-- previous expires_date), but the transaction, renewal info and DID_RENEW
-- notification are signed at billing time. The previous rule (signed no
-- earlier than purchase_date - 5 minutes, purchase_date no later than
-- now + 10 minutes) rejected every production renewal; TestFlight renewals
-- are signed seconds early and passed.
--
-- Only those two relations move to a 25-hour window, in the two functions
-- and two CHECK constraints on the renewal path. Unchanged: signatures dated
-- in the future, notification signed after the transaction, expires_date
-- after purchase_date, revocation, account token, chain ownership, refunds,
-- exact-once ledger and idempotency. Consumables, Sandbox review rows and the
-- retired lite/pro/max lifecycle keep their existing rules.
--
-- Function bodies are the production definitions read on 2026-10-02 with
-- only the date block changed; owners, SECURITY DEFINER, search_path and
-- grants stay as they are (EXECUTE for postgres only).
-- Check supabase/deploy/20261002_verified_renewal_early_signing_preflight.sql
-- first. Apply by hand with supabase db query --linked -f. Safe to re-run.
begin;
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.x5_apply_verified_app_store_transaction_signed_date_strict_inte(p_user_id uuid, p_transaction_id text, p_original_transaction_id text, p_product_id text, p_environment text, p_app_account_token uuid, p_purchase_date timestamp with time zone, p_expires_date timestamp with time zone, p_signed_date timestamp with time zone, p_revocation_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- Apple bills an auto-renewal up to 24 hours before the current period
  -- ends and signs it then, while purchase_date is the new period start.
  -- Allow that lead (plus one hour); a signature from the future stays invalid.
  if p_signed_date < p_purchase_date - interval '25 hours'
     or p_signed_date > clock_timestamp() + interval '10 minutes'
     or p_purchase_date > clock_timestamp() + interval '25 hours' then
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
$function$;

CREATE OR REPLACE FUNCTION public.x5_apply_verified_app_store_badge_lifecycle_internal(p_event_id uuid, p_notification_type text, p_notification_subtype text, p_notification_signed_date timestamp with time zone, p_user_id uuid, p_transaction_id text, p_original_transaction_id text, p_product_id text, p_environment text, p_app_account_token uuid, p_purchase_date timestamp with time zone, p_expires_date timestamp with time zone, p_transaction_signed_date timestamp with time zone, p_renewal_signed_date timestamp with time zone, p_revocation_date timestamp with time zone, p_grace_period_expires_date timestamp with time zone, p_auto_renew_status integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_notification_type text := upper(btrim(coalesce(p_notification_type, '')));
  v_notification_subtype text :=
    nullif(upper(btrim(coalesce(p_notification_subtype, ''))), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text :=
    nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  existing public.app_store_verified_lifecycle_events%rowtype;
  v_result jsonb;
  v_status text;
  v_verified_until timestamptz;
  v_resolved_user_id uuid;
  v_legacy_binding_used boolean;
begin
  if p_event_id is null then
    raise exception using errcode = '22023', message = 'invalid_event_id';
  end if;
  if v_notification_type not in (
    'SUBSCRIBED', 'DID_RENEW', 'DID_FAIL_TO_RENEW', 'EXPIRED',
    'GRACE_PERIOD_EXPIRED', 'REVOKE'
  ) then
    raise exception using errcode = '22023',
      message = 'invalid_notification_type';
  end if;
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  if v_product_id <> 'com.x5studio.app.verified.monthly' then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  if v_transaction_id is null or length(v_transaction_id) > 255
     or v_original_transaction_id is null
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023',
      message = 'invalid_transaction_id';
  end if;
  if p_notification_subtype is not null
     and (v_notification_subtype is null
          or length(v_notification_subtype) > 64) then
    raise exception using errcode = '22023',
      message = 'invalid_notification_subtype';
  end if;
  if v_notification_type = 'DID_FAIL_TO_RENEW'
     and v_notification_subtype is distinct from 'GRACE_PERIOD' then
    raise exception using errcode = '22023',
      message = 'invalid_notification_subtype';
  end if;
  if p_user_id is null or p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  -- Resolve and lock an exact legacy binding before taking the profile lock.
  -- The on-device renewal binder uses the same binding -> profile order.
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      v_environment, v_original_transaction_id, v_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;
  v_legacy_binding_used := p_app_account_token <> p_user_id;
  if p_purchase_date is null or p_expires_date is null
     or p_transaction_signed_date is null
     or p_renewal_signed_date is null
     or p_notification_signed_date is null then
    raise exception using errcode = '22023',
      message = 'missing_transaction_dates';
  end if;
  -- An early-billed renewal is signed up to 24 hours before its period
  -- (purchase_date) starts. Only that relation gets the 25-hour window.
  if p_expires_date <= p_purchase_date
     or p_purchase_date > clock_timestamp() + interval '25 hours'
     or p_transaction_signed_date > clock_timestamp() + interval '10 minutes'
     or p_renewal_signed_date > clock_timestamp() + interval '10 minutes'
     or p_notification_signed_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date < p_purchase_date - interval '25 hours'
     or p_renewal_signed_date < p_purchase_date - interval '25 hours'
     or p_notification_signed_date <
        p_transaction_signed_date - interval '5 minutes'
     or p_notification_signed_date <
        p_renewal_signed_date - interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid_signed_date';
  end if;
  if p_auto_renew_status is not null and p_auto_renew_status not in (0, 1) then
    raise exception using errcode = '22023',
      message = 'invalid_auto_renew_status';
  end if;

  if v_notification_type = 'REVOKE' then
    if p_revocation_date is null
       or p_revocation_date < p_purchase_date
       or p_revocation_date > clock_timestamp() + interval '10 minutes'
       or p_transaction_signed_date < p_revocation_date - interval '5 minutes' then
      raise exception using errcode = '22023',
        message = 'invalid_revocation_date';
    end if;
  elsif p_revocation_date is not null then
    raise exception using errcode = '22023', message = 'invalid_revocation_date';
  end if;

  if v_notification_type in ('EXPIRED', 'GRACE_PERIOD_EXPIRED')
     and p_expires_date > p_notification_signed_date + interval '5 minutes' then
    raise exception using errcode = '22023',
      message = 'invalid_expiration_date';
  end if;
  if v_notification_type in (
    'DID_FAIL_TO_RENEW', 'GRACE_PERIOD_EXPIRED'
  ) and (
    p_grace_period_expires_date is null
    or p_grace_period_expires_date < p_expires_date
    or (
      v_notification_type = 'DID_FAIL_TO_RENEW'
      and p_grace_period_expires_date <= clock_timestamp()
    )
    or (
      v_notification_type = 'GRACE_PERIOD_EXPIRED'
      and p_grace_period_expires_date >
          p_notification_signed_date + interval '5 minutes'
    )
  ) then
    raise exception using errcode = '22023',
      message = 'invalid_grace_period_expiration_date';
  end if;

  -- Billing grace can extend access, so it must preserve an entitlement that
  -- this backend already proved. A signed notification for an unknown chain
  -- is recorded only after its StoreKit transaction has passed the normal
  -- grant path (or the exact grandfather binding for the two legacy chains).
  if v_notification_type = 'DID_FAIL_TO_RENEW' then
    if v_environment = 'Sandbox' then
      perform 1
        from public.app_store_sandbox_review_transactions as source
       where source.transaction_id = v_transaction_id
         and source.original_transaction_id = v_original_transaction_id
         and source.user_id = p_user_id
         and source.product_id = v_product_id
         and source.environment = v_environment
         and source.app_account_token = p_app_account_token
         and source.purchase_date = p_purchase_date
         and source.expires_date = p_expires_date
         and source.is_verified_product
         and source.credits_granted = 0;
      if not found then
        raise exception using errcode = '22023',
          message = 'sandbox_review_account_not_allowed';
      end if;
    elsif not v_legacy_binding_used then
      perform 1
        from public.app_store_transactions as source
       where source.transaction_id = v_transaction_id
         and source.original_transaction_id = v_original_transaction_id
         and source.user_id = p_user_id
         and source.product_id = v_product_id
         and source.environment = v_environment
         and source.app_account_token = p_app_account_token
         and source.purchase_date = p_purchase_date
         and source.expires_date = p_expires_date
         and source.is_verified_product
         and source.credits_granted = 0;
      if not found then
        raise exception using errcode = '22023',
          message = 'lifecycle_grace_source_not_found';
      end if;
    else
      perform 1
        from public.app_store_legacy_bindings as binding
        join public.app_store_transactions as source
          on source.original_transaction_id = binding.original_transaction_id
         and source.user_id = binding.user_id
         and source.product_id = binding.product_id
       where binding.original_transaction_id = v_original_transaction_id
         and binding.user_id = p_user_id
         and binding.product_id = v_product_id
         and binding.app_account_token = p_app_account_token
         and binding.bound_at is not null
         and source.transaction_id = v_transaction_id
         and source.environment = v_environment
         and source.app_account_token is null
         and source.purchase_date = p_purchase_date
         and source.expires_date = p_expires_date
         and source.is_verified_product
         and source.credits_granted = 0;
      if not found then
        perform 1
          from public.app_store_legacy_bindings as binding
          join public.iap_entitlements as source
            on source.original_transaction_id = binding.original_transaction_id
           and source.user_id = binding.user_id
           and source.product_id = binding.product_id
           and lower(coalesce(source.platform, '')) = 'ios'
         where binding.original_transaction_id = v_original_transaction_id
           and binding.user_id = p_user_id
           and binding.product_id = v_product_id
           and binding.app_account_token = p_app_account_token
           and source.subscription_end_date = p_expires_date
           and (
             source.last_transaction_id = v_transaction_id
             or (
               binding.bound_at is null
               and source.credited_at is not distinct from
                   binding.legacy_credited_at
               and source.subscription_end_date is not distinct from
                   binding.legacy_subscription_end_date
               and source.created_at is not distinct from
                   binding.legacy_created_at
               and coalesce(
                 source.legacy_app_account_token,
                 source.app_account_token
               ) = binding.app_account_token
             )
           );
      end if;
      if not found then
        raise exception using errcode = '22023',
          message = 'lifecycle_grace_source_not_found';
      end if;
    end if;
  end if;

  -- Exact legacy bindings were already locked above; profile comes next.
  perform 1
    from public.profiles
   where id = p_user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-lifecycle:' || p_event_id::text, 0
    )
  );

  select event.*
    into existing
    from public.app_store_verified_lifecycle_events as event
   where event.event_id = p_event_id;
  if found then
    if existing.notification_type <> v_notification_type
       or existing.notification_subtype is distinct from
          v_notification_subtype
       or existing.notification_signed_date <> p_notification_signed_date
       or existing.transaction_signed_date <> p_transaction_signed_date
       or existing.renewal_signed_date <> p_renewal_signed_date
       or existing.environment <> v_environment
       or existing.transaction_id <> v_transaction_id
       or existing.original_transaction_id <> v_original_transaction_id
       or existing.user_id <> p_user_id
       or existing.product_id <> v_product_id
       or existing.app_account_token <> p_app_account_token
       or existing.purchase_date <> p_purchase_date
       or existing.expires_date <> p_expires_date
       or existing.revocation_date is distinct from p_revocation_date
       or existing.grace_period_expires_date is distinct from
          p_grace_period_expires_date
       or existing.auto_renew_status is distinct from p_auto_renew_status
       or existing.legacy_binding_used is distinct from
          v_legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'lifecycle_event_id_conflict';
    end if;
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    return jsonb_build_object(
      'status', 'already_applied',
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;

  if v_notification_type in ('SUBSCRIBED', 'DID_RENEW') then
    if p_expires_date <= clock_timestamp() then
      v_status := 'ignored_stale';
      v_verified_until :=
        public.x5_rebuild_app_store_verified_profile(p_user_id);
    else
      if v_environment = 'Production' then
        v_result := public.apply_verified_app_store_transaction(
          p_user_id, v_transaction_id, v_original_transaction_id,
          v_product_id, v_environment, p_app_account_token,
          p_purchase_date, p_expires_date, p_transaction_signed_date, null
        );
      else
        v_result :=
          public.apply_verified_app_store_sandbox_review_transaction(
            p_user_id, v_transaction_id, v_original_transaction_id,
            v_product_id, v_environment, p_app_account_token,
            p_purchase_date, p_expires_date, p_transaction_signed_date,
            null, null
          );
      end if;
      v_status := coalesce(v_result ->> 'status', 'applied');
      v_verified_until :=
        public.x5_rebuild_app_store_verified_profile(p_user_id);
    end if;
  elsif v_notification_type = 'REVOKE' then
    if v_legacy_binding_used then
      -- Preserve the real legacy token in the exact refund projection. Scope
      -- revocation to this StoreKit period so an older period cannot suppress a
      -- newer renewal, and let a later REFUND_REVERSED restore unexpired access.
      v_result := public.x5_apply_verified_legacy_subscription_notification(
        md5('lifecycle-legacy-revoke|' || p_event_id::text)::uuid,
        'REFUND', p_notification_signed_date, p_user_id,
        v_transaction_id, v_original_transaction_id, v_product_id,
        v_environment, p_app_account_token, p_purchase_date, p_expires_date,
        p_transaction_signed_date, p_revocation_date, 100000, null
      );
      v_status := coalesce(v_result ->> 'status', 'applied');
    else
      v_result := public.apply_verified_app_store_verified_revocation(
        p_user_id, v_transaction_id, v_original_transaction_id,
        v_product_id, v_environment, p_app_account_token,
        p_purchase_date, p_expires_date, p_transaction_signed_date,
        p_revocation_date
      );
      v_status := coalesce(v_result ->> 'status', 'applied');
    end if;
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
  else
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    v_status := 'applied';
  end if;

  if v_status not in ('applied', 'already_applied', 'ignored_stale') then
    raise exception using errcode = '22023',
      message = 'invalid_lifecycle_result';
  end if;

  insert into public.app_store_verified_lifecycle_events (
    event_id, notification_type, notification_subtype,
    notification_signed_date,
    transaction_signed_date, renewal_signed_date, environment,
    transaction_id, original_transaction_id, user_id, product_id,
    app_account_token, purchase_date, expires_date, revocation_date,
    grace_period_expires_date, auto_renew_status, applied,
    result_status, legacy_binding_used
  ) values (
    p_event_id, v_notification_type, v_notification_subtype,
    p_notification_signed_date,
    p_transaction_signed_date, p_renewal_signed_date, v_environment,
    v_transaction_id, v_original_transaction_id, p_user_id, v_product_id,
    p_app_account_token, p_purchase_date, p_expires_date,
    p_revocation_date, p_grace_period_expires_date, p_auto_renew_status,
    v_status = 'applied', v_status, v_legacy_binding_used
  );

  -- The newly inserted immutable event must be visible to the projection in
  -- this same request. This preserves grace immediately and lets a later
  -- terminal event supersede it before the next reconciliation cron.
  v_verified_until :=
    public.x5_rebuild_app_store_verified_profile(p_user_id);

  return jsonb_build_object(
    'status', v_status,
    'subscription_end_date', v_verified_until,
    'is_verified', v_verified_until is not null
  );
end;
$function$;

revoke execute on function
  public.x5_apply_verified_app_store_transaction_signed_date_strict_inte(
    uuid, text, text, text, text, uuid, timestamptz, timestamptz,
    timestamptz, timestamptz
  )
  from public, anon, authenticated, service_role;

revoke execute on function
  public.x5_apply_verified_app_store_badge_lifecycle_internal(
    uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, timestamptz,
    timestamptz, integer
  )
  from public, anon, authenticated, service_role;

-- The new predicates are strictly weaker than the validated old ones, so every
-- existing row satisfies them (checked in production on 2026-10-02: 0 of 2
-- transactions and 0 of 15 lifecycle events violate them). Add as NOT VALID
-- to keep the exclusive lock short, then validate under a lighter lock.
alter table public.app_store_transactions
  drop constraint if exists app_store_transactions_dates_valid,
  add constraint app_store_transactions_dates_valid
    check (
      expires_date > purchase_date
      and signed_date >= purchase_date - interval '25 hours'
    ) not valid;
alter table public.app_store_transactions
  validate constraint app_store_transactions_dates_valid;

alter table public.app_store_verified_lifecycle_events
  drop constraint if exists app_store_verified_lifecycle_events_dates,
  add constraint app_store_verified_lifecycle_events_dates
    check (
      expires_date > purchase_date
      and transaction_signed_date >= purchase_date - interval '25 hours'
      and renewal_signed_date >= purchase_date - interval '25 hours'
      and notification_signed_date >=
          transaction_signed_date - interval '5 minutes'
      and notification_signed_date >=
          renewal_signed_date - interval '5 minutes'
    ) not valid;
alter table public.app_store_verified_lifecycle_events
  validate constraint app_store_verified_lifecycle_events_dates;

commit;
