-- «Голос спит»: у ElevenLabs на тарифе только 10 мест под голоса аккаунта.
-- Запись голоса хранится в X5 (bucket voice-samples), а сам клон у
-- ElevenLabs живёт только пока нужен: давно не использованный голос
-- «засыпает» (удаляем у провайдера, место свободно), при озвучке —
-- «просыпается» (заново создаём клон из сохранённой записи).
--
-- provider_voice_id остаётся постоянным id голоса для приложения
-- (список, выбор, удаление — без изменений в iOS/вебе).
-- Текущий id у ElevenLabs = coalesce(live_voice_id, provider_voice_id),
-- пока asleep = false. Спит — у провайдера голоса нет.
-- Откат: supabase/rollback/20261105_voice_sleep_rollback.sql

alter table public.user_voices
  add column if not exists live_voice_id text,
  add column if not exists asleep boolean not null default false,
  add column if not exists sample_path text,
  add column if not exists last_used_at timestamptz;

alter table public.user_voices
  add constraint user_voices_live_voice_id_valid check (
    live_voice_id is null or live_voice_id ~ '^[A-Za-z0-9]{8,40}$'
  ),
  add constraint user_voices_sample_path_valid check (
    sample_path is null or sample_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9]{8,40}\.(mp3|m4a|wav|webm|ogg)$'
  ),
  -- спящий голос без записи не разбудить — такого состояния не бывает
  add constraint user_voices_asleep_has_sample check (
    not asleep or sample_path is not null
  );

create index if not exists user_voices_awake_lru_idx
  on public.user_voices ((coalesce(last_used_at, created_at)))
  where not asleep;

insert into storage.buckets (id, name, public, file_size_limit)
values ('voice-samples', 'voice-samples', false, 10485760)
on conflict (id) do nothing;

-- Голос владельца для озвучки/удаления: ключ — постоянный id.
create or replace function public.user_voice_state(
  p_user_id uuid,
  p_provider_voice_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v public.user_voices%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select * into v
    from public.user_voices as voice
   where voice.user_id = p_user_id
     and voice.provider_voice_id = p_provider_voice_id;
  if not found then
    return jsonb_build_object('owned', false);
  end if;
  return jsonb_build_object(
    'owned', true,
    'id', v.provider_voice_id,
    'name', v.name,
    'asleep', v.asleep,
    'live_voice_id', case when v.asleep then null
      else coalesce(v.live_voice_id, v.provider_voice_id) end,
    'sample_path', v.sample_path
  );
end;
$function$;

-- Отметка «голос используется сейчас»: его не усыпят ближайшие минуты.
create or replace function public.touch_user_voice(p_provider_voice_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  update public.user_voices
     set last_used_at = now()
   where provider_voice_id = p_provider_voice_id;
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end;
$function$;

create or replace function public.set_user_voice_sample(
  p_provider_voice_id text,
  p_sample_path text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  update public.user_voices
     set sample_path = p_sample_path
   where provider_voice_id = p_provider_voice_id;
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end;
$function$;

-- Кого усыпить: давно не использованные бодрствующие голоса X5.
-- Чужие голоса аккаунта ElevenLabs (не из X5) сюда не попадают никогда.
create or replace function public.user_voice_sleep_candidates(
  p_exclude text default null,
  p_idle_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  return jsonb_build_object('voices', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.provider_voice_id,
      'user_id', c.user_id,
      'live_voice_id', coalesce(c.live_voice_id, c.provider_voice_id),
      'sample_path', c.sample_path
    ) order by coalesce(c.last_used_at, c.created_at))
      from (
        select voice.*
          from public.user_voices as voice
         where not voice.asleep
           and voice.provider_voice_id is distinct from p_exclude
           -- новый голос ещё не использовали: считаем от создания, чтобы
           -- только что сделанный клон не усыпили первым
           and coalesce(voice.last_used_at, voice.created_at)
             < now() - make_interval(secs => p_idle_seconds)
         order by coalesce(voice.last_used_at, voice.created_at)
         limit 5
      ) as c
  ), '[]'::jsonb));
end;
$function$;

-- Усыпить: только если голос всё ещё бодрствует с тем же id и давно
-- не использовался (иначе кто-то озвучивает им прямо сейчас).
create or replace function public.mark_user_voice_asleep(
  p_provider_voice_id text,
  p_live_voice_id text,
  p_idle_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  update public.user_voices
     set asleep = true,
         live_voice_id = null
   where provider_voice_id = p_provider_voice_id
     and not asleep
     and sample_path is not null
     and coalesce(live_voice_id, provider_voice_id) = p_live_voice_id
     and coalesce(last_used_at, created_at)
       < now() - make_interval(secs => p_idle_seconds);
  return jsonb_build_object('status', case when found then 'asleep' else 'skipped' end);
end;
$function$;

-- Разбудить: ставим новый id только если голос ещё спит. Два параллельных
-- пробуждения — второй получит 'already_awake' и удалит свой лишний клон.
create or replace function public.mark_user_voice_awake(
  p_provider_voice_id text,
  p_live_voice_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_live text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_live_voice_id !~ '^[A-Za-z0-9]{8,40}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  update public.user_voices
     set asleep = false,
         live_voice_id = p_live_voice_id,
         last_used_at = now()
   where provider_voice_id = p_provider_voice_id
     and asleep;
  if found then
    return jsonb_build_object('status', 'awake', 'live_voice_id', p_live_voice_id);
  end if;
  select case when voice.asleep then null
    else coalesce(voice.live_voice_id, voice.provider_voice_id) end
    into v_live
    from public.user_voices as voice
   where voice.provider_voice_id = p_provider_voice_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object('status', 'already_awake', 'live_voice_id', v_live);
end;
$function$;

revoke execute on function public.user_voice_state(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.touch_user_voice(text)
  from public, anon, authenticated;
revoke execute on function public.set_user_voice_sample(text, text)
  from public, anon, authenticated;
revoke execute on function public.user_voice_sleep_candidates(text, integer)
  from public, anon, authenticated;
revoke execute on function public.mark_user_voice_asleep(text, text, integer)
  from public, anon, authenticated;
revoke execute on function public.mark_user_voice_awake(text, text)
  from public, anon, authenticated;

grant execute on function public.user_voice_state(uuid, text) to service_role;
grant execute on function public.touch_user_voice(text) to service_role;
grant execute on function public.set_user_voice_sample(text, text) to service_role;
grant execute on function public.user_voice_sleep_candidates(text, integer) to service_role;
grant execute on function public.mark_user_voice_asleep(text, text, integer) to service_role;
grant execute on function public.mark_user_voice_awake(text, text) to service_role;
