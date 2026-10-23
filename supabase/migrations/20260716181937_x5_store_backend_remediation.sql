begin;

-- Production acquired these columns together with the Google verifier. Keep a
-- clean migration replay self-contained before any reconciliation function
-- references them.
alter table public.iap_entitlements
  add column if not exists claim_key text,
  add column if not exists purchase_type text,
  add column if not exists purchase_token_hash text,
  add column if not exists order_id text,
  add column if not exists expires_at timestamptz;

-- This pre-verification owner chain was written without an App Account Token.
-- Bind only its complete, already-existing ledger tuple; if the known chain id
-- exists with any changed field, abort instead of trusting the mismatch.
do $owner_legacy_binding$
declare
  v_chain constant text := '2000001163575812';
  v_owner constant uuid :=
    'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid;
  v_product constant text := 'com.x5studio.app.pro.monthly';
  v_recorded_at constant timestamptz :=
    '2026-06-30 10:44:39.862088+00'::timestamptz;
  v_expires_at constant timestamptz :=
    '2026-07-30 10:44:39.862088+00'::timestamptz;
begin
  if exists (
    select 1
      from public.iap_entitlements as legacy
     where legacy.original_transaction_id = v_chain
  ) then
    perform 1
      from public.iap_entitlements as legacy
     where legacy.original_transaction_id = v_chain
       and legacy.user_id = v_owner
       and legacy.product_id = v_product
       and legacy.platform = 'ios'
       and legacy.created_at = v_recorded_at
       and legacy.credited_at = v_recorded_at
       and legacy.credits_granted = 2000
       and legacy.subscription_end_date = v_expires_at
       and legacy.app_account_token is null
       and legacy.claim_key = v_chain
       and legacy.purchase_type = 'subscription'
       and legacy.purchase_token_hash is null
       and legacy.order_id is null
       and legacy.expires_at = v_expires_at
       and legacy.last_transaction_id is null
       and legacy.legacy_app_account_token is null
     for update;
    if not found then
      raise exception using errcode = '22023',
        message = 'owner_legacy_chain_tuple_mismatch';
    end if;

    -- The owner UUID is an explicit nil-token sentinel for projection only.
    -- Every source field above and below must still match exactly.
    insert into public.app_store_legacy_bindings (
      original_transaction_id, user_id, app_account_token, product_id,
      legacy_credited_at, legacy_subscription_end_date, legacy_created_at
    ) values (
      v_chain, v_owner, v_owner, v_product,
      v_recorded_at, v_expires_at, v_recorded_at
    )
    on conflict (original_transaction_id) do nothing;

    perform 1
      from public.app_store_legacy_bindings as binding
     where binding.original_transaction_id = v_chain
       and binding.user_id = v_owner
       and binding.app_account_token = v_owner
       and binding.product_id = v_product
       and binding.legacy_credited_at = v_recorded_at
       and binding.legacy_subscription_end_date = v_expires_at
       and binding.legacy_created_at = v_recorded_at;
    if not found then
      raise exception using errcode = '22023',
        message = 'owner_legacy_binding_conflict';
    end if;
  end if;
end;
$owner_legacy_binding$;

-- Future one-time packs are tracked separately from expiring subscription
-- credits. Existing balances deliberately start with a zero permanent floor;
-- there is no heuristic backfill of old credit origins.
alter table public.profiles
  add column if not exists permanent_credits integer not null default 0,
  add column if not exists permanent_credit_debt integer not null default 0;
alter table public.profiles
  drop constraint if exists profiles_permanent_credits_bounds;
alter table public.profiles
  add constraint profiles_permanent_credits_bounds check (
    permanent_credits >= 0
    and permanent_credit_debt >= 0
    and permanent_credits <= greatest(coalesce(credits, 0), 0)
  );

create or replace function public.x5_protect_profile_entitlements()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.plan := 'free';
    new.credits := 0;
    new.permanent_credits := 0;
    new.permanent_credit_debt := 0;
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
    new.permanent_credits := old.permanent_credits;
    new.permanent_credit_debt := old.permanent_credit_debt;
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
$function$;

revoke execute on function public.x5_protect_profile_entitlements()
  from public, anon, authenticated, service_role;

-- One-time credit packs are permanent. Transaction-local markers are set only
-- by the service-only grant/refund functions below. Ordinary subscription
-- credits retain the existing one/three-month expiry window.
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
  permanent_grant boolean;
  permanent_adjustment boolean;
  old_credits integer;
  new_credits integer;
  old_permanent integer;
  old_permanent_debt integer;
  credit_delta integer;
  timed_credits integer;
  debt_reduction integer;
  permanent_reduction integer;
begin
  if tg_op = 'UPDATE'
     and current_setting('x5.store_reconciliation_user', true) = new.id::text
  then
    new.credits := old.credits;
    new.permanent_credits := old.permanent_credits;
    new.permanent_credit_debt := old.permanent_credit_debt;
    new.credits_expires_at := old.credits_expires_at;
    new.credits_retention_months := old.credits_retention_months;
    return new;
  end if;

  active_verified := public.x5_profile_has_active_verified_badge(
    new.is_verified,
    new.verified_until
  );
  retention_months := case when active_verified then 3 else 1 end;
  new.credits_retention_months := retention_months;

  if tg_op = 'INSERT' then
    old_credits := 0;
    new_credits := coalesce(new.credits, 0);
    old_permanent := 0;
    old_permanent_debt := 0;
    credit_delta := new_credits;
    credits_changed := true;
    verified_changed := false;
    permanent_grant := false;
    permanent_adjustment := false;
    new.permanent_credits := greatest(
      0,
      least(greatest(new_credits, 0), coalesce(new.permanent_credits, 0))
    );
    new.permanent_credit_debt := greatest(
      coalesce(new.permanent_credit_debt, 0),
      0
    );
  else
    old_credits := coalesce(old.credits, 0);
    new_credits := coalesce(new.credits, 0);
    old_permanent := greatest(coalesce(old.permanent_credits, 0), 0);
    old_permanent_debt := greatest(
      coalesce(old.permanent_credit_debt, 0),
      0
    );
    credit_delta := new_credits - old_credits;
    credits_changed := new_credits <> old_credits;
    verified_changed :=
      coalesce(new.is_verified, false) <> coalesce(old.is_verified, false)
      or coalesce(new.verified_until, '-infinity'::timestamptz) <>
         coalesce(old.verified_until, '-infinity'::timestamptz);
    permanent_grant :=
      current_setting('x5.permanent_credit_grant_user', true) = new.id::text
      and credit_delta > 0;
    permanent_adjustment :=
      current_setting('x5.permanent_credit_adjustment_user', true) =
        new.id::text
      and credit_delta <> 0;

    if permanent_adjustment and credit_delta < 0 then
      permanent_reduction := least(old_permanent, -credit_delta);
      new.permanent_credits := old_permanent - permanent_reduction;
      new.permanent_credit_debt := old_permanent_debt +
        (-credit_delta - permanent_reduction);
    elsif permanent_grant or permanent_adjustment then
      -- Refunded permanent credits already spent are fungible user debt. A
      -- future pack or reversal repays that debt before growing the floor.
      debt_reduction := least(old_permanent_debt, credit_delta);
      new.permanent_credits := greatest(
        0,
        least(
          greatest(new_credits, 0),
          old_permanent + credit_delta - debt_reduction
        )
      );
      new.permanent_credit_debt := old_permanent_debt - debt_reduction;
    else
      -- Spend expiring credits first. Only the portion of a spend that crosses
      -- the timed balance can reduce the purchased permanent floor.
      new.permanent_credits := greatest(
        0,
        least(greatest(new_credits, 0), old_permanent)
      );
      new.permanent_credit_debt := old_permanent_debt;
    end if;
  end if;

  timed_credits := greatest(new_credits, 0) - new.permanent_credits;

  if new_credits <= 0 or timed_credits <= 0 then
    new.credits_expires_at := null;
  elsif permanent_grant or permanent_adjustment then
    -- A permanent pack grant/refund does not change the timed portion. Preserve
    -- its existing deadline, creating one only for a legacy untimed remainder.
    new.credits_expires_at := coalesce(
      old.credits_expires_at,
      now() + make_interval(months => retention_months)
    );
  elsif credits_changed or verified_changed
        or new.credits_expires_at is null then
    new.credits_expires_at :=
      now() + make_interval(months => retention_months);
  end if;

  return new;
