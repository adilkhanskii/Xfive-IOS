-- Google Play grants are keyed to the line item's latest successful order.
-- Expiry snapshots for that same paid order may advance during grace/cancel
-- processing, but can never mint credits a second time or shorten access.

alter table public.iap_entitlements
  add column if not exists successful_order_id text,
  add column if not exists purchase_quantity integer not null default 1,
  add column if not exists refundable_quantity integer not null default 1,
  add column if not exists credits_revoked integer not null default 0,
  add column if not exists revoked_at timestamptz,
  add column if not exists revocation_reason text,
  add column if not exists updated_at timestamptz not null default now();

do $constraints$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'iap_entitlements_purchase_quantity_positive'
       and conrelid = 'public.iap_entitlements'::regclass
  ) then
    alter table public.iap_entitlements
      add constraint iap_entitlements_purchase_quantity_positive
      check (purchase_quantity > 0) not valid;
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'iap_entitlements_refundable_quantity_valid'
       and conrelid = 'public.iap_entitlements'::regclass
  ) then
    alter table public.iap_entitlements
      add constraint iap_entitlements_refundable_quantity_valid
      check (
        refundable_quantity >= 0
        and refundable_quantity <= purchase_quantity
      ) not valid;
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'iap_entitlements_credits_revoked_valid'
       and conrelid = 'public.iap_entitlements'::regclass
  ) then
    alter table public.iap_entitlements
      add constraint iap_entitlements_credits_revoked_valid
      check (credits_revoked >= 0 and credits_revoked <= credits_granted)
      not valid;
  end if;
end;
$constraints$;

alter table public.iap_entitlements
  validate constraint iap_entitlements_purchase_quantity_positive;
alter table public.iap_entitlements
  validate constraint iap_entitlements_refundable_quantity_valid;
alter table public.iap_entitlements
  validate constraint iap_entitlements_credits_revoked_valid;

create index if not exists iap_entitlements_android_successful_order_idx
  on public.iap_entitlements (successful_order_id)
  where lower(coalesce(platform, '')) = 'android'
    and successful_order_id is not null;

