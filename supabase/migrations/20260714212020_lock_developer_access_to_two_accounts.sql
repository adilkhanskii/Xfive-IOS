-- Course-management access is intentionally limited to exactly two immutable
-- Supabase auth user IDs. Email aliases and editable profile fields must not
-- grant privileges.

create or replace function public.is_x5_developer()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (select auth.uid()) in (
      'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
      'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
    ),
    false
  );
$$;

create or replace function public.x5_is_developer()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select public.is_x5_developer();
$$;

revoke all on function public.is_x5_developer() from public;
revoke all on function public.x5_is_developer() from public;
grant execute on function public.is_x5_developer() to anon, authenticated, service_role;
grant execute on function public.x5_is_developer() to anon, authenticated, service_role;

-- RLS is the authoritative course-management boundary. Client roles receive
-- only the table privileges required for policies to make a decision.
alter table public.courses enable row level security;

revoke all on table public.courses from anon, authenticated;
grant select on table public.courses to anon;
grant select, insert, update, delete on table public.courses to authenticated;

drop policy if exists "Authors can manage own courses" on public.courses;
drop policy if exists "Public courses visible to all" on public.courses;
drop policy if exists "courses public read" on public.courses;
drop policy if exists "courses dev write" on public.courses;
drop policy if exists "courses dev update" on public.courses;
drop policy if exists "courses dev delete" on public.courses;
drop policy if exists "courses developer select" on public.courses;
drop policy if exists "courses developer insert" on public.courses;
drop policy if exists "courses developer update" on public.courses;
drop policy if exists "courses developer delete" on public.courses;

create policy "courses public read"
  on public.courses for select
  to anon, authenticated
  using (is_public = true);

create policy "courses developer select"
  on public.courses for select
  to authenticated
  using (public.is_x5_developer());

create policy "courses developer insert"
  on public.courses for insert
  to authenticated
  with check (public.is_x5_developer());

create policy "courses developer update"
  on public.courses for update
  to authenticated
  using (public.is_x5_developer())
  with check (public.is_x5_developer());

create policy "courses developer delete"
  on public.courses for delete
  to authenticated
  using (public.is_x5_developer());

-- Ordinary signed-in users may submit a course for review and read only their
-- own submission. Only the two developers may review or update submissions.
alter table public.course_submissions enable row level security;

revoke all on table public.course_submissions from anon, authenticated;
grant select, insert, update on table public.course_submissions to authenticated;

drop policy if exists "Authenticated users can read submissions" on public.course_submissions;
drop policy if exists "Authenticated users can update submissions" on public.course_submissions;
drop policy if exists "Users can insert own submissions" on public.course_submissions;
drop policy if exists "course submissions owner insert" on public.course_submissions;
drop policy if exists "course submissions owner read" on public.course_submissions;
drop policy if exists "course submissions developer update" on public.course_submissions;

create policy "course submissions owner insert"
  on public.course_submissions for insert
  to authenticated
  with check (
    (select auth.uid()) is not null
    and author_id = (select auth.uid())::text
  );

create policy "course submissions owner read"
  on public.course_submissions for select
  to authenticated
  using (
    author_id = (select auth.uid())::text
    or public.is_x5_developer()
  );

create policy "course submissions developer update"
  on public.course_submissions for update
  to authenticated
  using (public.is_x5_developer())
  with check (public.is_x5_developer());

-- Global feature and lesson-video configuration stays readable by the app,
-- but only the two developers may mutate it.
alter table public.system_config enable row level security;

revoke all on table public.system_config from anon, authenticated;
grant select on table public.system_config to anon, authenticated;
grant insert, update, delete on table public.system_config to authenticated;

drop policy if exists "Allow public insert system_config" on public.system_config;
drop policy if exists "Allow public update system_config" on public.system_config;
drop policy if exists "Anyone can read system config" on public.system_config;
drop policy if exists "system config public read" on public.system_config;
drop policy if exists "system config developer select" on public.system_config;
drop policy if exists "system config developer insert" on public.system_config;
drop policy if exists "system config developer update" on public.system_config;
drop policy if exists "system config developer delete" on public.system_config;

create policy "system config public read"
  on public.system_config for select
  to anon, authenticated
  using (key in ('feature_toggles', 'lesson_videos'));

create policy "system config developer select"
  on public.system_config for select
  to authenticated
  using (public.is_x5_developer());

create policy "system config developer insert"
  on public.system_config for insert
  to authenticated
  with check (public.is_x5_developer());

create policy "system config developer update"
  on public.system_config for update
  to authenticated
  using (public.is_x5_developer())
  with check (public.is_x5_developer());

create policy "system config developer delete"
  on public.system_config for delete
  to authenticated
  using (public.is_x5_developer());

-- Remove storage write paths that bypassed the developer gate. Public reads
-- remain unchanged; signed-in users can still upload new submission videos.
drop policy if exists "course_media_insert_public" on storage.objects;
drop policy if exists "course_media_insert" on storage.objects;
drop policy if exists "course_media_update" on storage.objects;
drop policy if exists "course_media_delete" on storage.objects;

create policy "course_media_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'course-media'
    and public.is_x5_developer()
  );

create policy "course_media_update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'course-media'
    and public.is_x5_developer()
  )
  with check (
    bucket_id = 'course-media'
    and public.is_x5_developer()
  );

create policy "course_media_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'course-media'
    and public.is_x5_developer()
  );

drop policy if exists "course submission videos authenticated update" on storage.objects;

-- Preserve generic uploads for chat/profile/portfolio media, but remove the
-- course-cover overlap that made the stricter developer policies ineffective.
drop policy if exists "x5 storage authenticated write" on storage.objects;
drop policy if exists "x5 storage authenticated update" on storage.objects;
drop policy if exists "x5 storage authenticated delete own" on storage.objects;

create policy "x5 storage authenticated write"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = any (array['chat-media', 'portfolio', 'avatars']));

create policy "x5 storage authenticated update"
  on storage.objects for update
  to authenticated
  using (bucket_id = any (array['chat-media', 'portfolio', 'avatars']))
  with check (bucket_id = any (array['chat-media', 'portfolio', 'avatars']));

create policy "x5 storage authenticated delete own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = any (array['chat-media', 'portfolio', 'avatars'])
    and owner = (select auth.uid())
  );