end;
$function$;

create or replace function public.x5_expire_old_credits()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  expired integer;
begin
  update public.profiles
     set credits = permanent_credits,
         credits_expires_at = null
   where coalesce(credits, 0) > permanent_credits
     and credits_expires_at is not null
     and credits_expires_at <= now();

  get diagnostics expired = row_count;
  return expired;
end;
$function$;

revoke execute on function public.x5_expire_old_credits()
  from public, anon, authenticated, service_role;

-- Install the exact legacy notification identity before the first profile
-- reconciliation below. The rebuilt projection reads legacy_binding_used, so
-- these columns and constraints must exist before that function is executed.
alter table public.app_store_server_notification_events
  add column legacy_binding_used boolean not null default false;
alter table public.app_store_server_notification_events
  add column legacy_binding_original_transaction_id text
    generated always as (
      case when legacy_binding_used then original_transaction_id end
    ) stored,
  add column legacy_binding_user_id uuid
    generated always as (case when legacy_binding_used then user_id end) stored,
  add column legacy_binding_app_account_token uuid
    generated always as (
      case when legacy_binding_used then app_account_token end
    ) stored,
  add column legacy_binding_product_id text
    generated always as (case when legacy_binding_used then product_id end) stored;
alter table public.app_store_server_notification_events
  drop constraint app_store_server_notification_events_account_matches_user;
alter table public.app_store_server_notification_events
  add constraint app_store_server_notification_events_account_scope
    check (
      (
        not legacy_binding_used
        and app_account_token = user_id
      ) or (
        legacy_binding_used
        and environment = 'Production'
        and product_id = 'com.x5studio.app.verified.monthly'
        and app_account_token <> user_id
      )
    );
alter table public.app_store_server_notification_events
  add constraint app_store_server_notification_events_legacy_binding_fk
    foreign key (
      legacy_binding_original_transaction_id,
      legacy_binding_user_id,
      legacy_binding_app_account_token,
      legacy_binding_product_id
    ) references public.app_store_legacy_bindings (
      original_transaction_id, user_id, app_account_token, product_id
    );

alter table public.app_store_server_notification_state
  add column legacy_binding_used boolean not null default false;
alter table public.app_store_server_notification_state
  add column legacy_binding_original_transaction_id text
    generated always as (
      case when legacy_binding_used then original_transaction_id end
    ) stored,
  add column legacy_binding_user_id uuid
    generated always as (case when legacy_binding_used then user_id end) stored,
  add column legacy_binding_app_account_token uuid
    generated always as (
      case when legacy_binding_used then app_account_token end
    ) stored,
  add column legacy_binding_product_id text
    generated always as (case when legacy_binding_used then product_id end) stored;
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
          and product_id = 'com.x5studio.app.verified.monthly'
          and app_account_token <> user_id
        )
      )
    );
alter table public.app_store_server_notification_state
  add constraint app_store_server_notification_state_legacy_binding_fk
    foreign key (
      legacy_binding_original_transaction_id,
      legacy_binding_user_id,
      legacy_binding_app_account_token,
      legacy_binding_product_id
    ) references public.app_store_legacy_bindings (
      original_transaction_id, user_id, app_account_token, product_id
    );

-- The lifecycle ledger is created later. This stable placeholder is replaced
-- with exact transaction-period expiry semantics after the table exists.
create or replace function
  public.x5_app_store_lifecycle_transaction_allows_entitlement(
    p_environment text,
    p_transaction_id text
  )
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select true;
$function$;

revoke execute on function
  public.x5_app_store_lifecycle_transaction_allows_entitlement(text, text)
  from public, anon, authenticated, service_role;

create or replace function public.x5_active_app_store_grace_period(
  p_user_id uuid
)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $function$
  select null::timestamptz;
$function$;

revoke execute on function public.x5_active_app_store_grace_period(uuid)
  from public, anon, authenticated, service_role;

