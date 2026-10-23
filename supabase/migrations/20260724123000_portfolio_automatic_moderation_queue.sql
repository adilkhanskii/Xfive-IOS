-- Safe portfolio publishing:
-- * approved posts stay public;
-- * owners can see their own pending/rejected posts;
-- * only the two users accepted by is_x5_developer() can read the review queue.
alter table public.portfolio_items
  add column if not exists moderation_revision bigint not null default 1;

alter table public.portfolio_items
  drop constraint if exists portfolio_items_moderation_revision_check;

alter table public.portfolio_items
  add constraint portfolio_items_moderation_revision_check
  check (moderation_revision >= 1);

create or replace function public.x5_bump_portfolio_moderation_revision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  content_changed boolean;
begin
  if tg_op = 'INSERT' then
    new.moderation_revision := 1;
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
    new.moderation_revision := old.moderation_revision + 1;
  else
    new.moderation_revision := old.moderation_revision;
  end if;

  return new;
end;
$$;

drop trigger if exists portfolio_items_moderation_revision_guard
on public.portfolio_items;

create trigger portfolio_items_moderation_revision_guard
before insert or update on public.portfolio_items
for each row execute function public.x5_bump_portfolio_moderation_revision();

drop policy if exists "portfolio public read" on public.portfolio_items;

create policy "portfolio public read"
on public.portfolio_items for select
to anon, authenticated
using (
  moderation_status = 'approved'
  or (select auth.uid()) = user_id
  or (
    public.is_x5_developer()
    and moderation_status in ('pending', 'manual_review', 'failed')
  )
);

create index if not exists portfolio_items_moderation_queue_idx
on public.portfolio_items (moderation_status, created_at asc)
where moderation_status in ('pending', 'manual_review', 'failed');

-- Portfolio media is client-immutable. Preserve the installed clients'
-- chat/avatar upload behavior, while binding every portfolio insert to both
-- the JWT-derived owner and the caller's top-level folder.
drop policy if exists "portfolio_auth_insert" on storage.objects;
drop policy if exists "portfolio_auth_update" on storage.objects;
drop policy if exists "portfolio_auth_delete" on storage.objects;
drop policy if exists "x5 storage authenticated write" on storage.objects;

create policy "x5 storage authenticated write"
on storage.objects for insert
to authenticated
with check (
  bucket_id = any (array['chat-media', 'avatars'])
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
);

drop policy if exists "x5 storage authenticated update" on storage.objects;

create policy "x5 storage authenticated update"
on storage.objects for update
to authenticated
using (
  bucket_id = any (array['chat-media', 'avatars'])
  and owner = (select auth.uid())
)
with check (
  bucket_id = any (array['chat-media', 'avatars'])
  and owner = (select auth.uid())
);

drop policy if exists "x5 storage authenticated delete own" on storage.objects;

create policy "x5 storage authenticated delete own"
on storage.objects for delete
to authenticated
using (
  bucket_id = any (array['chat-media', 'avatars'])
  and owner = (select auth.uid())
);
