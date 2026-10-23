-- Emergency hardening: credit grants must never be callable with client-
-- supplied amounts or unverified App Store transaction identifiers.

begin;

create or replace function public.add_credits(user_id uuid, amount integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if amount is null or amount <= 0 then
    raise exception 'amount_must_be_positive';
  end if;

  update public.profiles
     set credits = coalesce(credits, 0) + amount
   where id = user_id;

  if not found then
    raise exception 'profile_not_found';
  end if;
end;
$$;

create or replace function public.deduct_credits(user_id uuid, cost integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if cost is null or cost <= 0 then
    raise exception 'cost_must_be_positive';
  end if;

  update public.profiles
     set credits = coalesce(credits, 0) - cost
   where id = user_id
     and coalesce(credits, 0) >= cost;

  if not found then
    raise exception 'profile_missing_or_insufficient_credits';
  end if;
end;
$$;

revoke execute on function public.add_credits(uuid, integer)
  from public, anon, authenticated;
revoke execute on function public.deduct_credits(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.add_credits(uuid, integer) to service_role;
grant execute on function public.deduct_credits(uuid, integer) to service_role;

do $guards$
begin
  if to_regprocedure('public.claim_iap_entitlement(text,text,text,text)') is not null then
    execute 'revoke execute on function public.claim_iap_entitlement(text, text, text, text) from public, anon, authenticated';
    execute 'grant execute on function public.claim_iap_entitlement(text, text, text, text) to service_role';
  end if;
end;
$guards$;

revoke execute on function public.claim_iap_entitlement_v2(text, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.claim_iap_entitlement_v2(text, text, text, text, text, timestamptz)
  to service_role;

commit;
