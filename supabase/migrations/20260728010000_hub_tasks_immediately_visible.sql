-- Hub is a public task marketplace: an open task must be visible to every
-- specialist immediately after creation. The old one-hour verified-user
-- priority window made the author see a row that ordinary specialists could
-- not select through RLS.

alter table public.tasks
  alter column public_visible_at set default now();

-- Release tasks that are still inside the retired priority window.
update public.tasks
set public_visible_at = now()
where status = 'open'
  and public_visible_at > now();

drop policy if exists "tasks_select" on public.tasks;
create policy "tasks_select"
on public.tasks for select
using (
  auth.uid() = author_id
  or coalesce(public_visible_at, created_at, now()) <= now()
);
