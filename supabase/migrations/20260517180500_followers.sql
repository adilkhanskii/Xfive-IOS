create table if not exists public.followers (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint followers_no_self_follow check (follower_id <> following_id)
);

alter table public.followers enable row level security;

drop policy if exists "followers_select_public" on public.followers;
create policy "followers_select_public"
on public.followers
for select
using (true);

drop policy if exists "followers_insert_own" on public.followers;
create policy "followers_insert_own"
on public.followers
for insert
with check (auth.uid() = follower_id);

drop policy if exists "followers_delete_own" on public.followers;
create policy "followers_delete_own"
on public.followers
for delete
using (auth.uid() = follower_id);

create index if not exists followers_follower_id_idx on public.followers(follower_id);
create index if not exists followers_following_id_idx on public.followers(following_id);
