-- Закреп сообщения в личном чате, как в Telegram (Адильхан 09.10):
-- один закреп на чат, общий для обоих участников и всех устройств (iOS, Android, сайт).
-- Раньше iOS хранил закреп только в памяти телефона — плашки сверху не было, собеседник его не видел.
--
-- Совместимость: поле новое и пустое, старые сборки его не читают и не пишут.
-- Права: участник чата уже может менять свою строку chats (политика "Users can update own chats").

alter table public.chats
  add column if not exists pinned_message_id uuid
  references public.messages(id) on delete set null;

-- Закрепить можно только сообщение из этого же чата — иначе чужой id попал бы в плашку.
create or replace function public.x5_guard_chat_pinned_message()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.pinned_message_id is not null
     and new.pinned_message_id is distinct from old.pinned_message_id
     and not exists (
       select 1 from public.messages m
       where m.id = new.pinned_message_id and m.chat_id = new.id
     ) then
    raise exception 'Можно закрепить только сообщение из этого чата'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists chats_pinned_message_guard on public.chats;
create trigger chats_pinned_message_guard
  before update of pinned_message_id on public.chats
  for each row execute function public.x5_guard_chat_pinned_message();

-- идея: если понадобится несколько закрепов (как в группах Telegram) — отдельная таблица chat_pins.
