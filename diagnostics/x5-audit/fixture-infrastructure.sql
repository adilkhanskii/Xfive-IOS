-- TEST INFRASTRUCTURE ONLY. This file is never a production migration.
-- Empty stand-ins for pre-existing Supabase/platform tables. Payment tables,
-- RPCs, constraints, ownership checks, triggers and refund business logic are
-- subsequently loaded verbatim from the recorded Git revision.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key, email text);
-- Synthetic UUID: the real lockdown migration requires this dedicated email.
-- No production user record, credentials, or spendable balance is imported.
insert into auth.users values (
  '55555555-5555-4555-8555-555555555555', 'appreview@x5studio.app'
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id),
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  plan text not null default 'free',
  credits integer not null default 0,
  purchased_course_ids text[],
  purchased_lesson_ids text[],
  subscription_type text,
  subscription_date timestamptz,
  subscription_end_date timestamptz,
  is_verified boolean not null default false,
  verified_until timestamptz,
  purchase_history jsonb,
  credits_expires_at timestamptz,
  credits_retention_months integer not null default 1,
  signup_number bigint
);
create table public.courses (
  id text primary key, is_public boolean, is_free boolean, price numeric
);
grant select, insert, update, delete on public.profiles to service_role;
grant usage on schema auth to service_role;
grant select on auth.users to service_role;

-- Scheduling infrastructure is intentionally inert. Tests call the real
-- reconciliation function themselves, with controlled concurrent sessions.
create schema cron;
create table cron.audit_schedules (
  jobname text primary key, schedule text, command text
);
create function cron.unschedule(p_name text) returns boolean
language plpgsql as $$
begin
  delete from cron.audit_schedules where jobname = p_name;
  return true;
end;
$$;
create function cron.schedule(p_name text, p_schedule text, p_command text)
returns bigint language plpgsql as $$
begin
  insert into cron.audit_schedules values (p_name, p_schedule, p_command)
  on conflict (jobname) do update
    set schedule = excluded.schedule, command = excluded.command;
  return 1;
end;
$$;
