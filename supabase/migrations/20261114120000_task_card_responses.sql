-- Отклик с iOS = карточка задания в чате (messages.type = 'task_card'), строки в task_responses не было:
-- на странице задания «Отклики (0)», хотя исполнители откликались. Теперь карточка сама создаёт отклик.
-- Веб-отклик на задание с шаблоном: сервер кладёт в чат карточку от исполнителя, потом автосообщение — как в iOS.

-- 1. Карточка от исполнителя → строка отклика (один раз на пару задание + исполнитель).
create or replace function public.x5_task_response_from_card()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_task_id uuid;
  v_author text;
  v_name text;
  v_avatar text;
begin
  begin
    v_task_id := nullif(new.content::jsonb ->> 'id', '')::uuid;
  exception when others then
    return new; -- не JSON или не uuid — просто карточка
  end;
  if v_task_id is null then
    return new;
  end if;

  -- Сбой отклика не должен ломать отправку карточки.
  begin
    select t.author_id::text into v_author from public.tasks t where t.id = v_task_id;
    if v_author is null or new.sender_id = v_author then
      return new;
    end if;
    -- Только карточка в чате автора с исполнителем.
    if not exists (
      select 1 from public.chats c
       where c.id = new.chat_id
         and v_author = any(c.participants)
         and new.sender_id = any(c.participants)
    ) then
      return new;
    end if;

    select p.name, p.avatar into v_name, v_avatar
      from public.profiles p
     where p.id::text = new.sender_id;

    -- specialist_name NOT NULL: без имени в профиле — «Исполнитель».
    -- status 'open': так пишет iOS, и только у 'open' iOS показывает автору кнопку «Принять».
    insert into public.task_responses (task_id, specialist_id, specialist_name, specialist_avatar, message, status)
    values (v_task_id, new.sender_id::uuid, coalesce(nullif(btrim(v_name), ''), 'Исполнитель'), v_avatar, 'Отклик через чат', 'open')
    on conflict (task_id, specialist_id) do nothing;
  exception when others then
    raise warning 'x5_task_response_from_card(%): %', v_task_id, sqlerrm;
  end;
  return new;
end;
$function$;

revoke all on function public.x5_task_response_from_card() from public, anon, authenticated;

-- Имя > messages_task_auto_message: сначала автосообщение, потом отклик (его триггер автосообщение второй раз не шлёт — журнал).
drop trigger if exists messages_task_response_from_card on public.messages;
create trigger messages_task_response_from_card
  after insert on public.messages
  for each row
  when (new.type = 'task_card')
  execute function public.x5_task_response_from_card();

-- 2. Автосообщение: при веб-отклике (p_chat_id is null) сначала карточка от исполнителя.
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
  v_author_name text;
  v_title text;
  v_description text;
  v_budget text;
  v_category text;
  v_text text;
  v_chat_id text;
  v_participants text[];
  v_message_id uuid;
begin
  -- Свой блок с exception: сбой автосообщения не должен ломать отклик/карточку задания.
  begin
    select t.author_id::text, t.author_name, t.title, t.description, t.budget,
           coalesce(nullif(t.category, ''), t.categories[1]),
           btrim(coalesce(t.auto_message, ''))
      into v_author, v_author_name, v_title, v_description, v_budget, v_category, v_text
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

    -- Веб-отклик: карточка «Отклик по заданию» от исполнителя, как шлёт iOS (ключи ChatTaskCardPayload).
    -- Её триггеры: автосообщение — уже в журнале, отклик — уже есть (on conflict).
    if p_chat_id is null and not exists (
      select 1 from public.messages m
       where m.chat_id = v_chat_id
         and m.type = 'task_card'
         and m.sender_id = p_responder_id
         and m.content like '%' || p_task_id::text || '%'
    ) then
      if v_author_name is null then
        select p.name into v_author_name from public.profiles p where p.id::text = v_author;
      end if;
      insert into public.messages (chat_id, sender_id, type, content, created_at)
      values (
        v_chat_id, p_responder_id, 'task_card',
        jsonb_build_object(
          'id', p_task_id::text,
          'title', coalesce(v_title, ''),
          'description', v_description,
          'budget', v_budget,
          'category', v_category,
          'authorName', v_author_name
        )::text,
        clock_timestamp()
      );
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

-- 3. Прошлые отклики с iOS (карточки в чатах) → строки откликов, чтобы счётчик стал верным.
-- Автосообщения по старым откликам не шлём: триггер отклика выключен только на время вставки.
alter table public.task_responses disable trigger task_responses_auto_message;

insert into public.task_responses (task_id, specialist_id, specialist_name, specialist_avatar, message, status, created_at)
select distinct on (t.id, m.sender_id)
       t.id, m.sender_id::uuid, coalesce(nullif(btrim(p.name), ''), 'Исполнитель'), p.avatar, 'Отклик через чат', 'open', m.created_at
  from public.messages m
  join public.tasks t on t.id::text = (m.content::jsonb ->> 'id')
  join public.chats c on c.id = m.chat_id
  left join public.profiles p on p.id::text = m.sender_id
 where m.type = 'task_card'
   and m.content ~ '^\s*\{'
   and m.sender_id ~ '^[0-9a-fA-F-]{36}$'
   and m.sender_id <> t.author_id::text
   and t.author_id::text = any(c.participants)
   and m.sender_id = any(c.participants)
 order by t.id, m.sender_id, m.created_at
on conflict (task_id, specialist_id) do nothing;

alter table public.task_responses enable trigger task_responses_auto_message;
