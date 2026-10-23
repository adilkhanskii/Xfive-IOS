-- Chat read state, unread counters, and APNs token storage.
-- Idempotent so it is safe to apply on databases that already have part of it.

alter table profiles add column if not exists push_token text;
alter table profiles add column if not exists push_token_updated_at timestamptz;

create or replace function public.x5_message_preview(
  message_type text,
  message_content text
) returns text
language sql
immutable
as $$
  select case
    when message_type = 'image' then 'Photo'
    when message_type = 'audio' then 'Voice message'
    when message_type = 'video' then 'Video'
    when message_type = 'file' then 'File'
    else coalesce(nullif(message_content, ''), 'Message')
  end
$$;

create or replace function public.x5_handle_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  participant_id uuid;
  next_unread jsonb;
begin
  select coalesce(unread, '{}'::jsonb)
    into next_unread
    from chats
    where id = new.chat_id
    for update;

  if next_unread is null then
    return new;
  end if;

  for participant_id in
    select unnest(participants) from chats where id = new.chat_id
  loop
    if participant_id <> new.sender_id then
      next_unread = jsonb_set(
        next_unread,
        array[participant_id::text],
        to_jsonb(coalesce((next_unread ->> participant_id::text)::int, 0) + 1),
        true
      );
    end if;
  end loop;

  update chats
     set last_message = public.x5_message_preview(new.type, new.content),
         last_message_at = new.created_at,
         unread = next_unread
   where id = new.chat_id;

  return new;
end;
$$;

drop trigger if exists messages_chat_state on messages;
create trigger messages_chat_state
  after insert on messages
  for each row execute function public.x5_handle_new_message();

create or replace function public.x5_mark_chat_read(p_chat_id text)
returns chats
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_chat chats;
begin
  update chats
     set unread = jsonb_set(
       coalesce(unread, '{}'::jsonb),
       array[auth.uid()::text],
       '0'::jsonb,
       true
     )
   where id = p_chat_id
     and auth.uid() = any(participants)
   returning * into updated_chat;

  return updated_chat;
end;
$$;

grant execute on function public.x5_mark_chat_read(text) to authenticated;
