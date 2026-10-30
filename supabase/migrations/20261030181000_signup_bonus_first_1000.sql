-- Бонус новым пользователям: первым 1000 — 200 кредитов (Адильхан 30.10).
--
-- Условия:
--   * только аккаунты, созданные ПОСЛЕ включения (signup_bonus_settings.started_at) —
--     существующим задним числом ничего не начисляем;
--   * почта подтверждена (auth.users.email_confirmed_at). Apple/Google приходят
--     уже подтверждёнными; анонимные (гостевые) аккаунты не участвуют;
--   * один бонус на аккаунт, на почту (хэш, переживает удаление аккаунта)
--     и на устройство (хэш id устройства от клиента);
--   * всего не больше max_grants выдач (1000) — считаем выдачи, а не signup_number:
--     старая нумерация (mig_signup_number.sql) уже дошла до ~810 из-за удалённых
--     аккаунтов, и «первые 1000 по номеру» дали бы только ~190 мест.
--
-- Старый бонус «первые 1000 → 300 кредитов» (android-web/mig_signup_number.sql):
-- на проде триггер trg_assign_signup_number есть, но тело assign_signup_number()
-- заменено на «No credit grant. All new accounts start at 0» (проверено 30.10),
-- а x5_protect_profile_entitlements обнуляет credits у вставки от клиента.
-- Двойного бонуса нет; этот файл тот триггер не трогает.
--
-- Кредиты бонуса — обычные (с 1–3 мес. сроком, как все не купленные кредиты:
-- x5_prepare_credit_retention), а не «вечные» купленные.
--
-- Повторный запуск безопасен.

begin;

create table if not exists public.signup_bonus_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default true,
  credits integer not null default 200 check (credits between 1 and 10000),
  max_grants integer not null default 1000 check (max_grants between 0 and 1000000),
  started_at timestamptz not null default now()
);
insert into public.signup_bonus_settings (id) values (true) on conflict (id) do nothing;

-- user_id без внешнего ключа: строка остаётся после удаления аккаунта,
-- иначе «удалил — зарегистрировался заново — снова бонус».
create table if not exists public.signup_bonus_grants (
  id bigint generated always as identity primary key,
  user_id uuid not null unique,
  email_hash text unique,
  device_hash text not null unique,
  platform text not null check (platform in ('ios', 'android', 'web')),
  credits integer not null check (credits > 0),
  granted_at timestamptz not null default now()
);

alter table public.signup_bonus_settings enable row level security;
alter table public.signup_bonus_grants enable row level security;
revoke all on table public.signup_bonus_settings from public, anon, authenticated;
revoke all on table public.signup_bonus_grants from public, anon, authenticated;

create or replace function public.claim_signup_bonus(p_device_id text, p_platform text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uid uuid := auth.uid();
  v_settings public.signup_bonus_settings%rowtype;
  v_email text;
  v_confirmed_at timestamptz;
  v_is_anonymous boolean;
  v_created_at timestamptz;
  v_device_hash text;
  v_email_hash text;
  v_granted integer;
  v_balance integer;
begin
  if v_uid is null then
    return jsonb_build_object('status', 'not_signed_in');
  end if;
  if p_platform is null or p_platform not in ('ios', 'android', 'web')
     or p_device_id is null or p_device_id !~ '^[A-Za-z0-9._:-]{16,128}$' then
    return jsonb_build_object('status', 'invalid_device');
  end if;

  select * into v_settings from public.signup_bonus_settings where id;
  if not found or not v_settings.enabled then
    return jsonb_build_object('status', 'disabled');
  end if;

  select u.email, u.email_confirmed_at, coalesce(u.is_anonymous, false), u.created_at
    into v_email, v_confirmed_at, v_is_anonymous, v_created_at
    from auth.users u
   where u.id = v_uid;
  if not found or v_is_anonymous then
    return jsonb_build_object('status', 'not_eligible');
  end if;
  if v_confirmed_at is null then
    return jsonb_build_object('status', 'email_not_confirmed');
  end if;
  if v_created_at < v_settings.started_at then
    return jsonb_build_object('status', 'not_eligible');
  end if;

  v_device_hash := encode(sha256(convert_to(p_platform || ':' || p_device_id, 'UTF8')), 'hex');
  v_email_hash := case
    when nullif(btrim(v_email), '') is null then null
    else encode(sha256(convert_to(lower(btrim(v_email)), 'UTF8')), 'hex')
  end;

  -- Одна выдача за раз: счётчик «N из 1000» не перескочит лимит.
  perform pg_advisory_xact_lock(hashtext('x5_signup_bonus'));

  if exists (
    select 1 from public.signup_bonus_grants g
     where g.user_id = v_uid
        or (v_email_hash is not null and g.email_hash = v_email_hash)
  ) then
    return jsonb_build_object('status', 'already_granted');
  end if;
  if exists (select 1 from public.signup_bonus_grants g where g.device_hash = v_device_hash) then
    return jsonb_build_object('status', 'device_used');
  end if;

  select count(*) into v_granted from public.signup_bonus_grants;
  if v_granted >= v_settings.max_grants then
    return jsonb_build_object('status', 'limit_reached');
  end if;

  -- SECURITY DEFINER: x5_protect_profile_entitlements пропускает (не anon/authenticated),
  -- x5_prepare_credit_retention оформит кредиты как обычные (со сроком).
  update public.profiles
     set credits = coalesce(credits, 0) + v_settings.credits
   where id = v_uid
  returning credits into v_balance;
  if not found then
    return jsonb_build_object('status', 'profile_missing');
  end if;

  insert into public.signup_bonus_grants (user_id, email_hash, device_hash, platform, credits)
  values (v_uid, v_email_hash, v_device_hash, p_platform, v_settings.credits);

  return jsonb_build_object(
    'status', 'granted',
    'credits', v_settings.credits,
    'balance', v_balance,
    'granted_count', v_granted + 1,
    'max_grants', v_settings.max_grants
  );
end;
$$;

-- Счётчик для владельца (Адильхан) и разработчика: «выдано N из 1000».
create or replace function public.signup_bonus_stats()
returns jsonb
language plpgsql
stable
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
  select * into v_settings from public.signup_bonus_settings where id;
  select count(*) into v_granted from public.signup_bonus_grants;
  return jsonb_build_object(
    'granted', v_granted,
    'max_grants', coalesce(v_settings.max_grants, 0),
    'credits', coalesce(v_settings.credits, 0),
    'enabled', coalesce(v_settings.enabled, false),
    'started_at', v_settings.started_at
  );
end;
$$;

revoke all on function public.claim_signup_bonus(text, text) from public, anon;
revoke all on function public.signup_bonus_stats() from public, anon;
grant execute on function public.claim_signup_bonus(text, text) to authenticated;
grant execute on function public.signup_bonus_stats() to authenticated;

commit;
