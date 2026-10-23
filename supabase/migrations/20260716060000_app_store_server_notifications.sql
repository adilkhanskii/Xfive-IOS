begin;

-- Refunds must be able to create credit debt after a user has already spent
-- the original pack. The older retention trigger collapsed every non-positive
-- balance to zero, silently forgiving that debt. Keep zero/negative balances
-- non-expiring, but preserve the signed amount for the spending guards.
create or replace function public.x5_prepare_credit_retention()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  retention_months integer;
  active_verified boolean;
  credits_changed boolean;
  verified_changed boolean;
begin
  active_verified := public.x5_profile_has_active_verified_badge(
    new.is_verified,
    new.verified_until
  );
  retention_months := case when active_verified then 3 else 1 end;
  new.credits_retention_months := retention_months;

  if tg_op = 'INSERT' then
    credits_changed := true;
    verified_changed := false;
  else
    credits_changed := coalesce(new.credits, 0) <>
      coalesce(old.credits, 0);
    verified_changed :=
      coalesce(new.is_verified, false) <> coalesce(old.is_verified, false)
      or coalesce(new.verified_until, '-infinity'::timestamptz) <>
         coalesce(old.verified_until, '-infinity'::timestamptz);
  end if;

  if coalesce(new.credits, 0) <= 0 then
    new.credits_expires_at := null;
  elsif credits_changed or verified_changed
        or new.credits_expires_at is null then
    new.credits_expires_at :=
      now() + make_interval(months => retention_months);
  end if;

  return new;
end;
$function$;

-- Every verified App Store Server Notification is retained exactly once. The
-- ledger is immutable; the adjacent projection is the sole mutable current
-- state for one Apple environment/transaction pair.
create table public.app_store_server_notification_events (
  event_id uuid primary key,
  notification_type text not null,
  notification_signed_date timestamptz not null,
  transaction_signed_date timestamptz not null,
  environment text not null,
  transaction_id text not null,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz,
  revocation_date timestamptz,
  revocation_percentage integer,
  quantity integer,
  applied boolean not null,
  resulting_revocation_percentage integer not null,
  credits_affected integer not null,
  pending_credits_affected integer not null,
  credits_delta integer not null,
  created_at timestamptz not null default now(),
  constraint app_store_server_notification_events_type
    check (notification_type in ('REFUND', 'REFUND_REVERSED')),
  constraint app_store_server_notification_events_environment
    check (environment in ('Production', 'Sandbox')),
  constraint app_store_server_notification_events_transaction_nonempty
    check (btrim(transaction_id) <> '' and btrim(original_transaction_id) <> ''),
  constraint app_store_server_notification_events_account_matches_user
    check (app_account_token = user_id),
  constraint app_store_server_notification_events_known_product
    check (product_id in (
      'com.x5studio.app.credits.1000',
      'com.x5studio.app.credits.2000',
      'com.x5studio.app.credits.5000',
      'com.x5studio.app.verified.monthly'
    )),
  constraint app_store_server_notification_events_product_shape
    check (
      (
        product_id like 'com.x5studio.app.credits.%'
        and quantity = 1
        and expires_date is null
      ) or (
        product_id = 'com.x5studio.app.verified.monthly'
        and quantity is null
        and expires_date > purchase_date
      )
    ),
  constraint app_store_server_notification_events_refund_shape
    check (
      (
        notification_type = 'REFUND'
        and revocation_date is not null
        and revocation_percentage between 1 and 100000
      ) or (
        notification_type = 'REFUND_REVERSED'
        and revocation_date is null
        and revocation_percentage is null
      )
    ),
  constraint app_store_server_notification_events_economics
    check (
      resulting_revocation_percentage between 0 and 100000
      and credits_affected between 0 and 5000
      and pending_credits_affected between 0 and 5000
      and (credits_affected = 0 or pending_credits_affected = 0)
      and abs(credits_delta) <= 5000
    )
);

create index app_store_server_notification_events_transaction_idx
  on public.app_store_server_notification_events (
    environment, transaction_id, transaction_signed_date desc,
    notification_signed_date desc
  );
create index app_store_server_notification_events_user_idx
  on public.app_store_server_notification_events (user_id, created_at desc);

create table public.app_store_server_notification_state (
  environment text not null,
  transaction_id text not null,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz,
  quantity integer,
  last_event_id uuid not null
    references public.app_store_server_notification_events(event_id)
    on delete restrict,
  last_notification_type text not null,
  last_notification_signed_date timestamptz not null,
  last_transaction_signed_date timestamptz not null,
  active boolean not null,
  revocation_percentage integer not null,
  credits_withheld integer not null,
  pending_credits_withheld integer not null,
  updated_at timestamptz not null default now(),
  primary key (environment, transaction_id),
  constraint app_store_server_notification_state_environment
    check (environment in ('Production', 'Sandbox')),
  constraint app_store_server_notification_state_identity
    check (
      btrim(transaction_id) <> ''
      and btrim(original_transaction_id) <> ''
      and app_account_token = user_id
    ),
  constraint app_store_server_notification_state_type
    check (last_notification_type in ('REFUND', 'REFUND_REVERSED')),
  constraint app_store_server_notification_state_projection
    check (
      revocation_percentage between 0 and 100000
      and credits_withheld between 0 and 5000
      and pending_credits_withheld between 0 and 5000
      and (credits_withheld = 0 or pending_credits_withheld = 0)
      and (
        (active and last_notification_type = 'REFUND'
          and revocation_percentage > 0)
        or (not active and last_notification_type = 'REFUND_REVERSED'
          and revocation_percentage = 0 and credits_withheld = 0
          and pending_credits_withheld = 0)
      )
    )
);

