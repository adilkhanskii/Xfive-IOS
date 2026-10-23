begin;

-- Paid-plan refunds use the same immutable V2 notification ledger as credit
-- packs and the verified badge. Legacy paid plans are Production-only, retain
-- their signed subscription expiry, and normalize Apple's optional quantity to
-- one at the Edge boundary.
alter table public.app_store_legacy_bindings
  add column legacy_credits_granted integer;
alter table public.app_store_legacy_bindings
  add constraint app_store_legacy_bindings_legacy_credit_economics
    check (
      legacy_credits_granted is null
      or (product_id = 'com.x5studio.app.lite.monthly'
          and legacy_credits_granted = 1000)
      or (product_id = 'com.x5studio.app.pro.monthly'
          and legacy_credits_granted = 2000)
      or (product_id = 'com.x5studio.app.max.monthly'
          and legacy_credits_granted = 5000)
      or (product_id = 'com.x5studio.app.verified.monthly'
          and legacy_credits_granted = 0)
    );

-- Freeze the exact already-credited economics alongside the immutable legacy
-- snapshot. A null value is deliberately not guessed: it cannot be used as a
-- refund source by the private engine below.
update public.app_store_legacy_bindings as binding
   set legacy_credits_granted = legacy.credits_granted
  from public.iap_entitlements as legacy
 where binding.original_transaction_id = legacy.original_transaction_id
   and binding.user_id = legacy.user_id
   and binding.product_id = legacy.product_id
   and binding.legacy_credited_at is not distinct from legacy.credited_at
   and binding.legacy_subscription_end_date is not distinct from
       legacy.subscription_end_date
   and binding.legacy_created_at is not distinct from legacy.created_at
   and binding.app_account_token = coalesce(
     legacy.legacy_app_account_token,
     legacy.app_account_token,
     legacy.user_id
   )
   and legacy.credits_granted is not null
   and legacy.credits_granted >= 0;

alter table public.app_store_server_notification_events
  drop constraint app_store_server_notification_events_known_product;
alter table public.app_store_server_notification_events
  add constraint app_store_server_notification_events_known_product
    check (product_id in (
      'com.x5studio.app.credits.1000',
      'com.x5studio.app.credits.2000',
      'com.x5studio.app.credits.5000',
      'com.x5studio.app.lite.monthly',
      'com.x5studio.app.pro.monthly',
      'com.x5studio.app.max.monthly',
      'com.x5studio.app.verified.monthly'
    ));

alter table public.app_store_server_notification_events
  drop constraint app_store_server_notification_events_product_shape;
alter table public.app_store_server_notification_events
  add constraint app_store_server_notification_events_product_shape
    check (
      (
        product_id like 'com.x5studio.app.credits.%'
        and quantity = 1
        and expires_date is null
      ) or (
        product_id = 'com.x5studio.app.verified.monthly'
        and quantity is null
        and expires_date > purchase_date
      ) or (
        product_id in (
          'com.x5studio.app.lite.monthly',
          'com.x5studio.app.pro.monthly',
          'com.x5studio.app.max.monthly'
        )
        and environment = 'Production'
        and quantity = 1
        and expires_date > purchase_date
      )
    );

alter table public.app_store_server_notification_events
  drop constraint app_store_server_notification_events_account_scope;
alter table public.app_store_server_notification_events
  add constraint app_store_server_notification_events_account_scope
    check (
      (
        not legacy_binding_used
        and app_account_token = user_id
      ) or (
        legacy_binding_used
        and environment = 'Production'
        and product_id in (
          'com.x5studio.app.lite.monthly',
          'com.x5studio.app.pro.monthly',
          'com.x5studio.app.max.monthly',
          'com.x5studio.app.verified.monthly'
        )
        and app_account_token <> user_id
      )
    );

alter table public.app_store_server_notification_state
  drop constraint app_store_server_notification_state_identity;
alter table public.app_store_server_notification_state
  add constraint app_store_server_notification_state_identity
    check (
      btrim(transaction_id) <> ''
      and btrim(original_transaction_id) <> ''
      and (
        (
          not legacy_binding_used
          and app_account_token = user_id
        ) or (
          legacy_binding_used
          and environment = 'Production'
          and product_id in (
            'com.x5studio.app.lite.monthly',
            'com.x5studio.app.pro.monthly',
            'com.x5studio.app.max.monthly',
            'com.x5studio.app.verified.monthly'
          )
          and app_account_token <> user_id
        )
      )
    );

-- Preserve the established resolver for every ordinary signed token. Missing
-- tokens are accepted only for an exact Production grandfather snapshot whose
-- private binding uses user_id as its explicit nil-token sentinel.
alter function public.resolve_verified_app_store_notification_user(
  text, text, text, uuid
) rename to x5_resolve_app_store_notification_user_pre_nil_token;
revoke execute on function
  public.x5_resolve_app_store_notification_user_pre_nil_token(
    text, text, text, uuid
  ) from public, anon, authenticated, service_role;

