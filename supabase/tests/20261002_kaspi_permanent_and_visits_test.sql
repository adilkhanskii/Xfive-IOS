-- Kaspi credits are permanent, visit tracking is write-only, and the three
-- migrations involved re-run cleanly.
--
-- Runs on a blank throwaway Postgres (never against a real project): it builds
-- stand-ins for the Supabase pieces the migrations touch, applies
--   20260813150000_kaspi_credit_payments.sql   (already live in production)
--   20260903150000_kaspi_manual_transfers.sql
--   20261002130000_kaspi_permanent_credit_grants.sql
--   20260925090000_admin_analytics.sql
-- then applies the last three a second time and checks behaviour.
--
--   docker run -d --name x5-mig-test -e POSTGRES_PASSWORD=test postgres:16-alpine
--   docker exec x5-mig-test mkdir -p /work/supabase
--   docker cp supabase/migrations x5-mig-test:/work/supabase/migrations
--   docker cp supabase/tests x5-mig-test:/work/supabase/tests
--   MSYS_NO_PATHCONV=1 docker exec x5-mig-test psql -U postgres -X -v ON_ERROR_STOP=1 \
--     -f /work/supabase/tests/20261002_kaspi_permanent_and_visits_test.sql
--   docker rm -f x5-mig-test
--
-- Fidelity notes. The retention trigger, the entitlement-protection trigger,
-- is_x5_developer() and auth.uid()/role()/jwt() are verbatim copies of the
-- production definitions (pg_get_functiondef, 2026-10-02). Objects are created
-- by x5_owner, a NON-superuser role with BYPASSRLS, which is exactly what
-- production's postgres role is. Supabase's default privileges (every new table
-- and function in public is granted to anon, authenticated and service_role)
-- are reproduced, so a missing revoke shows up as a failure here.

\set ON_ERROR_STOP on
\set VERBOSITY terse
set client_min_messages = warning;

-- ------------------------------------------------------------- stand-ins ----

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role x5_owner nologin bypassrls;

grant all on schema public to x5_owner;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges for role x5_owner in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role x5_owner in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges for role x5_owner in schema public
  grant all on sequences to anon, authenticated, service_role;

create schema auth;
create table auth.users (id uuid primary key);

-- production definition
CREATE OR REPLACE FUNCTION auth.jwt()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select 
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
$function$;

-- production definition
CREATE OR REPLACE FUNCTION auth.role()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$function$;

-- production definition
CREATE OR REPLACE FUNCTION auth.uid()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$function$;

grant usage on schema auth to anon, authenticated, service_role, x5_owner;
grant execute on all functions in schema auth to anon, authenticated, service_role, x5_owner;
grant select, references on auth.users to x5_owner;

-- Test helpers: switch the effective role and JWT claims the way PostgREST
-- does (transaction-local set_config), and back to the superuser session.
create schema x5_test;
grant usage on schema x5_test to public;
create function x5_test.act_as(p_role text, p_uid uuid default null)
returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object('role', p_role, 'sub', p_uid))::text,
    true
  );
  perform set_config('role', p_role, true);
end;
$$;
-- The guard configure_kaspi_manual_transfers used before 2026-10-02, kept only to
-- show it refused even the service role (owner = superuser, like production).
create function x5_test.old_configure_guard_refuses()
returns boolean language sql security definer as $$
  select current_setting('request.jwt.claim.role', true) is distinct from 'service_role'
     and current_user <> 'service_role'
$$;
create function x5_test.act_as_admin()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'none', true);
end;
$$;

set role x5_owner;

create table public.profiles (
  id uuid primary key references auth.users (id),
  name text, nickname text, email text, plan text,
  credits integer default 0,
  permanent_credits integer not null default 0,
  permanent_credit_debt integer not null default 0,
  credits_expires_at timestamptz,
  credits_retention_months integer default 1,
  is_verified boolean default false,
  verified_until timestamptz,
  purchased_course_ids text[], purchased_lesson_ids text[],
  subscription_type text, subscription_date timestamptz,
  subscription_end_date timestamptz, purchase_history jsonb,
  signup_number bigint, registration_platform text, country_code text,
  city text, language text, created_at timestamptz default now(),
  last_seen timestamptz
);
alter table public.profiles enable row level security;

