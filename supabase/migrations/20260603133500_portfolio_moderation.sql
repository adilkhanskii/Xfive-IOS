alter table public.portfolio_items
  add column if not exists moderation_status text not null default 'approved',
  add column if not exists moderation_reason text,
  add column if not exists moderation_result jsonb not null default '{}'::jsonb,
  add column if not exists moderation_model text,
  add column if not exists moderation_error text,
  add column if not exists moderated_at timestamptz;

alter table public.portfolio_items
  drop constraint if exists portfolio_items_moderation_status_check;

alter table public.portfolio_items
  add constraint portfolio_items_moderation_status_check
  check (moderation_status in ('pending', 'approved', 'rejected', 'manual_review', 'failed'));

update public.portfolio_items
set moderation_status = 'approved'
where moderation_status is null;

create index if not exists portfolio_items_user_moderation_idx
on public.portfolio_items(user_id, moderation_status, sort_order, created_at desc);

drop policy if exists "portfolio public read" on public.portfolio_items;
drop policy if exists "portfolio owner write" on public.portfolio_items;
drop policy if exists "portfolio_select" on public.portfolio_items;
drop policy if exists "portfolio_insert" on public.portfolio_items;
drop policy if exists "portfolio_update" on public.portfolio_items;
drop policy if exists "portfolio_delete" on public.portfolio_items;
create policy "portfolio public read"
on public.portfolio_items for select
using (moderation_status = 'approved' or auth.uid() = user_id);

create policy "portfolio owner write"
on public.portfolio_items for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create or replace function public.x5_guard_portfolio_moderation_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  jwt_role text := coalesce(auth.role(), '');
  content_changed boolean;
begin
  if jwt_role = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.moderation_status := 'pending';
    new.moderation_reason := null;
    new.moderation_result := '{}'::jsonb;
    new.moderation_model := null;
    new.moderation_error := null;
    new.moderated_at := null;
    return new;
  end if;

  content_changed :=
    coalesce(new.type, '') is distinct from coalesce(old.type, '')
    or coalesce(new.title, '') is distinct from coalesce(old.title, '')
    or coalesce(new.description, '') is distinct from coalesce(old.description, '')
    or coalesce(new.media_url, '') is distinct from coalesce(old.media_url, '')
    or coalesce(new.thumbnail_url, '') is distinct from coalesce(old.thumbnail_url, '')
    or coalesce(new.link, '') is distinct from coalesce(old.link, '');

  if content_changed then
    new.moderation_status := 'pending';
    new.moderation_reason := null;
    new.moderation_result := '{}'::jsonb;
    new.moderation_model := null;
    new.moderation_error := null;
    new.moderated_at := null;
  else
    new.moderation_status := old.moderation_status;
    new.moderation_reason := old.moderation_reason;
    new.moderation_result := old.moderation_result;
    new.moderation_model := old.moderation_model;
    new.moderation_error := old.moderation_error;
    new.moderated_at := old.moderated_at;
  end if;

  return new;
end;
$$;

drop trigger if exists portfolio_items_moderation_guard on public.portfolio_items;
create trigger portfolio_items_moderation_guard
before insert or update on public.portfolio_items
for each row execute function public.x5_guard_portfolio_moderation_fields();
