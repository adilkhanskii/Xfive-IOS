-- Задание в Hub: несколько стран, несколько городов, несколько категорий
-- и «Все страны» / «Все города» (Адильхан 30.10).
--
-- Обратная совместимость: старые клиенты (iOS 1.1.18/1.1.19, старые веб-вкладки)
-- продолжают писать и читать одиночные country_code / city / category.
-- Новые клиенты пишут массивы country_codes / cities / categories.
-- Триггер держит обе формы согласованными:
--   * массивы пусты = «Все страны» / «Все города» (категорий «все» нет);
--   * одиночное поле = первый элемент массива (NULL для «все») — так старые
--     клиенты видят задание хотя бы под первой страной/городом/категорией;
--   * старый клиент поменял одиночное поле → массив сворачивается в [значение].
-- Уведомление проверенным специалистам учитывает все категории задания.
--
-- Повторный запуск безопасен (if not exists / create or replace / guarded).

begin;

alter table public.tasks
  add column if not exists country_codes text[] not null default '{}',
  add column if not exists cities text[] not null default '{}',
  add column if not exists categories text[] not null default '{}';

comment on column public.tasks.country_codes is 'ISO 3166-1 alpha-2; пусто = все страны. country_code = первый элемент (для старых клиентов)';
comment on column public.tasks.cities is 'Города выполнения; пусто = все города. city = первый элемент (для старых клиентов)';
comment on column public.tasks.categories is 'Категории задания; category = первый элемент (для старых клиентов)';

-- Проверка элементов массива: без NULL, длина после trim в пределах, не больше p_max_items.
create or replace function public.x5_task_text_items_valid(
  p_items text[], p_max_items integer, p_min_len integer, p_max_len integer
)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select coalesce(cardinality(p_items), 0) <= p_max_items
     and not exists (
       select 1 from unnest(p_items) as item
       where item is null
          or char_length(btrim(item)) < p_min_len
          or char_length(btrim(item)) > p_max_len
     )
$$;

-- Порядок сохраняем (первый = «главный» для старых клиентов), повторы и пустые убираем.
create or replace function public.x5_task_clean_text_items(p_items text[], p_upper boolean)
returns text[]
language sql
immutable
set search_path to ''
as $$
  select coalesce(array_agg(v order by first_pos), '{}'::text[])
  from (
    select v, min(pos) as first_pos
    from (
      select case when p_upper then upper(btrim(item)) else btrim(item) end as v, pos
      from unnest(coalesce(p_items, '{}'::text[])) with ordinality as t(item, pos)
    ) cleaned
    where v is not null and v <> ''
    group by v
  ) dedup
$$;

create or replace function public.x5_sync_task_location_category()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.country_codes := public.x5_task_clean_text_items(new.country_codes, true);
  new.cities := public.x5_task_clean_text_items(new.cities, false);
  new.categories := public.x5_task_clean_text_items(new.categories, false);

  if tg_op = 'INSERT' then
    -- Новый клиент прислал массив → одиночное поле из него; старый — наоборот.
    if cardinality(new.country_codes) > 0 then
      new.country_code := new.country_codes[1];
    elsif new.country_code is not null then
      new.country_codes := array[upper(btrim(new.country_code))];
    end if;
    if cardinality(new.cities) > 0 then
      new.city := new.cities[1];
    elsif new.city is not null and btrim(new.city) <> '' then
      new.cities := array[btrim(new.city)];
    end if;
    if cardinality(new.categories) > 0 then
      new.category := new.categories[1];
    elsif new.category is not null and btrim(new.category) <> '' then
      new.categories := array[btrim(new.category)];
    end if;
    return new;
  end if;

  -- UPDATE: что изменили, то и главное.
  if new.country_codes is distinct from old.country_codes then
    new.country_code := new.country_codes[1];
  elsif new.country_code is distinct from old.country_code then
    new.country_codes := case when new.country_code is null then '{}'::text[]
                              else array[upper(btrim(new.country_code))] end;
  end if;
  if new.cities is distinct from old.cities then
    new.city := new.cities[1];
  elsif new.city is distinct from old.city then
    new.cities := case when new.city is null or btrim(new.city) = '' then '{}'::text[]
                       else array[btrim(new.city)] end;
  end if;
  if new.categories is distinct from old.categories then
    new.category := new.categories[1];
  elsif new.category is distinct from old.category then
    new.categories := case when new.category is null or btrim(new.category) = '' then '{}'::text[]
                           else array[btrim(new.category)] end;
  end if;
  return new;
