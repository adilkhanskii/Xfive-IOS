-- Управление бонусом новым из профиля владельца (Адильхан 01.11):
-- пауза / возобновление, размер подарка (credits) и лимит получателей (max_grants).
--
-- Настройки — та же строка public.signup_bonus_settings (20261030181000);
-- claim_signup_bonus уже читает enabled / credits / max_grants оттуда, его не трогаем.
-- Пауза: новые не получают бонус (claim вернёт 'disabled'), выданные кредиты остаются.
-- Менять может только владелец/разработчик (public.is_x5_developer) — проверка здесь,
-- на сервере; таблица для anon/authenticated закрыта (revoke all + RLS без политик).
--
-- null в параметре = оставить как есть.
-- Ошибки (message): developer_required (42501), invalid_credits, invalid_max_grants,
-- max_grants_below_granted (22023) — клиенты показывают их по-русски.
--
-- Повторный запуск безопасен (create or replace).

begin;

create or replace function public.signup_bonus_update_settings(
  p_enabled boolean default null,
  p_credits integer default null,
  p_max_grants integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_settings public.signup_bonus_settings%rowtype;
  v_granted integer;
begin
  if not public.is_x5_developer() then
    raise exception using errcode = '42501', message = 'developer_required';
  end if;

  if p_credits is not null and (p_credits < 1 or p_credits > 10000) then
    raise exception using errcode = '22023', message = 'invalid_credits';
  end if;
  if p_max_grants is not null and (p_max_grants < 0 or p_max_grants > 1000000) then
    raise exception using errcode = '22023', message = 'invalid_max_grants';
  end if;

  -- Тот же замок, что у claim_signup_bonus: счётчик выдач не сдвинется,
  -- пока сравниваем новый лимит с уже выданным.
  perform pg_advisory_xact_lock(hashtext('x5_signup_bonus'));

  select count(*) into v_granted from public.signup_bonus_grants;
  if p_max_grants is not null and p_max_grants < v_granted then
    raise exception using errcode = '22023', message = 'max_grants_below_granted',
      detail = v_granted::text;
  end if;

  update public.signup_bonus_settings
     set enabled = coalesce(p_enabled, enabled),
         credits = coalesce(p_credits, credits),
         max_grants = coalesce(p_max_grants, max_grants)
   where id
  returning * into v_settings;
  if not found then
    raise exception using errcode = 'P0002', message = 'settings_missing';
  end if;

  return jsonb_build_object(
    'granted', v_granted,
    'max_grants', v_settings.max_grants,
    'credits', v_settings.credits,
    'enabled', v_settings.enabled,
    'started_at', v_settings.started_at
  );
end;
$$;

revoke all on function public.signup_bonus_update_settings(boolean, integer, integer) from public, anon;
grant execute on function public.signup_bonus_update_settings(boolean, integer, integer) to authenticated;

commit;
