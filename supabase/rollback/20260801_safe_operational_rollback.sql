-- NON-AUTOMATIC, REVIEW-REQUIRED operational rollback for:
--   20260801115000_push_tokens_contract.sql
--   20260801120000_secure_push_dispatch.sql
--   20260801121000_portfolio_automatic_moderation_enforcement.sql
--   20260801122000_secure_chat_attachments.sql
--   20260801123000_private_portfolio_media.sql
--
-- This script preserves every user message, notification, task, response,
-- portfolio row and Storage object. It intentionally retains private ledgers
-- and security/data-integrity hardening. Run only after the backup and drain
-- checks in ROLLBACK_20260801.md.

begin;

-- Refuse to strand an event that has not reached a terminal outbox state.
do $push_drain_required$
declare
  v_unfinished bigint;
begin
  select count(*)
    into v_unfinished
    from public.push_webhook_outbox as outbox
   where outbox.status in ('pending', 'in_flight');
  if v_unfinished > 0 then
    raise exception using
      errcode = '55000',
      message = 'push_outbox_must_be_drained_or_exported_before_rollback';
  end if;
end;
$push_drain_required$;

-- Pause push production and retry processing without restoring the old
-- spoofable anonymous webhook body. Database notifications continue to be
-- created; only the external provider send is paused.
do $unschedule_push_jobs$
begin
  begin
    perform cron.unschedule('x5-process-push-webhook-outbox');
  exception when others then
    null;
  end;
  begin
    perform cron.unschedule('x5-clean-push-dispatches');
  exception when others then
    null;
  end;
  begin
    perform cron.unschedule('x5-portfolio-moderation-sweep');
  exception when others then
    null;
  end;
end;
$unschedule_push_jobs$;

drop trigger if exists messages_push_notify on public.messages;

create or replace function public.x5_enqueue_push_webhook(
  p_event_type text,
  p_event_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null then
    raise exception using errcode = '22023', message = 'invalid_push_event';
  end if;
  return null;
end;
$function$;

revoke all on function public.x5_enqueue_push_webhook(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_enqueue_push_webhook(text, uuid)
  to postgres;
comment on function public.x5_enqueue_push_webhook(text, uuid) is
  'Push paused by reviewed 2026-08-01 operational rollback; rerun the release migration to resume.';

-- Restore the previous public chat-media transport for an incompatible client
-- rollback. This does not delete or rename any object. Keep this window short.
update storage.buckets
   set public = true,
       file_size_limit = 52428800,
       allowed_mime_types = null
 where id = 'chat-media';

drop trigger if exists messages_validate_attachment on public.messages;
drop function if exists public.x5_validate_message_attachment();

drop policy if exists "chat_media_participant_select" on storage.objects;
drop policy if exists "chat_media_participant_insert" on storage.objects;
drop policy if exists "chat_media_owner_delete" on storage.objects;

drop policy if exists "x5 storage public read" on storage.objects;
create policy "x5 storage public read"
on storage.objects for select
to public
using (
  bucket_id = any (
    array['course-covers', 'chat-media', 'avatars']
  )
);

drop policy if exists "x5 storage authenticated write" on storage.objects;
create policy "x5 storage authenticated write"
on storage.objects for insert
to authenticated
with check (
  bucket_id = any (array['chat-media', 'avatars'])
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and pg_catalog.cardinality(storage.foldername(name)) in (1, 2)
    and (
      pg_catalog.cardinality(storage.foldername(name)) = 1
      or (storage.foldername(name))[2] = 'thumbnails'
    )
    and storage.filename(name) ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$'
    and name not like '%..%'
    and name not like '%//%'
    and name not like '%\\%'
  )
);

drop policy if exists "x5 storage authenticated update" on storage.objects;
create policy "x5 storage authenticated update"
on storage.objects for update
to authenticated
using (
  bucket_id = any (array['chat-media', 'avatars'])
  and owner_id = (select auth.uid())::text
)
with check (
  bucket_id = any (array['chat-media', 'avatars'])
  and owner_id = (select auth.uid())::text
);

drop policy if exists "x5 storage authenticated delete own" on storage.objects;
create policy "x5 storage authenticated delete own"
on storage.objects for delete
to authenticated
using (
  (
    bucket_id = any (array['chat-media', 'avatars'])
    and owner_id = (select auth.uid())::text
  )
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and not public.x5_portfolio_object_is_referenced(name)
  )
);

-- The prior portfolio release was already automatic-only. Restore its compact
-- owner policy while retaining the hardened fail-closed trigger and the exact
-- pending/approved/rejected constraint. No verdict or media row is rewritten.
drop policy if exists "portfolio public read" on public.portfolio_items;
drop policy if exists "portfolio_owner_insert" on public.portfolio_items;
drop policy if exists "portfolio_owner_update" on public.portfolio_items;
drop policy if exists "portfolio_owner_delete" on public.portfolio_items;
drop policy if exists "portfolio owner write" on public.portfolio_items;

create policy "portfolio public read"
on public.portfolio_items for select
to anon, authenticated
using (
  moderation_status = 'approved'
  or (select auth.uid()) = user_id
);

create policy "portfolio owner write"
on public.portfolio_items for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

alter table public.portfolio_items
  alter column moderation_status set default 'pending';

commit;

-- Deliberately absent: DROP TABLE, DELETE/TRUNCATE, Storage object removal,
-- notification/message deletion, and restoration of the legacy spoofable push
-- webhook. Retire ledgers only in a later reviewed migration after retention.
