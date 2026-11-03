-- Начисление кредитов владельцем из профиля (Адильхан 02.11):
-- владелец находит аккаунт по почте / нику / имени и отправляет ему N кредитов.
--
-- owner_search_users(p_query)            → до 20 аккаунтов: id, имя, ник, почта, баланс
-- owner_grant_credits(p_target, p_amount, p_note) → новый баланс
--
-- Только владелец/разработчик (public.is_x5_developer) — проверка здесь, на сервере.
-- Начисление — через public.add_credits, как бонус новым: обычные кредиты со сроком
-- (x5_prepare_credit_retention ставит срок сам), не «вечные» из покупки.
-- История — public.owner_credit_grants (кто, кому, сколько, комментарий, баланс после);
-- таблица для anon/authenticated закрыта (revoke all + RLS без политик).
--
-- Ошибки (message): developer_required (42501), invalid_amount, target_required,
-- query_too_short (22023), profile_not_found (из add_credits) — клиенты показывают их по-русски.
--
-- Повторный запуск безопасен (if not exists / create or replace).

begin;

create table if not exists public.owner_credit_grants (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check (amount between 1 and 100000),
  reason text not null,
  note text,
  granted_by uuid not null,
  balance_after integer not null,
  created_at timestamptz not null default now()
);

create index if not exists owner_credit_grants_user_idx
  on public.owner_credit_grants (user_id, created_at desc);

alter table public.owner_credit_grants enable row level security;
revoke all on table public.owner_credit_grants from public, anon, authenticated;

create or replace function public.owner_grant_credits(
  p_target uuid,
  p_amount integer,
  p_note text default null
)
returns integer
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 200), '');
  v_balance integer;
begin
  if not public.is_x5_developer() then
    raise exception using errcode = '42501', message = 'developer_required';
  end if;
  if p_target is null then
    raise exception using errcode = '22023', message = 'target_required';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception using errcode = '22023', message = 'invalid_amount';
  end if;

  -- SECURITY DEFINER: x5_protect_profile_entitlements пропускает (не anon/authenticated),
  -- add_credits сам бросит profile_not_found, если аккаунта нет.
  perform public.add_credits(p_target, p_amount);

  select coalesce(p.credits, 0) into v_balance from public.profiles p where p.id = p_target;

  insert into public.owner_credit_grants (user_id, amount, reason, note, granted_by, balance_after)
  values (
    p_target,
    p_amount,
    'Начисление от владельца' || coalesce(': ' || v_note, ''),
    v_note,
    auth.uid(),
    v_balance
  );

  return v_balance;
end;
$$;

create or replace function public.owner_search_users(p_query text)
returns table (id uuid, name text, nickname text, email text, credits integer)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_q text := btrim(coalesce(p_query, ''));
  v_like text;
begin
  if not public.is_x5_developer() then
    raise exception using errcode = '42501', message = 'developer_required';
  end if;
  if char_length(v_q) < 3 then
    raise exception using errcode = '22023', message = 'query_too_short';
  end if;

  -- % и _ из запроса — буквально, не шаблон; ник ищем и с «@», и без
  v_like := '%' || replace(replace(replace(ltrim(v_q, '@'), '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return query
    select p.id, p.name, p.nickname, coalesce(u.email, p.email)::text, coalesce(p.credits, 0)
      from public.profiles p
      left join auth.users u on u.id = p.id
     where u.email ilike v_like
        or p.email ilike v_like
        or p.nickname ilike v_like
        or p.name ilike v_like
     order by (lower(coalesce(u.email, p.email)) = lower(v_q)) desc,
              (lower(p.nickname) = lower(ltrim(v_q, '@'))) desc,
              p.created_at desc nulls last
     limit 20;
end;
$$;

revoke all on function public.owner_grant_credits(uuid, integer, text) from public, anon;
grant execute on function public.owner_grant_credits(uuid, integer, text) to authenticated;
revoke all on function public.owner_search_users(text) from public, anon;
grant execute on function public.owner_search_users(text) to authenticated;

commit;