-- When a verified refund beats the matching consumable grant, the projection
-- holds a pending amount. The later grant applies that amount exactly once and
-- records the balance delta here without mutating the Apple notification event.
create table public.app_store_server_notification_grant_adjustments (
  environment text not null,
  transaction_id text not null,
  event_id uuid not null
    references public.app_store_server_notification_events(event_id)
    on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  credits_withheld integer not null,
  credits_delta integer not null,
  created_at timestamptz not null default now(),
  primary key (environment, transaction_id),
  constraint app_store_server_notification_grant_adjustment_environment
    check (environment in ('Production', 'Sandbox')),
  constraint app_store_server_notification_grant_adjustment_economics
    check (
      credits_withheld between 1 and 5000
      and credits_delta = -credits_withheld
    )
);

alter table public.app_store_server_notification_events owner to postgres;
alter table public.app_store_server_notification_state owner to postgres;
alter table public.app_store_server_notification_grant_adjustments
  owner to postgres;
alter table public.app_store_server_notification_events enable row level security;
alter table public.app_store_server_notification_events force row level security;
alter table public.app_store_server_notification_state enable row level security;
alter table public.app_store_server_notification_state force row level security;
alter table public.app_store_server_notification_grant_adjustments
  enable row level security;
alter table public.app_store_server_notification_grant_adjustments
  force row level security;

revoke all privileges on table public.app_store_server_notification_events
  from public, anon, authenticated;
revoke all privileges on table public.app_store_server_notification_events
  from service_role;
revoke all privileges on table public.app_store_server_notification_state
  from public, anon, authenticated;
revoke all privileges on table public.app_store_server_notification_state
  from service_role;
revoke all privileges on table
  public.app_store_server_notification_grant_adjustments
  from public, anon, authenticated, service_role;

create function public.x5_reject_app_store_notification_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  raise exception using errcode = '22023',
    message = 'app_store_notification_events_append_only';
end;
$function$;

-- Keep the established validators/grant engines, but put the canonical
-- notification projection in front of each public grant RPC. A reversed
-- projection overrides an old legacy tombstone; the legacy row is removed and
-- restored inside the same transaction only while the immutable engine runs.
alter function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) rename to x5_app_store_consumable_grant_legacy;

revoke execute on function public.x5_app_store_consumable_grant_legacy(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_consumable(
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
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  legacy public.app_store_consumable_refunds%rowtype;
  v_removed boolean := false;
  projection public.app_store_server_notification_state%rowtype;
  v_projection_removed boolean := false;
  v_expected_credits integer;
  v_result jsonb;
begin
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-consumable:' || v_environment || ':' || v_transaction_id, 0
    )
  );

  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  if found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          nullif(btrim(p_original_transaction_id), '')
       or projection.product_id <> nullif(btrim(p_product_id), '')
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date is not null
       or projection.quantity is distinct from p_quantity then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    if projection.active then
      -- The refund may have arrived before this grant. Its exact withheld
      -- amount is either already reflected in the profile or still pending.
      -- Temporarily hide the projection while the immutable grant engine
      -- records the full pack, then apply a pending hold exactly once.
      delete from public.app_store_server_notification_state
       where environment = projection.environment
         and transaction_id = projection.transaction_id;
      v_projection_removed := true;
    end if;
  elsif public.x5_app_store_notification_refund_active(
    v_environment, v_transaction_id
  ) then
    -- Until the first canonical server projection exists, the immutable
    -- device-refund row remains an active full tombstone.
    return jsonb_build_object(
      'status', 'already_applied', 'credits_granted', 0,
      'subscription_end_date', null, 'is_verified', false
    );
  end if;

  select refund.* into legacy
    from public.app_store_consumable_refunds as refund
   where refund.environment = v_environment
     and refund.transaction_id = v_transaction_id
   for update;
  if found then
    delete from public.app_store_consumable_refunds
     where environment = legacy.environment
       and transaction_id = legacy.transaction_id;
    v_removed := true;
  end if;

  v_result := public.x5_app_store_consumable_grant_legacy(
    p_user_id, p_transaction_id, p_original_transaction_id, p_product_id,
    p_environment, p_app_account_token, p_purchase_date, p_signed_date,
    p_revocation_date, p_quantity
  );

  if v_removed then
    insert into public.app_store_consumable_refunds (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, signed_date,
      revocation_date, quantity, credits_reversed, created_at
    ) values (
      legacy.environment, legacy.transaction_id,
      legacy.original_transaction_id, legacy.user_id, legacy.product_id,
      legacy.app_account_token, legacy.purchase_date, legacy.signed_date,
      legacy.revocation_date, legacy.quantity, legacy.credits_reversed,
      legacy.created_at
    );
  end if;

  if v_projection_removed then
    if v_result ->> 'status' = 'applied' then
      v_expected_credits := case nullif(btrim(p_product_id), '')
        when 'com.x5studio.app.credits.1000' then 1000
        when 'com.x5studio.app.credits.2000' then 2000
        when 'com.x5studio.app.credits.5000' then 5000
        else 0
      end;

      if projection.pending_credits_withheld > 0 then
        update public.profiles
           set credits = coalesce(credits, 0) -
             projection.pending_credits_withheld
         where id = p_user_id;
        insert into
          public.app_store_server_notification_grant_adjustments (
            environment, transaction_id, event_id, user_id, product_id,
            credits_withheld, credits_delta
          ) values (
            projection.environment, projection.transaction_id,
            projection.last_event_id, projection.user_id,
            projection.product_id, projection.pending_credits_withheld,
            -projection.pending_credits_withheld
          );
        projection.credits_withheld :=
          projection.pending_credits_withheld;
        projection.pending_credits_withheld := 0;
      end if;

      v_result := v_result || jsonb_build_object(
        'credits_granted', greatest(
          v_expected_credits - projection.credits_withheld,
          0
        )
      );
    end if;

    insert into public.app_store_server_notification_state (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, expires_date, quantity,
      last_event_id, last_notification_type,
      last_notification_signed_date, last_transaction_signed_date,
      active, revocation_percentage, credits_withheld,
      pending_credits_withheld, updated_at
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
      projection.pending_credits_withheld, projection.updated_at
    );
  end if;
  return v_result;
