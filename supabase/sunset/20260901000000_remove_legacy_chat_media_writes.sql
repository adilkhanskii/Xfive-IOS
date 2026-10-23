-- REVIEWED MANUAL SUNSET MIGRATION. Apply on or after 2026-09-01 00:00 UTC
-- after confirming supported iOS/web/Android versions use
-- <chat_id>/<user_id>/<filename>. The release policy and message validator
-- already reject legacy writes after this timestamp; this removes dead ACL.

do $sunset_date$
begin
  if clock_timestamp() < timestamptz '2026-09-01 00:00:00+00' then
    raise exception using
      errcode = '55000',
      message = 'legacy_chat_media_sunset_not_due';
  end if;
end;
$sunset_date$;

drop policy if exists "chat_media_legacy_insert_until_2026_09_01"
  on storage.objects;
