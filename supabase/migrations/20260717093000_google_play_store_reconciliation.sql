-- Private exact-once ledger for Google RTDN and Voided Purchases recovery.
-- Raw purchase tokens are never stored; callers pass only SHA-256 hashes.

alter table public.iap_entitlements
  add column if not exists revoked_at timestamptz,
  add column if not exists revocation_reason text;

create table public.google_play_reconciliation_events (
  event_id text primary key,
  event_kind text not null,
  purchase_token_hash text not null,
  successful_order_id text,
  original_transaction_id text not null
    references public.iap_entitlements(original_transaction_id),
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  event_time timestamptz not null,
  snapshot_subscription_state text,
  snapshot_expiry timestamptz,
  requested_voided_quantity integer not null default 0,
  voided_quantity integer not null default 0,
  reverse_credits boolean not null,
  credits_reversed integer not null default 0,
  result_status text not null default 'applied'
    check (result_status in ('applied', 'ignored_stale')),
  created_at timestamptz not null default now(),
  constraint google_play_reconciliation_event_id_nonempty
    check (btrim(event_id) <> ''),
  constraint google_play_reconciliation_token_hash_nonempty
    check (btrim(purchase_token_hash) <> ''),
  constraint google_play_reconciliation_kind_valid
    check (event_kind in (
      'voided_full', 'voided_partial', 'subscription_revoked',
      'subscription_expired', 'subscription_on_hold', 'subscription_paused',
      'one_time_canceled'
    )),
  constraint google_play_reconciliation_amounts_nonnegative
    check (
      requested_voided_quantity >= 0
      and voided_quantity >= 0
      and credits_reversed >= 0
    )
);

create index google_play_reconciliation_events_user_idx
  on public.google_play_reconciliation_events (user_id, event_time desc);
create index google_play_reconciliation_events_token_idx
  on public.google_play_reconciliation_events (purchase_token_hash);

alter table public.google_play_reconciliation_events owner to postgres;
alter table public.google_play_reconciliation_events enable row level security;
alter table public.google_play_reconciliation_events force row level security;
revoke all privileges on table public.google_play_reconciliation_events
  from public, anon, authenticated, service_role;

