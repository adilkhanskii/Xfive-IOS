-- Откат 20261102120000_owner_grant_credits.sql (начисление кредитов владельцем).
-- Сначала клиенты: без функций строка «Начислить кредиты» покажет ошибку поиска / начисления.
-- Уже начисленные кредиты остаются на балансах — откат их не списывает.
-- История public.owner_credit_grants удаляется вместе с таблицей; сохранить перед откатом при необходимости:
--   create table public.backup_owner_credit_grants as table public.owner_credit_grants;

begin;

drop function if exists public.owner_grant_credits(uuid, integer, text);
drop function if exists public.owner_search_users(text);
drop table if exists public.owner_credit_grants;

delete from supabase_migrations.schema_migrations where version = '20261102120000';

commit;