-- Rebuild the badge projection from current, server-proven sources. The old
-- iOS table is trusted only when its complete historical tuple is present in
-- the immutable grandfather allowlist.
create or replace function public.x5_rebuild_app_store_verified_profile(
  p_user_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_verified_until timestamptz;
  v_grace_until timestamptz;
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
          and public.x5_app_store_lifecycle_transaction_allows_entitlement(
            'Production', production.transaction_id
          )
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
          and public.x5_app_store_lifecycle_transaction_allows_entitlement(
            'Sandbox', sandbox.transaction_id
          )
         and not public.x5_app_store_notification_refund_active(
           'Sandbox', sandbox.transaction_id
         )
      union all
      select coalesce(android.expires_at, android.subscription_end_date)
        from public.iap_entitlements as android
       where android.user_id = p_user_id
         and lower(coalesce(android.platform, '')) = 'android'
         and android.product_id in (
           'x5_verified_monthly_v2', 'x5_verified_monthly'
         )
         and android.purchase_type = 'subscription'
         and android.purchase_token_hash is not null
         and btrim(android.purchase_token_hash) <> ''
         and android.claim_key is not null
         and btrim(android.claim_key) <> ''
         and android.app_account_token = android.user_id
         and coalesce(android.expires_at, android.subscription_end_date) > v_now
      union all
      select legacy_ios.subscription_end_date
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
         and legacy_ios.product_id = 'com.x5studio.app.verified.monthly'
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
               and refund_state.active
               and (
                 refund_state.transaction_id = legacy_ios.last_transaction_id
                 or refund_state.legacy_binding_used
               )
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

  v_grace_until := public.x5_active_app_store_grace_period(p_user_id);
  if v_grace_until is not null then
    v_verified_until := greatest(
      coalesce(v_verified_until, '-infinity'::timestamptz),
      v_grace_until
    );
  end if;

  update public.profiles
     set is_verified = v_verified_until is not null,
         verified_until = v_verified_until
   where id = p_user_id
     and (
       is_verified is distinct from (v_verified_until is not null)
       or verified_until is distinct from v_verified_until
     );

  return v_verified_until;
end;
$function$;

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

  -- Black and null-end paid accounts are permanent/manual and must never be
  -- downgraded by an automated store projection.
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
     and v_profile.subscription_end_date is not null
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

create table public.x5_store_reconciliation_state (
  singleton boolean primary key default true check (singleton),
  last_profile_id uuid,
  updated_at timestamptz not null default now()
);
insert into public.x5_store_reconciliation_state (singleton, last_profile_id)
values (true, null);
alter table public.x5_store_reconciliation_state owner to postgres;
alter table public.x5_store_reconciliation_state enable row level security;
alter table public.x5_store_reconciliation_state force row level security;
revoke all privileges on table public.x5_store_reconciliation_state
  from public, anon, authenticated, service_role;

create or replace function public.x5_reconcile_store_profiles(
  p_limit integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  candidate record;
  reconciled integer := 0;
  v_last_profile_id uuid;
  v_final_profile_id uuid;
  v_batch_limit integer :=
    least(greatest(coalesce(p_limit, 5000), 1), 10000);
begin
  select state.last_profile_id
    into v_last_profile_id
    from public.x5_store_reconciliation_state as state
   where state.singleton
   for update;

  for candidate in
    select profile.id
      from public.profiles as profile
     where v_last_profile_id is null
        or profile.id > v_last_profile_id
     order by profile.id
     limit v_batch_limit
  loop
    perform pg_catalog.set_config(
      'x5.store_reconciliation_user', candidate.id::text, true
    );
    perform public.x5_rebuild_app_store_verified_profile(candidate.id);
    perform pg_catalog.set_config('x5.store_reconciliation_user', '', true);
    perform public.x5_reconcile_paid_plan_profile(candidate.id);
    v_final_profile_id := candidate.id;
    reconciled := reconciled + 1;
  end loop;

  update public.x5_store_reconciliation_state
     set last_profile_id = case
           when v_final_profile_id is not null
            and exists (
              select 1 from public.profiles as remaining
               where remaining.id > v_final_profile_id
            ) then v_final_profile_id
           else null
         end,
         updated_at = now()
   where singleton;

  return reconciled;
end;
$function$;

revoke execute on function public.x5_rebuild_app_store_verified_profile(uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.x5_reconcile_paid_plan_profile(uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.x5_reconcile_store_profiles(integer)
  from public, anon, authenticated, service_role;

-- Idempotent backfill fixes current profile drift without changing the balance.
select public.x5_reconcile_store_profiles(10000);

do $cron$
begin
  begin
    perform cron.unschedule('x5-reconcile-store-profiles');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-reconcile-store-profiles',
    '*/15 * * * *',
    'select public.x5_reconcile_store_profiles(10000);'
  );
end;
$cron$;


alter function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) rename to x5_app_store_consumable_notification_wrapper_legacy;

revoke execute on function
  public.x5_app_store_consumable_notification_wrapper_legacy(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;

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
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user',
    coalesce(p_user_id::text, ''),
    true
  );
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user',
    coalesce(p_user_id::text, ''),
    true
  );
  v_result :=
    public.x5_app_store_consumable_notification_wrapper_legacy(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_signed_date, p_revocation_date, p_quantity
    );
  perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', '', true
  );
  return v_result;
end;
$function$;

alter function public.apply_verified_app_store_sandbox_review_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer
) rename to x5_app_store_sandbox_notification_wrapper_legacy;

revoke execute on function
  public.x5_app_store_sandbox_notification_wrapper_legacy(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;

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
  v_product_id text := nullif(btrim(p_product_id), '');
  v_result jsonb;
begin
  if v_product_id in (
    'com.x5studio.app.credits.1000',
    'com.x5studio.app.credits.2000',
    'com.x5studio.app.credits.5000'
  ) then
    perform pg_catalog.set_config(
      'x5.permanent_credit_grant_user',
      coalesce(p_user_id::text, ''),
      true
    );
    perform pg_catalog.set_config(
      'x5.permanent_credit_adjustment_user',
      coalesce(p_user_id::text, ''),
      true
    );
  end if;

  v_result :=
    public.x5_app_store_sandbox_notification_wrapper_legacy(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_signed_date, p_revocation_date, p_quantity
    );
  perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', '', true
  );
  return v_result;
end;
$function$;

revoke execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_consumable(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) to service_role;

