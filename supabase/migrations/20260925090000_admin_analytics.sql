-- Analytics for the admin dashboard.
--
-- Two things the product could not answer before: how many people actually open
-- the app, and where the credits go. Visits were never recorded at all, and
-- every usage table lives behind RLS that only lets a user see their own rows,
-- so the dashboard needs server-side aggregates instead of raw reads.
--
-- Every function below is SECURITY DEFINER and refuses anyone who is not in
-- public.is_x5_developer(). They return aggregates as JSON; no raw row of one
-- user is ever handed to another.
--
-- Safe to run more than once: every object is created with if-not-exists,
-- create-or-replace or a guarded block, and grants are restated from scratch.

begin;

-- ---------------------------------------------------------------- visits ----

create table if not exists public.app_visit_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  session_id uuid not null,
  platform text not null check (platform in ('web', 'ios', 'android')),
  screen text,
  app_version text,
  occurred_at timestamptz not null default now()
);

create index if not exists app_visit_events_occurred_at_idx
  on public.app_visit_events (occurred_at desc);
create index if not exists app_visit_events_user_idx
  on public.app_visit_events (user_id, occurred_at desc);
-- date_trunc on a timestamptz is not immutable, so the "one ping per minute"
-- rule lives in the client instead of a unique index.
create index if not exists app_visit_events_session_idx
  on public.app_visit_events (session_id, occurred_at desc);

-- The site writes screen names and the native build string; anything longer is
-- not a screen name and must not grow the table.
do $visit_limits$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.app_visit_events'::regclass
       and conname = 'app_visit_events_screen_length'
  ) then
    alter table public.app_visit_events
      add constraint app_visit_events_screen_length
      check (screen is null or char_length(screen) <= 200);
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.app_visit_events'::regclass
       and conname = 'app_visit_events_app_version_length'
  ) then
    alter table public.app_visit_events
      add constraint app_visit_events_app_version_length
      check (app_version is null or char_length(app_version) <= 80);
  end if;
end;
$visit_limits$;

-- A signed-in client may only append its own visit rows, and only the columns
-- web/src/services/visitTracking.ts sends: id and occurred_at stay server-owned.
-- Nobody but the service role reads raw rows; the developer reports below are
-- SECURITY DEFINER functions owned by postgres, which has BYPASSRLS.
alter table public.app_visit_events enable row level security;
alter table public.app_visit_events force row level security;

revoke all on table public.app_visit_events from public, anon, authenticated;
grant all on table public.app_visit_events to service_role;
grant insert (user_id, session_id, platform, screen, app_version)
  on public.app_visit_events to authenticated;

drop policy if exists "visit events insert own" on public.app_visit_events;
create policy "visit events insert own"
  on public.app_visit_events for insert to authenticated
  with check (user_id = (select auth.uid()));

-- Raw visit rows are never readable from a client, not even a developer's.
drop policy if exists "visit events developer read" on public.app_visit_events;

-- ------------------------------------------------------------ price table ---

-- The stores hold the real payouts; until that sync runs, revenue is the
-- catalog price of what was actually credited.
--
-- App Store product ids sit next to their Google Play twins: most
-- iap_entitlements rows carry com.x5studio.app.* ids, which used to fall
-- through to 0. Prices: scripts/asc_configure_credit_store.py (credit packs) and
-- .github/workflows/asc-configure-subscriptions.yml (lite/pro/max/verified).
-- The retired Google Play ids x5_pro_monthly, x5_pro_yearly and
-- x5_verified_monthly have no price anywhere in the repository and stay 0.
create or replace function public.x5_product_price_kzt(product_id text)
returns integer
language sql
immutable
set search_path to ''
as $$
  select case product_id
    when 'x5_credits_1000_v2' then 1000
    when 'com.x5studio.app.credits.1000' then 1000
    when 'x5_credits_2000_v2' then 2000
    when 'com.x5studio.app.credits.2000' then 2000
    when 'x5_credits_5000_v2' then 5000
    when 'com.x5studio.app.credits.5000' then 5000
    when 'x5_verified_monthly_v2' then 1000
    when 'com.x5studio.app.verified.monthly' then 1000
    when 'x5_lite_monthly_v2' then 1000
    when 'com.x5studio.app.lite.monthly' then 1000
    when 'x5_pro_monthly_v2' then 2000
    when 'com.x5studio.app.pro.monthly' then 2000
    when 'x5_max_monthly_v2' then 5000
    when 'com.x5studio.app.max.monthly' then 5000
    else 0
  end;