create function public.resolve_verified_app_store_notification_user(
  p_environment text,
  p_original_transaction_id text,
  p_product_id text,
  p_app_account_token uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_original_transaction_id text :=
    nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_binding public.app_store_legacy_bindings%rowtype;
begin
  if v_environment = 'Production'
     and v_product_id in (
       'com.x5studio.app.lite.monthly',
       'com.x5studio.app.pro.monthly',
       'com.x5studio.app.max.monthly'
     )
     and v_original_transaction_id is not null
     and length(v_original_transaction_id) <= 255 then
    select binding.* into v_binding
      from public.app_store_legacy_bindings as binding
     where binding.original_transaction_id = v_original_transaction_id
       and binding.product_id = v_product_id
       and binding.app_account_token = binding.user_id
       and (
         p_app_account_token is null
         or p_app_account_token = binding.user_id
       )
     for update;
    if found then
      if v_binding.legacy_credits_granted is null then
        raise exception using errcode = '22023',
          message = 'legacy_binding_mismatch';
      end if;

      if v_binding.bound_at is null then
        perform 1
          from public.iap_entitlements as legacy
         where legacy.original_transaction_id =
               v_binding.original_transaction_id
           and legacy.user_id = v_binding.user_id
           and legacy.product_id = v_binding.product_id
           and lower(coalesce(legacy.platform, '')) = 'ios'
           and legacy.app_account_token is null
           and legacy.legacy_app_account_token is null
           and legacy.credited_at is not distinct from
               v_binding.legacy_credited_at
           and legacy.subscription_end_date is not distinct from
               v_binding.legacy_subscription_end_date
           and legacy.created_at is not distinct from
               v_binding.legacy_created_at
           and legacy.credits_granted is not distinct from
               v_binding.legacy_credits_granted
         for share;
      else
        perform 1
          from public.iap_entitlements as legacy
         where legacy.original_transaction_id =
               v_binding.original_transaction_id
           and legacy.user_id = v_binding.user_id
           and legacy.product_id = v_binding.product_id
           and lower(coalesce(legacy.platform, '')) = 'ios'
           and legacy.app_account_token is null
           and legacy.legacy_app_account_token is null
         for share;
        if found then
          perform 1
            from public.app_store_transactions as purchase
           where purchase.environment = 'Production'
             and purchase.original_transaction_id =
                 v_binding.original_transaction_id
             and purchase.user_id = v_binding.user_id
             and purchase.product_id = v_binding.product_id
             and purchase.app_account_token is null;
        end if;
      end if;
      if not found then
        raise exception using errcode = '22023',
          message = 'legacy_binding_mismatch';
      end if;
      return v_binding.user_id;
    end if;
  end if;

  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  return public.x5_resolve_app_store_notification_user_pre_nil_token(
    p_environment, p_original_transaction_id, p_product_id,
    p_app_account_token
  );
end;
$function$;

alter function public.resolve_verified_app_store_notification_user(
  text, text, text, uuid
) owner to postgres;
revoke execute on function public.resolve_verified_app_store_notification_user(
  text, text, text, uuid
) from public, anon, authenticated, service_role;
grant execute on function public.resolve_verified_app_store_notification_user(
  text, text, text, uuid
) to service_role;

-- A pre-verifier paid-plan row is still a valid source until Apple sends an
-- active refund for that exact owner/product/transaction chain. Do not let
-- the grandfather projection re-enable a refunded period while its signed
-- purchase row is still waiting to reach the canonical ledger.
create or replace function public.x5_reconcile_paid_plan_profile(
  p_user_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_profile public.profiles%rowtype;
  v_expires_at timestamptz;
  v_started_at timestamptz;
  v_subscription_type text;
begin
  select profile.*
    into v_profile
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    return null;
  end if;

  if v_profile.plan = 'black' then
    return v_profile.subscription_end_date;
  end if;
  if lower(coalesce(v_profile.plan, 'free')) in ('lite', 'pro', 'max')
     and v_profile.subscription_end_date is null then
    return null;
  end if;

  select entitlement.expires_at,
         entitlement.started_at,
         entitlement.subscription_type
    into v_expires_at, v_started_at, v_subscription_type
    from (
      select production.expires_date as expires_at,
             production.purchase_date as started_at,
             case production.product_id
               when 'com.x5studio.app.lite.monthly' then 'lite_monthly'
               when 'com.x5studio.app.pro.monthly' then 'pro_monthly'
               when 'com.x5studio.app.max.monthly' then 'max_monthly'
             end as subscription_type
        from public.app_store_transactions as production
       where production.user_id = p_user_id
         and production.product_id in (
           'com.x5studio.app.lite.monthly',
           'com.x5studio.app.pro.monthly',
           'com.x5studio.app.max.monthly'
         )
         and not production.is_verified_product
         and production.expires_date > v_now
         and not public.x5_app_store_notification_refund_active(
           'Production', production.transaction_id
         )
      union all
      select legacy_ios.subscription_end_date,
             coalesce(legacy_ios.credited_at, legacy_ios.created_at),
             case legacy_ios.product_id
               when 'com.x5studio.app.lite.monthly' then 'lite_monthly'
               when 'com.x5studio.app.pro.monthly' then 'pro_monthly'
               when 'com.x5studio.app.max.monthly' then 'max_monthly'
             end
        from public.iap_entitlements as legacy_ios
        join public.app_store_legacy_bindings as binding
          on binding.original_transaction_id =
             legacy_ios.original_transaction_id
         and binding.user_id = legacy_ios.user_id
         and binding.product_id = legacy_ios.product_id
         and binding.legacy_credited_at is not distinct from
             legacy_ios.credited_at
         and binding.legacy_subscription_end_date is not distinct from
             legacy_ios.subscription_end_date
         and binding.legacy_created_at is not distinct from
             legacy_ios.created_at
         and binding.app_account_token = coalesce(
           legacy_ios.legacy_app_account_token,
           legacy_ios.app_account_token,
           legacy_ios.user_id
         )
       where legacy_ios.user_id = p_user_id
         and lower(coalesce(legacy_ios.platform, '')) = 'ios'
         and legacy_ios.product_id in (
           'com.x5studio.app.lite.monthly',
           'com.x5studio.app.pro.monthly',
           'com.x5studio.app.max.monthly'
         )
         and legacy_ios.subscription_end_date > v_now
         and not exists (
           select 1
             from public.app_store_server_notification_state as refund_state
            where refund_state.environment = 'Production'
              and refund_state.user_id = legacy_ios.user_id
              and refund_state.product_id = legacy_ios.product_id
              and refund_state.original_transaction_id =
                  legacy_ios.original_transaction_id
              and refund_state.expires_date is not distinct from
                  legacy_ios.subscription_end_date
              and refund_state.active
         )
         and not exists (
           select 1
             from public.app_store_transactions as migrated
            where migrated.original_transaction_id =
                  legacy_ios.original_transaction_id
              and migrated.user_id = legacy_ios.user_id
         )
      union all
      select coalesce(android.expires_at, android.subscription_end_date),
             coalesce(android.credited_at, android.created_at),
             case android.product_id
               when 'x5_lite_monthly_v2' then 'lite_monthly'
               when 'x5_pro_monthly_v2' then 'pro_monthly'
               when 'x5_max_monthly_v2' then 'max_monthly'
               when 'x5_pro_monthly' then 'monthly'
               when 'x5_pro_yearly' then 'yearly'
             end
        from public.iap_entitlements as android
       where android.user_id = p_user_id
         and lower(coalesce(android.platform, '')) = 'android'
         and android.product_id in (
           'x5_lite_monthly_v2', 'x5_pro_monthly_v2',
           'x5_max_monthly_v2', 'x5_pro_monthly', 'x5_pro_yearly'
         )
         and android.purchase_type = 'subscription'
         and android.purchase_token_hash is not null
         and btrim(android.purchase_token_hash) <> ''
         and android.claim_key is not null
         and btrim(android.claim_key) <> ''
         and android.app_account_token = android.user_id
         and coalesce(android.expires_at, android.subscription_end_date) > v_now
    ) as entitlement
   order by entitlement.expires_at desc
   limit 1;

  if found then
    update public.profiles
       set plan = 'pro',
           subscription_type = v_subscription_type,
           subscription_date = coalesce(subscription_date, v_started_at),
           subscription_end_date = v_expires_at
     where id = p_user_id
       and (
         plan is distinct from 'pro'
         or subscription_type is distinct from v_subscription_type
         or subscription_end_date is distinct from v_expires_at
       );
    return v_expires_at;
  end if;

  if v_profile.subscription_end_date is null then
    return null;
  end if;
  if lower(coalesce(v_profile.plan, 'free')) in ('lite', 'pro', 'max')
     and v_profile.subscription_end_date <= v_now then
    update public.profiles
       set plan = 'free',
           subscription_type = null,
           subscription_date = null,
           subscription_end_date = null
     where id = p_user_id;
    return null;
  end if;
  return v_profile.subscription_end_date;
end;
$function$;

alter function public.x5_reconcile_paid_plan_profile(uuid) owner to postgres;
revoke execute on function public.x5_reconcile_paid_plan_profile(uuid)
  from public, anon, authenticated, service_role;

create function public.x5_apply_verified_app_store_legacy_plan_refund(
  p_event_id uuid,
  p_notification_type text,
  p_notification_signed_date timestamptz,
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
  p_transaction_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_revocation_percentage integer,
  p_quantity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_notification_type text := upper(btrim(coalesce(p_notification_type, '')));
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text :=
    nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_nominal_credits integer;
  v_resolved_user_id uuid;
  v_legacy_binding_used boolean;
  source public.app_store_transactions%rowtype;
  existing_event public.app_store_server_notification_events%rowtype;
  projection public.app_store_server_notification_state%rowtype;
  v_source_found boolean := false;
  v_legacy_source_found boolean := false;
  v_nil_token_sentinel boolean := false;
  v_legacy_frozen_credits integer;
  v_refund_credits_basis integer;
  v_projection_found boolean := false;
  v_prior_active boolean := false;
  v_prior_percentage integer := 0;
  v_prior_credits_affected integer := 0;
  v_prior_pending_credits integer := 0;
  v_prior_transaction_signed_date timestamptz;
  v_prior_revocation_date timestamptz;
  v_target_credits_affected integer := 0;
  v_target_pending_credits integer := 0;
  v_credits_delta integer := 0;
  v_resulting_percentage integer := 0;
  v_subscription_end timestamptz;
begin
  if p_event_id is null then
    raise exception using errcode = '22023',
      message = 'invalid_notification_uuid';
  end if;
  if v_notification_type not in ('REFUND', 'REFUND_REVERSED') then
    raise exception using errcode = '22023',
      message = 'invalid_notification_type';
  end if;
  if v_environment is distinct from 'Production' then
    raise exception using errcode = '22023',
      message = 'invalid_legacy_plan_environment';
  end if;
  v_nominal_credits := case v_product_id
    when 'com.x5studio.app.lite.monthly' then 1000
    when 'com.x5studio.app.pro.monthly' then 2000
    when 'com.x5studio.app.max.monthly' then 5000
    else null
  end;
  if v_nominal_credits is null then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  if p_quantity is distinct from 1 then
    raise exception using errcode = '22023', message = 'invalid_quantity';
  end if;
  if v_transaction_id is null or length(v_transaction_id) > 255
     or v_original_transaction_id is null
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023',
      message = 'invalid_transaction_id';
  end if;
  if p_user_id is null or p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_purchase_date is null or p_expires_date is null
     or p_transaction_signed_date is null
     or p_notification_signed_date is null
     or p_expires_date <= p_purchase_date
     or p_purchase_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date > clock_timestamp() + interval '10 minutes'
     or p_notification_signed_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date < p_purchase_date - interval '5 minutes'
     or p_notification_signed_date <
        p_transaction_signed_date - interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid_signed_date';
  end if;
  if v_notification_type = 'REFUND' then
    if p_revocation_date is null
       or p_revocation_percentage is null
       or p_revocation_percentage not between 1 and 100000
       or p_revocation_date < p_purchase_date
       or p_revocation_date > clock_timestamp() + interval '10 minutes'
       or p_transaction_signed_date <
          p_revocation_date - interval '5 minutes' then
      raise exception using errcode = '22023',
        message = 'invalid_revocation_date';
    end if;
  elsif p_revocation_date is not null
        or p_revocation_percentage is not null then
    raise exception using errcode = '22023',
      message = 'invalid_refund_reversal';
  end if;

  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      v_environment, v_original_transaction_id, v_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;
  v_legacy_binding_used := p_app_account_token <> p_user_id;

  -- This immutable grandfather tuple is an economic source only while every
  -- frozen binding field, including the credited amount, still matches.
  select binding.legacy_credits_granted,
         binding.app_account_token = binding.user_id
           and legacy.app_account_token is null
           and legacy.legacy_app_account_token is null
    into v_legacy_frozen_credits, v_nil_token_sentinel
    from public.app_store_legacy_bindings as binding
    join public.iap_entitlements as legacy
      on legacy.original_transaction_id = binding.original_transaction_id
     and legacy.user_id = binding.user_id
     and legacy.product_id = binding.product_id
     and lower(coalesce(legacy.platform, '')) = 'ios'
     and coalesce(
       legacy.legacy_app_account_token,
       legacy.app_account_token,
       legacy.user_id
     ) = binding.app_account_token
   where binding.original_transaction_id = v_original_transaction_id
     and binding.user_id = p_user_id
     and binding.product_id = v_product_id
     and binding.app_account_token = p_app_account_token
     and binding.legacy_credits_granted is not null
     and binding.legacy_subscription_end_date is not distinct from
         p_expires_date
     and (
       binding.bound_at is not null
       or (
         legacy.credited_at is not distinct from binding.legacy_credited_at
         and legacy.subscription_end_date is not distinct from
             binding.legacy_subscription_end_date
         and legacy.created_at is not distinct from binding.legacy_created_at
         and legacy.credits_granted is not distinct from
             binding.legacy_credits_granted
       )
     )
   for share of legacy;
  v_legacy_source_found := found;

  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-transaction:' || v_transaction_id, 0
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-notification:' || p_event_id::text, 0
    )
  );

  select event.* into existing_event
    from public.app_store_server_notification_events as event
   where event.event_id = p_event_id;
  if found then
    if existing_event.notification_type <> v_notification_type
       or existing_event.notification_signed_date <>
          p_notification_signed_date
       or existing_event.transaction_signed_date <>
          p_transaction_signed_date
       or existing_event.environment <> v_environment
       or existing_event.transaction_id <> v_transaction_id
       or existing_event.original_transaction_id <>
          v_original_transaction_id
       or existing_event.user_id <> p_user_id
       or existing_event.product_id <> v_product_id
       or existing_event.app_account_token <> p_app_account_token
       or existing_event.purchase_date <> p_purchase_date
       or existing_event.expires_date <> p_expires_date
       or existing_event.revocation_date is distinct from p_revocation_date
       or existing_event.revocation_percentage is distinct from
          p_revocation_percentage
       or existing_event.quantity is distinct from 1
       or existing_event.legacy_binding_used is distinct from
          v_legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'notification_event_id_conflict';
    end if;
    v_subscription_end :=
      public.x5_reconcile_paid_plan_profile(p_user_id);
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_affected', existing_event.credits_affected,
      'credits_delta', 0,
      'subscription_end_date', v_subscription_end
    );
  end if;

  select state.* into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  v_projection_found := found;
  if v_projection_found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          v_original_transaction_id
       or projection.product_id <> v_product_id
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date <> p_expires_date
       or projection.quantity is distinct from 1
       or projection.legacy_binding_used is distinct from
          v_legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    v_prior_active := projection.active;
    v_prior_percentage := projection.revocation_percentage;
    v_prior_credits_affected := projection.credits_withheld;
    v_prior_pending_credits := projection.pending_credits_withheld;
    v_prior_transaction_signed_date :=
      projection.last_transaction_signed_date;
    select event.revocation_date into v_prior_revocation_date
      from public.app_store_server_notification_events as event
     where event.event_id = projection.last_event_id;
  end if;

  select purchase.* into source
    from public.app_store_transactions as purchase
   where purchase.transaction_id = v_transaction_id
   for update;
  v_source_found := found;
  if v_source_found then
    if source.user_id <> p_user_id
       or source.original_transaction_id <> v_original_transaction_id
       or source.product_id <> v_product_id
       or source.environment <> v_environment
       or source.purchase_date <> p_purchase_date
       or source.expires_date <> p_expires_date
       or source.signed_date > p_transaction_signed_date + interval '5 minutes'
       or source.is_verified_product
       or source.credits_granted < 0
       or source.credits_granted > v_nominal_credits
       or (
         v_legacy_binding_used and source.app_account_token is not null
       ) or (
         not v_legacy_binding_used and not v_nil_token_sentinel
         and source.app_account_token is distinct from p_app_account_token
       ) or (
         v_nil_token_sentinel
         and source.app_account_token is not null
         and source.app_account_token <> p_user_id
       ) then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
  else
    perform 1
      from public.app_store_entitlement_owners as owner
     where owner.original_transaction_id = v_original_transaction_id
       and owner.user_id <> p_user_id;
    if found then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
  end if;

  if v_prior_transaction_signed_date is not null
     and p_transaction_signed_date < v_prior_transaction_signed_date then
    insert into public.app_store_server_notification_events (
      event_id, notification_type, notification_signed_date,
      transaction_signed_date, environment, transaction_id,
      original_transaction_id, user_id, product_id, app_account_token,
      purchase_date, expires_date, revocation_date, revocation_percentage,
      quantity, applied, resulting_revocation_percentage,
      credits_affected, pending_credits_affected, credits_delta,
      legacy_binding_used
    ) values (
      p_event_id, v_notification_type, p_notification_signed_date,
      p_transaction_signed_date, v_environment, v_transaction_id,
      v_original_transaction_id, p_user_id, v_product_id,
      p_app_account_token, p_purchase_date, p_expires_date,
      p_revocation_date, p_revocation_percentage, 1, false,
      case when v_prior_active then v_prior_percentage else 0 end,
      v_prior_credits_affected, v_prior_pending_credits, 0,
      v_legacy_binding_used
    );
    return jsonb_build_object(
      'status', 'ignored_stale',
      'credits_affected', v_prior_credits_affected,
      'credits_delta', 0
    );
  end if;

  if v_prior_transaction_signed_date is not null
     and p_transaction_signed_date = v_prior_transaction_signed_date then
    if (
      v_prior_active
      and v_notification_type = 'REFUND'
      and p_revocation_percentage = v_prior_percentage
      and p_revocation_date is not distinct from v_prior_revocation_date
    ) or (
      not v_prior_active and v_notification_type = 'REFUND_REVERSED'
    ) then
      insert into public.app_store_server_notification_events (
        event_id, notification_type, notification_signed_date,
        transaction_signed_date, environment, transaction_id,
        original_transaction_id, user_id, product_id, app_account_token,
        purchase_date, expires_date, revocation_date,
        revocation_percentage, quantity, applied,
        resulting_revocation_percentage, credits_affected,
        pending_credits_affected, credits_delta, legacy_binding_used
      ) values (
        p_event_id, v_notification_type, p_notification_signed_date,
        p_transaction_signed_date, v_environment, v_transaction_id,
        v_original_transaction_id, p_user_id, v_product_id,
        p_app_account_token, p_purchase_date, p_expires_date,
        p_revocation_date, p_revocation_percentage, 1, false,
        case when v_prior_active then v_prior_percentage else 0 end,
        v_prior_credits_affected, v_prior_pending_credits, 0,
        v_legacy_binding_used
      );
      return jsonb_build_object(
        'status', 'already_applied',
        'credits_affected', v_prior_credits_affected,
        'credits_delta', 0
      );
    end if;
    raise exception using errcode = '22023',
      message = 'notification_source_mismatch';
  end if;

  if v_notification_type = 'REFUND' then
    v_resulting_percentage := p_revocation_percentage;
    v_refund_credits_basis := case
      when v_legacy_source_found
        then v_legacy_frozen_credits
      when v_source_found and source.credits_granted > 0
        then source.credits_granted
      when v_source_found then source.credits_granted
      else null
    end;
    if v_refund_credits_basis is not null then
      v_target_credits_affected := ceil(
        v_refund_credits_basis::numeric *
        p_revocation_percentage::numeric / 100000
      )::integer;
      v_target_pending_credits := 0;
    else
      v_target_credits_affected := 0;
      v_target_pending_credits := ceil(
        v_nominal_credits::numeric *
        p_revocation_percentage::numeric / 100000
      )::integer;
    end if;
    v_credits_delta :=
      v_prior_credits_affected - v_target_credits_affected;
  else
    v_resulting_percentage := 0;
    v_target_credits_affected := 0;
    v_target_pending_credits := 0;
    v_credits_delta := v_prior_credits_affected;
  end if;

  if v_credits_delta <> 0 then
    update public.profiles
       set credits = coalesce(credits, 0) + v_credits_delta
     where id = p_user_id;
  end if;

  insert into public.app_store_server_notification_events (
    event_id, notification_type, notification_signed_date,
    transaction_signed_date, environment, transaction_id,
    original_transaction_id, user_id, product_id, app_account_token,
    purchase_date, expires_date, revocation_date, revocation_percentage,
    quantity, applied, resulting_revocation_percentage,
    credits_affected, pending_credits_affected, credits_delta,
    legacy_binding_used
  ) values (
    p_event_id, v_notification_type, p_notification_signed_date,
    p_transaction_signed_date, v_environment, v_transaction_id,
    v_original_transaction_id, p_user_id, v_product_id,
    p_app_account_token, p_purchase_date, p_expires_date,
    p_revocation_date, p_revocation_percentage, 1, true,
    v_resulting_percentage,
    case when v_notification_type = 'REFUND_REVERSED'
      then v_prior_credits_affected else v_target_credits_affected end,
    case when v_notification_type = 'REFUND_REVERSED'
      then v_prior_pending_credits else v_target_pending_credits end,
    v_credits_delta, v_legacy_binding_used
  );

  insert into public.app_store_server_notification_state (
    environment, transaction_id, original_transaction_id, user_id,
    product_id, app_account_token, purchase_date, expires_date, quantity,
    last_event_id, last_notification_type,
    last_notification_signed_date, last_transaction_signed_date,
    active, revocation_percentage, credits_withheld,
    pending_credits_withheld, updated_at, legacy_binding_used
  ) values (
    v_environment, v_transaction_id, v_original_transaction_id, p_user_id,
    v_product_id, p_app_account_token, p_purchase_date, p_expires_date, 1,
    p_event_id, v_notification_type, p_notification_signed_date,
    p_transaction_signed_date, v_notification_type = 'REFUND',
    v_resulting_percentage, v_target_credits_affected,
    v_target_pending_credits, now(), v_legacy_binding_used
  )
  on conflict (environment, transaction_id) do update
    set last_event_id = excluded.last_event_id,
        last_notification_type = excluded.last_notification_type,
        last_notification_signed_date = excluded.last_notification_signed_date,
        last_transaction_signed_date = excluded.last_transaction_signed_date,
        active = excluded.active,
        revocation_percentage = excluded.revocation_percentage,
        credits_withheld = excluded.credits_withheld,
        pending_credits_withheld = excluded.pending_credits_withheld,
        updated_at = excluded.updated_at;

  if v_notification_type = 'REFUND' then
    -- Make the existing reconciler authoritative immediately. It intentionally
    -- preserves future profile dates, so expire only the exact refunded period;
    -- any newer Apple/Google entitlement is restored by the same reconciliation.
    update public.profiles
       set subscription_end_date =
             least(subscription_end_date, clock_timestamp())
     where id = p_user_id
       and lower(coalesce(plan, 'free')) in ('lite', 'pro', 'max')
       and subscription_end_date is not null
       and subscription_end_date <= p_expires_date + interval '5 minutes';
  end if;
  v_subscription_end :=
    public.x5_reconcile_paid_plan_profile(p_user_id);

  return jsonb_build_object(
    'status', 'applied',
    'credits_affected', case
      when v_notification_type = 'REFUND_REVERSED'
        then v_prior_credits_affected
      else v_target_credits_affected
    end,
    'credits_delta', v_credits_delta,
    'subscription_end_date', v_subscription_end
  );