revoke execute on function
  public.apply_verified_app_store_sandbox_review_transaction(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;
grant execute on function
  public.apply_verified_app_store_sandbox_review_transaction(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer
  ) to service_role;

-- Permanent-pack refunds/reversals change the permanent floor by the exact
-- credit delta already computed by the established immutable refund engine.
create or replace function public.resolve_verified_app_store_notification_user(
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
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  if v_original_transaction_id is null
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023',
      message = 'invalid_original_transaction_id';
  end if;
  if v_product_id not in (
    'com.x5studio.app.credits.1000',
    'com.x5studio.app.credits.2000',
    'com.x5studio.app.credits.5000',
    'com.x5studio.app.lite.monthly',
    'com.x5studio.app.pro.monthly',
    'com.x5studio.app.max.monthly',
    'com.x5studio.app.verified.monthly'
  ) then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  if p_app_account_token is null then
    raise exception using errcode = '22023', message = 'missing_account_token';
  end if;

  if v_environment = 'Production' then
    select binding.*
      into v_binding
     from public.app_store_legacy_bindings as binding
     where binding.original_transaction_id = v_original_transaction_id
     for update;

    if found then
      if v_binding.product_id <> v_product_id
         or v_binding.app_account_token <> p_app_account_token then
        raise exception using errcode = '22023',
          message = 'account_token_mismatch';
      end if;

      if v_binding.bound_at is null then
        -- Before the first verified event, every immutable grandfather
        -- snapshot field must still match the retired iOS row exactly.
        perform 1
          from public.iap_entitlements as legacy
         where legacy.original_transaction_id =
               v_binding.original_transaction_id
           and legacy.user_id = v_binding.user_id
           and legacy.product_id = v_binding.product_id
           and lower(coalesce(legacy.platform, '')) = 'ios'
           and legacy.credited_at is not distinct from
               v_binding.legacy_credited_at
           and legacy.subscription_end_date is not distinct from
               v_binding.legacy_subscription_end_date
           and legacy.created_at is not distinct from
               v_binding.legacy_created_at
           and coalesce(
             legacy.legacy_app_account_token,
             legacy.app_account_token,
             legacy.user_id
           ) = v_binding.app_account_token
         for share;
      else
        -- The first genuine Apple JWS moves the random legacy token to the
        -- audit column and future renewals may advance mutable expiry fields.
        -- Continue only for that exact already-bound chain and owner.
        perform 1
          from public.iap_entitlements as legacy
         where legacy.original_transaction_id =
               v_binding.original_transaction_id
           and legacy.user_id = v_binding.user_id
           and legacy.product_id = v_binding.product_id
           and lower(coalesce(legacy.platform, '')) = 'ios'
           and legacy.legacy_app_account_token =
               v_binding.app_account_token
           and legacy.app_account_token is null
         for share;
      end if;

      if not found then
        raise exception using errcode = '22023',
          message = 'legacy_binding_mismatch';
      end if;
      return v_binding.user_id;
    end if;
  end if;

  perform 1 from public.profiles where id = p_app_account_token;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  return p_app_account_token;
end;
$function$;

alter function public.resolve_verified_app_store_notification_user(
  text, text, text, uuid
) owner to postgres;
revoke execute on function
  public.resolve_verified_app_store_notification_user(text, text, text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function
  public.resolve_verified_app_store_notification_user(text, text, text, uuid)
  to service_role;

-- Keep the original full-snapshot binder for the first mismatch-token JWS.
-- After it records bound_at and moves the token to the audit column, future
-- renewals use the same private grant engine without requiring mutable expiry
-- fields to equal the historical snapshot forever.
alter function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) rename to x5_app_store_transaction_legacy_resolver_wrapper;

revoke execute on function
  public.x5_app_store_transaction_legacy_resolver_wrapper(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz
  ) from public, anon, authenticated, service_role;

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
as $function$
declare
  v_resolved_user_id uuid;
  v_binding public.app_store_legacy_bindings%rowtype;
begin
  if p_app_account_token is null or p_app_account_token = p_user_id then
    return public.x5_app_store_transaction_legacy_resolver_wrapper(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_signed_date, p_revocation_date
    );
  end if;

  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      p_environment, p_original_transaction_id, p_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  select binding.*
    into v_binding
    from public.app_store_legacy_bindings as binding
   where binding.original_transaction_id =
         nullif(btrim(p_original_transaction_id), '')
   for update;

  if v_binding.bound_at is null then
    return public.x5_app_store_transaction_legacy_resolver_wrapper(
      p_user_id, p_transaction_id, p_original_transaction_id,
      p_product_id, p_environment, p_app_account_token, p_purchase_date,
      p_expires_date, p_signed_date, p_revocation_date
    );
  end if;

  return public.x5_apply_verified_app_store_transaction_production_internal(
    p_user_id, p_transaction_id, p_original_transaction_id,
    p_product_id, p_environment, null, p_purchase_date,
    p_expires_date, p_signed_date, p_revocation_date
  );
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

create or replace function
  public.x5_apply_verified_legacy_subscription_notification(
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
  v_original_transaction_id text :=
    nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'production' then 'Production'
    when 'sandbox' then 'Sandbox'
    else null
  end;
  v_resolved_user_id uuid;
  existing_event public.app_store_server_notification_events%rowtype;
  projection public.app_store_server_notification_state%rowtype;
  source public.app_store_transactions%rowtype;
  v_projection_found boolean := false;
  v_prior_active boolean := false;
  v_prior_percentage integer := 0;
  v_prior_transaction_signed_date timestamptz;
  v_prior_revocation_date timestamptz;
  v_verified_until timestamptz;
begin
  if p_event_id is null then
    raise exception using errcode = '22023',
      message = 'invalid_notification_uuid';
  end if;
  if v_notification_type not in ('REFUND', 'REFUND_REVERSED') then
    raise exception using errcode = '22023',
      message = 'invalid_notification_type';
  end if;
  if v_environment <> 'Production'
     or v_product_id <> 'com.x5studio.app.verified.monthly'
     or p_app_account_token is null
     or p_app_account_token = p_user_id then
    raise exception using errcode = '22023',
      message = 'invalid_legacy_notification_scope';
  end if;
  if v_transaction_id is null or length(v_transaction_id) > 255
     or v_original_transaction_id is null
     or length(v_original_transaction_id) > 255 then
    raise exception using errcode = '22023',
      message = 'invalid_transaction_id';
  end if;

  -- Exact legacy binding is locked before the profile. This matches the
  -- on-device renewal binder and prevents binding/profile lock inversion.
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      v_environment, v_original_transaction_id, v_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  if p_purchase_date is null or p_expires_date is null
     or p_transaction_signed_date is null
     or p_notification_signed_date is null
     or p_expires_date <= p_purchase_date
     or p_quantity is not null
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
       or existing_event.expires_date <> p_expires_date
       or existing_event.revocation_date is distinct from p_revocation_date
       or existing_event.revocation_percentage is distinct from
          p_revocation_percentage
       or existing_event.quantity is not null
       or not existing_event.legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'notification_event_id_conflict';
    end if;
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    return jsonb_build_object(
      'status', 'already_applied',
      'credits_affected', 0,
      'credits_delta', 0,
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
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
       or projection.original_transaction_id <>
          v_original_transaction_id
       or projection.product_id <> v_product_id
       or projection.app_account_token <> p_app_account_token
       or projection.purchase_date <> p_purchase_date
       or projection.expires_date <> p_expires_date
       or projection.quantity is not null
       or not projection.legacy_binding_used then
      raise exception using errcode = '22023',
        message = 'notification_source_mismatch';
    end if;
    v_prior_active := projection.active;
    v_prior_percentage := projection.revocation_percentage;
    v_prior_transaction_signed_date :=
      projection.last_transaction_signed_date;
    select event.revocation_date
      into v_prior_revocation_date
      from public.app_store_server_notification_events as event
     where event.event_id = projection.last_event_id;
  end if;

  select purchase.*
    into source
    from public.app_store_transactions as purchase
   where purchase.transaction_id = v_transaction_id
   for update;
  if found and (
    source.user_id <> p_user_id
    or source.original_transaction_id <> v_original_transaction_id
    or source.product_id <> v_product_id
    or source.environment <> v_environment
    or source.app_account_token is not null
    or source.purchase_date <> p_purchase_date
    or source.expires_date <> p_expires_date
    or source.signed_date > p_transaction_signed_date + interval '5 minutes'
    or not source.is_verified_product
    or source.credits_granted <> 0
  ) then
    raise exception using errcode = '22023',
      message = 'notification_source_mismatch';
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
      p_revocation_date, p_revocation_percentage, null, false,
      case when v_prior_active then v_prior_percentage else 0 end,
      0, 0, 0, true
    );
    return jsonb_build_object(
      'status', 'ignored_stale', 'credits_affected', 0,
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
        purchase_date, expires_date, revocation_date,
        revocation_percentage, quantity, applied,
        resulting_revocation_percentage, credits_affected,
        pending_credits_affected, credits_delta, legacy_binding_used
      ) values (
        p_event_id, v_notification_type, p_notification_signed_date,
        p_transaction_signed_date, v_environment, v_transaction_id,
        v_original_transaction_id, p_user_id, v_product_id,
        p_app_account_token, p_purchase_date, p_expires_date,
        p_revocation_date, p_revocation_percentage, null, false,
        case when v_prior_active then v_prior_percentage else 0 end,
        0, 0, 0, true
      );
      return jsonb_build_object(
        'status', 'already_applied', 'credits_affected', 0,
        'credits_delta', 0
      );
    end if;
    raise exception using errcode = '22023',
      message = 'notification_source_mismatch';
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
    p_revocation_date, p_revocation_percentage, null, true,
    case when v_notification_type = 'REFUND'
      then p_revocation_percentage else 0 end,
    0, 0, 0, true
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
    v_product_id, p_app_account_token, p_purchase_date, p_expires_date,
    null, p_event_id, v_notification_type, p_notification_signed_date,
    p_transaction_signed_date, v_notification_type = 'REFUND',
    case when v_notification_type = 'REFUND'
      then p_revocation_percentage else 0 end,
    0, 0, now(), true
  )
  on conflict (environment, transaction_id) do update
    set last_event_id = excluded.last_event_id,
        last_notification_type = excluded.last_notification_type,
        last_notification_signed_date = excluded.last_notification_signed_date,
        last_transaction_signed_date = excluded.last_transaction_signed_date,
        active = excluded.active,
        revocation_percentage = excluded.revocation_percentage,
        credits_withheld = 0,
        pending_credits_withheld = 0,
        updated_at = excluded.updated_at;

  v_verified_until :=
    public.x5_rebuild_app_store_verified_profile(p_user_id);
  return jsonb_build_object(
    'status', 'applied', 'credits_affected', 0, 'credits_delta', 0,
    'subscription_end_date', v_verified_until,
    'is_verified', v_verified_until is not null
  );
end;
$function$;

alter function public.x5_apply_verified_legacy_subscription_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) owner to postgres;
revoke execute on function
  public.x5_apply_verified_legacy_subscription_notification(
    uuid, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
  ) from public, anon, authenticated, service_role;

alter function public.apply_verified_app_store_server_notification(
  uuid, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
) rename to x5_app_store_server_notification_wrapper_legacy;

revoke execute on function
  public.x5_app_store_server_notification_wrapper_legacy(
    uuid, text, timestamptz, uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz, integer, integer
  ) from public, anon, authenticated, service_role;

create or replace function public.apply_verified_app_store_server_notification(
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
  v_result jsonb;
  v_resolved_user_id uuid;
  v_is_permanent_pack boolean := nullif(btrim(p_product_id), '') in (
    'com.x5studio.app.credits.1000',
    'com.x5studio.app.credits.2000',
    'com.x5studio.app.credits.5000'
  );
  v_type text := upper(btrim(coalesce(p_notification_type, '')));
begin
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      p_environment, p_original_transaction_id, p_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;
  if p_app_account_token <> p_user_id then
    return public.x5_apply_verified_legacy_subscription_notification(
      p_event_id, p_notification_type, p_notification_signed_date,
      p_user_id, p_transaction_id, p_original_transaction_id, p_product_id,
      p_environment, p_app_account_token, p_purchase_date, p_expires_date,
      p_transaction_signed_date, p_revocation_date,
      p_revocation_percentage, p_quantity
    );
  end if;

  if v_is_permanent_pack and v_type in ('REFUND', 'REFUND_REVERSED') then
    perform pg_catalog.set_config(
      'x5.permanent_credit_adjustment_user',
      coalesce(p_user_id::text, ''),
      true
    );
  end if;

  v_result := public.x5_app_store_server_notification_wrapper_legacy(
    p_event_id, p_notification_type, p_notification_signed_date,
    p_user_id, p_transaction_id, p_original_transaction_id, p_product_id,
    p_environment, p_app_account_token, p_purchase_date, p_expires_date,
    p_transaction_signed_date, p_revocation_date,
    p_revocation_percentage, p_quantity
  );
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', '', true
  );
  return v_result;
end;
$function$;

-- StoreKit can surface a signed revocation directly on device before the V2
-- server notification arrives. Preserve the exact legacy Apple token through
-- the same projection instead of inserting it into the old token=user ledger.
alter function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) rename to x5_app_store_verified_revocation_legacy_wrapper;