end;
$function$;

alter function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) rename to x5_app_store_sandbox_grant_legacy;

revoke execute on function public.x5_app_store_sandbox_grant_legacy(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_sandbox_review_transaction(
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
  v_product_id text := nullif(btrim(p_product_id), '');
  legacy public.app_store_consumable_refunds%rowtype;
  v_removed boolean := false;
  projection public.app_store_server_notification_state%rowtype;
  v_projection_removed boolean := false;
  v_expected_credits integer;
  v_result jsonb;
  v_verified_until timestamptz;
begin
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      case when v_product_id = 'com.x5studio.app.verified.monthly'
        then 'app-store-sandbox-review:' || v_transaction_id
        else 'app-store-consumable:Sandbox:' || v_transaction_id end,
      0
    )
  );

  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = 'Sandbox'
     and state.transaction_id = v_transaction_id
   for update;
  if found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          nullif(btrim(p_original_transaction_id), '')
       or projection.product_id <> v_product_id
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date is distinct from p_expires_date
       or projection.quantity is distinct from p_quantity then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    if projection.active and
       v_product_id = 'com.x5studio.app.verified.monthly' then
      v_verified_until :=
        public.x5_rebuild_app_store_verified_profile(p_user_id);
      return jsonb_build_object(
        'status', 'already_applied', 'credits_granted', 0,
        'subscription_end_date', v_verified_until,
        'is_verified', v_verified_until is not null
      );
    elsif projection.active then
      delete from public.app_store_server_notification_state
       where environment = projection.environment
         and transaction_id = projection.transaction_id;
      v_projection_removed := true;
    end if;
  elsif public.x5_app_store_notification_refund_active(
    'Sandbox', v_transaction_id
  ) then
    return jsonb_build_object(
      'status', 'already_applied', 'credits_granted', 0,
      'subscription_end_date', null, 'is_verified', false
    );
  end if;

  if v_product_id <> 'com.x5studio.app.verified.monthly' then
    select refund.* into legacy
      from public.app_store_consumable_refunds as refund
     where refund.environment = 'Sandbox'
       and refund.transaction_id = v_transaction_id
     for update;
    if found then
      delete from public.app_store_consumable_refunds
       where environment = legacy.environment
         and transaction_id = legacy.transaction_id;
      v_removed := true;
    end if;
  end if;

  v_result := public.x5_app_store_sandbox_grant_legacy(
    p_user_id, p_transaction_id, p_original_transaction_id, p_product_id,
    p_environment, p_app_account_token, p_purchase_date, p_expires_date,
    p_signed_date, p_revocation_date, p_quantity
  );

  if v_removed then
    insert into public.app_store_consumable_refunds (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, signed_date,
      revocation_date, quantity, credits_reversed, created_at
    ) values (
      legacy.environment, legacy.transaction_id,
      legacy.original_transaction_id, legacy.user_id, legacy.product_id,
      legacy.app_account_token, legacy.purchase_date, legacy.signed_date,
      legacy.revocation_date, legacy.quantity, legacy.credits_reversed,
      legacy.created_at
    );
  end if;

  if v_projection_removed then
    if v_result ->> 'status' = 'applied' then
      v_expected_credits := case v_product_id
        when 'com.x5studio.app.credits.1000' then 1000
        when 'com.x5studio.app.credits.2000' then 2000
        when 'com.x5studio.app.credits.5000' then 5000
        else 0
      end;
      if projection.pending_credits_withheld > 0 then
        update public.profiles
           set credits = coalesce(credits, 0) -
             projection.pending_credits_withheld
         where id = p_user_id;
        insert into
          public.app_store_server_notification_grant_adjustments (
            environment, transaction_id, event_id, user_id, product_id,
            credits_withheld, credits_delta
          ) values (
            projection.environment, projection.transaction_id,
            projection.last_event_id, projection.user_id,
            projection.product_id, projection.pending_credits_withheld,
            -projection.pending_credits_withheld
          );
        projection.credits_withheld :=
          projection.pending_credits_withheld;
        projection.pending_credits_withheld := 0;
      end if;
      v_result := v_result || jsonb_build_object(
        'credits_granted', greatest(
          v_expected_credits - projection.credits_withheld,
          0
        )
      );
    end if;

    insert into public.app_store_server_notification_state (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, expires_date, quantity,
      last_event_id, last_notification_type,
      last_notification_signed_date, last_transaction_signed_date,
      active, revocation_percentage, credits_withheld,
      pending_credits_withheld, updated_at
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
      projection.pending_credits_withheld, projection.updated_at
    );
  end if;

  if v_product_id = 'com.x5studio.app.verified.monthly' then
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    v_result := v_result || jsonb_build_object(
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;
  return v_result;
end;
$function$;

alter function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) rename to x5_app_store_subscription_grant_legacy;

