begin;

do $course_submission_video_limit$
declare
  v_file_size_limit bigint;
begin
  select file_size_limit
    into v_file_size_limit
    from storage.buckets
   where id = 'videos';

  if not found then
    raise exception 'course_submission_video_bucket_missing';
  end if;

  if v_file_size_limit is null or v_file_size_limit < 5368709120 then
    raise exception 'course_submission_video_limit_too_small: %', v_file_size_limit;
  end if;
end;
$course_submission_video_limit$;

rollback;

select 'course_submission_video_limit_supports_large_uploads' as status;
