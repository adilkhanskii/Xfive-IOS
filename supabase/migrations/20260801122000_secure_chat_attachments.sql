-- Chat attachments are private conversation data. Bind Storage paths and
-- message references to the canonical chat participant relationship.

update storage.buckets
   set public = false,
       -- Supabase Free rejects objects above 50 MB. Keep the same 47,000,000
       -- byte safety ceiling as CourseUP so multipart and TUS agree.
       file_size_limit = 47000000,
       allowed_mime_types = array[
         'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp',
         'audio/m4a', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/mpeg',
         'audio/webm', 'audio/ogg', 'audio/wav',
         'video/mp4', 'video/quicktime', 'video/webm', 'video/x-m4v'
       ]::text[]
 where id = 'chat-media';

drop policy if exists "chat-media select" on storage.objects;
drop policy if exists "chat-media insert" on storage.objects;
drop policy if exists "chat-media update" on storage.objects;
drop policy if exists "chat-media delete" on storage.objects;
drop policy if exists "chat_media_public_read" on storage.objects;
drop policy if exists "chat_media_authenticated_insert" on storage.objects;
drop policy if exists "chat_media_authenticated_update" on storage.objects;
drop policy if exists "chat_media_authenticated_delete" on storage.objects;

-- Remove chat-media from broad legacy policies while preserving their avatar
-- and portfolio behavior.
drop policy if exists "x5 storage public read" on storage.objects;
create policy "x5 storage public read"
on storage.objects for select
to public
using (bucket_id = any (array['course-covers', 'portfolio', 'avatars']));

drop policy if exists "x5 storage authenticated write" on storage.objects;
create policy "x5 storage authenticated write"
on storage.objects for insert
to authenticated
with check (
  (
    bucket_id = 'avatars'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
);

drop policy if exists "x5 storage authenticated update" on storage.objects;
create policy "x5 storage authenticated update"
on storage.objects for update
to authenticated
using (
  bucket_id = 'avatars'
  and owner_id = (select auth.uid())::text
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'avatars'
  and owner_id = (select auth.uid())::text
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "x5 storage authenticated delete own" on storage.objects;
create policy "x5 storage authenticated delete own"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'avatars'
  and owner_id = (select auth.uid())::text
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "chat_media_participant_select"
on storage.objects for select
to authenticated
using (
  bucket_id = 'chat-media'
  and exists (
    select 1
      from public.chats as chat
     where chat.id::text = case
       when (storage.foldername(name))[1] = 'chats'
         then (storage.foldername(name))[2]
       else (storage.foldername(name))[1]
     end
       and (select auth.uid())::text = any(chat.participants::text[])
  )
);

create policy "chat_media_participant_insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'chat-media'
  and owner_id = (select auth.uid())::text
  and pg_catalog.cardinality(storage.foldername(name)) = 2
  and (storage.foldername(name))[1] ~ '^[A-Za-z0-9_-]{1,200}$'
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and storage.filename(name) ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$'
  and name not like '%..%'
  and name not like '%//%'
  and name not like '%\\%'
  and exists (
    select 1
      from public.chats as chat
     where chat.id::text = (storage.foldername(name))[1]
       and (select auth.uid())::text = any(chat.participants::text[])
  )
);

-- Compatibility window for already-installed clients that still upload
-- chats/<chat_id>/<filename>. The policy expires by database time even if the
-- explicit sunset migration is delayed. New clients use the canonical policy
-- above and never depend on this route.
drop policy if exists "chat_media_legacy_insert_until_2026_09_01"
  on storage.objects;
create policy "chat_media_legacy_insert_until_2026_09_01"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'chat-media'
  and clock_timestamp() < timestamptz '2026-09-01 00:00:00+00'
  and owner_id = (select auth.uid())::text
  and pg_catalog.cardinality(storage.foldername(name)) = 2
  and (storage.foldername(name))[1] = 'chats'
  and storage.filename(name) ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$'
  and name not like '%..%'
  and name not like '%//%'
  and name not like '%\\%'
  and exists (
    select 1
      from public.chats as chat
     where chat.id::text = (storage.foldername(name))[2]
       and (select auth.uid())::text = any(chat.participants::text[])
  )
);

create policy "chat_media_owner_delete"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'chat-media'
  and owner_id = (select auth.uid())::text
  and exists (
    select 1
      from public.chats as chat
     where chat.id::text = case
       when (storage.foldername(name))[1] = 'chats'
         then (storage.foldername(name))[2]
       else (storage.foldername(name))[1]
     end
       and (select auth.uid())::text = any(chat.participants::text[])
  )
);

create or replace function public.x5_validate_message_attachment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_public_prefix constant text :=
    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/chat-media/';
  v_authenticated_prefix constant text :=
    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/authenticated/chat-media/';
  v_object_name text;
  v_object_owner text;
  v_object_mime text;
  v_object_size bigint;
  v_is_legacy_path boolean;