end;
$function$;

alter function public.x5_apply_verified_app_store_legacy_plan_refund(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) owner to postgres;
revoke execute on function public.x5_apply_verified_app_store_legacy_plan_refund(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) from public, anon, authenticated, service_role;

alter function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) rename to x5_app_store_server_notification_pre_legacy_plan_refund;
revoke execute on function
  public.x5_app_store_server_notification_pre_legacy_plan_refund(
    uuid, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
  ) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_server_notification(
  p_event_id uuid,
  p_notification_type text,
  p_notification_signed_date timestamptz,
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
  p_transaction_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_revocation_percentage integer,
  p_quantity integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if nullif(btrim(p_product_id), '') in (
    'com.x5studio.app.lite.monthly',
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.max.monthly'
  ) then
    return public.x5_apply_verified_app_store_legacy_plan_refund(
      p_event_id, p_notification_type, p_notification_signed_date,
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_transaction_signed_date, p_revocation_date,
      p_revocation_percentage, p_quantity
    );
  end if;
  return public.x5_app_store_server_notification_pre_legacy_plan_refund(
    p_event_id, p_notification_type, p_notification_signed_date,
    p_user_id, p_transaction_id, p_original_transaction_id,
    p_product_id, p_environment, p_app_account_token, p_purchase_date,
    p_expires_date, p_transaction_signed_date, p_revocation_date,
    p_revocation_percentage, p_quantity
  );
end;
$function$;

alter function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) owner to postgres;
revoke execute on function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) to service_role;