revoke execute on function public.x5_app_store_subscription_grant_legacy(
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
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_result jsonb;
  v_verified_until timestamptz;
begin
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-transaction:' || v_transaction_id, 0
    )
  );

  if v_product_id = 'com.x5studio.app.verified.monthly'
     and public.x5_app_store_notification_refund_active(
       'Production', v_transaction_id
     ) then
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    return jsonb_build_object(
      'status', 'already_applied', 'credits_granted', 0,
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;

  v_result := public.x5_app_store_subscription_grant_legacy(
    p_user_id, p_transaction_id, p_original_transaction_id, p_product_id,
    p_environment, p_app_account_token, p_purchase_date, p_expires_date,
    p_signed_date, p_revocation_date
  );
  if v_product_id = 'com.x5studio.app.verified.monthly' then
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    v_result := v_result || jsonb_build_object(
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;
  return v_result;
end;
$function$;

-- StoreKit reconciliation already calls these two RPCs with independently
-- verified JWS payloads. Bridge them into the same projection so a device sync
-- and Apple's webhook can never deduct twice. The older ledgers remain as an
-- immutable compatibility/audit baseline.
create or replace function public.apply_verified_app_store_consumable_refund(
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
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_had_legacy boolean;
  v_result jsonb;
  v_status text;
  v_credits_reversed integer;
  projection public.app_store_server_notification_state%rowtype;
begin
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-consumable:' || v_environment || ':' || v_transaction_id, 0
    )
  );

  -- The device transaction JWS does not expose the cumulative refund
  -- percentage. Once an App Store Server Notification projection exists, it
  -- is authoritative and a later re-sign on the device must not inflate a
  -- partial refund to 100 percent.
  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  if found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          nullif(btrim(p_original_transaction_id), '')
       or projection.product_id <> nullif(btrim(p_product_id), '')
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date is not null
       or projection.quantity is distinct from p_quantity then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', null,
      'is_verified', false
    );
  end if;

  select exists (
    select 1 from public.app_store_consumable_refunds as refund
     where refund.environment = v_environment
       and refund.transaction_id = v_transaction_id
  ) into v_had_legacy;

  v_result := public.apply_verified_app_store_server_notification(
    md5(
      'storekit-consumable-refund|' || coalesce(v_environment, '') || '|' ||
      coalesce(v_transaction_id, '') || '|' || coalesce(p_signed_date::text, '')
    )::uuid,
    'REFUND', p_signed_date, p_user_id, p_transaction_id,
    p_original_transaction_id, p_product_id, p_environment,
    p_app_account_token, p_purchase_date, null, p_signed_date,
    p_revocation_date, 100000, p_quantity
  );

  v_status := v_result ->> 'status';
  if v_status <> 'ignored_stale'
     and public.x5_app_store_notification_refund_active(
       v_environment, v_transaction_id
     ) then
    v_credits_reversed := coalesce(
      (v_result ->> 'credits_affected')::integer, 0
    );
    insert into public.app_store_consumable_refunds (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, signed_date,
      revocation_date, quantity, credits_reversed
    ) values (
      v_environment, v_transaction_id,
      nullif(btrim(p_original_transaction_id), ''), p_user_id,
      nullif(btrim(p_product_id), ''), p_app_account_token,
      p_purchase_date, p_signed_date, p_revocation_date, p_quantity,
      v_credits_reversed
    ) on conflict (environment, transaction_id) do nothing;
  end if;

  return jsonb_build_object(
    'status', case
      when v_had_legacy or v_status = 'ignored_stale'
        then 'already_applied'
      else v_status
    end,
    'credits_granted', 0,
    'subscription_end_date', null,
    'is_verified', false
  );
end;
$function$;

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
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_had_legacy boolean;
  v_result jsonb;
  v_status text;
  v_verified_until timestamptz;
  projection public.app_store_server_notification_state%rowtype;
begin
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      case when v_environment = 'Sandbox'
        then 'app-store-sandbox-review:' || v_transaction_id
        else 'app-store-transaction:' || v_transaction_id end,
      0
    )
  );

  -- Server notifications retain refund/reversal ordering and are therefore
  -- authoritative over the percentage-free on-device reconciliation path.
  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  if found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <>
          nullif(btrim(p_original_transaction_id), '')
       or projection.product_id <> nullif(btrim(p_product_id), '')
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date is distinct from p_expires_date
       or projection.quantity is not null then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_granted', 0,
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;

  select exists (
    select 1 from public.app_store_verified_revocations as revoked
     where revoked.environment = v_environment
       and revoked.transaction_id = v_transaction_id
  ) into v_had_legacy;

  v_result := public.apply_verified_app_store_server_notification(
    md5(
      'storekit-verified-refund|' || coalesce(v_environment, '') || '|' ||
      coalesce(v_transaction_id, '') || '|' || coalesce(p_signed_date::text, '')
    )::uuid,
    'REFUND', p_signed_date, p_user_id, p_transaction_id,
    p_original_transaction_id, p_product_id, p_environment,
    p_app_account_token, p_purchase_date, p_expires_date, p_signed_date,
    p_revocation_date, 100000, null
  );
  v_status := v_result ->> 'status';

  if v_status <> 'ignored_stale'
     and public.x5_app_store_notification_refund_active(
       v_environment, v_transaction_id
     ) then
    insert into public.app_store_verified_revocations (
      environment, transaction_id, original_transaction_id, user_id,
      product_id, app_account_token, purchase_date, expires_date,
      signed_date, revocation_date, credits_granted
    ) values (
      v_environment, v_transaction_id,
      nullif(btrim(p_original_transaction_id), ''), p_user_id,
      nullif(btrim(p_product_id), ''), p_app_account_token,
      p_purchase_date, p_expires_date, p_signed_date, p_revocation_date, 0
    ) on conflict (environment, transaction_id) do nothing;
  end if;

  v_verified_until :=
    public.x5_rebuild_app_store_verified_profile(p_user_id);
  return jsonb_build_object(
    'status', case
      when v_had_legacy or v_status = 'ignored_stale'
        then 'already_applied'
      else v_status
    end,
    'credits_granted', 0,
    'subscription_end_date', v_verified_until,
    'is_verified', v_verified_until is not null
  );
