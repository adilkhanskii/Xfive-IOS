create extension if not exists pg_net;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  type text not null,
  title text not null,
  body text,
  object_type text,
  object_id text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications enable row level security;

drop policy if exists "notifications_select_own" on public.notifications;
create policy "notifications_select_own"
on public.notifications for select
using (auth.uid() = user_id);

drop policy if exists "notifications_update_own" on public.notifications;
create policy "notifications_update_own"
on public.notifications for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "notifications_delete_own" on public.notifications;
create policy "notifications_delete_own"
on public.notifications for delete
using (auth.uid() = user_id);

create index if not exists notifications_user_created_idx
on public.notifications(user_id, created_at desc);

create table if not exists public.portfolio_item_likes (
  item_id uuid not null references public.portfolio_items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (item_id, user_id)
);

alter table public.portfolio_item_likes enable row level security;

drop policy if exists "portfolio_likes_select_public" on public.portfolio_item_likes;
create policy "portfolio_likes_select_public"
on public.portfolio_item_likes for select
using (true);

drop policy if exists "portfolio_likes_insert_own" on public.portfolio_item_likes;
create policy "portfolio_likes_insert_own"
on public.portfolio_item_likes for insert
with check (auth.uid() = user_id);

drop policy if exists "portfolio_likes_delete_own" on public.portfolio_item_likes;
create policy "portfolio_likes_delete_own"
on public.portfolio_item_likes for delete
using (auth.uid() = user_id);

create index if not exists portfolio_item_likes_user_idx
on public.portfolio_item_likes(user_id);

create or replace function public.x5_enqueue_social_notification(
  recipient_id uuid,
  actor_id uuid,
  event_type text,
  event_title text,
  event_body text,
  event_object_type text,
  event_object_id text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if recipient_id is null or actor_id is null or recipient_id = actor_id then
    return;
  end if;

  insert into public.notifications(user_id, actor_id, type, title, body, object_type, object_id)
  values (recipient_id, actor_id, event_type, event_title, event_body, event_object_type, event_object_id);

  perform net.http_post(
    url := 'https://afwznqjpshybmqhlewmy.functions.supabase.co/send-message-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
    ),
    body := jsonb_build_object(
      'recipient_id', recipient_id,
      'actor_id', actor_id,
      'type', event_type,
      'title', event_title,
      'body', event_body,
      'object_type', event_object_type,
      'object_id', event_object_id
    )
  );
end;
$$;

create or replace function public.x5_notify_new_task_followers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  follower record;
  actor_name text;
begin
  select coalesce(nullif(name, ''), nullif(nickname, ''), 'Someone')
  into actor_name
  from public.profiles
  where id = new.author_id;

  for follower in
    select follower_id
    from public.followers
    where following_id = new.author_id
  loop
    perform public.x5_enqueue_social_notification(
      follower.follower_id,
      new.author_id,
      'followed_user_posted',
      'Новый пост в X5',
      coalesce(actor_name, 'Someone') || ': ' || coalesce(new.title, 'новая публикация'),
      'task',
      new.id::text
    );
  end loop;

  return new;
end;
$$;

do $$
begin
  if to_regclass('public.tasks') is not null then
    execute 'drop trigger if exists tasks_followers_notify on public.tasks';
    execute 'create trigger tasks_followers_notify after insert on public.tasks for each row execute function public.x5_notify_new_task_followers()';
  end if;
end $$;

create or replace function public.x5_notify_portfolio_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owner_id uuid;
  actor_name text;
  item_title text;
begin
  select user_id, nullif(title, '')
  into owner_id, item_title
  from public.portfolio_items
  where id = new.item_id;

  if owner_id is null or owner_id = new.user_id then
    return new;
  end if;

  select coalesce(nullif(name, ''), nullif(nickname, ''), 'Someone')
  into actor_name
  from public.profiles
  where id = new.user_id;

  perform public.x5_enqueue_social_notification(
    owner_id,
    new.user_id,
    'portfolio_like',
    'Новый лайк',
    coalesce(actor_name, 'Someone') || ' поставил лайк' || case when item_title is null then '' else ': ' || item_title end,
    'portfolio_item',
    new.item_id::text
  );

  return new;
end;
$$;

drop trigger if exists portfolio_like_notify on public.portfolio_item_likes;
create trigger portfolio_like_notify
after insert on public.portfolio_item_likes
for each row execute function public.x5_notify_portfolio_like();
