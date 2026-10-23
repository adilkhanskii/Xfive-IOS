begin;

-- Apple still sends signed V2 notifications for the paid subscription
-- products used by the public build 179. Reuse the existing private lifecycle
-- ledger for immutable event identity, but keep the grant itself in the
-- established per-transaction exact-once engine.
alter table public.app_store_verified_lifecycle_events
  drop constraint app_store_verified_lifecycle_events_identity;
alter table public.app_store_verified_lifecycle_events
  add constraint app_store_verified_lifecycle_events_identity
    check (
      environment in ('Production', 'Sandbox')
      and btrim(transaction_id) <> ''
      and btrim(original_transaction_id) <> ''
      and product_id in (
        'com.x5studio.app.lite.monthly',
        'com.x5studio.app.pro.monthly',
        'com.x5studio.app.max.monthly',
        'com.x5studio.app.verified.monthly'
      )
      and (
        product_id = 'com.x5studio.app.verified.monthly'
        or environment = 'Production'
      )
      and (
        (
          not legacy_binding_used
          and app_account_token = user_id
        ) or (
          legacy_binding_used
          and environment = 'Production'
          and app_account_token <> user_id
        )
      )
    );

create function public.x5_apply_verified_app_store_legacy_plan_lifecycle(
  p_event_id uuid,
  p_notification_type text,
  p_notification_subtype text,
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
  p_renewal_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_grace_period_expires_date timestamptz,
  p_auto_renew_status integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
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
  v_resolved_user_id uuid;
  v_legacy_binding_used boolean;
  v_result jsonb := '{}'::jsonb;
  v_status text;
  existing public.app_store_verified_lifecycle_events%rowtype;
begin
  if p_event_id is null then
    raise exception using errcode = '22023', message = 'invalid_event_id';
  end if;
  if v_notification_type not in ('SUBSCRIBED', 'DID_RENEW') then
    raise exception using errcode = '22023',
      message = 'legacy_plan_unsupported_notification_type';
  end if;
  if v_environment is distinct from 'Production' then
    raise exception using errcode = '22023',
      message = 'invalid_legacy_plan_environment';
  end if;
  if v_product_id is null or v_product_id not in (
    'com.x5studio.app.lite.monthly',
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.max.monthly'
  ) then
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
  if p_user_id is null or p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_revocation_date is not null
     or p_grace_period_expires_date is not null then
    raise exception using errcode = '22023',
      message = 'invalid_legacy_plan_grant_shape';
  end if;
  if p_auto_renew_status is not null
     and p_auto_renew_status not in (0, 1) then
    raise exception using errcode = '22023',
      message = 'invalid_auto_renew_status';
  end if;
  if p_purchase_date is null or p_expires_date is null
     or p_transaction_signed_date is null
     or p_renewal_signed_date is null
     or p_notification_signed_date is null then
    raise exception using errcode = '22023',
      message = 'missing_transaction_dates';
  end if;
  if p_expires_date <= p_purchase_date
     or p_purchase_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date > clock_timestamp() + interval '10 minutes'
     or p_renewal_signed_date > clock_timestamp() + interval '10 minutes'
     or p_notification_signed_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date < p_purchase_date - interval '5 minutes'
     or p_renewal_signed_date < p_purchase_date - interval '5 minutes'
     or p_notification_signed_date <
        p_transaction_signed_date - interval '5 minutes'
     or p_notification_signed_date <
        p_renewal_signed_date - interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid_signed_date';
  end if;

  -- The resolver either proves appAccountToken == profile UUID or locks the
  -- one exact grandfather binding for this original transaction chain.
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      v_environment, v_original_transaction_id, v_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;
  v_legacy_binding_used := p_app_account_token <> p_user_id;

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
       or existing.revocation_date is not null
       or existing.grace_period_expires_date is not null
       or existing.auto_renew_status is distinct from p_auto_renew_status
       or existing.legacy_binding_used is distinct from
          v_legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'lifecycle_event_id_conflict';
    end if;
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', existing.expires_date,
      'is_verified', false
    );
  end if;

  if p_expires_date <= clock_timestamp() then
    v_status := 'ignored_stale';
  else
    v_result := public.apply_verified_app_store_transaction(
      p_user_id, v_transaction_id, v_original_transaction_id,
      v_product_id, v_environment, p_app_account_token,
      p_purchase_date, p_expires_date, p_transaction_signed_date, null
    );
    v_status := coalesce(v_result ->> 'status', 'applied');
  end if;
  if v_status not in ('applied', 'already_applied', 'ignored_stale') then
    raise exception using errcode = '22023',
      message = 'invalid_lifecycle_result';
  end if;

  insert into public.app_store_verified_lifecycle_events (
    event_id, notification_type, notification_subtype,
    notification_signed_date, transaction_signed_date,
    renewal_signed_date, environment, transaction_id,
    original_transaction_id, user_id, product_id, app_account_token,
    purchase_date, expires_date, revocation_date,
    grace_period_expires_date, auto_renew_status, applied,
    result_status, legacy_binding_used
  ) values (
    p_event_id, v_notification_type, v_notification_subtype,
    p_notification_signed_date, p_transaction_signed_date,
    p_renewal_signed_date, v_environment, v_transaction_id,
    v_original_transaction_id, p_user_id, v_product_id,
    p_app_account_token, p_purchase_date, p_expires_date, null,
    null, p_auto_renew_status, v_status = 'applied', v_status,
    v_legacy_binding_used
  );

  return jsonb_build_object(
    'status', v_status,
    'credits_granted', case when v_status = 'applied'
      then coalesce((v_result ->> 'credits_granted')::integer, 0)
      else 0 end,
    'subscription_end_date', p_expires_date,
    'is_verified', false
  );
