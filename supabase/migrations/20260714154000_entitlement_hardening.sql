-- Keep profile balances and entitlements server-owned while remaining
-- backward-compatible with older app builds that still PATCH those fields.
-- Direct client writes are silently restored to their previous values; trusted
-- SECURITY DEFINER functions and service-role jobs are unaffected.

begin;

create or replace function public.x5_protect_profile_entitlements()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.plan := 'free';
    new.credits := 0;
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
$$;

-- BEFORE triggers run alphabetically. Protect the client-supplied value first,
-- then let trg_assign_signup_number assign the trusted sequence value.
drop trigger if exists x5_protect_profile_entitlements on public.profiles;
drop trigger if exists a_x5_protect_profile_entitlements on public.profiles;
create trigger a_x5_protect_profile_entitlements
before insert or update on public.profiles
for each row execute function public.x5_protect_profile_entitlements();

revoke execute on function public.x5_protect_profile_entitlements() from public, anon, authenticated;

-- Existing paid subscribers previously received course access through their
-- generic Pro flag. Preserve that already-promised access before new clients
-- switch to explicit course ownership.
with paid_courses as (
  select coalesce(array_agg(c.id::text order by c.id::text), array[]::text[]) as ids
    from public.courses as c
   where coalesce(c.is_public, false)
     and not coalesce(c.is_free, false)
     and greatest(coalesce(c.price, 0), 0) > 0
)
update public.profiles as p
   set purchased_course_ids = (
     select array_agg(distinct course_id order by course_id)
       from unnest(coalesce(p.purchased_course_ids, array[]::text[]) || paid_courses.ids) as course_id
   )
  from paid_courses
 where p.plan in ('pro', 'black')
   and cardinality(paid_courses.ids) > 0;

-- A transaction id changes on every App Store renewal. Tracking it together
-- with the Apple expiry prevents restore/retry from granting credits twice and
-- lets one new monthly period grant credits exactly once.
-- Some older environments created this table from Dashboard SQL instead of a
-- checked-in migration. Keep a complete baseline here so a clean migration
-- replay does not depend on that out-of-band state.
create table if not exists public.iap_entitlements (
  original_transaction_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  platform text not null default 'ios',
  app_account_token uuid,
  credited_at timestamptz,
  credits_granted integer not null default 0,
  subscription_end_date timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint iap_entitlements_original_transaction_id_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint iap_entitlements_credits_granted_nonnegative
    check (credits_granted >= 0)
);

alter table public.iap_entitlements enable row level security;
revoke all privileges on table public.iap_entitlements from public, anon, authenticated;
grant select, insert, update, delete on table public.iap_entitlements to service_role;

alter table public.iap_entitlements
  add column if not exists last_transaction_id text;

