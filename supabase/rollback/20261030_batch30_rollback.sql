-- Откат миграций пачки 30.10 (Адильхан):
--   20261030180000_task_multi_location_category.sql
--   20261030181000_signup_bonus_first_1000.sql
-- Сначала откатить клиентов (веб — передеплой прошлого коммита release/android-web),
-- иначе новые клиенты будут писать в несуществующие колонки.
-- После отката у заданий остаётся только первая страна/город/категория
-- (одиночные поля уже синхронизированы триггером).

begin;

-- ---- бонус 200 ----
-- Кредиты, уже начисленные бонусом, остаются у людей (не списываем).
drop function if exists public.claim_signup_bonus(text, text);
drop function if exists public.signup_bonus_stats();
-- Таблицы оставляем для учёта выдач; удалить при необходимости:
-- drop table if exists public.signup_bonus_grants;
-- drop table if exists public.signup_bonus_settings;
-- Мягкая остановка без отката: update public.signup_bonus_settings set enabled = false;

-- ---- несколько стран / городов / категорий ----
-- Уведомление по одной категории — прод-определение до 30.10.
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
begin
  notification_body := task_title || ' — откликнись первым, пока проект свежий.';
  for recipient in
    select p.id
    from public.profiles p
    where p.id <> new.author_id
      and coalesce(p.show_in_hub, false) = true
      and coalesce(p.is_public, true) = true
      and public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
      and public.x5_task_matches_specialist(new.category, p.specialist_category)
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
    and public.x5_task_matches_specialist(new.category, p.specialist_category)
  on conflict (task_id, recipient_id) do nothing;
  return new;
end;
$function$;

drop trigger if exists tasks_sync_location_category on public.tasks;
drop function if exists public.x5_sync_task_location_category();
drop function if exists public.x5_task_matches_specialist_any(text[], text[]);

alter table public.tasks
  drop constraint if exists tasks_country_codes_valid,
  drop constraint if exists tasks_cities_valid,
  drop constraint if exists tasks_categories_valid;
drop index if exists public.tasks_country_codes_gin;
drop index if exists public.tasks_cities_gin;
drop index if exists public.tasks_categories_gin;

alter table public.tasks
  drop column if exists country_codes,
  drop column if exists cities,
  drop column if exists categories;

drop function if exists public.x5_task_text_items_valid(text[], integer, integer, integer);
drop function if exists public.x5_task_clean_text_items(text[], boolean);

delete from supabase_migrations.schema_migrations
 where version in ('20261030180000', '20261030181000');

commit;
