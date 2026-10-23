-- Persistent Instagram-style saves for X5 portfolio posts.
create table if not exists public.portfolio_item_saves (
  item_id uuid not null references public.portfolio_items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (item_id, user_id)
);

create index if not exists portfolio_item_saves_user_created_idx
  on public.portfolio_item_saves (user_id, created_at desc);

alter table public.portfolio_item_saves enable row level security;

drop policy if exists "portfolio_saves_select_own" on public.portfolio_item_saves;
create policy "portfolio_saves_select_own"
  on public.portfolio_item_saves for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "portfolio_saves_insert_own" on public.portfolio_item_saves;
create policy "portfolio_saves_insert_own"
  on public.portfolio_item_saves for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.portfolio_items as item
      where item.id = item_id
        and (
          item.moderation_status = 'approved'
          or item.user_id = (select auth.uid())
        )
    )
  );

drop policy if exists "portfolio_saves_delete_own" on public.portfolio_item_saves;
create policy "portfolio_saves_delete_own"
  on public.portfolio_item_saves for delete
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.portfolio_item_saves from anon;
grant select, insert, delete on table public.portfolio_item_saves to authenticated;