$$;

create or replace function public.x5_require_developer()
returns void
language plpgsql
stable
set search_path to ''
as $$
begin
  if not public.is_x5_developer() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
end;
$$;

-- Every generation table shares the same shape, so one view feeds every report.
-- security_invoker: the view never lends its owner's rights to a caller. Only
-- the SECURITY DEFINER reports (owner postgres) and the service role read it.
create or replace view public.x5_generation_usage
  with (security_invoker = true) as
  select 'image'::text as tool, user_id, status, cost_credits, error_code,
         refunded_at, created_at
    from public.image_generation_requests
  union all
  select 'voice', user_id, status, cost_credits, error_code, refunded_at, created_at
    from public.voice_generation_requests
  union all
  select 'video', user_id, status, cost_credits, error_code, refunded_at, created_at
    from public.video_generation_jobs
  union all
  select 'lipsync', user_id, status, cost_credits, error_code, refunded_at, created_at
    from public.lipsync_generation_jobs;

revoke all on public.x5_generation_usage from public, anon, authenticated;
grant select on public.x5_generation_usage to service_role;

-- ---------------------------------------------------------------- reports ---

create or replace function public.admin_analytics_overview(
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  span interval := p_to - p_from;
  prev_from timestamptz := p_from - span;
  result jsonb;
begin
  perform public.x5_require_developer();

  with paid as (
    select user_id, credited_at, platform, product_id, credits_granted,
           public.x5_product_price_kzt(product_id) as price
      from public.iap_entitlements
     where credited_at is not null and revoked_at is null
  ),
  money as (
    select
      coalesce(sum(price) filter (where credited_at >= p_from and credited_at < p_to), 0) as revenue,
      coalesce(sum(price) filter (where credited_at >= prev_from and credited_at < p_from), 0) as revenue_previous,
      coalesce(sum(credits_granted) filter (where credited_at >= p_from and credited_at < p_to), 0) as credits_sold,
      coalesce(sum(price) filter (where credited_at >= p_from and credited_at < p_to and platform = 'ios'), 0) as revenue_ios,
      coalesce(sum(price) filter (where credited_at >= p_from and credited_at < p_to and platform = 'android'), 0) as revenue_android,
      count(*) filter (where credited_at >= p_from and credited_at < p_to) as purchases
    from paid
  ),
  spend as (
    select
      coalesce(sum(cost_credits) filter (where created_at >= p_from and created_at < p_to and refunded_at is null), 0) as credits_spent,
      coalesce(sum(cost_credits) filter (where created_at >= prev_from and created_at < p_from and refunded_at is null), 0) as credits_spent_previous,
      count(*) filter (where created_at >= p_from and created_at < p_to) as generations,
      count(*) filter (where created_at >= p_from and created_at < p_to and (status in ('failed', 'refunded') or refunded_at is not null)) as generations_failed
    from public.x5_generation_usage
  ),
  people as (
    select
      count(distinct user_id) filter (where occurred_at >= p_from and occurred_at < p_to) as active,
      count(distinct user_id) filter (where occurred_at >= prev_from and occurred_at < p_from) as active_previous
    from public.app_visit_events
  ),
  signups as (
    select
      count(*) filter (where created_at >= p_from and created_at < p_to) as registered,
      count(*) filter (where created_at >= prev_from and created_at < p_from) as registered_previous,
      count(*) as registered_total
    from public.profiles
  ),
  funnel as (
    select
      (select count(*) from public.profiles where created_at >= p_from and created_at < p_to) as step_registered,
      (select count(distinct user_id) from public.x5_generation_usage where created_at >= p_from and created_at < p_to) as step_generated,
      (select count(distinct user_id) from paid where credited_at >= p_from and credited_at < p_to) as step_paid
  ),
  daily as (
    select jsonb_agg(row_to_json(d) order by d.day) as series from (
      select
        day::date as day,
        coalesce((select sum(price) from paid where credited_at >= day and credited_at < day + interval '1 day'), 0) as revenue,
        coalesce((select sum(cost_credits) from public.x5_generation_usage
                   where created_at >= day and created_at < day + interval '1 day' and refunded_at is null), 0) as credits_spent,
        coalesce((select count(distinct user_id) from public.app_visit_events
                   where occurred_at >= day and occurred_at < day + interval '1 day'), 0) as active_users
      from generate_series(date_trunc('day', p_from), date_trunc('day', p_to - interval '1 second'), interval '1 day') as day
    ) d
  )
  select jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'revenue_kzt', money.revenue,
    'revenue_kzt_previous', money.revenue_previous,
    'revenue_ios_kzt', money.revenue_ios,
    'revenue_android_kzt', money.revenue_android,
    'purchases', money.purchases,
    'credits_sold', money.credits_sold,
    'credits_spent', spend.credits_spent,
    'credits_spent_previous', spend.credits_spent_previous,
    -- Customer price is twice the provider cost, so half the credits is what we paid.
    'provider_cost_kzt', round(spend.credits_spent / 2.0),
    'profit_kzt', money.revenue - round(spend.credits_spent / 2.0),
    'generations', spend.generations,
    'generations_failed', spend.generations_failed,
    'active_users', people.active,
    'active_users_previous', people.active_previous,
    'registered', signups.registered,
    'registered_previous', signups.registered_previous,
    'registered_total', signups.registered_total,
    'funnel', jsonb_build_object(
      'registered', funnel.step_registered,
      'generated', funnel.step_generated,
      'paid', funnel.step_paid
    ),
    'daily', coalesce(daily.series, '[]'::jsonb)
  )
  into result
  from money, spend, people, signups, funnel, daily;

  return result;
