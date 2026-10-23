create or replace function public.spend_generation_credits(
  p_user_id uuid,
  p_amount integer
)
returns table (credits integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_amount <= 0 then
    raise exception 'amount_must_be_positive';
  end if;

  update public.profiles
  set credits = coalesce(public.profiles.credits, 0) - p_amount
  where id = p_user_id
    and coalesce(public.profiles.credits, 0) >= p_amount
  returning public.profiles.credits into credits;

  if not found then
    return;
  end if;

  return next;
end;
$$;

create or replace function public.refund_generation_credits(
  p_user_id uuid,
  p_amount integer
)
returns table (credits integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_amount <= 0 then
    raise exception 'amount_must_be_positive';
  end if;

  update public.profiles
  set credits = coalesce(public.profiles.credits, 0) + p_amount
  where id = p_user_id
  returning public.profiles.credits into credits;

  if not found then
    return;
  end if;

  return next;
end;
$$;

revoke execute on function public.spend_generation_credits(uuid, integer) from public, anon, authenticated;
revoke execute on function public.refund_generation_credits(uuid, integer) from public, anon, authenticated;

grant execute on function public.spend_generation_credits(uuid, integer) to service_role;
grant execute on function public.refund_generation_credits(uuid, integer) to service_role;
