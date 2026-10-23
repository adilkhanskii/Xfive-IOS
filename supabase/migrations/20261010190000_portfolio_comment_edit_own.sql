-- Адильхан 10.10 18:03: «комент не редактируется, не удаляется».
-- Прод: у portfolio_comments есть «читать всем / добавлять своё / удалять своё»,
-- но нет права изменить. Даём автору править свой текст на месте:
-- порядок комментариев не прыгает, а под текстом видно «изменено».
--
-- Зачем триггер: политика UPDATE пускает автора к строке целиком. Триггер
-- оставляет менять только text: пост, автор и дата создания не меняются,
-- edited_at ставит сервер (клиенту не доверяем).

alter table public.portfolio_comments
  add column if not exists edited_at timestamptz;

create or replace function public.portfolio_comments_guard_edit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.id := old.id;
  new.portfolio_id := old.portfolio_id;
  new.user_id := old.user_id;
  new.created_at := old.created_at;
  -- Сайт и приложение режут комментарий до 1000 символов — держим так же.
  new.text := substring(btrim(new.text) from 1 for 1000);
  if new.text is null or new.text = '' then
    raise exception 'comment text is empty' using errcode = '22023';
  end if;
  if new.text is distinct from old.text then
    new.edited_at := now();
  else
    new.edited_at := old.edited_at;
  end if;
  return new;
end;
$$;

drop trigger if exists portfolio_comments_guard_edit on public.portfolio_comments;
create trigger portfolio_comments_guard_edit
  before update on public.portfolio_comments
  for each row execute function public.portfolio_comments_guard_edit();

drop policy if exists "owner_update_comment" on public.portfolio_comments;
create policy "owner_update_comment"
  on public.portfolio_comments for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
