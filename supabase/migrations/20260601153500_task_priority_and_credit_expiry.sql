create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table public.tasks
  add column if not exists public_visible_at timestamptz;

update public.tasks
set public_visible_at = coalesce(public_visible_at, created_at + interval '1 hour')
where public_visible_at is null;

alter table public.tasks
  alter column public_visible_at set default (now() + interval '1 hour');

create index if not exists tasks_status_public_visible_idx
on public.tasks(status, public_visible_at desc);

create or replace function public.x5_profile_has_active_verified_badge(
  p_is_verified boolean,
  p_verified_until timestamptz
) returns boolean
language sql
stable
as $$
  select coalesce(p_is_verified, false)
     and p_verified_until is not null
     and p_verified_until > now()
$$;

create or replace function public.x5_user_has_active_verified_badge(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
  )
$$;

drop policy if exists "tasks_select" on public.tasks;
create policy "tasks_select"
on public.tasks for select
using (
  auth.uid() = author_id
  or public.x5_user_has_active_verified_badge(auth.uid())
  or coalesce(public_visible_at, created_at + interval '1 hour') <= now()
);

create table if not exists public.task_notification_queue (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  due_at timestamptz not null,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (task_id, recipient_id)
);

alter table public.task_notification_queue enable row level security;

create index if not exists task_notification_queue_due_idx
on public.task_notification_queue(due_at)
where processed_at is null;

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

create or replace function public.x5_task_matches_specialist(
  p_task_category text,
  p_specialist_categories text[]
) returns boolean
language sql
stable
as $$
  select p_task_category is null
      or p_task_category = ''
      or p_specialist_categories is null
      or cardinality(p_specialist_categories) = 0
      or p_task_category = any(p_specialist_categories)
$$;

create or replace function public.x5_notify_new_task_audience()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recipient record;
  task_title text := coalesce(nullif(new.title, ''), 'Новый проект');
  notification_body text;
begin
  notification_body := task_title || ' — откликнись первым, пока проект свежий.';

  for recipient in
    select p.id
    from public.profiles p
    where p.id <> new.author_id
      and coalesce(p.show_in_hub, false) = true
      and coalesce(p.is_public, true) = true
      and public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
      and public.x5_task_matches_specialist(new.category, p.specialist_category)
  loop
    perform public.x5_enqueue_social_notification(
      recipient.id,
      new.author_id,
      'new_task_priority',
      'Новый проект для проверенных',
      notification_body,
      'task',
      new.id::text
    );
  end loop;

  insert into public.task_notification_queue(task_id, recipient_id, actor_id, due_at)
  select
    new.id,
    p.id,
    new.author_id,
    coalesce(new.created_at, now()) + interval '1 hour'
  from public.profiles p
  where p.id <> new.author_id
    and coalesce(p.show_in_hub, false) = true
    and coalesce(p.is_public, true) = true
    and not public.x5_profile_has_active_verified_badge(p.is_verified, p.verified_until)
    and public.x5_task_matches_specialist(new.category, p.specialist_category)
  on conflict (task_id, recipient_id) do nothing;

  return new;
end;
$$;

drop trigger if exists tasks_priority_notify on public.tasks;
create trigger tasks_priority_notify
after insert on public.tasks
for each row execute function public.x5_notify_new_task_audience();

create or replace function public.x5_process_due_task_notifications(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  processed integer := 0;
begin
  for item in
    select q.id, q.task_id, q.recipient_id, q.actor_id, t.title
    from public.task_notification_queue q
    join public.tasks t on t.id = q.task_id
    where q.processed_at is null
      and q.due_at <= now()
      and coalesce(t.status, 'open') = 'open'
    order by q.due_at asc
    limit greatest(coalesce(p_limit, 200), 1)
    for update of q skip locked
  loop
    perform public.x5_enqueue_social_notification(
      item.recipient_id,
      item.actor_id,
      'new_task_public',
      'Новый проект в Hub',
      coalesce(nullif(item.title, ''), 'Новый проект') || ' — теперь доступен всем специалистам.',
      'task',
      item.task_id::text
    );

    update public.task_notification_queue
    set processed_at = now()
    where id = item.id;

    processed := processed + 1;
  end loop;

  return processed;
end;
$$;

do $$
begin
  begin
    perform cron.unschedule('x5-process-due-task-notifications');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-process-due-task-notifications',
    '* * * * *',
    'select public.x5_process_due_task_notifications(200);'
  );
end $$;

create or replace function public.x5_prepare_credit_retention()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  retention_months integer;
  active_verified boolean;
  credits_changed boolean;
  verified_changed boolean;
begin
  active_verified := public.x5_profile_has_active_verified_badge(new.is_verified, new.verified_until);
  retention_months := case when active_verified then 3 else 1 end;

  new.credits_retention_months := retention_months;

  if tg_op = 'INSERT' then
    credits_changed := true;
    verified_changed := false;
  else
    credits_changed := coalesce(new.credits, 0) <> coalesce(old.credits, 0);
    verified_changed :=
      coalesce(new.is_verified, false) <> coalesce(old.is_verified, false)
      or coalesce(new.verified_until, '-infinity'::timestamptz) <> coalesce(old.verified_until, '-infinity'::timestamptz);
  end if;

  if coalesce(new.credits, 0) <= 0 then
    new.credits := 0;
    new.credits_expires_at := null;
  elsif credits_changed or verified_changed or new.credits_expires_at is null then
    new.credits_expires_at := now() + make_interval(months => retention_months);
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_credit_retention on public.profiles;
create trigger profiles_credit_retention
before insert or update of credits, is_verified, verified_until on public.profiles
for each row execute function public.x5_prepare_credit_retention();

create or replace function public.x5_expire_old_credits()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired integer;
begin
  update public.profiles
  set credits = 0,
      credits_expires_at = null
  where coalesce(credits, 0) > 0
    and credits_expires_at is not null
    and credits_expires_at <= now();

  get diagnostics expired = row_count;
  return expired;
end;
$$;

do $$
begin
  begin
    perform cron.unschedule('x5-expire-old-credits');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'x5-expire-old-credits',
    '*/15 * * * *',
    'select public.x5_expire_old_credits();'
  );
end $$;