end;
$function$;

create trigger x5_app_store_notification_events_append_only
before update or delete on public.app_store_server_notification_events
for each row execute function
  public.x5_reject_app_store_notification_event_mutation();

create trigger x5_app_store_notification_grant_adjustments_append_only
before update or delete on
  public.app_store_server_notification_grant_adjustments
for each row execute function
  public.x5_reject_app_store_notification_event_mutation();

revoke execute on function
  public.x5_reject_app_store_notification_event_mutation()
  from public, anon, authenticated, service_role;

-- A server-notification projection, when present, is authoritative. Before
-- the first V2 notification, the two older immutable refund ledgers remain the
-- compatibility baseline.
create function public.x5_app_store_notification_refund_active(
  p_environment text,
  p_transaction_id text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_active boolean;
begin
  select projection.active
    into v_active
    from public.app_store_server_notification_state as projection
   where projection.environment = p_environment
     and projection.transaction_id = p_transaction_id;

  if found then
    return v_active;
  end if;

  return exists (
    select 1
      from public.app_store_consumable_refunds as legacy
     where legacy.environment = p_environment
       and legacy.transaction_id = p_transaction_id
  ) or exists (
    select 1
      from public.app_store_verified_revocations as legacy
     where legacy.environment = p_environment
       and legacy.transaction_id = p_transaction_id
  );
end;
$function$;

create function public.x5_rebuild_app_store_verified_profile(p_user_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_verified_until timestamptz;
begin
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
         and not public.x5_app_store_notification_refund_active(
           'Production', production.transaction_id
         )
      union all
      select sandbox.expires_date
        from public.app_store_sandbox_review_transactions as sandbox
       where sandbox.user_id = p_user_id
         and sandbox.product_id = 'com.x5studio.app.verified.monthly'
         and sandbox.is_verified_product
         and sandbox.credits_granted = 0
         and sandbox.expires_date > v_now
         and not public.x5_app_store_notification_refund_active(
           'Sandbox', sandbox.transaction_id
         )
      union all
      select android.subscription_end_date
        from public.iap_entitlements as android
       where android.user_id = p_user_id
         and lower(coalesce(android.platform, '')) = 'android'
         and android.product_id in (
           'x5_verified_monthly_v2', 'x5_verified_monthly'
         )
         and android.subscription_end_date > v_now
      union all
      select legacy_ios.subscription_end_date
        from public.iap_entitlements as legacy_ios
       where legacy_ios.user_id = p_user_id
         and lower(coalesce(legacy_ios.platform, '')) = 'ios'
         and legacy_ios.product_id in (
           'com.x5studio.app.verified.monthly', 'x5_verified_monthly'
         )
         and legacy_ios.subscription_end_date > v_now
         and not exists (
           select 1
             from public.app_store_server_notification_state as refund_state
            where refund_state.environment = 'Production'
              and refund_state.user_id = legacy_ios.user_id
              and refund_state.product_id =
                  'com.x5studio.app.verified.monthly'
              and refund_state.original_transaction_id =
                  legacy_ios.original_transaction_id
              and refund_state.transaction_id =
                  legacy_ios.last_transaction_id
              and refund_state.active
         )
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

  return v_verified_until;
end;
$function$;

revoke execute on function
  public.x5_app_store_notification_refund_active(text, text)
  from public, anon, authenticated, service_role;
revoke execute on function
  public.x5_rebuild_app_store_verified_profile(uuid)
  from public, anon, authenticated, service_role;

create function public.x5_guard_app_store_notification_grant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_lock_key text;
  projection public.app_store_server_notification_state%rowtype;
begin
  perform 1
    from public.profiles
   where id = new.user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  v_lock_key := case tg_table_name
    when 'app_store_consumable_transactions' then
      'app-store-consumable:' || new.environment || ':' || new.transaction_id
    when 'app_store_sandbox_review_transactions' then
      'app-store-sandbox-review:' || new.transaction_id
    else 'app-store-transaction:' || new.transaction_id
  end;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_lock_key, 0)
  );

  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = new.environment
     and state.transaction_id = new.transaction_id
   for update;

  if found then
    if projection.user_id <> new.user_id
       or projection.original_transaction_id <> new.original_transaction_id
       or projection.product_id <> new.product_id
       or projection.app_account_token is distinct from new.app_account_token
       or projection.purchase_date <> new.purchase_date
       or projection.expires_date is distinct from
          nullif(to_jsonb(new) ->> 'expires_date', '')::timestamptz
       or projection.quantity is distinct from
          nullif(to_jsonb(new) ->> 'quantity', '')::integer then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    if projection.active then
      raise exception using errcode = '22023',
        message = 'app_store_notification_refund_active';
    end if;
  elsif public.x5_app_store_notification_refund_active(
    new.environment, new.transaction_id
  ) then
    raise exception using errcode = '22023',
      message = 'app_store_notification_refund_active';
  end if;

  return new;
end;
$function$;

drop trigger if exists x5_guard_app_store_notification_refund
  on public.app_store_consumable_transactions;
create trigger x5_guard_app_store_notification_refund
before insert on public.app_store_consumable_transactions
for each row execute function public.x5_guard_app_store_notification_grant();

drop trigger if exists x5_guard_app_store_notification_refund
  on public.app_store_transactions;
create trigger x5_guard_app_store_notification_refund
before insert on public.app_store_transactions
for each row execute function public.x5_guard_app_store_notification_grant();

drop trigger if exists x5_guard_app_store_notification_refund
  on public.app_store_sandbox_review_transactions;
