begin;

do $course_video_bucket_limits$
declare
  v_missing_buckets text[];
begin
  select array_agg(expected.id order by expected.id)
    into v_missing_buckets
    from (values ('videos'), ('course-media')) as expected(id)
    left join storage.buckets as bucket
      on bucket.id = expected.id
     and bucket.file_size_limit >= 5368709120
   where bucket.id is null;

  if coalesce(array_length(v_missing_buckets, 1), 0) > 0 then
    raise exception 'course_video_bucket_limits_missing_or_too_small: %', v_missing_buckets;
  end if;
end;
$course_video_bucket_limits$;

rollback;

select 'course_video_bucket_limits_support_large_uploads' as status;
