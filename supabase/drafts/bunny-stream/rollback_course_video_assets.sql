-- DRAFT rollback for the Bunny course-video drafts. Run only after the
-- clients have stopped writing Bunny lessons (flag off) and lessons that
-- point at Bunny were restored (scripts/bunny/migrate-course-videos-to-bunny.mjs
-- --rollback <manifest>), otherwise those lessons lose playback.
--
-- Bunny videos themselves are NOT deleted by this script. List them first:
--   select bunny_video_id, course_id, lesson_id, status
--     from public.course_video_assets where status <> 'deleted';

begin;

update public.app_feature_flags
   set enabled = false, updated_at = now()
 where key = 'bunny_course_video_upload';

do $$
begin
  begin
    perform cron.unschedule('x5-reconcile-course-videos');
  exception when others then
    null;
  end;
end $$;

drop function if exists public.enqueue_course_video_reconciliation();
drop function if exists public.course_video_playback_grant(uuid, uuid, text);
drop function if exists public.course_video_mark_deleted(uuid);
drop function if exists public.course_video_reconcile_batch(integer);
drop function if exists public.course_video_owner_lookup(uuid, uuid);
drop function if exists public.course_video_record_provider_status(
  uuid, integer, integer, integer, text, text, integer, integer
);
drop function if exists public.course_video_attach_to_lesson(uuid, text, uuid, boolean);
drop function if exists public.course_video_register_migrated(
  uuid, text, uuid, text, text, bigint
);
drop function if exists public.course_video_complete_upload(
  uuid, text, text, uuid, uuid, text
);
drop function if exists public.course_video_claim_upload(
  uuid, uuid, text, text, text, uuid, bigint
);
-- Keep the ledger table for audit unless explicitly asked:
-- drop table if exists public.course_video_assets;
-- Helpers are harmless; drop when nothing else uses them:
-- drop function if exists public.x5_course_find_lesson(jsonb, text);
-- drop function if exists public.x5_course_lessons_patch(jsonb, text, text, jsonb, text[]);
-- drop function if exists public.x5_is_developer_user(uuid);

commit;