revoke execute on function
  public.x5_app_store_verified_revocation_legacy_wrapper(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, timestamptz
  ) from public, anon, authenticated, service_role;

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
  v_resolved_user_id uuid;
  v_result jsonb;
  v_verified_until timestamptz;
begin
  v_resolved_user_id :=
    public.resolve_verified_app_store_notification_user(
      p_environment, p_original_transaction_id, p_product_id,
      p_app_account_token
    );
  if v_resolved_user_id <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  if p_app_account_token <> p_user_id then
    v_result := public.x5_apply_verified_legacy_subscription_notification(
      md5(
        'storekit-verified-refund|' || coalesce(v_environment, '') || '|' ||
        coalesce(v_transaction_id, '') || '|' ||
        coalesce(p_signed_date::text, '')
      )::uuid,
      'REFUND', p_signed_date, p_user_id, v_transaction_id,
      p_original_transaction_id, p_product_id, v_environment,
      p_app_account_token, p_purchase_date, p_expires_date, p_signed_date,
      p_revocation_date, 100000, null
    );
    v_verified_until :=
      public.x5_rebuild_app_store_verified_profile(p_user_id);
    return jsonb_build_object(
      'status', case when v_result ->> 'status' = 'ignored_stale'
        then 'already_applied' else v_result ->> 'status' end,
      'credits_granted', 0,
      'subscription_end_date', v_verified_until,
      'is_verified', v_verified_until is not null
    );
  end if;

  return public.x5_app_store_verified_revocation_legacy_wrapper(
    p_user_id, p_transaction_id, p_original_transaction_id,
    p_product_id, p_environment, p_app_account_token, p_purchase_date,
    p_expires_date, p_signed_date, p_revocation_date
  );
