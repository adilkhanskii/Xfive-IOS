-- Keep active invitation discovery public, but restrict every mutation to the
-- two immutable developer accounts enforced by public.is_x5_developer().
alter table public.course_invites enable row level security;

revoke all on table public.course_invites from anon, authenticated;
grant select on table public.course_invites to anon, authenticated;
grant insert, update, delete on table public.course_invites to authenticated;

drop policy if exists "Authors can manage invites" on public.course_invites;
drop policy if exists "course invites developer select" on public.course_invites;
drop policy if exists "course invites developer insert" on public.course_invites;
drop policy if exists "course invites developer update" on public.course_invites;
drop policy if exists "course invites developer delete" on public.course_invites;

create policy "course invites developer select"
  on public.course_invites for select
  to authenticated
  using (public.is_x5_developer());

create policy "course invites developer insert"
  on public.course_invites for insert
  to authenticated
  with check (public.is_x5_developer());

create policy "course invites developer update"
  on public.course_invites for update
  to authenticated
  using (public.is_x5_developer())
  with check (public.is_x5_developer());

create policy "course invites developer delete"
  on public.course_invites for delete
  to authenticated
  using (public.is_x5_developer());

-- Submission videos remain public to read. New clients use
-- course-submissions/<auth uid>/<file>; the flat course-submissions/<file>
-- shape stays available for the installed App Store build. In both cases the
-- Storage-owned owner_id must match the authenticated JWT subject.
drop policy if exists "course submission videos authenticated upload" on storage.objects;
drop policy if exists "course submission videos authenticated update" on storage.objects;
drop policy if exists "course submission videos authenticated delete" on storage.objects;
drop policy if exists "course submission videos owner insert" on storage.objects;
drop policy if exists "course submission videos owner update" on storage.objects;
drop policy if exists "course submission videos owner delete" on storage.objects;
drop policy if exists "course submission videos developer insert" on storage.objects;
drop policy if exists "course submission videos developer update" on storage.objects;
drop policy if exists "course submission videos developer delete" on storage.objects;

create policy "course submission videos owner insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and owner_id = (select auth.uid())::text
    and (
      array_length(storage.foldername(name), 1) = 1
      or (storage.foldername(name))[2] = (select auth.uid())::text
    )
  );

create policy "course submission videos owner update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and owner_id = (select auth.uid())::text
    and (
      array_length(storage.foldername(name), 1) = 1
      or (storage.foldername(name))[2] = (select auth.uid())::text
    )
  )
  with check (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and owner_id = (select auth.uid())::text
    and (
      array_length(storage.foldername(name), 1) = 1
      or (storage.foldername(name))[2] = (select auth.uid())::text
    )
  );

create policy "course submission videos owner delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and owner_id = (select auth.uid())::text
    and (
      array_length(storage.foldername(name), 1) = 1
      or (storage.foldername(name))[2] = (select auth.uid())::text
    )
  );

create policy "course submission videos developer insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and public.is_x5_developer()
  );

create policy "course submission videos developer update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and public.is_x5_developer()
  )
  with check (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and public.is_x5_developer()
  );

create policy "course submission videos developer delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'videos'
    and (storage.foldername(name))[1] = 'course-submissions'
    and public.is_x5_developer()
  );
