create table if not exists public.portfolio_item_comments (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.portfolio_items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  user_name text,
  user_avatar text,
  text text not null,
  created_at timestamptz not null default now()
);

alter table public.portfolio_item_comments enable row level security;

drop policy if exists "portfolio_comments_select_public" on public.portfolio_item_comments;
create policy "portfolio_comments_select_public"
on public.portfolio_item_comments for select
using (true);

drop policy if exists "portfolio_comments_insert_own" on public.portfolio_item_comments;
create policy "portfolio_comments_insert_own"
on public.portfolio_item_comments for insert
with check (auth.uid() = user_id);

drop policy if exists "portfolio_comments_delete_own" on public.portfolio_item_comments;
create policy "portfolio_comments_delete_own"
on public.portfolio_item_comments for delete
using (auth.uid() = user_id);

create index if not exists portfolio_item_comments_item_created_idx
on public.portfolio_item_comments(item_id, created_at asc);
