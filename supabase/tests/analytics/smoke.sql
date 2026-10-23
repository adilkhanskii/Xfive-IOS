-- Seed two users, a purchase, a few generations and some visits, then check the
-- numbers each report returns.
insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

insert into public.profiles (id, name, email, plan, credits, created_at, last_seen, registration_platform, city, country_code)
values
  ('11111111-1111-4111-8111-111111111111', 'Payer', 'payer@x5.kz', 'free', 500, now() - interval '10 days', now(), 'ios', 'Алматы', 'KZ'),
  ('22222222-2222-4222-8222-222222222222', 'Freeloader', 'free@x5.kz', 'free', 50, now() - interval '3 days', now(), 'android', 'Астана', 'KZ');

insert into public.iap_entitlements (original_transaction_id, user_id, product_id, platform, purchase_type, credits_granted, credited_at)
values ('tx-1', '11111111-1111-4111-8111-111111111111', 'x5_credits_2000_v2', 'ios', 'consumable', 2000, now() - interval '2 days');

insert into public.image_generation_requests (user_id, status, cost_credits, created_at)
values
  ('11111111-1111-4111-8111-111111111111', 'completed', 60, now() - interval '1 day'),
  ('11111111-1111-4111-8111-111111111111', 'completed', 120, now() - interval '1 day'),
  ('22222222-2222-4222-8222-222222222222', 'failed', 60, now() - interval '1 day');
update public.image_generation_requests set refunded_at = now(), error_code = 'provider_unavailable'
 where status = 'failed';

insert into public.voice_generation_requests (user_id, status, cost_credits, created_at)
values ('11111111-1111-4111-8111-111111111111', 'completed', 60, now() - interval '5 hours');

insert into public.app_visit_events (user_id, session_id, platform, screen, occurred_at)
values
  ('11111111-1111-4111-8111-111111111111', gen_random_uuid(), 'ios', 'home', now() - interval '2 hours'),
  ('11111111-1111-4111-8111-111111111111', gen_random_uuid(), 'ios', 'photo', now() - interval '1 hour'),
  ('22222222-2222-4222-8222-222222222222', gen_random_uuid(), 'android', 'home', now() - interval '30 minutes');

insert into public.ai_provider_health (provider, capability, available, model, updated_at)
values ('openai', 'image', true, 'gpt-image-2', now());

\echo '--- overview ---'
select jsonb_pretty(jsonb_build_object(
  'revenue', o->'revenue_kzt',
  'credits_sold', o->'credits_sold',
  'credits_spent', o->'credits_spent',
  'provider_cost', o->'provider_cost_kzt',
  'profit', o->'profit_kzt',
  'generations', o->'generations',
  'failed', o->'generations_failed',
  'active_users', o->'active_users',
  'funnel', o->'funnel',
  'days', jsonb_array_length(o->'daily')
)) from (select public.admin_analytics_overview(now() - interval '7 days', now()) o) s;

\echo '--- tools ---'
select jsonb_pretty(public.admin_analytics_tools(now() - interval '7 days', now()));

\echo '--- revenue totals ---'
select jsonb_pretty(public.admin_analytics_revenue(now() - interval '7 days', now()) -> 'totals');

\echo '--- users ---'
select jsonb_pretty(public.admin_analytics_users(now() - interval '7 days', now(), null, 10, 0));

\echo '--- visits active ---'
select jsonb_pretty(public.admin_analytics_visits(now() - interval '7 days', now()) -> 'active');

\echo '--- user detail tools ---'
select jsonb_pretty(public.admin_analytics_user_detail('11111111-1111-4111-8111-111111111111') -> 'tools');

\echo '--- health providers ---'
select jsonb_pretty(public.admin_analytics_health() -> 'providers');

\echo '--- outsider is refused ---'
update public.test_gate set allowed = false;
do $$
begin
  perform public.admin_analytics_overview(now() - interval '1 day', now());
  raise exception 'SECURITY HOLE: a non-developer got the overview';
exception when insufficient_privilege then
  raise notice 'refused as expected';
end;
$$;