create or replace function public.apply_google_play_reversal(
  p_event_id text,
  p_event_kind text,
  p_purchase_token_hash text,
  p_successful_order_id text,
  p_event_time timestamptz,
  p_voided_quantity integer,
  p_reverse_credits boolean,
  p_snapshot_subscription_state text,
  p_snapshot_expiry timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_source public.iap_entitlements%rowtype;
  v_existing public.google_play_reconciliation_events%rowtype;
  v_quantity integer := 0;
  v_credits integer := 0;
  v_remaining_credits integer := 0;
  v_newer_claim_exists boolean := false;
  v_snapshot_matches_terminal boolean := false;
  v_snapshot_currently_entitled boolean := false;
  v_source_postdates_event boolean := false;
  v_effective_time timestamptz;
  v_profile public.profiles%rowtype;
begin
  if nullif(btrim(p_event_id), '') is null
     or nullif(btrim(p_purchase_token_hash), '') is null
     or p_event_kind not in (
       'voided_full', 'voided_partial', 'subscription_revoked',
       'subscription_expired', 'subscription_on_hold', 'subscription_paused',
       'one_time_canceled'
     )
     or p_event_time is null
     or p_event_time > clock_timestamp() + interval '10 minutes'
     or coalesce(p_voided_quantity, 0) < 0
     or p_reverse_credits is null then
    raise exception using errcode = '22023',
      message = 'invalid_google_play_reversal';
  end if;
  if p_event_kind in (
       'subscription_revoked', 'subscription_expired', 'subscription_on_hold',
       'subscription_paused'
     ) and (
       nullif(btrim(p_successful_order_id), '') is null
       or nullif(btrim(p_snapshot_subscription_state), '') is null
       or p_snapshot_expiry is null
     ) then
    raise exception using errcode = '22023',
      message = 'invalid_google_play_subscription_snapshot';
  end if;
  if p_event_kind = 'voided_partial'
     and coalesce(p_voided_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'authoritative_voided_quantity_required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(btrim(p_purchase_token_hash), 0)
  );

  select event.*
    into v_existing
    from public.google_play_reconciliation_events as event
   where event.event_id = btrim(p_event_id)
   for update;
  if found then
    if v_existing.event_kind <> p_event_kind
       or v_existing.purchase_token_hash <> btrim(p_purchase_token_hash)
       or v_existing.event_time <> p_event_time
       or v_existing.requested_voided_quantity <>
          coalesce(p_voided_quantity, 0)
       or v_existing.reverse_credits <> p_reverse_credits
       or (
         v_existing.event_id not like 'rtdn:%'
         and (
           v_existing.successful_order_id is distinct from
             nullif(btrim(p_successful_order_id), '')
           or v_existing.snapshot_subscription_state is distinct from
             nullif(btrim(p_snapshot_subscription_state), '')
           or v_existing.snapshot_expiry is distinct from p_snapshot_expiry
         )
       ) then
      raise exception using errcode = '22023',
        message = 'google_play_reversal_event_conflict';
    end if;
    return jsonb_build_object(
      'status', case
        when v_existing.result_status = 'ignored_stale'
          then 'ignored_stale'
        else 'already_applied'
      end,
      'user_id', v_existing.user_id,
      'product_id', v_existing.product_id,
      'credits_reversed', v_existing.credits_reversed
    );
  end if;

  select entitlement.*
    into v_source
    from public.iap_entitlements as entitlement
   where lower(coalesce(entitlement.platform, '')) = 'android'
     and entitlement.purchase_token_hash = btrim(p_purchase_token_hash)
     and (
       nullif(btrim(p_successful_order_id), '') is null
       or entitlement.successful_order_id = btrim(p_successful_order_id)
       or entitlement.order_id = btrim(p_successful_order_id)
     )
   order by entitlement.created_at desc
   limit 1
   for update;
  if not found then
    return jsonb_build_object('status', 'source_not_found');
  end if;

  if v_source.purchase_type = 'inapp'
     and p_event_kind not in (
       'voided_full', 'voided_partial', 'one_time_canceled'
     ) then
    raise exception using errcode = '22023',
      message = 'google_play_reversal_type_mismatch';
  end if;
  if v_source.purchase_type = 'subscription'
     and p_event_kind = 'one_time_canceled' then
    raise exception using errcode = '22023',
      message = 'google_play_reversal_type_mismatch';
  end if;

  if v_source.purchase_type = 'subscription'
     and p_event_kind in (
       'subscription_revoked', 'subscription_expired', 'subscription_on_hold',
       'subscription_paused'
     ) then
    v_snapshot_matches_terminal := case
      when p_event_kind = 'subscription_on_hold' then
        p_snapshot_subscription_state = 'SUBSCRIPTION_STATE_ON_HOLD'
      when p_event_kind = 'subscription_paused' then
        p_snapshot_subscription_state = 'SUBSCRIPTION_STATE_PAUSED'
      else p_snapshot_subscription_state = 'SUBSCRIPTION_STATE_EXPIRED'
    end;
    v_snapshot_currently_entitled :=
      p_snapshot_subscription_state in (
        'SUBSCRIPTION_STATE_ACTIVE',
        'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
        'SUBSCRIPTION_STATE_CANCELED'
      )
      and p_snapshot_expiry > greatest(p_event_time, clock_timestamp());
    -- RTDN does not identify the source renewal. A delayed terminal message
    -- must not be attached to an order first recorded well after that event.
    -- Five minutes allows the normal RTDN-before-client verification race.
    v_source_postdates_event :=
      coalesce(v_source.credited_at, v_source.created_at) >
        p_event_time + interval '5 minutes';
    select exists (
      select 1
        from public.iap_entitlements as newer
       where lower(coalesce(newer.platform, '')) = 'android'
         and newer.purchase_type = 'subscription'
         and newer.purchase_token_hash = btrim(p_purchase_token_hash)
          and newer.successful_order_id is distinct from
              btrim(p_successful_order_id)
          and coalesce(newer.expires_at, newer.subscription_end_date) >
              clock_timestamp()
          and coalesce(newer.expires_at, newer.subscription_end_date) >
              coalesce(v_source.expires_at, v_source.subscription_end_date)
    ) into v_newer_claim_exists;
  end if;

  if v_source.purchase_type = 'subscription'
     and p_event_kind in (
       'subscription_revoked', 'subscription_expired', 'subscription_on_hold',
       'subscription_paused'
     )
     and (
       not v_snapshot_matches_terminal
       or v_snapshot_currently_entitled
       or v_newer_claim_exists
       or v_source_postdates_event
     ) then
    insert into public.google_play_reconciliation_events (
      event_id, event_kind, purchase_token_hash, successful_order_id,
      original_transaction_id, user_id, product_id, event_time,
      snapshot_subscription_state, snapshot_expiry,
      requested_voided_quantity, voided_quantity, reverse_credits,
      credits_reversed, result_status
    ) values (
      btrim(p_event_id), p_event_kind, btrim(p_purchase_token_hash),
      nullif(btrim(p_successful_order_id), ''),
      v_source.original_transaction_id, v_source.user_id,
      v_source.product_id, p_event_time,
      nullif(btrim(p_snapshot_subscription_state), ''), p_snapshot_expiry,
      coalesce(p_voided_quantity, 0), 0,
      p_reverse_credits, 0,
      'ignored_stale'
    );
    return jsonb_build_object(
      'status', 'ignored_stale',
      'user_id', v_source.user_id,
      'product_id', v_source.product_id,
      'credits_reversed', 0
    );
  end if;

  v_effective_time := case
    when p_event_kind = 'subscription_expired' then p_snapshot_expiry
    else p_event_time
  end;

  if p_event_kind in ('voided_full', 'subscription_revoked') then
    v_quantity := v_source.refundable_quantity;
  elsif p_event_kind in ('voided_partial', 'one_time_canceled') then
    v_quantity := least(
      v_source.refundable_quantity,
      greatest(coalesce(p_voided_quantity, 1), 1)
    );
  else
    v_quantity := 0;
  end if;

  v_remaining_credits := greatest(
    v_source.credits_granted - v_source.credits_revoked,
    0
  );
  if p_reverse_credits and v_quantity > 0 then
    if v_quantity = v_source.refundable_quantity then
      v_credits := v_remaining_credits;
    else
      v_credits := least(
        v_remaining_credits,
        (v_source.credits_granted / v_source.purchase_quantity) * v_quantity
      );
    end if;
  end if;

  insert into public.google_play_reconciliation_events (
    event_id, event_kind, purchase_token_hash, successful_order_id,
    original_transaction_id, user_id, product_id, event_time,
    snapshot_subscription_state, snapshot_expiry,
    requested_voided_quantity, voided_quantity, reverse_credits,
    credits_reversed, result_status
  ) values (
    btrim(p_event_id), p_event_kind, btrim(p_purchase_token_hash),
    nullif(btrim(p_successful_order_id), ''),
    v_source.original_transaction_id, v_source.user_id,
    v_source.product_id, p_event_time,
    nullif(btrim(p_snapshot_subscription_state), ''), p_snapshot_expiry,
    coalesce(p_voided_quantity, 0),
    v_quantity, p_reverse_credits, v_credits,
    'applied'
  );

  if v_quantity > 0 or p_event_kind in (
    'subscription_revoked', 'subscription_expired', 'subscription_on_hold',
    'subscription_paused'
  ) then
    update public.iap_entitlements
       set refundable_quantity = refundable_quantity - v_quantity,
           credits_revoked = credits_revoked + v_credits,
           revoked_at = case
             when purchase_type = 'subscription'
               or refundable_quantity - v_quantity = 0
             then v_effective_time else revoked_at
           end,
           revocation_reason = p_event_kind,
           expires_at = case
             when purchase_type = 'subscription' then least(
               coalesce(expires_at, v_effective_time), v_effective_time
             )
             else expires_at
           end,
           subscription_end_date = case
             when purchase_type = 'subscription' then least(
               coalesce(subscription_end_date, v_effective_time),
               v_effective_time
             )
             else subscription_end_date
           end,
           updated_at = now()
     where original_transaction_id = v_source.original_transaction_id;
  end if;

  if v_credits > 0 then
    if v_source.purchase_type = 'inapp' then
      perform pg_catalog.set_config(
        'x5.permanent_credit_adjustment_user', v_source.user_id::text, true
      );
    end if;
    update public.profiles
       set credits = coalesce(credits, 0) - v_credits
     where id = v_source.user_id
     returning * into v_profile;
    if v_source.purchase_type = 'inapp' then
      perform pg_catalog.set_config(
        'x5.permanent_credit_adjustment_user', '', true
      );
    end if;
  end if;

  if v_source.purchase_type = 'subscription' then
    if v_source.product_id in (
      'x5_verified_monthly_v2', 'x5_verified_monthly'
    ) then
      perform public.x5_rebuild_app_store_verified_profile(v_source.user_id);
    else
      -- Reconcile needs the automated profile projection to observe the
      -- terminal cutoff. Permanent black/manual null-end access is excluded.
      update public.profiles
         set subscription_end_date = least(
           subscription_end_date,
           v_effective_time
         )
       where id = v_source.user_id
         and lower(coalesce(plan, 'free')) in ('lite', 'pro', 'max')
         and subscription_end_date is not null;
      perform public.x5_reconcile_paid_plan_profile(v_source.user_id);
    end if;
  end if;

  select profile.* into v_profile
    from public.profiles as profile
   where profile.id = v_source.user_id;

  return jsonb_build_object(
    'status', 'applied',
    'user_id', v_source.user_id,
    'product_id', v_source.product_id,
    'quantity_reversed', v_quantity,
    'credits_reversed', v_credits,
    'profile', to_jsonb(v_profile)
  );
end;
$function$;

revoke execute on function public.apply_google_play_reversal(
  text, text, text, text, timestamptz, integer, boolean, text, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.apply_google_play_reversal(
  text, text, text, text, timestamptz, integer, boolean, text, timestamptz
) to service_role;