end;
$$;

drop trigger if exists tasks_sync_location_category on public.tasks;
create trigger tasks_sync_location_category
  before insert or update on public.tasks
  for each row execute function public.x5_sync_task_location_category();

-- Перенос старых заданий: массив = [одиночное значение]. Строк мало (десятки).
update public.tasks
   set country_codes = array[upper(btrim(country_code))]
 where country_code is not null and cardinality(country_codes) = 0;
update public.tasks
   set cities = array[btrim(city)]
 where city is not null and btrim(city) <> '' and cardinality(cities) = 0;
update public.tasks
   set categories = array[btrim(category)]
 where category is not null and btrim(category) <> '' and cardinality(categories) = 0;

do $constraints$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.tasks'::regclass
                  and conname = 'tasks_country_codes_valid') then
    alter table public.tasks add constraint tasks_country_codes_valid check (
      cardinality(country_codes) <= 20
      and array_position(country_codes, null) is null
      and array_to_string(country_codes, ',') ~ '^([A-Z]{2}(,[A-Z]{2})*)?$'
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.tasks'::regclass
                  and conname = 'tasks_cities_valid') then
    alter table public.tasks add constraint tasks_cities_valid check (
      public.x5_task_text_items_valid(cities, 30, 2, 120)
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.tasks'::regclass
                  and conname = 'tasks_categories_valid') then
    alter table public.tasks add constraint tasks_categories_valid check (
      public.x5_task_text_items_valid(categories, 10, 2, 60)
    ) not valid;
  end if;
end;
$constraints$;

-- Старые строки уже перенесены триггером/update выше — можно проверить сразу.
alter table public.tasks validate constraint tasks_country_codes_valid;
alter table public.tasks validate constraint tasks_cities_valid;
alter table public.tasks validate constraint tasks_categories_valid;

create index if not exists tasks_country_codes_gin on public.tasks using gin (country_codes);
create index if not exists tasks_cities_gin on public.tasks using gin (cities);
create index if not exists tasks_categories_gin on public.tasks using gin (categories);

-- Специалист подходит, если любая категория задания совпала с его категориями.
create or replace function public.x5_task_matches_specialist_any(
  p_task_categories text[], p_specialist_categories text[]
)
returns boolean
language sql
stable
set search_path to ''
as $$
  select p_task_categories is null
      or cardinality(p_task_categories) = 0
      or p_specialist_categories is null
      or cardinality(p_specialist_categories) = 0
      or p_task_categories && p_specialist_categories
$$;

-- Тело — прод-определение (pg_get_functiondef, 30.10) с заменой
-- x5_task_matches_specialist(new.category, …) на версию по всем категориям.
create or replace function public.x5_notify_new_task_audience()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  recipient record;
  task_title text := coalesce(nullif(new.title, ''), 'Новый проект');
  notification_body text;
  task_categories text[] := case
    when cardinality(coalesce(new.categories, '{}'::text[])) > 0 then new.categories
    when nullif(new.category, '') is not null then array[new.category]
    else '{}'::text[]
  end;
begin
  notification_body := task_title || ' — откликнись первым, пока проект свежий.';
  for recipient in
    select p.id
    from public.profiles p
    where p.id <> new.author_id
      and coalesce(p.show_in_hub, false) = true
      and coalesce(p.is_public, true) = true
      and public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
      and public.x5_task_matches_specialist_any(task_categories, p.specialist_category)
  loop
    perform public.x5_enqueue_social_notification(
      recipient.id,
      new.author_id,
      'new_task_priority',
      'Новый проект для проверенных',
      notification_body,
      'task',
      new.id::text
    );
  end loop;
  insert into public.task_notification_queue(task_id, recipient_id, actor_id, due_at)
  select
    new.id,
    p.id,
    new.author_id,
    coalesce(new.created_at, now()) + interval '1 hour'
  from public.profiles p
  where p.id <> new.author_id
    and coalesce(p.show_in_hub, false) = true
    and coalesce(p.is_public, true) = true
    and not public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
    and public.x5_task_matches_specialist_any(task_categories, p.specialist_category)
  on conflict (task_id, recipient_id) do nothing;
  return new;
end;
$function$;

commit;
