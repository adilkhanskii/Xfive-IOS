-- Откат 20261113190000_task_auto_message: автосообщения перестают уходить.
-- Колонку tasks.auto_message НЕ удаляем: новые iOS/веб шлют её при создании задания,
-- без колонки PostgREST вернёт ошибку и задание не создастся.
drop trigger if exists messages_task_auto_message on public.messages;
drop trigger if exists task_responses_auto_message on public.task_responses;
drop function if exists public.x5_task_auto_message_on_card();
drop function if exists public.x5_task_auto_message_on_response();
drop function if exists public.x5_send_task_auto_message(uuid, text, text);
drop table if exists public.task_auto_message_log;
-- Полное удаление — только когда в сторах нет сборок с полем:
-- alter table public.tasks drop constraint if exists tasks_auto_message_length;
-- alter table public.tasks drop column if exists auto_message;
-- delete from supabase_migrations.schema_migrations where version = '20261113190000';
-- Бэкап заданий до миграции: public.backup_20261113_tasks (16 строк), удалить после 13.12.
