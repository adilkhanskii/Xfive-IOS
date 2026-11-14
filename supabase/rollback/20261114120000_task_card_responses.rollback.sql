-- Откат 20261114120000_task_card_responses: карточка больше не создаёт отклик,
-- веб-отклик снова шлёт только автосообщение (функция — как в 20261113190000).
drop trigger if exists messages_task_response_from_card on public.messages;
drop function if exists public.x5_task_response_from_card();

-- Отклики, созданные из карточек (и перенесённые из старых чатов), — у них такой текст.
delete from public.task_responses where message = 'Отклик через чат';

-- Бэкап откликов до миграции: public.backup_20261114_task_responses, удалить после 14.12.

create or replace function public.x5_send_task_auto_message(
  p_task_id uuid,
  p_responder_id text,
  p_chat_id text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_author text;
  v_title text;
  v_text text;
  v_chat_id text;
  v_participants text[];
  v_message_id uuid;
begin
  -- Свой блок с exception: сбой автосообщения не должен ломать отклик/карточку задания.
  begin
    select t.author_id::text, t.title, btrim(coalesce(t.auto_message, ''))
      into v_author, v_title, v_text
      from public.tasks t
     where t.id = p_task_id;

    if not found or v_text = '' then
      return;
    end if;
    if p_responder_id is null or btrim(p_responder_id) = '' or p_responder_id = v_author then
      return;
    end if;

    -- Тот же id чата, что строят приложения: два id по возрастанию через «_» (collate "C" = как sort() в JS/Swift).
    v_chat_id := coalesce(
      nullif(btrim(p_chat_id), ''),
      (select string_agg(x, '_' order by x collate "C") from unnest(array[v_author, p_responder_id]) as x)
    );

    insert into public.task_auto_message_log (task_id, responder_id, chat_id)
    values (p_task_id, p_responder_id, v_chat_id)
    on conflict do nothing;
    if not found then
      return; -- уже отправляли этому исполнителю
    end if;

    -- Веб-отклик чат не создаёт — создаём сами.
    insert into public.chats (id, participants, task_id, task_title, unread)
    values (v_chat_id, array[v_author, p_responder_id], p_task_id::text, v_title, '{}'::jsonb)
    on conflict (id) do nothing;

    select c.participants into v_participants from public.chats c where c.id = v_chat_id;
    if v_participants is null
       or not (v_author = any(v_participants))
       or not (p_responder_id = any(v_participants)) then
      delete from public.task_auto_message_log where task_id = p_task_id and responder_id = p_responder_id;
      return;
    end if;

    -- clock_timestamp(): строго позже карточки задания из той же транзакции.
    insert into public.messages (chat_id, sender_id, type, content, created_at)
    values (v_chat_id, v_author, 'text', v_text, clock_timestamp())
    returning id into v_message_id;

    update public.task_auto_message_log
       set message_id = v_message_id
     where task_id = p_task_id and responder_id = p_responder_id;
  exception when others then
    raise warning 'x5_send_task_auto_message(%): %', p_task_id, sqlerrm;
  end;
end;
$function$;

revoke all on function public.x5_send_task_auto_message(uuid, text, text) from public, anon, authenticated;