end;
$function$;

revoke execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.apply_verified_app_store_verified_revocation(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

alter function public.apply_verified_app_store_consumable_refund(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, integer
) rename to x5_app_store_consumable_refund_wrapper_legacy;

revoke execute on function
  public.x5_app_store_consumable_refund_wrapper_legacy(
    uuid, text, text, text, text, uuid,
    timestamptz, timestamptz, timestamptz, integer
  ) from public, anon, authenticated, service_role;

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
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user',
    coalesce(p_user_id::text, ''),
    true
  );
  v_result := public.x5_app_store_consumable_refund_wrapper_legacy(
    p_user_id, p_transaction_id, p_original_transaction_id,
    p_product_id, p_environment, p_app_account_token, p_purchase_date,
    p_signed_date, p_revocation_date, p_quantity
  );
  perform pg_catalog.set_config(
    'x5.permanent_credit_adjustment_user', '', true
  );
  return v_result;
end;
$function$;

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

-- Production acquired these columns together with the Google verifier. Keep a
-- clean migration replay self-contained before replacing the live RPC.
alter table public.iap_entitlements
  add column if not exists claim_key text,
  add column if not exists purchase_type text,
  add column if not exists purchase_token_hash text,
  add column if not exists order_id text,
  add column if not exists expires_at timestamptz;

create index if not exists iap_entitlements_android_token_owner_idx
  on public.iap_entitlements (purchase_token_hash)
  where lower(coalesce(platform, '')) = 'android'
    and purchase_token_hash is not null;

create or replace function public.apply_android_purchase_entitlement(
  p_user_id uuid,
  p_claim_key text,
  p_product_id text,
  p_purchase_type text,
  p_purchase_token_hash text,
  p_order_id text,
  p_expires_at timestamptz,
  p_credits integer,
  p_subscription_type text,
  p_profile_plan text,
  p_verified boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_existing_user uuid;
  v_existing_entitlement public.iap_entitlements%rowtype;
  v_inserted integer := 0;
  v_profile public.profiles%rowtype;
  v_credits_granted integer := 0;
  v_expiry_advances boolean := false;
  v_expected_purchase_type text;
  v_expected_credits integer;
  v_expected_subscription_type text;
  v_expected_profile_plan text;
  v_expected_verified boolean;
begin
  if p_user_id is null
     or nullif(btrim(p_claim_key), '') is null
     or nullif(btrim(p_product_id), '') is null
     or nullif(btrim(p_purchase_token_hash), '') is null then
    raise exception using errcode = '22023',
      message = 'invalid_android_entitlement';
  end if;

  select product.purchase_type, product.credits,
         product.subscription_type, product.profile_plan, product.verified
    into v_expected_purchase_type, v_expected_credits,
         v_expected_subscription_type, v_expected_profile_plan,
         v_expected_verified
    from (values
      ('x5_lite_monthly_v2', 'subscription', 1000, 'lite_monthly', 'pro', false),
      ('x5_pro_monthly_v2', 'subscription', 2000, 'pro_monthly', 'pro', false),
      ('x5_max_monthly_v2', 'subscription', 5000, 'max_monthly', 'pro', false),
      ('x5_verified_monthly_v2', 'subscription', 0, 'verified_monthly', null, true),
      ('x5_pro_monthly', 'subscription', 1000, 'monthly', 'pro', false),
      ('x5_pro_yearly', 'subscription', 12000, 'yearly', 'pro', false),
      ('x5_verified_monthly', 'subscription', 0, 'verified_monthly', null, true),
      ('x5_credits_1000_v2', 'inapp', 1000, null, null, false),
      ('x5_credits_2000_v2', 'inapp', 2000, null, null, false),
      ('x5_credits_5000_v2', 'inapp', 5000, null, null, false)
    ) as product(
      product_id, purchase_type, credits, subscription_type,
      profile_plan, verified
    )
   where product.product_id = btrim(p_product_id);

  if not found then
    raise exception using errcode = '22023', message = 'unknown_product';
  end if;
  if p_purchase_type is distinct from v_expected_purchase_type
     or p_credits is distinct from v_expected_credits
     or p_subscription_type is distinct from v_expected_subscription_type
     or p_profile_plan is distinct from v_expected_profile_plan
     or p_verified is distinct from v_expected_verified then
    raise exception using errcode = '22023',
      message = 'invalid_android_entitlement_mapping';
  end if;
  if p_purchase_type = 'subscription' then
    if p_expires_at is null or p_expires_at <= clock_timestamp() then
      raise exception using errcode = '22023',
        message = 'subscription_expiry_required';
    end if;
  elsif p_expires_at is not null then
    raise exception using errcode = '22023',
      message = 'inapp_expiry_not_allowed';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(btrim(p_purchase_token_hash), 0)
  );

  select entitlement.user_id
    into v_existing_user
    from public.iap_entitlements as entitlement
   where lower(coalesce(entitlement.platform, '')) = 'android'
     and entitlement.purchase_token_hash = btrim(p_purchase_token_hash)
   limit 1;
  if v_existing_user is not null and v_existing_user <> p_user_id then
    raise exception using errcode = '22023', message = 'owned_by_other';
  end if;

  select profile.*
    into v_profile
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;

  insert into public.iap_entitlements (
    original_transaction_id, claim_key, user_id, product_id, platform,
    purchase_type, purchase_token_hash, order_id, expires_at,
    subscription_end_date, app_account_token
  ) values (
    btrim(p_claim_key), btrim(p_claim_key), p_user_id, btrim(p_product_id),
    'android', p_purchase_type, btrim(p_purchase_token_hash), p_order_id,
    p_expires_at, p_expires_at, p_user_id
  )
  on conflict (original_transaction_id) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    select entitlement.*
      into v_existing_entitlement
      from public.iap_entitlements as entitlement
     where entitlement.original_transaction_id = btrim(p_claim_key)
     for update;
    if v_existing_entitlement.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_existing_entitlement.product_id <> btrim(p_product_id)
       or v_existing_entitlement.platform <> 'android'
       or v_existing_entitlement.purchase_type <> p_purchase_type
       or v_existing_entitlement.purchase_token_hash <>
          btrim(p_purchase_token_hash)
       or v_existing_entitlement.order_id is distinct from p_order_id
       or v_existing_entitlement.expires_at is distinct from p_expires_at
       or v_existing_entitlement.app_account_token <> p_user_id then
      raise exception using errcode = '22023',
        message = 'android_claim_key_conflict';
    end if;
    select profile.* into v_profile
      from public.profiles as profile
     where profile.id = p_user_id;
    return jsonb_build_object(
      'already_claimed', true,
      'credits_granted', 0,
      'profile', to_jsonb(v_profile)
    );
  end if;

  if p_verified then
    update public.profiles
       set is_verified = true,
           verified_until = greatest(
             coalesce(verified_until, '-infinity'::timestamptz),
             p_expires_at
           )
     where id = p_user_id
     returning * into v_profile;
  elsif p_purchase_type = 'inapp' then
    v_credits_granted := v_expected_credits;
    perform pg_catalog.set_config(
      'x5.permanent_credit_grant_user', p_user_id::text, true
    );
    update public.profiles
       set credits = coalesce(credits, 0) + v_credits_granted
     where id = p_user_id
     returning * into v_profile;
    perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);
  else
    v_expiry_advances := v_profile.subscription_end_date is null
      or p_expires_at > v_profile.subscription_end_date;
    v_credits_granted := case
      when v_expiry_advances then v_expected_credits else 0 end;

    update public.profiles
       set plan = coalesce(v_expected_profile_plan, plan, 'free'),
           credits = coalesce(credits, 0) + v_credits_granted,
           subscription_type = coalesce(
             v_expected_subscription_type,
             subscription_type
           ),
           subscription_date = case
             when v_expiry_advances then now() else subscription_date end,
           subscription_end_date = case
             when v_expiry_advances then p_expires_at
             else subscription_end_date end
     where id = p_user_id
     returning * into v_profile;
  end if;

  update public.iap_entitlements
     set credits_granted = v_credits_granted,
         credited_at = case
           when v_credits_granted > 0 then now() else credited_at end,
         subscription_end_date = p_expires_at,
         expires_at = p_expires_at
   where original_transaction_id = btrim(p_claim_key);

  return jsonb_build_object(
    'already_claimed', false,
    'credits_granted', v_credits_granted,
    'profile', to_jsonb(v_profile)
  );