create trigger x5_guard_app_store_notification_refund
before insert on public.app_store_sandbox_review_transactions
for each row execute function public.x5_guard_app_store_notification_grant();

revoke execute on function public.x5_guard_app_store_notification_grant()
  from public, anon, authenticated, service_role;

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
declare
  v_notification_type text := upper(btrim(coalesce(p_notification_type, '')));
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text := nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_is_subscription boolean;
  v_expected_credits integer;
  v_lock_key text;
  v_source_found boolean := false;
  source record;
  existing_event public.app_store_server_notification_events%rowtype;
  projection public.app_store_server_notification_state%rowtype;
  legacy_refund public.app_store_consumable_refunds%rowtype;
  legacy_revocation public.app_store_verified_revocations%rowtype;
  v_projection_found boolean := false;
  v_legacy_found boolean := false;
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
  v_verified_until timestamptz;
  v_incoming_is_device boolean := false;
  v_prior_is_device boolean := false;
begin
  if p_event_id is null then
    raise exception using errcode = '22023', message = 'invalid_notification_uuid';
  end if;
  if v_notification_type not in ('REFUND', 'REFUND_REVERSED') then
    raise exception using errcode = '22023', message = 'invalid_notification_type';
  end if;
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
  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;
  if p_app_account_token <> p_user_id then
    raise exception using errcode = '22023', message = 'account_token_mismatch';
  end if;

  v_expected_credits := case v_product_id
    when 'com.x5studio.app.credits.1000' then 1000
    when 'com.x5studio.app.credits.2000' then 2000
    when 'com.x5studio.app.credits.5000' then 5000
    when 'com.x5studio.app.verified.monthly' then 0
    else null
  end;
  if v_expected_credits is null then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  v_is_subscription := v_product_id = 'com.x5studio.app.verified.monthly';
  v_incoming_is_device := p_event_id = md5(
    case when v_is_subscription
      then 'storekit-verified-refund|'
      else 'storekit-consumable-refund|' end ||
    coalesce(v_environment, '') || '|' ||
    coalesce(v_transaction_id, '') || '|' ||
    coalesce(p_transaction_signed_date::text, '')
  )::uuid;

  if p_purchase_date is null
     or p_transaction_signed_date is null
     or p_notification_signed_date is null then
    raise exception using errcode = '22023', message = 'missing_transaction_dates';
  end if;
  if p_purchase_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date > clock_timestamp() + interval '10 minutes'
     or p_notification_signed_date > clock_timestamp() + interval '10 minutes'
     or p_transaction_signed_date < p_purchase_date - interval '5 minutes'
     or p_notification_signed_date <
        p_transaction_signed_date - interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid_signed_date';
  end if;

  if v_is_subscription then
    if p_expires_date is null or p_expires_date <= p_purchase_date
       or p_quantity is not null then
      raise exception using errcode = '22023', message = 'invalid_product_shape';
    end if;
  elsif p_expires_date is not null or p_quantity is distinct from 1 then
    raise exception using errcode = '22023', message = 'invalid_product_shape';
  end if;

  if v_notification_type = 'REFUND' then
    if p_revocation_date is null
       or p_revocation_percentage is null
       or p_revocation_percentage not between 1 and 100000 then
      raise exception using errcode = '22023', message = 'invalid_revocation_percentage';
    end if;
    if p_revocation_date < p_purchase_date
       or p_revocation_date > clock_timestamp() + interval '10 minutes'
       or p_transaction_signed_date < p_revocation_date - interval '5 minutes' then
      raise exception using errcode = '22023', message = 'invalid_revocation_date';
    end if;
  elsif p_revocation_date is not null or p_revocation_percentage is not null then
    raise exception using errcode = '22023', message = 'invalid_refund_reversal';
  end if;

  -- Match every purchase/refund path: profile first, then the exact existing
  -- per-transaction advisory key.
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  v_lock_key := case
    when not v_is_subscription then
      'app-store-consumable:' || v_environment || ':' || v_transaction_id
    when v_environment = 'Sandbox' then
      'app-store-sandbox-review:' || v_transaction_id
    else 'app-store-transaction:' || v_transaction_id
  end;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_lock_key, 0)
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'app-store-notification:' || p_event_id::text, 0
    )
  );

  select event.*
    into existing_event
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
       or existing_event.expires_date is distinct from p_expires_date
       or existing_event.revocation_date is distinct from p_revocation_date
       or existing_event.revocation_percentage is distinct from
          p_revocation_percentage
       or existing_event.quantity is distinct from p_quantity then
      raise exception using errcode = '22023',
        message = 'notification_event_id_conflict';
    end if;
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_affected', existing_event.credits_affected,
      'credits_delta', 0
    );
  end if;

  select state.*
    into projection
    from public.app_store_server_notification_state as state
   where state.environment = v_environment
     and state.transaction_id = v_transaction_id
   for update;
  v_projection_found := found;

  if v_projection_found then
    if projection.user_id <> p_user_id
       or projection.original_transaction_id <> v_original_transaction_id
       or projection.product_id <> v_product_id
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date is distinct from p_expires_date
       or projection.quantity is distinct from p_quantity then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    v_prior_active := projection.active;
    v_prior_percentage := projection.revocation_percentage;
    v_prior_credits_affected := projection.credits_withheld;
    v_prior_pending_credits := projection.pending_credits_withheld;
    v_prior_transaction_signed_date :=
      projection.last_transaction_signed_date;
    v_prior_is_device := projection.last_event_id = md5(
      case when v_is_subscription
        then 'storekit-verified-refund|'
        else 'storekit-consumable-refund|' end ||
      coalesce(v_environment, '') || '|' ||
      coalesce(v_transaction_id, '') || '|' ||
      coalesce(projection.last_transaction_signed_date::text, '')
    )::uuid;
    select event.revocation_date
      into v_prior_revocation_date
      from public.app_store_server_notification_events as event
     where event.event_id = projection.last_event_id;
  elsif not v_is_subscription then
    select refund.*
      into legacy_refund
      from public.app_store_consumable_refunds as refund
     where refund.environment = v_environment
       and refund.transaction_id = v_transaction_id
     for update;
    v_legacy_found := found;
    if v_legacy_found then
      if legacy_refund.user_id <> p_user_id
         or legacy_refund.original_transaction_id <>
            v_original_transaction_id
         or legacy_refund.product_id <> v_product_id
         or legacy_refund.app_account_token <> p_app_account_token
         or legacy_refund.purchase_date <> p_purchase_date
         or legacy_refund.quantity <> p_quantity then
        raise exception using errcode = '22023',
          message = 'notification_source_mismatch';
      end if;
      v_prior_active := true;
      v_prior_percentage := 100000;
      v_prior_credits_affected := legacy_refund.credits_reversed;
      v_prior_transaction_signed_date := legacy_refund.signed_date;
      v_prior_revocation_date := legacy_refund.revocation_date;
    end if;
  else
    select revoked.*
      into legacy_revocation
      from public.app_store_verified_revocations as revoked
     where revoked.environment = v_environment
       and revoked.transaction_id = v_transaction_id
     for update;
    v_legacy_found := found;
    if v_legacy_found then
      if legacy_revocation.user_id <> p_user_id
         or legacy_revocation.original_transaction_id <>
            v_original_transaction_id
         or legacy_revocation.product_id <> v_product_id
         or legacy_revocation.app_account_token <> p_app_account_token
         or legacy_revocation.purchase_date <> p_purchase_date
         or legacy_revocation.expires_date <> p_expires_date then
        raise exception using errcode = '22023',
          message = 'notification_source_mismatch';
      end if;
      v_prior_active := true;
      v_prior_percentage := 100000;
      v_prior_credits_affected := 0;
      v_prior_transaction_signed_date := legacy_revocation.signed_date;
      v_prior_revocation_date := legacy_revocation.revocation_date;
    end if;
  end if;

  if not v_is_subscription and v_environment = 'Production' then
    select
      purchase.user_id, purchase.original_transaction_id,
      purchase.product_id, purchase.environment,
      purchase.app_account_token, purchase.purchase_date,
      null::timestamptz as expires_date, purchase.signed_date,
      purchase.quantity, purchase.credits_granted,
      false as is_verified_product
      into source
      from public.app_store_consumable_transactions as purchase
     where purchase.transaction_id = v_transaction_id
     for update;
  elsif not v_is_subscription then
    select
      purchase.user_id, purchase.original_transaction_id,
      purchase.product_id, purchase.environment,
      purchase.app_account_token, purchase.purchase_date,
      purchase.expires_date, purchase.signed_date,
      purchase.quantity, purchase.credits_granted,
      purchase.is_verified_product
      into source
      from public.app_store_sandbox_review_transactions as purchase
     where purchase.transaction_id = v_transaction_id
     for update;
  elsif v_environment = 'Production' then
    select
      purchase.user_id, purchase.original_transaction_id,
      purchase.product_id, purchase.environment,
      purchase.app_account_token, purchase.purchase_date,
      purchase.expires_date, purchase.signed_date,
      null::integer as quantity, purchase.credits_granted,
      purchase.is_verified_product
      into source
      from public.app_store_transactions as purchase
     where purchase.transaction_id = v_transaction_id
     for update;
  else
    select
      purchase.user_id, purchase.original_transaction_id,
      purchase.product_id, purchase.environment,
      purchase.app_account_token, purchase.purchase_date,
      purchase.expires_date, purchase.signed_date,
      purchase.quantity, purchase.credits_granted,
      purchase.is_verified_product
      into source
      from public.app_store_sandbox_review_transactions as purchase
     where purchase.transaction_id = v_transaction_id
     for update;
  end if;
  v_source_found := found;

  if v_source_found then
    if source.user_id <> p_user_id
       or source.original_transaction_id <> v_original_transaction_id
       or source.product_id <> v_product_id
       or source.environment <> v_environment
       or source.app_account_token is distinct from p_app_account_token
       or source.purchase_date <> p_purchase_date
       or source.expires_date is distinct from p_expires_date
       or source.quantity is distinct from p_quantity
       or source.signed_date > p_transaction_signed_date + interval '5 minutes'
       or source.credits_granted <> v_expected_credits
       or source.is_verified_product <> v_is_subscription then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
  elsif v_environment = 'Production' and v_is_subscription then
    -- A known subscription chain may be refunded before its current period is
    -- replayed, but it can never be rebound to another account.
    perform 1
      from public.app_store_entitlement_owners as owner
     where owner.original_transaction_id = v_original_transaction_id
       and (
         owner.user_id <> p_user_id
         or owner.app_account_token is distinct from p_app_account_token
       );
    if found then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
  end if;

  -- transaction_signed_date is the canonical Apple version. An equal version
  -- is accepted only when it is semantically identical; conflicting equal
  -- versions are rejected instead of relying on delivery order.
  if v_prior_transaction_signed_date is not null
     and p_transaction_signed_date < v_prior_transaction_signed_date then
    insert into public.app_store_server_notification_events (
      event_id, notification_type, notification_signed_date,
      transaction_signed_date, environment, transaction_id,
      original_transaction_id, user_id, product_id, app_account_token,
      purchase_date, expires_date, revocation_date, revocation_percentage,
      quantity, applied, resulting_revocation_percentage,
      credits_affected, pending_credits_affected, credits_delta
    ) values (
      p_event_id, v_notification_type, p_notification_signed_date,
      p_transaction_signed_date, v_environment, v_transaction_id,
      v_original_transaction_id, p_user_id, v_product_id,
      p_app_account_token, p_purchase_date, p_expires_date,
      p_revocation_date, p_revocation_percentage, p_quantity, false,
      case when v_prior_active then v_prior_percentage else 0 end,
      v_prior_credits_affected, v_prior_pending_credits, 0
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
      not v_prior_active
      and v_notification_type = 'REFUND_REVERSED'
    ) then
      insert into public.app_store_server_notification_events (
        event_id, notification_type, notification_signed_date,
        transaction_signed_date, environment, transaction_id,
        original_transaction_id, user_id, product_id, app_account_token,
        purchase_date, expires_date, revocation_date, revocation_percentage,
        quantity, applied, resulting_revocation_percentage,
        credits_affected, pending_credits_affected, credits_delta
      ) values (
        p_event_id, v_notification_type, p_notification_signed_date,
        p_transaction_signed_date, v_environment, v_transaction_id,
        v_original_transaction_id, p_user_id, v_product_id,
        p_app_account_token, p_purchase_date, p_expires_date,
        p_revocation_date, p_revocation_percentage, p_quantity, false,
        case when v_prior_active then v_prior_percentage else 0 end,
        v_prior_credits_affected, v_prior_pending_credits, 0
      );
      return jsonb_build_object(
        'status', 'already_applied',
        'credits_affected', v_prior_credits_affected,
        'credits_delta', 0
      );
    elsif (v_prior_is_device or v_legacy_found)
          and not v_incoming_is_device then
      -- StoreKit's on-device JWS proves the revocation but does not include
      -- Apple's cumulative revocationPercentage. A real server notification
      -- with the same transaction signedDate is therefore allowed to replace
      -- that conservative 100% compatibility projection.
      null;
    else
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
  end if;

  if v_notification_type = 'REFUND' then
    v_resulting_percentage := p_revocation_percentage;
    if not v_is_subscription then
      -- Apple sends cumulative milliunits. Keep the ceiling conservative: a
      -- 40% then 60% sequence withholds only the extra 20% on the second event.
      -- Never debit a refund that arrived before its immutable purchase grant.
      -- Keep it pending until StoreKit later grants the matching transaction.
      if v_source_found or v_prior_credits_affected > 0 then
        v_target_credits_affected := ceil(
          (v_expected_credits::numeric *
           p_revocation_percentage::numeric) / 100000
        )::integer;
        v_target_pending_credits := 0;
      else
        v_target_credits_affected := 0;
        v_target_pending_credits := ceil(
          (v_expected_credits::numeric *
           p_revocation_percentage::numeric) / 100000
        )::integer;
      end if;
      v_credits_delta :=
        v_prior_credits_affected - v_target_credits_affected;
    end if;
  else
    v_resulting_percentage := 0;
    v_target_credits_affected := 0;
    v_target_pending_credits := 0;
    v_credits_delta := v_prior_credits_affected;
  end if;

  if not v_is_subscription and v_credits_delta <> 0 then
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
    credits_affected, pending_credits_affected, credits_delta
  ) values (
    p_event_id, v_notification_type, p_notification_signed_date,
    p_transaction_signed_date, v_environment, v_transaction_id,
    v_original_transaction_id, p_user_id, v_product_id,
    p_app_account_token, p_purchase_date, p_expires_date,
    p_revocation_date, p_revocation_percentage, p_quantity, true,
    v_resulting_percentage,
    case when v_notification_type = 'REFUND_REVERSED'
      then v_prior_credits_affected else v_target_credits_affected end,
    case when v_notification_type = 'REFUND_REVERSED'
      then v_prior_pending_credits else v_target_pending_credits end,
    v_credits_delta
  );

  insert into public.app_store_server_notification_state (
    environment, transaction_id, original_transaction_id, user_id,
    product_id, app_account_token, purchase_date, expires_date, quantity,
    last_event_id, last_notification_type,
    last_notification_signed_date, last_transaction_signed_date,
    active, revocation_percentage, credits_withheld,
    pending_credits_withheld, updated_at
  ) values (
    v_environment, v_transaction_id, v_original_transaction_id, p_user_id,
    v_product_id, p_app_account_token, p_purchase_date, p_expires_date,
    p_quantity, p_event_id, v_notification_type,
    p_notification_signed_date, p_transaction_signed_date,
    v_notification_type = 'REFUND', v_resulting_percentage,
    v_target_credits_affected, v_target_pending_credits, now()
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

  if v_is_subscription then
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
  end if;

  return jsonb_build_object(
    'status', 'applied',
    'credits_affected', case
      when v_notification_type = 'REFUND_REVERSED'
        then v_prior_credits_affected
      else v_target_credits_affected
    end,
    'credits_delta', v_credits_delta,
    'subscription_end_date', v_verified_until,
    'is_verified', case when v_is_subscription
      then v_verified_until is not null else false end
  );
end;
$function$;

comment on table public.app_store_server_notification_events is
  'Private append-only ledger of verified App Store V2 refund and refund-reversal notifications.';
comment on table public.app_store_server_notification_state is
  'Private canonical refund projection. A newer verified reversal overrides legacy refund tombstones.';
comment on function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) is
  'Applies one Apple-verified V2 refund state transition with exact cumulative economics. Service role only.';

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

revoke execute on function public.apply_verified_app_store_consumable_refund(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_consumable_refund(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) to service_role;

revoke execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

revoke execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) to service_role;

revoke execute on function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) to service_role;

revoke execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

commit;
