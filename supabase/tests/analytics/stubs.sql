-- Minimal stand-ins for the production tables the analytics migration reads, so
-- the migration can be compiled and smoke-tested in a throwaway Postgres.
create schema if not exists auth;
create table auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;

create table public.profiles (
  id uuid primary key references auth.users (id),
  name text, email text, plan text, credits integer, permanent_credits integer,
  permanent_credit_debt integer, registration_platform text, country_code text,
  city text, language text, created_at timestamptz default now(), last_seen timestamptz,
  is_verified boolean, signup_number integer, purchase_history jsonb
);

create table public.iap_entitlements (
  original_transaction_id text primary key,
  user_id uuid, product_id text, platform text, purchase_type text,
  credits_granted integer, credits_revoked integer, revocation_reason text,
  credited_at timestamptz, revoked_at timestamptz
);

create table public.image_generation_requests (
  id uuid primary key default gen_random_uuid(), user_id uuid, status text,
  cost_credits integer, error_code text, refunded_at timestamptz, created_at timestamptz default now()
);
create table public.voice_generation_requests (like public.image_generation_requests including all);
create table public.video_generation_jobs (like public.image_generation_requests including all);
create table public.lipsync_generation_jobs (like public.image_generation_requests including all);

create table public.ai_provider_health (
  provider text, capability text, available boolean, model text,
  last_success_at timestamptz, last_failure_at timestamptz, last_error_code text,
  updated_at timestamptz
);

-- The real gate lists two developer UUIDs; here it is a switch the test flips.
create table public.test_gate (allowed boolean not null);
insert into public.test_gate values (true);
create or replace function public.is_x5_developer() returns boolean
language sql stable as $$ select coalesce((select allowed from public.test_gate limit 1), false) $$;
