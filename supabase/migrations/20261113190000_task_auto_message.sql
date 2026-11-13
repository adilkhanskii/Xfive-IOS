-- Автосообщение задания: автор пишет шаблон при создании задания,
-- при первом отклике исполнителя текст один раз уходит в чат от имени автора.
-- Делается на сервере: телефон исполнителя не может писать от имени автора (RLS messages: sender = auth.uid()).

alter table public.tasks
  add column if not exists auto_message text;

alter table public.tasks
  drop constraint if exists tasks_auto_message_length;
alter table public.tasks
  add constraint tasks_auto_message_length
  check (auto_message is null or char_length(auto_message) <= 1000);

-- «Уже отправлено»: одна строка на пару (задание, исполнитель) — второй раз не шлём.
create table if not exists public.task_auto_message_log (
  task_id uuid not null references public.tasks(id) on delete cascade,
  responder_id text not null,
  chat_id text not null,
  message_id uuid,
  created_at timestamptz not null default now(),
  primary key (task_id, responder_id)
);
-- Пишут только серверные функции ниже; клиентам таблица не видна.
alter table public.task_auto_message_log enable row level security;
revoke all on public.task_auto_message_log from anon, authenticated;

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

-- iOS: «Откликнуться» открывает чат и шлёт карточку задания (type = task_card, content.id = id задания).
create or replace function public.x5_task_auto_message_on_card()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_task_id uuid;
begin
  begin
    v_task_id := nullif(new.content::jsonb ->> 'id', '')::uuid;
  exception when others then
    return new; -- не JSON или не uuid — просто карточка
  end;
  if v_task_id is not null then
    perform public.x5_send_task_auto_message(v_task_id, new.sender_id, new.chat_id);
  end if;
  return new;
end;
$function$;

drop trigger if exists messages_task_auto_message on public.messages;
create trigger messages_task_auto_message
  after insert on public.messages
  for each row
  when (new.type = 'task_card')
  execute function public.x5_task_auto_message_on_card();

-- Веб/Android: отклик = строка в task_responses, чат пока не открывается.
create or replace function public.x5_task_auto_message_on_response()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform public.x5_send_task_auto_message(new.task_id, new.specialist_id::text, null);
  return new;
end;
$function$;

drop trigger if exists task_responses_auto_message on public.task_responses;
create trigger task_responses_auto_message
  after insert on public.task_responses
  for each row
  execute function public.x5_task_auto_message_on_response();

revoke all on function public.x5_task_auto_message_on_card() from public, anon, authenticated;
revoke all on function public.x5_task_auto_message_on_response() from public, anon, authenticated;
