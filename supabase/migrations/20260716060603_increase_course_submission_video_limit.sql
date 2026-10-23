-- Native iOS course applications upload the first lesson video to `videos`.
-- The legacy 10 MiB bucket limit rejected normal phone videos with HTTP 413.
insert into storage.buckets (id, name, public, file_size_limit)
values ('videos', 'videos', true, 5368709120)
on conflict (id) do update
set file_size_limit = excluded.file_size_limit;
