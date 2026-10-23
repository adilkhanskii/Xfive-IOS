-- Repair live chat push state that was missing from the production database.
-- The production chat schema stores user ids in text columns/arrays, so this
-- migration mirrors that shape instead of the older local uuid-only draft.

alter table public.profiles
  add column if not exists push_token text;

alter table public.profiles
  add column if not exists push_token_updated_at timestamptz;

alter table public.chats
  add column if not exists unread jsonb not null default '{}'::jsonb;

alter table public.chats
  add column if not exists task_id text;

alter table public.chats
  add column if not exists task_title text;

create or replace function public.x5_message_preview(
  message_type text,
  message_content text
) returns text
language sql
immutable
as $$
  select case
    when message_type = 'image' then 'Фото'
    when message_type = 'audio' then 'Голосовое'
    when message_type = 'video' then 'Видео'
    when message_type = 'file' then 'Файл'
    else coalesce(nullif(message_content, ''), 'Сообщение')
  end
$$;

create or replace function public.x5_handle_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  participant_id text;
  next_unread jsonb;
begin
  select coalesce(unread, '{}'::jsonb)
    into next_unread
    from public.chats
    where id = new.chat_id
    for update;

  if next_unread is null then
    return new;
  end if;

  for participant_id in
    select unnest(participants) from public.chats where id = new.chat_id
  loop
    if participant_id <> new.sender_id then
      next_unread = jsonb_set(
        next_unread,
        array[participant_id],
        to_jsonb(coalesce((next_unread ->> participant_id)::int, 0) + 1),
        true
      );
    end if;
  end loop;

  update public.chats
     set last_message = public.x5_message_preview(new.type, new.content),
         last_message_at = new.created_at,
         unread = next_unread
   where id = new.chat_id;

  return new;
end;
$$;

drop trigger if exists messages_chat_state on public.messages;
create trigger messages_chat_state
  after insert on public.messages
  for each row execute function public.x5_handle_new_message();

create or replace function public.x5_mark_chat_read(p_chat_id text)
returns public.chats
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_chat public.chats;
begin
  update public.chats
     set unread = jsonb_set(
       coalesce(unread, '{}'::jsonb),
       array[(auth.uid())::text],
       '0'::jsonb,
       true
     )
   where id = p_chat_id
     and (auth.uid())::text = any(participants)
   returning * into updated_chat;

  return updated_chat;
end;
$$;

grant execute on function public.x5_mark_chat_read(text) to authenticated;