create or replace function public.apply_android_purchase_entitlement_v2(
  p_user_id uuid,
  p_claim_key text,
  p_product_id text,
  p_purchase_type text,
  p_purchase_token_hash text,
  p_successful_order_id text,
  p_expires_at timestamptz,
  p_quantity integer,
  p_refundable_quantity integer,
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
  v_access_refreshed boolean := false;
  v_preserve_permanent_access boolean := false;
  v_expected_purchase_type text;
  v_expected_credits integer;
  v_expected_subscription_type text;
  v_expected_profile_plan text;
  v_expected_verified boolean;
begin
  if p_user_id is null
     or nullif(btrim(p_claim_key), '') is null
     or nullif(btrim(p_product_id), '') is null
     or nullif(btrim(p_purchase_token_hash), '') is null
     or nullif(btrim(p_successful_order_id), '') is null then
    raise exception using errcode = '22023',
      message = 'invalid_android_entitlement';
  end if;

  if p_claim_key <> btrim(p_product_id) || ':' ||
      btrim(p_purchase_token_hash) || ':' || btrim(p_successful_order_id) then
    raise exception using errcode = '22023',
      message = 'invalid_android_claim_key';
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
  if p_quantity is null or p_quantity <= 0
     or p_refundable_quantity is null or p_refundable_quantity < 0
     or p_refundable_quantity > p_quantity then
    raise exception using errcode = '22023',
      message = 'invalid_android_purchase_quantity';
  end if;
  if p_purchase_type = 'subscription' then
    if p_quantity <> 1 or p_refundable_quantity <> 1
       or p_expires_at is null or p_expires_at <= clock_timestamp() then
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
  v_preserve_permanent_access := v_profile.plan = 'black'
    or (
      lower(coalesce(v_profile.plan, 'free')) in ('lite', 'pro', 'max')
      and v_profile.subscription_end_date is null
    );

  insert into public.iap_entitlements (
    original_transaction_id, claim_key, user_id, product_id, platform,
    purchase_type, purchase_token_hash, order_id, successful_order_id,
    expires_at, subscription_end_date, app_account_token,
    purchase_quantity, refundable_quantity, credits_revoked
  ) values (
    btrim(p_claim_key), btrim(p_claim_key), p_user_id, btrim(p_product_id),
    'android', p_purchase_type, btrim(p_purchase_token_hash),
    btrim(p_successful_order_id), btrim(p_successful_order_id),
    p_expires_at, p_expires_at, p_user_id,
    p_quantity, p_refundable_quantity, 0
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
       or lower(coalesce(v_existing_entitlement.platform, '')) <> 'android'
       or v_existing_entitlement.purchase_type <> p_purchase_type
       or v_existing_entitlement.purchase_token_hash <>
          btrim(p_purchase_token_hash)
       or v_existing_entitlement.successful_order_id <>
          btrim(p_successful_order_id)
       or v_existing_entitlement.app_account_token <> p_user_id
       or v_existing_entitlement.purchase_quantity <> p_quantity then
      raise exception using errcode = '22023',
        message = 'android_claim_key_conflict';
    end if;

    if p_purchase_type = 'subscription'
       and p_expires_at > v_existing_entitlement.expires_at then
      v_access_refreshed := true;
      update public.iap_entitlements
         set expires_at = p_expires_at,
             subscription_end_date = p_expires_at,
             refundable_quantity = p_refundable_quantity,
             updated_at = now()
       where original_transaction_id = btrim(p_claim_key);

      if p_verified then
        update public.profiles
           set is_verified = true,
               verified_until = greatest(
                 coalesce(verified_until, '-infinity'::timestamptz),
                 p_expires_at
               )
         where id = p_user_id
         returning * into v_profile;
      elsif not v_preserve_permanent_access then
        update public.profiles
           set plan = coalesce(v_expected_profile_plan, plan, 'free'),
               subscription_type = coalesce(
                 v_expected_subscription_type,
                 subscription_type
               ),
               subscription_end_date = greatest(
                 coalesce(subscription_end_date, '-infinity'::timestamptz),
                 p_expires_at
               )
         where id = p_user_id
         returning * into v_profile;
      end if;
    end if;

    return jsonb_build_object(
      'already_claimed', true,
      'credits_granted', 0,
      'access_refreshed', v_access_refreshed,
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
    v_credits_granted := v_expected_credits * p_quantity;
    perform pg_catalog.set_config(
      'x5.permanent_credit_grant_user', p_user_id::text, true
    );
    update public.profiles
       set credits = coalesce(credits, 0) + v_credits_granted
     where id = p_user_id
     returning * into v_profile;
    perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);
  else
    v_expiry_advances := not v_preserve_permanent_access
      and (
        v_profile.subscription_end_date is null
        or p_expires_at > v_profile.subscription_end_date
      );
    -- A successful paid order owns its monthly credit grant exactly once.
    -- Access projection is independent: a longer Apple/manual entitlement may
    -- keep the profile expiry farther out without suppressing paid credits.
    v_credits_granted := v_expected_credits;

    update public.profiles
       set plan = case
             when v_expiry_advances
               then coalesce(v_expected_profile_plan, plan, 'free')
             else plan
           end,
           credits = coalesce(credits, 0) + v_credits_granted,
           subscription_type = case
             when v_expiry_advances
               then coalesce(v_expected_subscription_type, subscription_type)
             else subscription_type
           end,
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
         updated_at = now()
   where original_transaction_id = btrim(p_claim_key);

  return jsonb_build_object(
    'already_claimed', false,
    'credits_granted', v_credits_granted,
    'access_refreshed', false,
    'profile', to_jsonb(v_profile)
  );
end;
$function$;

revoke execute on function public.apply_android_purchase_entitlement_v2(
  uuid, text, text, text, text, text, timestamptz,
  integer, integer, integer, text, text, boolean
) from public, anon, authenticated, service_role;
grant execute on function public.apply_android_purchase_entitlement_v2(
  uuid, text, text, text, text, text, timestamptz,
  integer, integer, integer, text, text, boolean
) to service_role;

create or replace function public.close_android_linked_subscription(
  p_user_id uuid,
  p_linked_purchase_token_hash text,
  p_replacement_purchase_token_hash text,
  p_effective_time timestamptz
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_closed integer := 0;
  v_replacement_exists boolean := false;
begin
  if p_user_id is null
     or nullif(btrim(p_linked_purchase_token_hash), '') is null
     or nullif(btrim(p_replacement_purchase_token_hash), '') is null
     or p_linked_purchase_token_hash = p_replacement_purchase_token_hash
     or p_effective_time is null then
    raise exception using errcode = '22023',
      message = 'invalid_android_linked_subscription';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(btrim(p_linked_purchase_token_hash), 0)
  );

  select exists (
    select 1
      from public.iap_entitlements as replacement
     where replacement.user_id = p_user_id
       and lower(coalesce(replacement.platform, '')) = 'android'
       and replacement.purchase_type = 'subscription'
       and replacement.purchase_token_hash =
           btrim(p_replacement_purchase_token_hash)
  ) into v_replacement_exists;
  if not v_replacement_exists then
    raise exception using errcode = '22023',
      message = 'replacement_subscription_unavailable';
  end if;

  update public.iap_entitlements
     set revoked_at = case
           when revoked_at is null or revoked_at > p_effective_time
             then p_effective_time
           else revoked_at
         end,
         revocation_reason = 'subscription_replaced',
         expires_at = least(
           coalesce(expires_at, p_effective_time),
           p_effective_time
         ),
         subscription_end_date = least(
           coalesce(subscription_end_date, p_effective_time),
           p_effective_time
         ),
         updated_at = now()
   where user_id = p_user_id
     and lower(coalesce(platform, '')) = 'android'
     and purchase_type = 'subscription'
     and purchase_token_hash = btrim(p_linked_purchase_token_hash)
     and purchase_token_hash <> btrim(p_replacement_purchase_token_hash)
     and coalesce(expires_at, subscription_end_date) > p_effective_time;
  get diagnostics v_closed = row_count;

  perform public.x5_rebuild_app_store_verified_profile(p_user_id);
  perform public.x5_reconcile_paid_plan_profile(p_user_id);
  return v_closed;
end;
$function$;

revoke execute on function public.close_android_linked_subscription(
  uuid, text, text, timestamptz
) from public, anon, authenticated, service_role;
grant execute on function public.close_android_linked_subscription(
  uuid, text, text, timestamptz
) to service_role;
