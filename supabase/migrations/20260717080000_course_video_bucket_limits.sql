-- Keep both course video paths large enough for normal phone recordings.
-- `videos` is used by the native application flow, while `course-media`
-- is used by the shared web/Android course editor.
insert into storage.buckets (id, name, public, file_size_limit)
values
  ('videos', 'videos', true, 5368709120),
  ('course-media', 'course-media', true, 5368709120)
on conflict (id) do update
set file_size_limit = excluded.file_size_limit;
