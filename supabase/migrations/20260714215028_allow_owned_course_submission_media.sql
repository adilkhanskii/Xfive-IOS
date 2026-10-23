-- Course applications remain available to ordinary authenticated users, but
-- their uploads are confined to an immutable per-user submissions folder.
-- Published course media continues to require is_x5_developer().

drop policy if exists "course_media_submission_insert" on storage.objects;
drop policy if exists "course_media_submission_delete" on storage.objects;

create policy "course_media_submission_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'course-media'
    and (storage.foldername(name))[1] = 'submissions'
    and (storage.foldername(name))[2] = (select auth.uid())::text
  );

create policy "course_media_submission_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'course-media'
    and (storage.foldername(name))[1] = 'submissions'
    and (storage.foldername(name))[2] = (select auth.uid())::text
  );