-- production definition (pg_get_functiondef, 2026-10-02)
CREATE OR REPLACE FUNCTION public.x5_profile_has_active_verified_badge(p_is_verified boolean, p_verified_until timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(p_is_verified, false)
     and p_verified_until is not null
     and p_verified_until > now()
$function$;

-- production definition (pg_get_functiondef, 2026-10-02)
CREATE OR REPLACE FUNCTION public.is_x5_developer()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(
    (select auth.uid()) in (
      'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
      'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
    ),
    false
  );
$function$;

-- production definition (pg_get_functiondef, 2026-10-02)
CREATE OR REPLACE FUNCTION public.x5_protect_profile_entitlements()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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

-- production definition (pg_get_functiondef, 2026-10-02)
CREATE OR REPLACE FUNCTION public.x5_prepare_credit_retention()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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

create trigger a_x5_protect_profile_entitlements
  before insert or update on public.profiles
  for each row execute function public.x5_protect_profile_entitlements();
create trigger profiles_credit_retention
  before insert or update of credits, is_verified, verified_until on public.profiles
  for each row execute function public.x5_prepare_credit_retention();

-- Tables the analytics reports read (columns as in production).
create table public.iap_entitlements (
  original_transaction_id text primary key,
  user_id uuid, product_id text, platform text, purchase_type text,
  credits_granted integer, credits_revoked integer, revocation_reason text,
  created_at timestamptz default now(), credited_at timestamptz,
  revoked_at timestamptz
);
create table public.image_generation_requests (
  id uuid primary key default gen_random_uuid(), user_id uuid, status text,
  cost_credits integer, error_code text, refunded_at timestamptz,
  created_at timestamptz default now()
);
create table public.voice_generation_requests (like public.image_generation_requests including all);
create table public.video_generation_jobs (like public.image_generation_requests including all);
create table public.lipsync_generation_jobs (like public.image_generation_requests including all);
create table public.ai_provider_health (
  provider text, capability text, configured boolean, available boolean,
  model text, last_success_at timestamptz, last_failure_at timestamptz,
  last_error_code text, updated_at timestamptz
);

-- ------------------------------------------------- migrations, first pass ----

\echo '== apply 20260813150000_kaspi_credit_payments.sql (production state)'
\ir ../migrations/20260813150000_kaspi_credit_payments.sql
\echo '== apply 20260903150000_kaspi_manual_transfers.sql'
\ir ../migrations/20260903150000_kaspi_manual_transfers.sql

reset role;

-- Seed: two buyers with 300 expiring credits each, one control buyer, and the
-- first production developer account.
insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('a0000000-0000-4000-8000-000000000002'),
  ('a0000000-0000-4000-8000-000000000003'),
  ('f3eea23f-0aeb-405b-ab35-2c53173b7a8f');
insert into public.profiles (id, name, email, credits) values
  ('a0000000-0000-4000-8000-000000000001', 'Manual buyer', 'm@x5.test', 0),
  ('a0000000-0000-4000-8000-000000000002', 'Provider buyer', 'p@x5.test', 0),
  ('a0000000-0000-4000-8000-000000000003', 'Control buyer', 'c@x5.test', 0),
  ('f3eea23f-0aeb-405b-ab35-2c53173b7a8f', 'Developer', 'd@x5.test', 0);
update public.profiles set credits = 300
 where id in ('a0000000-0000-4000-8000-000000000001',
              'a0000000-0000-4000-8000-000000000002',
              'a0000000-0000-4000-8000-000000000003');

do $$
declare r record;
begin
  for r in select * from public.profiles where credits = 300 loop
    if r.permanent_credits <> 0 or r.credits_expires_at is null then
      raise exception 'seed: 300 plain credits must be timed, got %', row_to_json(r);
    end if;
  end loop;

  perform x5_test.act_as('service_role');
  perform public.configure_kaspi_pay_integration('X5Test', 'svc-1', 'account', null, true);
  perform x5_test.act_as_admin();
end;
$$;

\echo '== control: the production apply_kaspi_provider_command makes a paid pack expire'
do $$
declare
  v_buyer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_account text;
  v_result jsonb;
  v_profile public.profiles%rowtype;
begin
  perform x5_test.act_as('authenticated', v_buyer);
  perform public.create_kaspi_credit_payment('x5_credits_1000_v2');
  perform x5_test.act_as_admin();
  select account_code into v_account from public.kaspi_credit_payments where buyer_id = v_buyer;

  perform x5_test.act_as('service_role');
  v_result := public.apply_kaspi_provider_command('pay', '900001', '20261002090000', v_account, 1000);
  perform x5_test.act_as_admin();
  if (v_result ->> 'result')::int <> 0 then
    raise exception 'control pay failed: %', v_result;
  end if;

  select * into v_profile from public.profiles where id = v_buyer;
  if v_profile.credits <> 1300 or v_profile.permanent_credits <> 0
     or v_profile.credits_expires_at is null then
    raise exception 'control did not reproduce the bug: %', row_to_json(v_profile);
  end if;
  raise warning 'control OK: unfixed provider pay left the 1000 bought credits timed (permanent=%, expires=%)',
    v_profile.permanent_credits, v_profile.credits_expires_at;
end;
$$;

set role x5_owner;
\echo '== apply 20261002130000_kaspi_permanent_credit_grants.sql'
\ir ../migrations/20261002130000_kaspi_permanent_credit_grants.sql
\echo '== apply 20260925090000_admin_analytics.sql'
\ir ../migrations/20260925090000_admin_analytics.sql

-- ------------------------------------------------ migrations, second pass ----

\echo '== second pass: 20260903150000, 20261002130000, 20260925090000'
\ir ../migrations/20260903150000_kaspi_manual_transfers.sql
\ir ../migrations/20261002130000_kaspi_permanent_credit_grants.sql
\ir ../migrations/20260925090000_admin_analytics.sql
reset role;

-- ------------------------------------------------------------------ tests ----

\echo '== manual transfer: approval grants permanent credits exactly once'
do $$
declare
  v_buyer uuid := 'a0000000-0000-4000-8000-000000000001';
  v_dev uuid := 'f3eea23f-0aeb-405b-ab35-2c53173b7a8f';
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
  v_order jsonb;
  v_id uuid;
  v_result jsonb;
  v_denied boolean := false;
begin
  -- The configure switch works for the service role as PostgREST calls it
  -- today (request.jwt.claims JSON only) and refuses a signed-in user.
  perform x5_test.act_as('authenticated', v_buyer);
  begin
    perform public.configure_kaspi_manual_transfers('X', '+7 700 000 0000', '', true);
  exception when insufficient_privilege then v_denied := true;
  end;
  perform x5_test.act_as_admin();
  if not v_denied then raise exception 'authenticated user configured manual transfers'; end if;

  perform x5_test.act_as('service_role');
  if not x5_test.old_configure_guard_refuses() then
    raise exception 'expected the old configure guard to refuse the service role';
  end if;
  v_result := public.configure_kaspi_manual_transfers('ИП ТЕСТ', '+7 700 000 0000', '', true);
  perform x5_test.act_as_admin();
  if (v_result ->> 'manualEnabled')::boolean is not true then
    raise exception 'service role could not enable manual transfers: %', v_result;
  end if;

  select * into v_before from public.profiles where id = v_buyer;

  perform x5_test.act_as('authenticated', v_buyer);
  v_order := public.create_kaspi_manual_payment('x5_credits_2000_v2');
  v_id := (v_order ->> 'id')::uuid;
  perform public.submit_kaspi_manual_payment(v_id);

  perform x5_test.act_as('authenticated', v_dev);
  v_result := public.review_kaspi_manual_payment(v_id, true, 'checked');
  if (v_result ->> 'creditsGranted')::int <> 2000 then
    raise exception 'first approval did not grant 2000: %', v_result;
  end if;
  v_result := public.review_kaspi_manual_payment(v_id, true, 'again');
  if (v_result ->> 'creditsGranted')::int <> 0
     or (v_result ->> 'alreadyReviewed')::boolean is not true then
    raise exception 'second approval granted again: %', v_result;
  end if;
  perform x5_test.act_as_admin();

  select * into v_after from public.profiles where id = v_buyer;
  if v_after.credits <> v_before.credits + 2000 then
    raise exception 'manual credits not granted exactly once: before %, after %',
      v_before.credits, v_after.credits;
  end if;
  if v_after.permanent_credits <> v_before.permanent_credits + 2000 then
    raise exception 'manual Kaspi credits are not permanent: %', row_to_json(v_after);
  end if;
  if v_after.credits_expires_at is distinct from v_before.credits_expires_at then
    raise exception 'manual grant moved the deadline of the old timed credits';
  end if;

  -- The flag is cleared inside the same transaction: a later plain increase
  -- for the same buyer is timed again.
  update public.profiles set credits = credits + 100 where id = v_buyer;
  select * into v_after from public.profiles where id = v_buyer;
  if v_after.permanent_credits <> v_before.permanent_credits + 2000 then
    raise exception 'permanent flag leaked past the Kaspi grant: %', row_to_json(v_after);
  end if;

  raise warning 'manual OK: credits % -> % (permanent % -> %), double approval granted 0',
    v_before.credits, v_after.credits - 100, v_before.permanent_credits,
    v_before.permanent_credits + 2000;
end;
$$;

\echo '== provider pay: permanent, idempotent, refund comes off the permanent floor'
do $$
declare
  v_buyer uuid := 'a0000000-0000-4000-8000-000000000002';
  v_before public.profiles%rowtype;
  v_after public.profiles%rowtype;
  v_account text;
  v_payment_id uuid;
  v_r1 jsonb;
  v_r2 jsonb;
  v_r3 jsonb;
begin
  select * into v_before from public.profiles where id = v_buyer;

  perform x5_test.act_as('authenticated', v_buyer);
  perform public.create_kaspi_credit_payment('x5_credits_5000_v2');
  perform x5_test.act_as_admin();
  select id, account_code into v_payment_id, v_account
    from public.kaspi_credit_payments where buyer_id = v_buyer;

  perform x5_test.act_as('service_role');
  v_r1 := public.apply_kaspi_provider_command('check', '900002', null, v_account, 5000);
  if (v_r1 ->> 'result')::int <> 0 then raise exception 'check failed: %', v_r1; end if;
  v_r1 := public.apply_kaspi_provider_command('pay', '900002', '20261002100000', v_account, 5000);
  v_r2 := public.apply_kaspi_provider_command('pay', '900002', '20261002100000', v_account, 5000);
  v_r3 := public.apply_kaspi_provider_command('pay', '900003', '20261002100100', v_account, 5000);
  perform x5_test.act_as_admin();

  if (v_r1 ->> 'result')::int <> 0 or (v_r2 ->> 'result')::int <> 0
     or (v_r1 ->> 'prv_txn_id') <> (v_r2 ->> 'prv_txn_id') then
    raise exception 'pay replay not idempotent: % / %', v_r1, v_r2;
  end if;
  if (v_r3 ->> 'result')::int <> 3 then
    raise exception 'second Kaspi txn for a paid order was not refused: %', v_r3;
  end if;

  select * into v_after from public.profiles where id = v_buyer;
  if v_after.credits <> v_before.credits + 5000
     or v_after.permanent_credits <> v_before.permanent_credits + 5000 then
    raise exception 'provider pay is not a single permanent grant: before %, after %',
      row_to_json(v_before), row_to_json(v_after);
  end if;
  if v_after.credits_expires_at is distinct from v_before.credits_expires_at then
    raise exception 'provider grant moved the deadline of the old timed credits';
  end if;
  raise warning 'provider OK: credits % -> %, permanent % -> %, replay and second txn granted 0',
    v_before.credits, v_after.credits, v_before.permanent_credits, v_after.permanent_credits;

  -- Refund: the 5000 come off the permanent floor; the 300 timed credits and
  -- their deadline stay untouched.
  perform x5_test.act_as('service_role');
  v_r1 := public.refund_kaspi_credit_payment(v_payment_id);
  perform x5_test.act_as_admin();
  select * into v_after from public.profiles where id = v_buyer;
  if (v_r1 ->> 'status') <> 'refunded'
     or v_after.credits <> v_before.credits
     or v_after.permanent_credits <> v_before.permanent_credits
     or v_after.credits_expires_at is distinct from v_before.credits_expires_at then
    raise exception 'refund did not reverse the permanent grant: % %', v_r1, row_to_json(v_after);
  end if;
  raise warning 'refund OK: credits back to %, permanent back to %',
    v_after.credits, v_after.permanent_credits;
end;
$$;

\echo '== visits: insert own rows only, no reads, server-owned columns'
do $$
declare
  v_buyer uuid := 'a0000000-0000-4000-8000-000000000001';
  v_other uuid := 'a0000000-0000-4000-8000-000000000002';
  v_dev uuid := 'f3eea23f-0aeb-405b-ab35-2c53173b7a8f';
  v_count bigint;
  v_state text;
  v_visits jsonb;
begin
  -- The exact insert web/src/services/visitTracking.ts sends.
  perform x5_test.act_as('authenticated', v_buyer);
  insert into public.app_visit_events (user_id, session_id, platform, screen, app_version)
  values (v_buyer, gen_random_uuid(), 'web', 'home', null);
  insert into public.app_visit_events (user_id, session_id, platform, screen, app_version)
  values (v_buyer, gen_random_uuid(), 'ios', 'photo', '1.1.12 (243)');

  -- Someone else's user_id: refused by the policy.
  begin
    insert into public.app_visit_events (user_id, session_id, platform, screen)
    values (v_other, gen_random_uuid(), 'web', 'home');
    raise exception 'HOLE: inserted a visit for another user';
  exception when insufficient_privilege then v_state := sqlerrm;
  end;
  if v_state not like '%row-level security%' then
    raise exception 'foreign insert failed for the wrong reason: %', v_state;
  end if;

  -- occurred_at is server-owned.
  v_state := null;
  begin
    insert into public.app_visit_events (user_id, session_id, platform, screen, occurred_at)
    values (v_buyer, gen_random_uuid(), 'web', 'home', now() - interval '30 days');
    raise exception 'HOLE: client wrote occurred_at';
  exception when insufficient_privilege then v_state := sqlerrm;
  end;
  if v_state not like 'permission denied%' then
    raise exception 'occurred_at insert failed for the wrong reason: %', v_state;
  end if;

  -- No reads, updates or deletes from a client.
  begin
    select count(*) into v_count from public.app_visit_events;
    raise exception 'HOLE: authenticated user read app_visit_events';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.app_visit_events set screen = 'x' where user_id = v_buyer;
    raise exception 'HOLE: authenticated user updated app_visit_events';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.app_visit_events where user_id = v_buyer;
    raise exception 'HOLE: authenticated user deleted app_visit_events';
  exception when insufficient_privilege then null;
  end;

  -- Length limits.
  begin
    insert into public.app_visit_events (user_id, session_id, platform, screen)
    values (v_buyer, gen_random_uuid(), 'web', repeat('s', 201));
    raise exception 'HOLE: 201-char screen accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.app_visit_events (user_id, session_id, platform, app_version)
    values (v_buyer, gen_random_uuid(), 'web', repeat('v', 81));
    raise exception 'HOLE: 81-char app_version accepted';
  exception when check_violation then null;
  end;

  -- A developer cannot read raw rows either, only the aggregate reports.
  perform x5_test.act_as('authenticated', v_dev);
  begin
    select count(*) into v_count from public.app_visit_events;
    raise exception 'HOLE: developer read raw app_visit_events';
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into v_count from public.x5_generation_usage;
    raise exception 'HOLE: developer read x5_generation_usage directly';
  exception when insufficient_privilege then null;
  end;
  v_visits := public.admin_analytics_visits(now() - interval '1 day', now() + interval '1 minute');

  -- anon cannot touch the table or the reports.
  perform x5_test.act_as('anon');
  begin
    insert into public.app_visit_events (user_id, session_id, platform)
    values (v_buyer, gen_random_uuid(), 'web');
    raise exception 'HOLE: anon inserted a visit';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.admin_analytics_overview(now() - interval '1 day', now());
    raise exception 'HOLE: anon executed admin_analytics_overview';
  exception when insufficient_privilege then null;
  end;

  -- A signed-in non-developer is refused by the report itself.
  perform x5_test.act_as('authenticated', v_buyer);
  begin
    perform public.admin_analytics_overview(now() - interval '1 day', now());
    raise exception 'HOLE: non-developer executed admin_analytics_overview';
  exception when insufficient_privilege then null;
  end;
  perform x5_test.act_as_admin();

  select count(*) into v_count from public.app_visit_events;
  if v_count <> 2 then
    raise exception 'expected exactly the 2 own visits, found %', v_count;
  end if;
  if (v_visits -> 'active' ->> 'dau')::int <> 1
     or jsonb_array_length(v_visits -> 'platforms') <> 2 then
    raise exception 'developer report did not see the visits through FORCE RLS: %', v_visits;
  end if;
  raise warning 'visits OK: own insert allowed; foreign user_id, occurred_at, select/update/delete, anon, long screen/app_version refused; developer report dau=%',
    v_visits -> 'active' ->> 'dau';
end;
$$;

\echo '== revenue: App Store product ids are priced'
do $$
declare
  v_dev uuid := 'f3eea23f-0aeb-405b-ab35-2c53173b7a8f';
  v_totals jsonb;
begin
  insert into public.iap_entitlements
    (original_transaction_id, user_id, product_id, platform, purchase_type, credits_granted, credited_at)
  values
    ('t-pro', 'a0000000-0000-4000-8000-000000000001', 'com.x5studio.app.pro.monthly', 'ios', 'subscription', 2000, now() - interval '1 hour'),
    ('t-ver', 'a0000000-0000-4000-8000-000000000001', 'com.x5studio.app.verified.monthly', 'ios', null, 0, now() - interval '1 hour'),
    ('t-and', 'a0000000-0000-4000-8000-000000000002', 'x5_credits_1000_v2', 'android', 'inapp', 1000, now() - interval '1 hour'),
    ('t-old', 'a0000000-0000-4000-8000-000000000002', 'x5_pro_yearly', 'android', 'subscription', 12000, now() - interval '1 hour');

  perform x5_test.act_as('authenticated', v_dev);
  v_totals := public.admin_analytics_revenue(now() - interval '1 day', now()) -> 'totals';
  perform x5_test.act_as_admin();

  -- 2000 (pro) + 1000 (verified) + 1000 (Android pack) + 0 (unpriced legacy id)
  if (v_totals ->> 'revenue_kzt')::int <> 4000 then
    raise exception 'revenue mapping wrong: %', v_totals;
  end if;
  raise warning 'revenue OK: %', v_totals;
end;
$$;

\echo '== catalog: protections and grants as intended after two passes'
do $$
declare
  v_policies text;
  v_acl text;
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class
           where oid = 'public.app_visit_events'::regclass) then
    raise exception 'app_visit_events RLS not enabled and forced';
  end if;
  select string_agg(policyname || ':' || cmd, ', ' order by policyname) into v_policies
    from pg_policies where schemaname = 'public' and tablename = 'app_visit_events';
  if v_policies is distinct from 'visit events insert own:INSERT' then
    raise exception 'unexpected policies on app_visit_events: %', v_policies;
  end if;
  if (select count(*) from pg_constraint
       where conrelid = 'public.app_visit_events'::regclass
         and conname in ('app_visit_events_screen_length', 'app_visit_events_app_version_length')) <> 2 then
    raise exception 'length constraints missing or duplicated';
  end if;
  if has_table_privilege('authenticated', 'public.app_visit_events', 'select')
     or has_table_privilege('anon', 'public.app_visit_events', 'insert')
     or has_column_privilege('authenticated', 'public.app_visit_events', 'occurred_at', 'insert')
     or has_column_privilege('authenticated', 'public.app_visit_events', 'id', 'insert')
     or not has_column_privilege('authenticated', 'public.app_visit_events', 'screen', 'insert')
     or not has_table_privilege('service_role', 'public.app_visit_events', 'select') then
    raise exception 'app_visit_events grants are wrong';
  end if;
  if (select not coalesce('security_invoker=true' = any(reloptions), false)
        from pg_class where oid = 'public.x5_generation_usage'::regclass) then
    raise exception 'x5_generation_usage is not security_invoker';
  end if;
  if has_function_privilege('anon', 'public.admin_analytics_overview(timestamptz, timestamptz)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_analytics_overview(timestamptz, timestamptz)', 'execute') then
    raise exception 'admin_analytics_overview execute grants are wrong';
  end if;

  select proacl::text into v_acl from pg_proc
   where oid = 'public.apply_kaspi_provider_command(text, text, text, text, numeric)'::regprocedure;
  if has_function_privilege('anon', 'public.apply_kaspi_provider_command(text, text, text, text, numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.apply_kaspi_provider_command(text, text, text, text, numeric)', 'execute')
     or not has_function_privilege('service_role', 'public.apply_kaspi_provider_command(text, text, text, text, numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.refund_kaspi_credit_payment(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.refund_kaspi_credit_payment(uuid)', 'execute') then
    raise exception 'Kaspi provider function grants changed: %', v_acl;
  end if;
  raise warning 'catalog OK: apply_kaspi_provider_command acl %, app_visit_events policies [%]',
    v_acl, v_policies;
end;
$$;

\echo 'ALL CHECKS PASSED'
