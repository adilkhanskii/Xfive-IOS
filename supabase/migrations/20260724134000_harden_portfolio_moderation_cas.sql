-- Every portfolio update invalidates any moderation decision made from an
-- older snapshot. The trigger owns the counter so API clients cannot choose or
-- preserve a revision while changing content or moderation state.
create or replace function public.x5_bump_portfolio_moderation_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.moderation_revision := 1;
  else
    new.moderation_revision := old.moderation_revision + 1;
  end if;

  return new;
end;
$$;
