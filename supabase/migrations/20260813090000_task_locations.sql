begin;

alter table public.tasks
  add column if not exists country_code text,
  add column if not exists city text;

alter table public.tasks
  drop constraint if exists tasks_country_code_format,
  drop constraint if exists tasks_city_length;

alter table public.tasks
  add constraint tasks_country_code_format
    check (country_code is null or country_code ~ '^[A-Z]{2}$') not valid,
  add constraint tasks_city_length
    check (city is null or char_length(btrim(city)) between 2 and 120) not valid;

create index if not exists tasks_location_created_idx
  on public.tasks (country_code, city, created_at desc);

comment on column public.tasks.country_code is 'ISO 3166-1 alpha-2 location selected by the task author';
comment on column public.tasks.city is 'City where the task should be performed';

commit;