-- If a verified refund arrives before its signed purchase grant, record the
-- purchase in the immutable ledger and convert the pending nominal hold to the
-- exact credits_granted value written by that row, in the same transaction.
alter function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) rename to x5_app_store_legacy_plan_grant_pre_refund;
revoke execute on function public.x5_app_store_legacy_plan_grant_pre_refund(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_transaction(
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
as $function$
declare
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text :=
    nullif(btrim(p_original_transaction_id), '');
  v_resolved_user_id uuid;
  v_canonical_app_account_token uuid :=
    coalesce(p_app_account_token, p_user_id);
  v_effective_app_account_token uuid := p_app_account_token;
  v_nil_token_sentinel boolean := false;
  projection public.app_store_server_notification_state%rowtype;
  source public.app_store_transactions%rowtype;
  v_projection_found boolean := false;
  v_target_withheld integer := 0;
  v_result jsonb;
  v_subscription_end timestamptz;
begin
  if v_product_id not in (
    'com.x5studio.app.lite.monthly',
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.max.monthly'
  ) then
    return public.x5_app_store_legacy_plan_grant_pre_refund(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_signed_date, p_revocation_date
    );
  end if;
  if v_environment is distinct from 'Production' then
    raise exception using errcode = '22023',
      message = 'invalid_legacy_plan_environment';
  end if;

  -- Retain the pre-existing nil-token restore for an exact legacy iap row
  -- that predates the private binding table. No notification can target this
  -- path because notification resolution requires a frozen sentinel binding.
  if p_app_account_token is null and not exists (
    select 1
      from public.app_store_legacy_bindings as binding
     where binding.original_transaction_id = v_original_transaction_id
  ) then
    return public.x5_app_store_legacy_plan_grant_pre_refund(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_signed_date, p_revocation_date
    );
  end if;

  -- A mismatch-token grant and refund both acquire the grandfather binding
  -- before the profile. Keeping one global order avoids binding/profile
  -- deadlocks when Apple delivers purchase and refund concurrently.
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      v_environment, v_original_transaction_id, v_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;
  select exists (
    select 1
      from public.app_store_legacy_bindings as binding
     where binding.original_transaction_id = v_original_transaction_id
       and binding.user_id = p_user_id
       and binding.product_id = v_product_id
       and binding.app_account_token = binding.user_id
  ) into v_nil_token_sentinel;
  if v_nil_token_sentinel then
    -- Event/state tables keep a non-null user sentinel. The underlying grant
    -- engine must retain Apple's real NULL so repeated nil-token renewals keep
    -- both legacy token columns NULL.
    v_effective_app_account_token := null;
  end if;

  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-transaction:' || coalesce(v_transaction_id, ''), 0
    )
  );
  select state.* into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  v_projection_found := found;
  if v_projection_found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          v_original_transaction_id
       or projection.product_id <> v_product_id
       or projection.app_account_token <>
          v_canonical_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date <> p_expires_date
       or projection.quantity is distinct from 1 then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    delete from public.app_store_server_notification_state
     where environment = projection.environment
       and transaction_id = projection.transaction_id;
  end if;

  v_result := public.x5_app_store_legacy_plan_grant_pre_refund(
    p_user_id, p_transaction_id, p_original_transaction_id,
    p_product_id, p_environment, v_effective_app_account_token, p_purchase_date,
    p_expires_date, p_signed_date, p_revocation_date
  );

  if v_nil_token_sentinel then
    update public.app_store_legacy_bindings
       set bound_at = coalesce(bound_at, clock_timestamp())
     where original_transaction_id = v_original_transaction_id
       and user_id = p_user_id
       and product_id = v_product_id
       and app_account_token = p_user_id;
  end if;

  if v_projection_found then
    select purchase.* into source
      from public.app_store_transactions as purchase
     where purchase.transaction_id = v_transaction_id
     for update;
    if not found
       or source.user_id <> p_user_id
       or source.original_transaction_id <>
          v_original_transaction_id
       or source.product_id <> v_product_id
       or source.environment <> v_environment
       or source.purchase_date <> p_purchase_date
       or source.expires_date <> p_expires_date
       or source.is_verified_product then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;

    if projection.active and projection.pending_credits_withheld > 0 then
      v_target_withheld := ceil(
        source.credits_granted::numeric *
        projection.revocation_percentage::numeric / 100000
      )::integer;
      if v_target_withheld > 0 then
        update public.profiles
           set credits = coalesce(credits, 0) - v_target_withheld
         where id = p_user_id;
        insert into public.app_store_server_notification_grant_adjustments (
          environment, transaction_id, event_id, user_id, product_id,
          credits_withheld, credits_delta
        ) values (
          projection.environment, projection.transaction_id,
          projection.last_event_id, projection.user_id,
          projection.product_id, v_target_withheld, -v_target_withheld
        );
      end if;
      projection.credits_withheld := v_target_withheld;
      projection.pending_credits_withheld := 0;
      v_result := v_result || jsonb_build_object(
        'credits_granted', greatest(
          source.credits_granted - v_target_withheld, 0
        )
      );
    end if;

    insert into public.app_store_server_notification_state (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, expires_date, quantity,
      last_event_id, last_notification_type,
      last_notification_signed_date, last_transaction_signed_date,
      active, revocation_percentage, credits_withheld,
      pending_credits_withheld, updated_at, legacy_binding_used
    ) values (
      projection.environment, projection.transaction_id,
      projection.original_transaction_id, projection.user_id,
      projection.product_id, projection.app_account_token,
      projection.purchase_date, projection.expires_date,
      projection.quantity, projection.last_event_id,
      projection.last_notification_type,
      projection.last_notification_signed_date,
      projection.last_transaction_signed_date, projection.active,
      projection.revocation_percentage, projection.credits_withheld,
      projection.pending_credits_withheld, projection.updated_at,
      projection.legacy_binding_used
    );

    if projection.active then
      update public.profiles
         set subscription_end_date =
               least(subscription_end_date, clock_timestamp())
       where id = p_user_id
         and lower(coalesce(plan, 'free')) in ('lite', 'pro', 'max')
         and subscription_end_date is not null
         and subscription_end_date <= p_expires_date + interval '5 minutes';
    end if;
    v_subscription_end :=
      public.x5_reconcile_paid_plan_profile(p_user_id);
    v_result := v_result || jsonb_build_object(
      'subscription_end_date', v_subscription_end
    );
  end if;
  return v_result;
end;
$function$;

alter function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) owner to postgres;
revoke execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

comment on function public.x5_apply_verified_app_store_legacy_plan_refund(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) is
  'Private Production-only exact-once Apple V2 refund/reversal engine for legacy paid subscription periods.';

commit;