end;
$function$;

alter function public.x5_apply_verified_app_store_legacy_plan_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) owner to postgres;
revoke execute on function
  public.x5_apply_verified_app_store_legacy_plan_lifecycle(
    uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz,
    timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;

-- Preserve the already-audited verified-badge implementation unchanged and
-- put a narrow product switch in front of it.
alter function public.apply_verified_app_store_subscription_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) rename to x5_apply_verified_app_store_badge_lifecycle_internal;

revoke execute on function
  public.x5_apply_verified_app_store_badge_lifecycle_internal(
    uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz,
    timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_subscription_lifecycle(
  p_event_id uuid,
  p_notification_type text,
  p_notification_subtype text,
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
  p_renewal_signed_date timestamptz,
  p_revocation_date timestamptz,
  p_grace_period_expires_date timestamptz,
  p_auto_renew_status integer
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
    return public.x5_apply_verified_app_store_legacy_plan_lifecycle(
      p_event_id, p_notification_type, p_notification_subtype,
      p_notification_signed_date, p_user_id, p_transaction_id,
      p_original_transaction_id, p_product_id, p_environment,
      p_app_account_token, p_purchase_date, p_expires_date,
      p_transaction_signed_date, p_renewal_signed_date,
      p_revocation_date, p_grace_period_expires_date,
      p_auto_renew_status
    );
  end if;
  return public.x5_apply_verified_app_store_badge_lifecycle_internal(
    p_event_id, p_notification_type, p_notification_subtype,
    p_notification_signed_date, p_user_id, p_transaction_id,
    p_original_transaction_id, p_product_id, p_environment,
    p_app_account_token, p_purchase_date, p_expires_date,
    p_transaction_signed_date, p_renewal_signed_date,
    p_revocation_date, p_grace_period_expires_date,
    p_auto_renew_status
  );
end;
$function$;

alter function public.apply_verified_app_store_subscription_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) owner to postgres;
revoke execute on function public.apply_verified_app_store_subscription_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_subscription_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) to service_role;

comment on function public.x5_apply_verified_app_store_legacy_plan_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) is
  'Private exact-once bridge from verified Apple V2 initial-buy and renewal notifications to the existing transaction ledger.';

commit;