end;
$function$;

revoke execute on function public.apply_android_purchase_entitlement(
  uuid, text, text, text, text, text, timestamptz,
  integer, text, text, boolean
) from public, anon, authenticated, service_role;
grant execute on function public.apply_android_purchase_entitlement(
  uuid, text, text, text, text, text, timestamptz,
  integer, text, text, boolean
) to service_role;


-- App Review remains email-bound. TestFlight is additionally allowed only for
-- the same two immutable auth UUIDs that own course-management access.
alter table public.app_store_sandbox_review_accounts
  add column if not exists account_kind text;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_exact_email;

update public.app_store_sandbox_review_accounts
   set account_kind = case
     when lower(canonical_email) = 'appreview@x5studio.app'
       then 'app_review'
     when user_id in (
       'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
       'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
     ) then 'developer'
     else null
   end;

delete from public.app_store_sandbox_review_accounts
 where account_kind is null;

insert into public.app_store_sandbox_review_accounts (
  user_id, canonical_email, enabled, max_credit_balance, account_kind
)
select
  account.id,
  lower(account.email),
  true,
  10000,
  'developer'
from auth.users as account
where account.id in (
  'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
  'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
)
  and account.email is not null
on conflict (user_id) do update
set canonical_email = excluded.canonical_email,
    enabled = true,
    max_credit_balance = least(
      public.app_store_sandbox_review_accounts.max_credit_balance,
      10000
    ),
    account_kind = 'developer';

alter table public.app_store_sandbox_review_accounts
  alter column account_kind set not null;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_exact_email;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_exact_scope;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_account_kind;
alter table public.app_store_sandbox_review_accounts
  add constraint app_store_sandbox_review_accounts_account_kind
    check (account_kind in ('app_review', 'developer')),
  add constraint app_store_sandbox_review_accounts_exact_scope
    check (
      (
        account_kind = 'app_review'
        and lower(canonical_email) = 'appreview@x5studio.app'
      ) or (
        account_kind = 'developer'
        and user_id in (
          'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
          'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
        )
      )
    );

create or replace function public.x5_app_store_sandbox_grant_legacy(
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
  refund public.app_store_consumable_refunds%rowtype;
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

  select review.max_credit_balance
    into v_max_credit_balance
    from public.app_store_sandbox_review_accounts as review
    join auth.users as account on account.id = review.user_id
   where review.user_id = p_user_id
     and review.enabled
     and (
       (
         review.account_kind = 'app_review'
         and lower(review.canonical_email) = 'appreview@x5studio.app'
         and lower(account.email) = 'appreview@x5studio.app'
       ) or (
         review.account_kind = 'developer'
         and p_user_id in (
           'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
           'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
         )
       )
     )
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

  if v_is_verified_product then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'app-store-sandbox-review:' || v_transaction_id,
        0
      )
    );
  else
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'app-store-consumable:' || v_environment || ':' || v_transaction_id,
        0
      )
    );
  end if;

  if not v_is_verified_product then
    select tombstone.*
      into refund
      from public.app_store_consumable_refunds as tombstone
     where tombstone.environment = v_environment
       and tombstone.transaction_id = v_transaction_id
     for update;
    if found then
      if refund.user_id <> p_user_id then
        raise exception using errcode = '22023', message = 'owned_by_other';
      end if;
      if refund.original_transaction_id <> v_original_transaction_id
         or refund.product_id <> v_product_id
         or refund.app_account_token <> p_app_account_token
         or refund.purchase_date <> p_purchase_date
         or refund.quantity <> p_quantity
         or refund.credits_reversed not in (0, v_credits) then
        raise exception using errcode = '22023', message = 'transaction_id_conflict';
      end if;
      return jsonb_build_object(
        'status', 'already_applied',
        'credits_granted', 0,
        'subscription_end_date', null,
        'is_verified', false
      );
    end if;
  end if;

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
    transaction_id, original_transaction_id, user_id, product_id,
    environment, app_account_token, purchase_date, expires_date,
    signed_date, revocation_date, quantity, credits_granted,
    is_verified_product
  ) values (
    v_transaction_id, v_original_transaction_id, p_user_id, v_product_id,
    v_environment, p_app_account_token, p_purchase_date, p_expires_date,
    p_signed_date, null, p_quantity, v_credits, v_is_verified_product
  );

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

