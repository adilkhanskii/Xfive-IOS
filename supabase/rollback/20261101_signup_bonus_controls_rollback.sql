-- Откат 20261101120000_signup_bonus_owner_controls.sql (управление бонусом новым).
-- Сначала клиенты: без функции кнопка «Сохранить» покажет ошибку, строка «выдано N из L» останется.
-- Настройки бонуса (enabled / credits / max_grants) не трогаем — какие стоят, такие и останутся.
-- Вернуть значения по умолчанию при необходимости:
--   update public.signup_bonus_settings set enabled = true, credits = 200, max_grants = 1000 where id;

begin;

drop function if exists public.signup_bonus_update_settings(boolean, integer, integer);

delete from supabase_migrations.schema_migrations where version = '20261101120000';

commit;
