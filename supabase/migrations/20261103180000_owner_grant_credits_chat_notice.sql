-- Начисление кредитов владельцем → получателю приходит сообщение в чат от владельца
-- («Вам начислено N кредитов · комментарий»). Превью чата, непрочитанные и пуш делают
-- существующие триггеры messages_chat_state / messages_push_notify — клиенты не меняются.

-- 1 кредит / 2 кредита / 5 кредитов
create or replace function public.x5_credits_word(p_n integer)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when abs(p_n) % 100 between 11 and 14 then 'кредитов'
    when abs(p_n) % 10 = 1 then 'кредит'
    when abs(p_n) % 10 between 2 and 4 then 'кредита'
    else 'кредитов'
  end;
$$;

create or replace function public.owner_grant_credits(p_target uuid, p_amount integer, p_note text default null::text)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 200), '');
  v_balance integer;
  v_owner uuid := auth.uid();
  v_chat_id text;
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
    v_owner,
    v_balance
  );

  -- Сообщение в чат. Сбой чата не должен отменять уже начисленные кредиты —
  -- поэтому отдельный блок с перехватом (откатится только чат).
  if v_owner is not null and v_owner <> p_target then
    begin
      -- id чата как в приложении: два id по возрастанию через «_» (сортировка JS/Swift = байтовая → collate "C")
      v_chat_id := least(v_owner::text collate "C", p_target::text collate "C")
        || '_' || greatest(v_owner::text collate "C", p_target::text collate "C");

      insert into public.chats (id, participants, unread)
      values (v_chat_id, array[v_owner, p_target], '{}'::jsonb)
      on conflict (id) do nothing;

      insert into public.messages (chat_id, sender_id, type, content)
      values (
        v_chat_id,
        v_owner,
        'text',
        'Вам начислено ' || p_amount || ' ' || public.x5_credits_word(p_amount)
          || coalesce(' · ' || v_note, '')
      );
    exception when others then
      raise warning 'owner_grant_credits chat notice failed: %', sqlerrm;
    end;
  end if;

  return v_balance;
end;
$function$;

revoke all on function public.x5_credits_word(integer) from public;
