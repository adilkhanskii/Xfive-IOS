-- Порядок курсов (courses.sort_order) меняет только аккаунт Адильхана.
-- Адильхан 08.10 19:43: «эта возможность должна быть только у моего аккаунта, не для всех».
--
-- Зачем триггер, а не RLS: политика "courses developer update" пускает обоих
-- разработчиков ко всей строке, а RLS не умеет ограничивать одну колонку.
-- Триггер срабатывает только когда sort_order реально меняется, поэтому
-- обычное редактирование курса вторым разработчиком (Диасом) не ломается.
--
-- Кого пропускаем:
--   * eee55a08-… — Адильхан (adilkhanskii@gmail.com), тот же id, что в Roles.swift;
--   * service_role и прямой SQL из Dashboard (current_user не anon/authenticated).
-- Новый курс (INSERT с sort_order = max+1) триггер не трогает.
-- идея: если владельцев станет больше — таблица ролей вместо id в коде.

create or replace function public.x5_guard_course_sort_order()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.sort_order is distinct from old.sort_order
     and current_user in ('anon', 'authenticated')
     and (select auth.uid()) is distinct from 'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
  then
    raise exception 'Порядок курсов может менять только владелец'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.x5_guard_course_sort_order() from public;

drop trigger if exists courses_sort_order_owner_only on public.courses;

create trigger courses_sort_order_owner_only
  before update of sort_order on public.courses
  for each row
  execute function public.x5_guard_course_sort_order();
