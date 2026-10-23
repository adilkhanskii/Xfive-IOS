begin;

alter table public.profiles
  add column if not exists country_code text,
  add column if not exists city text,
  add column if not exists registration_platform text,
  add column if not exists onboarding_completed_at timestamptz;

alter table public.profiles
  drop constraint if exists profiles_country_code_format,
  drop constraint if exists profiles_city_length,
  drop constraint if exists profiles_registration_platform_allowed;

alter table public.profiles
  add constraint profiles_country_code_format
    check (country_code is null or country_code ~ '^[A-Z]{2}$') not valid,
  add constraint profiles_city_length
    check (city is null or char_length(btrim(city)) between 2 and 120) not valid,
  add constraint profiles_registration_platform_allowed
    check (registration_platform is null or registration_platform in ('ios', 'android', 'web')) not valid;

comment on column public.profiles.country_code is 'ISO 3166-1 alpha-2 country selected during onboarding';
comment on column public.profiles.city is 'City selected during onboarding';
comment on column public.profiles.registration_platform is 'Platform where onboarding was completed';
comment on column public.profiles.onboarding_completed_at is 'Timestamp of completed mandatory onboarding';

commit;