create or replace function public.claim_iap_entitlement_v2(
  p_original_transaction_id text,
  p_transaction_id text,
  p_product_id text,
  p_platform text default 'ios',
  p_app_account_token text default null,
  p_expiration_date timestamptz default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.iap_entitlements%rowtype;
  v_app_account_token uuid;
  v_credits integer;
  v_subscription_type text;
  v_period_end timestamptz;
  v_should_grant boolean := false;
  v_is_verified_product boolean := false;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  if nullif(btrim(p_original_transaction_id), '') is null
     or nullif(btrim(p_transaction_id), '') is null then
    return 'invalid_transaction';
  end if;

  begin
    v_app_account_token := nullif(btrim(p_app_account_token), '')::uuid;
  exception
    when invalid_text_representation then
      return 'invalid_account_token';
  end;

  if v_app_account_token is not null and v_app_account_token <> v_uid then
    return 'owned_by_other';
  end if;

  v_credits := case p_product_id
    when 'com.x5studio.app.lite.monthly' then 1000
    when 'com.x5studio.app.pro.monthly' then 2000
    when 'com.x5studio.app.max.monthly' then 5000
    when 'x5_lite_monthly' then 1000
    when 'x5_pro_monthly' then 2000
    when 'x5_max_monthly' then 5000
    else 0
  end;

  v_subscription_type := case p_product_id
    when 'com.x5studio.app.lite.monthly' then 'lite_monthly'
    when 'com.x5studio.app.pro.monthly' then 'pro_monthly'
    when 'com.x5studio.app.max.monthly' then 'max_monthly'
    when 'x5_lite_monthly' then 'lite_monthly'
    when 'x5_pro_monthly' then 'pro_monthly'
    when 'x5_max_monthly' then 'max_monthly'
    else null
  end;

  v_is_verified_product := p_product_id in (
    'com.x5studio.app.verified.monthly',
    'x5_verified_monthly'
  );

  if v_credits = 0 and not v_is_verified_product then
    return 'unknown_product';
  end if;

  v_period_end := coalesce(
    p_expiration_date,
    now() + interval '1 month'
  );

  select *
    into v_row
    from public.iap_entitlements
   where original_transaction_id = btrim(p_original_transaction_id)
   for update;

  if not found then
    -- New StoreKit 2 purchases are bound to the signed-in X5 account.
    if v_app_account_token is null then
      return 'missing_account_token';
    end if;

    insert into public.iap_entitlements (
      original_transaction_id,
      user_id,
      product_id,
      platform,
      app_account_token,
      last_transaction_id,
      subscription_end_date
    ) values (
      btrim(p_original_transaction_id),
      v_uid,
      p_product_id,
      coalesce(nullif(btrim(p_platform), ''), 'ios'),
      v_app_account_token,
      null,
      null
    )
    returning * into v_row;
    v_should_grant := true;
  elsif v_row.user_id <> v_uid then
    return 'owned_by_other';
  elsif v_row.app_account_token is not null
        and v_row.app_account_token <> v_uid then
    return 'owned_by_other';
  elsif v_row.last_transaction_id is not distinct from btrim(p_transaction_id) then
    v_should_grant := false;
  elsif v_row.credited_at is null then
    v_should_grant := true;
  elsif p_expiration_date is not null
        and (
          v_row.subscription_end_date is null
          or p_expiration_date > v_row.subscription_end_date + interval '60 seconds'
        ) then
    v_should_grant := true;
  end if;

  update public.iap_entitlements
     set product_id = p_product_id,
         platform = coalesce(nullif(btrim(p_platform), ''), platform),
         app_account_token = coalesce(v_app_account_token, app_account_token),
         last_transaction_id = btrim(p_transaction_id),
         credited_at = case when v_should_grant then now() else credited_at end,
         credits_granted = credits_granted + case when v_should_grant then v_credits else 0 end,
         subscription_end_date = greatest(
           coalesce(subscription_end_date, '-infinity'::timestamptz),
           v_period_end
         )
   where original_transaction_id = btrim(p_original_transaction_id);

  if v_credits > 0 then
    insert into public.profiles (
      id,
      credits,
      plan,
      subscription_type,
      subscription_date,
      subscription_end_date
    ) values (
      v_uid,
      case when v_should_grant then v_credits else 0 end,
      'pro',
      v_subscription_type,
      now(),
      v_period_end
    )
    on conflict (id) do update
       set credits = coalesce(public.profiles.credits, 0)
                     + case when v_should_grant then v_credits else 0 end,
           plan = 'pro',
           subscription_type = v_subscription_type,
           subscription_date = coalesce(public.profiles.subscription_date, excluded.subscription_date),
           subscription_end_date = greatest(
             coalesce(public.profiles.subscription_end_date, '-infinity'::timestamptz),
             excluded.subscription_end_date
           );
  else
    insert into public.profiles (id, is_verified, verified_until)
    values (v_uid, true, v_period_end)
    on conflict (id) do update
       set is_verified = true,
           verified_until = greatest(
             coalesce(public.profiles.verified_until, '-infinity'::timestamptz),
             excluded.verified_until
           );
  end if;

  if v_should_grant then
    return 'claimed';
  end if;
  return 'already_owned';
end;
$$;

revoke execute on function public.claim_iap_entitlement_v2(text, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.claim_iap_entitlement_v2(text, text, text, text, text, timestamptz)
  to service_role;

-- The legacy objects existed only in out-of-band production SQL on some
-- environments. Guard them so clean migration replays remain valid.
do $guards$
begin
  if to_regprocedure('public.claim_iap_entitlement(text,text,text,text)') is not null then
    execute 'alter function public.claim_iap_entitlement(text, text, text, text) set search_path = ''''';
    execute 'revoke execute on function public.claim_iap_entitlement(text, text, text, text) from public, anon, authenticated';
    execute 'grant execute on function public.claim_iap_entitlement(text, text, text, text) to service_role';
  end if;
end;
$guards$;

-- Separate-lesson sales had no safe server-priced flow. Disable the old RPC;
-- iOS now grants lesson access only via full-course ownership or free preview.
do $guards$
begin
  if to_regprocedure('public.purchase_lesson(text,text,integer)') is not null then
    execute 'revoke execute on function public.purchase_lesson(text, text, integer) from public, anon, authenticated';
    execute 'grant execute on function public.purchase_lesson(text, text, integer) to service_role';
  end if;
end;
$guards$;

commit;
