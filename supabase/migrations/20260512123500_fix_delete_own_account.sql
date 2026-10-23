-- Harden account deletion for App Store Guideline 5.1.1(v).
-- Handles optional tables/columns and uuid/text owner id variants.

create or replace function public.x5_delete_eq_if_exists(
  p_table_name text,
  p_column_name text,
  p_owner_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  col_type text;
begin
  select c.udt_name
    into col_type
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = p_table_name
    and c.column_name = p_column_name;

  if col_type is null then
    return;
  end if;

  if col_type = 'uuid' then
    execute format('delete from public.%I where %I = $1', p_table_name, p_column_name)
      using p_owner_id;
  else
    execute format('delete from public.%I where %I = $1', p_table_name, p_column_name)
      using p_owner_id::text;
  end if;
exception
  when undefined_table or undefined_column or undefined_function
    or datatype_mismatch or invalid_text_representation
    or foreign_key_violation then
      return;
end;
$$;

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  perform public.x5_delete_eq_if_exists('messages', 'sender_id', uid);
  perform public.x5_delete_eq_if_exists('task_responses', 'specialist_id', uid);
  perform public.x5_delete_eq_if_exists('task_responses', 'client_id', uid);
  perform public.x5_delete_eq_if_exists('tasks', 'author_id', uid);
  perform public.x5_delete_eq_if_exists('portfolio_items', 'user_id', uid);
  perform public.x5_delete_eq_if_exists('specialists', 'user_id', uid);
  perform public.x5_delete_eq_if_exists('push_tokens', 'user_id', uid);
  perform public.x5_delete_eq_if_exists('notification_queue', 'to_user_id', uid);
  perform public.x5_delete_eq_if_exists('notification_queue', 'user_id', uid);
  perform public.x5_delete_eq_if_exists('course_submissions', 'authorId', uid);
  perform public.x5_delete_eq_if_exists('courses', 'author_id', uid);
  perform public.x5_delete_eq_if_exists('courses', 'user_id', uid);

  begin
    delete from public.followers
    where follower_id = uid or following_id = uid;
  exception
    when undefined_table or undefined_column or undefined_function
      or datatype_mismatch or invalid_text_representation
      or foreign_key_violation then null;
  end;

  begin
    delete from public.chats
    where uid = any(participants);
  exception
    when undefined_table or undefined_column or undefined_function
      or datatype_mismatch or invalid_text_representation
      or foreign_key_violation then
        begin
          delete from public.chats
          where uid::text = any(participants);
        exception
          when undefined_table or undefined_column or undefined_function
            or datatype_mismatch or invalid_text_representation
            or foreign_key_violation then null;
        end;
  end;

  perform public.x5_delete_eq_if_exists('profiles', 'id', uid);

  delete from auth.users where id = uid;
end;
$$;

grant execute on function public.delete_own_account() to authenticated;