end;
$$;

create or replace function public.admin_analytics_revenue(
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'purchases', coalesce(jsonb_agg(row_to_json(p) order by p.credited_at desc), '[]'::jsonb),
    'totals', jsonb_build_object(
      'revenue_kzt', coalesce(sum(p.price_kzt), 0),
      'purchases', count(*),
      'payers', count(distinct p.user_id),
      'credits_granted', coalesce(sum(p.credits_granted), 0),
      'credits_revoked', coalesce(sum(p.credits_revoked), 0),
      'average_check_kzt', case when count(*) = 0 then 0 else round(coalesce(sum(p.price_kzt), 0)::numeric / count(*)) end
    )
  )
  into result
  from (
    select
      e.original_transaction_id as transaction_id,
      e.user_id,
      coalesce(pr.name, pr.email, '—') as user_name,
      pr.email,
      e.platform,
      e.product_id,
      e.purchase_type,
      e.credits_granted,
      coalesce(e.credits_revoked, 0) as credits_revoked,
      e.revocation_reason,
      public.x5_product_price_kzt(e.product_id) as price_kzt,
      e.credited_at
    from public.iap_entitlements e
    left join public.profiles pr on pr.id = e.user_id
    where e.credited_at >= p_from and e.credited_at < p_to
  ) p;

  return result;
end;
$$;

