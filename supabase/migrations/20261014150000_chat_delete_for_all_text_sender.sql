-- Фикс «Удалить у всех» (Адильхан 14.10 15:10, iPhone: «Не получилось / Не удалось удалить сообщение у всех»).
-- Корень: на проде messages.sender_id — text, а auth.uid() — uuid. Сравнение
-- `msg.sender_id is distinct from auth.uid()` падало ошибкой 42883 (operator does not exist: text = uuid)
-- на КАЖДОМ вызове — у всех платформ, с 12.10. В репозитории 20260430_chats_messages.sql пишет uuid,
-- поэтому в тестах типа не было видно.
-- Сравниваем как текст: работает и при text, и при uuid в sender_id. Остальное тело — как в 20261012200000.
create or replace function public.x5_delete_message_for_all(p_message_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  msg public.messages;
  peer text;
  peer_unread int;
  newer_from_sender int;
  last_row public.messages;
begin
  select * into msg from public.messages where id = p_message_id;
  if msg.id is null then
    return false;
  end if;
  if msg.sender_id::text is distinct from auth.uid()::text then
    raise exception 'only the sender can delete a message for everyone' using errcode = '42501';
  end if;

  -- Блокируем строку чата, как триггер новых сообщений, чтобы счётчики не разъехались.
  perform 1 from public.chats where id = msg.chat_id for update;

  delete from public.messages where id = p_message_id;

  -- Непрочитанное у собеседника: удалённое среди его непрочитанных, если оно в «хвосте» из unread
  -- последних сообщений автора.
  for peer in
    select unnest(participants)::text from public.chats where id = msg.chat_id
  loop
    if peer <> msg.sender_id::text then
      select coalesce((unread ->> peer)::int, 0) into peer_unread from public.chats where id = msg.chat_id;
      select count(*) into newer_from_sender
        from public.messages
       where chat_id = msg.chat_id
         and sender_id = msg.sender_id
         and created_at > msg.created_at;
      if peer_unread > 0 and newer_from_sender < peer_unread then
        update public.chats
           set unread = jsonb_set(coalesce(unread, '{}'::jsonb), array[peer], to_jsonb(peer_unread - 1), true)
         where id = msg.chat_id;
      end if;
    end if;
  end loop;

  select * into last_row
    from public.messages
   where chat_id = msg.chat_id
   order by created_at desc
   limit 1;

  update public.chats
     set last_message = case when last_row.id is null then null else public.x5_message_preview(last_row.type, last_row.content) end,
         last_message_at = case when last_row.id is null then last_message_at else last_row.created_at end
   where id = msg.chat_id;

  return true;
end;
$$;

revoke all on function public.x5_delete_message_for_all(uuid) from public;
grant execute on function public.x5_delete_message_for_all(uuid) to authenticated;
-- Supabase по умолчанию даёт execute и anon: убираем явно (без входа auth.uid() = null → и так отказ 42501).
revoke execute on function public.x5_delete_message_for_all(uuid) from anon;