begin
  if new.type not in ('text', 'task_card', 'image', 'audio', 'video') then
    raise exception using errcode = '23514', message = 'unsupported_message_type';
  end if;

  if new.type in ('text', 'task_card') then
    if new.media_url is not null or new.media_mime is not null then
      raise exception using errcode = '23514', message = 'text_message_media_forbidden';
    end if;
    return new;
  end if;

  if new.media_url is null
     or new.media_url like '%?%'
     or new.media_url like '%#%' then
    raise exception using errcode = '23514', message = 'canonical_chat_media_url_required';
  end if;

  if pg_catalog.left(new.media_url, pg_catalog.length(v_public_prefix)) =
       v_public_prefix then
    v_object_name := pg_catalog.substring(
      new.media_url from pg_catalog.length(v_public_prefix) + 1
    );
  elsif pg_catalog.left(
    new.media_url,
    pg_catalog.length(v_authenticated_prefix)
  ) = v_authenticated_prefix then
    v_object_name := pg_catalog.substring(
      new.media_url from pg_catalog.length(v_authenticated_prefix) + 1
    );
  else
    raise exception using errcode = '23514', message = 'external_chat_media_url_forbidden';
  end if;

  if v_object_name = ''
     or v_object_name like '%..%'
     or v_object_name like '%//%'
     or v_object_name like '%\\%' then
    raise exception using errcode = '23514', message = 'chat_media_path_mismatch';
  end if;

  v_is_legacy_path :=
    v_object_name like 'chats/' || new.chat_id::text || '/%';

  -- Existing legacy rows remain immutable. During the bounded compatibility
  -- window, installed clients may create a new legacy row only when the
  -- Storage object owner, chat membership, MIME and size all validate below.
  if v_is_legacy_path then
    if tg_op = 'UPDATE' then
      if new.chat_id is distinct from old.chat_id
         or new.sender_id is distinct from old.sender_id
         or new.type is distinct from old.type
         or new.media_url is distinct from old.media_url
         or new.media_mime is distinct from old.media_mime then
        raise exception using errcode = '23514', message = 'legacy_chat_media_read_only';
      end if;
      return new;
    end if;
    if clock_timestamp() >= timestamptz '2026-09-01 00:00:00+00' then
      raise exception using errcode = '23514', message = 'legacy_chat_media_write_sunset';
    end if;
    if pg_catalog.cardinality(storage.foldername(v_object_name)) <> 2
       or (storage.foldername(v_object_name))[1] <> 'chats'
       or (storage.foldername(v_object_name))[2] is distinct from new.chat_id::text
       or storage.filename(v_object_name) !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$' then
      raise exception using errcode = '23514', message = 'chat_media_path_mismatch';
    end if;
  else
    if pg_catalog.cardinality(storage.foldername(v_object_name)) <> 2
       or (storage.foldername(v_object_name))[1] is distinct from new.chat_id::text
       or (storage.foldername(v_object_name))[2] is distinct from new.sender_id::text
       or storage.filename(v_object_name) !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$' then
      raise exception using errcode = '23514', message = 'chat_media_path_mismatch';
    end if;
  end if;

  select
    object.owner_id,
    pg_catalog.lower(object.metadata ->> 'mimetype'),
    case
      when object.metadata ->> 'size' ~ '^[0-9]{1,12}$'
        then (object.metadata ->> 'size')::bigint
      else null
    end
    into v_object_owner, v_object_mime, v_object_size
    from storage.objects as object
   where object.bucket_id = 'chat-media'
     and object.name = v_object_name;

  if not found then
    raise exception using errcode = '23503', message = 'chat_media_object_not_found';
  end if;
  if v_object_owner is distinct from new.sender_id::text then
    raise exception using errcode = '42501', message = 'chat_media_owner_mismatch';
  end if;
  if v_object_size is null or v_object_size <= 0 then
    raise exception using errcode = '23514', message = 'chat_media_size_invalid';
  end if;

  if (
    new.type = 'image'
    and (
      v_object_mime not in (
        'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp'
      )
      or v_object_size > 12582912
    )
  ) or (
    new.type = 'audio'
    and (
      v_object_mime not in (
        'audio/m4a', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/mpeg',
        'audio/webm', 'audio/ogg', 'audio/wav'
      )
      or v_object_size > 20971520
    )
  ) or (
    new.type = 'video'
    and (
      v_object_mime not in (
        'video/mp4', 'video/quicktime', 'video/webm', 'video/x-m4v'
      )
      or v_object_size > 47000000
    )
  ) then
    raise exception using errcode = '23514', message = 'chat_media_type_mismatch';
  end if;

  -- MIME is Storage-derived; a client-provided value is never authoritative.
  new.media_mime := v_object_mime;
  new.media_url := v_public_prefix || v_object_name;
  return new;
end;
$function$;

revoke all on function public.x5_validate_message_attachment()
  from public, anon, authenticated, service_role;

drop trigger if exists messages_validate_attachment on public.messages;
create trigger messages_validate_attachment
before insert or update of chat_id, sender_id, type, media_url, media_mime
on public.messages
for each row execute function public.x5_validate_message_attachment();

comment on function public.x5_validate_message_attachment() is
  'Requires canonical sender-owned paths for new media, preserves unchanged legacy rows for read compatibility, and derives MIME from Storage.';