create or replace function public.admin_analytics_tools(
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'tools', coalesce((
      select jsonb_agg(row_to_json(t) order by t.credits_spent desc) from (
        select
          tool,
          count(*) as runs,
          count(*) filter (where status = 'completed') as completed,
          count(*) filter (where status in ('failed', 'refunded') or refunded_at is not null) as failed,
          coalesce(sum(cost_credits) filter (where refunded_at is null), 0) as credits_spent,
          coalesce(sum(cost_credits) filter (where refunded_at is not null), 0) as credits_refunded,
          round(coalesce(sum(cost_credits) filter (where refunded_at is null), 0) / 2.0) as provider_cost_kzt,
          count(distinct user_id) as users
        from public.x5_generation_usage
        where created_at >= p_from and created_at < p_to
        group by tool
      ) t
    ), '[]'::jsonb),
    'errors', coalesce((
      select jsonb_agg(row_to_json(e) order by e.runs desc) from (
        select tool, coalesce(error_code, 'unknown') as error_code, count(*) as runs
        from public.x5_generation_usage
        where created_at >= p_from and created_at < p_to
          and (status in ('failed', 'refunded') or error_code is not null)
        group by tool, error_code
        limit 20
      ) e
    ), '[]'::jsonb),
    'top_spenders', coalesce((
      select jsonb_agg(row_to_json(s) order by s.credits_spent desc) from (
        select
          u.user_id,
          coalesce(pr.name, pr.email, '—') as user_name,
          -- A user whose every run was refunded spent nothing, not "unknown".
          coalesce(sum(u.cost_credits) filter (where u.refunded_at is null), 0) as credits_spent,
          count(*) as runs
        from public.x5_generation_usage u
        left join public.profiles pr on pr.id = u.user_id
        where u.created_at >= p_from and u.created_at < p_to
        group by u.user_id, pr.name, pr.email
        order by 3 desc
        limit 20
      ) s
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$$;

create or replace function public.admin_analytics_users(
  p_from timestamptz,
  p_to timestamptz,
  p_search text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
  safe_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  needle text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'total', (select count(*) from public.profiles),
    'users', coalesce(jsonb_agg(row_to_json(u) order by u.credits_spent desc nulls last), '[]'::jsonb)
  )
  into result
  from (
    select
      pr.id as user_id,
      coalesce(pr.name, '—') as name,
      pr.email,
      pr.plan,
      pr.credits,
      pr.permanent_credits,
      pr.registration_platform,
      pr.country_code,
      pr.city,
      pr.created_at,
      pr.last_seen,
      coalesce((
        select sum(public.x5_product_price_kzt(e.product_id))
        from public.iap_entitlements e
        where e.user_id = pr.id and e.credited_at is not null and e.revoked_at is null
      ), 0) as paid_kzt,
      coalesce((
        select sum(g.cost_credits) from public.x5_generation_usage g
        where g.user_id = pr.id and g.refunded_at is null
          and g.created_at >= p_from and g.created_at < p_to
      ), 0) as credits_spent,
      coalesce((
        select count(*) from public.x5_generation_usage g
        where g.user_id = pr.id and g.created_at >= p_from and g.created_at < p_to
      ), 0) as generations
    from public.profiles pr
    where needle is null
       or pr.email ilike '%' || needle || '%'
       or pr.name ilike '%' || needle || '%'
    limit safe_limit offset greatest(coalesce(p_offset, 0), 0)
  ) u;

  return result;
end;
$$;

create or replace function public.admin_analytics_user_detail(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'profile', (
      select row_to_json(p) from (
        select id, name, email, plan, credits, permanent_credits, permanent_credit_debt,
               registration_platform, country_code, city, language, created_at, last_seen,
               is_verified, signup_number
        from public.profiles where id = p_user
      ) p
    ),
    'purchases', coalesce((
      select jsonb_agg(row_to_json(e) order by e.credited_at desc) from (
        select product_id, platform, purchase_type, credits_granted,
               coalesce(credits_revoked, 0) as credits_revoked,
               public.x5_product_price_kzt(product_id) as price_kzt, credited_at
        from public.iap_entitlements where user_id = p_user and credited_at is not null
      ) e
    ), '[]'::jsonb),
    'tools', coalesce((
      select jsonb_agg(row_to_json(t) order by t.credits_spent desc) from (
        select tool, count(*) as runs,
               coalesce(sum(cost_credits) filter (where refunded_at is null), 0) as credits_spent,
               count(*) filter (where status in ('failed', 'refunded')) as failed
        from public.x5_generation_usage where user_id = p_user
        group by tool
      ) t
    ), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(row_to_json(r) order by r.created_at desc) from (
        select tool, status, cost_credits, error_code, created_at
        from public.x5_generation_usage where user_id = p_user
        order by created_at desc limit 50
      ) r
    ), '[]'::jsonb),
    'visits', coalesce((
      select jsonb_agg(row_to_json(v) order by v.day desc) from (
        select occurred_at::date as day, count(*) as events,
               count(distinct session_id) as sessions
        from public.app_visit_events where user_id = p_user
        group by 1 order by 1 desc limit 60
      ) v
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$$;

create or replace function public.admin_analytics_visits(
  p_from timestamptz,
  p_to timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'daily', coalesce((
      select jsonb_agg(row_to_json(d) order by d.day) from (
        select
          day::date as day,
          coalesce((select count(distinct user_id) from public.app_visit_events
                     where occurred_at >= day and occurred_at < day + interval '1 day'), 0) as users,
          coalesce((select count(distinct session_id) from public.app_visit_events
                     where occurred_at >= day and occurred_at < day + interval '1 day'), 0) as sessions
        from generate_series(date_trunc('day', p_from), date_trunc('day', p_to - interval '1 second'), interval '1 day') as day
      ) d
    ), '[]'::jsonb),
    'platforms', coalesce((
      select jsonb_agg(row_to_json(p)) from (
        select platform, count(distinct user_id) as users, count(*) as events
        from public.app_visit_events
        where occurred_at >= p_from and occurred_at < p_to
        group by platform
      ) p
    ), '[]'::jsonb),
    'screens', coalesce((
      select jsonb_agg(row_to_json(s) order by s.views desc) from (
        select coalesce(screen, '—') as screen, count(*) as views,
               count(distinct user_id) as users
        from public.app_visit_events
        where occurred_at >= p_from and occurred_at < p_to
        group by 1 order by 2 desc limit 20
      ) s
    ), '[]'::jsonb),
    'cities', coalesce((
      select jsonb_agg(row_to_json(c) order by c.users desc) from (
        select coalesce(pr.country_code, '—') as country, coalesce(nullif(pr.city, ''), '—') as city,
               count(*) as users
        from public.profiles pr
        group by 1, 2 order by 3 desc limit 20
      ) c
    ), '[]'::jsonb),
    'active', jsonb_build_object(
      'dau', (select count(distinct user_id) from public.app_visit_events where occurred_at >= now() - interval '1 day'),
      'wau', (select count(distinct user_id) from public.app_visit_events where occurred_at >= now() - interval '7 days'),
      'mau', (select count(distinct user_id) from public.app_visit_events where occurred_at >= now() - interval '30 days'),
      -- last_seen is the only signal that predates visit tracking.
      'seen_30d', (select count(*) from public.profiles where last_seen >= now() - interval '30 days')
    )
  )
  into result;

  return result;
end;
$$;

create or replace function public.admin_analytics_health()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  result jsonb;
begin
  perform public.x5_require_developer();

  select jsonb_build_object(
    'providers', coalesce((
      select jsonb_agg(row_to_json(h)) from (
        select provider, capability, available, model, last_success_at, last_failure_at,
               last_error_code, updated_at
        from public.ai_provider_health order by provider, capability
      ) h
    ), '[]'::jsonb),
    'recent_failures', coalesce((
      select jsonb_agg(row_to_json(f) order by f.created_at desc) from (
        select tool, status, error_code, created_at
        from public.x5_generation_usage
        where status in ('failed', 'refunded') or error_code is not null
        order by created_at desc limit 30
      ) f
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$$;

-- Supabase's default privileges hand every new function to anon as well. The
-- reports refuse non-developers anyway; this keeps them off the anon surface.
revoke all on function public.x5_product_price_kzt(text) from public, anon;
revoke all on function public.x5_require_developer() from public, anon;
revoke all on function public.admin_analytics_overview(timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_analytics_revenue(timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_analytics_tools(timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_analytics_users(timestamptz, timestamptz, text, integer, integer) from public, anon;
revoke all on function public.admin_analytics_user_detail(uuid) from public, anon;
revoke all on function public.admin_analytics_visits(timestamptz, timestamptz) from public, anon;
revoke all on function public.admin_analytics_health() from public, anon;

grant execute on function public.x5_product_price_kzt(text) to authenticated, service_role;
grant execute on function public.x5_require_developer() to authenticated, service_role;
grant execute on function public.admin_analytics_overview(timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_analytics_revenue(timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_analytics_tools(timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_analytics_users(timestamptz, timestamptz, text, integer, integer) to authenticated;
grant execute on function public.admin_analytics_user_detail(uuid) to authenticated;
grant execute on function public.admin_analytics_visits(timestamptz, timestamptz) to authenticated;
grant execute on function public.admin_analytics_health() to authenticated;

commit;
