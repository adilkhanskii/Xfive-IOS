-- Откат 20261103180000: owner_grant_credits без сообщения в чат (как в 20261102120000).
create or replace function public.owner_grant_credits(p_target uuid, p_amount integer, p_note text default null::text)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
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
$function$;

drop function if exists public.x5_credits_word(integer);