create table public.app_store_verified_lifecycle_events (
  event_id uuid primary key,
  notification_type text not null,
  notification_subtype text,
  notification_signed_date timestamptz not null,
  transaction_signed_date timestamptz not null,
  renewal_signed_date timestamptz not null,
  environment text not null,
  transaction_id text not null,
  original_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz not null,
  revocation_date timestamptz,
  grace_period_expires_date timestamptz,
  auto_renew_status integer,
  applied boolean not null,
  result_status text not null,
  legacy_binding_used boolean not null default false,
  legacy_binding_original_transaction_id text
    generated always as (
      case when legacy_binding_used then original_transaction_id end
    ) stored,
  legacy_binding_user_id uuid
    generated always as (case when legacy_binding_used then user_id end) stored,
  legacy_binding_app_account_token uuid
    generated always as (
      case when legacy_binding_used then app_account_token end
    ) stored,
  legacy_binding_product_id text
    generated always as (case when legacy_binding_used then product_id end) stored,
  created_at timestamptz not null default now(),
  constraint app_store_verified_lifecycle_events_type
    check (notification_type in (
      'SUBSCRIBED', 'DID_RENEW', 'DID_FAIL_TO_RENEW', 'EXPIRED',
      'GRACE_PERIOD_EXPIRED', 'REVOKE'
    )),
  constraint app_store_verified_lifecycle_events_identity
    check (
      environment in ('Production', 'Sandbox')
      and btrim(transaction_id) <> ''
      and btrim(original_transaction_id) <> ''
      and product_id = 'com.x5studio.app.verified.monthly'
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
    ),
  constraint app_store_verified_lifecycle_events_dates
    check (
      expires_date > purchase_date
      and transaction_signed_date >= purchase_date - interval '5 minutes'
      and renewal_signed_date >= purchase_date - interval '5 minutes'
      and notification_signed_date >=
          transaction_signed_date - interval '5 minutes'
      and notification_signed_date >= renewal_signed_date - interval '5 minutes'
    ),
  constraint app_store_verified_lifecycle_events_shape
    check (
      (
        notification_type = 'REVOKE'
        and revocation_date is not null
      ) or (
        notification_type <> 'REVOKE'
        and revocation_date is null
      )
    ),
  constraint app_store_verified_lifecycle_events_subtype_shape
    check (
      (notification_subtype is null or btrim(notification_subtype) <> '')
      and (
        notification_type <> 'DID_FAIL_TO_RENEW'
        or notification_subtype = 'GRACE_PERIOD'
      )
    ),
  constraint app_store_verified_lifecycle_events_grace_shape
    check (
      notification_type not in (
        'DID_FAIL_TO_RENEW', 'GRACE_PERIOD_EXPIRED'
      )
      or grace_period_expires_date is not null
    ),
  constraint app_store_verified_lifecycle_events_auto_renew
    check (auto_renew_status is null or auto_renew_status in (0, 1)),
  constraint app_store_verified_lifecycle_events_result
    check (result_status in ('applied', 'already_applied', 'ignored_stale'))
);

alter table public.app_store_verified_lifecycle_events
  add constraint app_store_verified_lifecycle_events_legacy_binding_fk
    foreign key (
      legacy_binding_original_transaction_id,
      legacy_binding_user_id,
      legacy_binding_app_account_token,
      legacy_binding_product_id
    ) references public.app_store_legacy_bindings (
      original_transaction_id, user_id, app_account_token, product_id
    );

create or replace function
  public.x5_app_store_lifecycle_transaction_allows_entitlement(
    p_environment text,
    p_transaction_id text
  )
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(
    (
      select latest.notification_type not in (
        'EXPIRED', 'GRACE_PERIOD_EXPIRED'
      )
        from public.app_store_verified_lifecycle_events as latest
       where latest.environment = p_environment
         and latest.transaction_id = p_transaction_id
       order by latest.notification_signed_date desc,
                latest.renewal_signed_date desc,
                latest.transaction_signed_date desc,
                latest.event_id desc
       limit 1
    ),
    true
  );
$function$;

create or replace function public.x5_active_app_store_grace_period(
  p_user_id uuid
)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $function$
  select max(latest.grace_period_expires_date)
    from (
      select distinct on (
        event.environment, event.original_transaction_id
      )
        event.notification_type,
        event.notification_subtype,
        event.grace_period_expires_date,
        event.environment,
        event.original_transaction_id,
        event.transaction_id
      from public.app_store_verified_lifecycle_events as event
      where event.user_id = p_user_id
      order by event.environment, event.original_transaction_id,
               event.notification_signed_date desc,
               event.renewal_signed_date desc,
               event.transaction_signed_date desc,
               event.event_id desc
    ) as latest
   where latest.notification_type = 'DID_FAIL_TO_RENEW'
     and latest.notification_subtype = 'GRACE_PERIOD'
     and latest.grace_period_expires_date > now()
     and not public.x5_app_store_notification_refund_active(
       latest.environment, latest.transaction_id
     );
$function$;

create index app_store_verified_lifecycle_events_user_idx
  on public.app_store_verified_lifecycle_events (user_id, created_at desc);
create index app_store_verified_lifecycle_events_chain_idx
  on public.app_store_verified_lifecycle_events (
    environment, original_transaction_id, notification_signed_date desc
  );

alter table public.app_store_verified_lifecycle_events owner to postgres;
alter table public.app_store_verified_lifecycle_events enable row level security;
alter table public.app_store_verified_lifecycle_events force row level security;
revoke all privileges on table public.app_store_verified_lifecycle_events
  from public, anon, authenticated, service_role;

create trigger x5_app_store_verified_lifecycle_events_append_only
before update or delete on public.app_store_verified_lifecycle_events
for each row execute function
  public.x5_reject_app_store_notification_event_mutation();

create or replace function public.apply_verified_app_store_subscription_lifecycle(
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

comment on table public.app_store_verified_lifecycle_events is
  'Private append-only ledger of fully verified Apple subscription lifecycle JWS payloads.';
comment on function public.apply_verified_app_store_subscription_lifecycle(
  uuid, text, text, timestamptz, uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, integer
) is
  'Applies verified Apple subscription renewal, billing grace, expiry and revoke events exactly once. Service role only.';

comment on table public.app_store_sandbox_review_accounts is
  'Private Sandbox allowlist: canonical App Review plus exactly two immutable developer UUIDs, all under a 10,000-credit cap.';

commit;
