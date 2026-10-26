-- Премиум-озвучка: «Мои голоса» (клон ElevenLabs IVC и голос по описанию)
-- и списание кредитов за них.
--
-- Экономика прежняя: кредиты из profiles.credits, как у озвучки. Списываем
-- ТОЛЬКО после успеха у провайдера одним атомарным вызовом
-- voice_studio_charge: не хватило кредитов или места — ничего не списано,
-- сервер сразу удаляет созданный у провайдера голос. Поэтому возвратов
-- (refund) здесь нет вообще.
--
-- Цены (сервер, voice-studio/contract.mjs): клон 300, дизайн 50 за набор из
-- 3 превью, сохранение превью 0, удаление 0. Лимит — 3 своих голоса.
-- Сам аудио-образец не храним — только provider_voice_id.

create table public.user_voices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  provider text not null default 'elevenlabs',
  provider_voice_id text not null,
  name text not null,
  source text not null,
  created_at timestamptz not null default now(),
  constraint user_voices_provider_valid check (provider = 'elevenlabs'),
  constraint user_voices_provider_voice_id_valid check (
    provider_voice_id ~ '^[A-Za-z0-9]{8,40}$'
  ),
  constraint user_voices_name_valid check (
    char_length(btrim(name)) between 1 and 40
  ),
  constraint user_voices_source_valid check (source in ('clone', 'design')),
  constraint user_voices_provider_voice_unique unique (provider, provider_voice_id)
);

create index user_voices_user_idx on public.user_voices (user_id, created_at);

comment on table public.user_voices is
  'Own premium voices (ElevenLabs IVC / Voice Design). Only voice IDs, never audio samples.';

alter table public.user_voices enable row level security;
alter table public.user_voices force row level security;
revoke all on table public.user_voices from public, anon, authenticated;
grant select on table public.user_voices to authenticated;
grant all on table public.user_voices to service_role;

create policy user_voices_owner_select
on public.user_voices
for select
to authenticated
using (user_id = auth.uid());

create table public.voice_studio_operations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  request_key text not null,
  kind text not null,
  cost_credits integer not null,
  credits_after_debit integer,
  provider_voice_id text,
  created_at timestamptz not null default now(),
  constraint voice_studio_operations_user_key_unique unique (user_id, request_key),
  constraint voice_studio_operations_key_valid check (
    request_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  ),
  constraint voice_studio_operations_kind_valid check (
    kind in ('clone', 'design', 'save')
  ),
  constraint voice_studio_operations_cost_valid check (
    (kind = 'clone' and cost_credits = 300)
    or (kind = 'design' and cost_credits = 50)
    or (kind = 'save' and cost_credits = 0)
  )
);

comment on table public.voice_studio_operations is
  'Exact-once debit ledger for voice cloning and voice design (charged after provider success).';

alter table public.voice_studio_operations enable row level security;
alter table public.voice_studio_operations force row level security;
revoke all on table public.voice_studio_operations
  from public, anon, authenticated;
grant all on table public.voice_studio_operations to service_role;

-- Быстрая проверка до вызова провайдера: хватает ли кредитов и места.
create or replace function public.voice_studio_quote(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_credits integer;
  v_voices integer;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select coalesce(profile.credits, 0)
    into v_credits
    from public.profiles as profile
   where profile.id = p_user_id;
  if not found then
    return jsonb_build_object('status', 'profile_not_found');
  end if;
  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  select count(*)::integer
    into v_voices
    from public.user_voices as voice
   where voice.user_id = p_user_id;
  return jsonb_build_object(
    'status', 'ok',
    'credits', v_credits,
    'voice_count', v_voices,
    'voice_limit', 3
  );
end;
$function$;

-- Атомарно: проверка лимита и баланса, списание, запись голоса.
create or replace function public.voice_studio_charge(
  p_user_id uuid,
  p_request_key text,
  p_kind text,
  p_cost_credits integer,
  p_provider_voice_id text default null,
  p_voice_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_credits integer;
  v_voices integer;
  v_existing public.voice_studio_operations%rowtype;
  v_request_key text := lower(btrim(coalesce(p_request_key, '')));
  v_voice_id text := nullif(btrim(coalesce(p_provider_voice_id, '')), '');
  v_name text := left(btrim(coalesce(p_voice_name, '')), 40);
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_user_id is null
     or v_request_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     or p_kind is null
     or not (
       (p_kind = 'clone' and p_cost_credits = 300)
       or (p_kind = 'design' and p_cost_credits = 50)
       or (p_kind = 'save' and p_cost_credits = 0)
     )
     or (p_kind in ('clone', 'save') and (
       v_voice_id is null
       or v_voice_id !~ '^[A-Za-z0-9]{8,40}$'
       or char_length(v_name) < 1
     )) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  -- Лочим профиль: параллельные клоны не обойдут лимит и баланс.
  select coalesce(profile.credits, 0)
    into v_credits
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    return jsonb_build_object('status', 'profile_not_found');
  end if;

  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;

  select operation.*
    into v_existing
    from public.voice_studio_operations as operation
   where operation.user_id = p_user_id
     and operation.request_key = v_request_key;
  if found then
    -- Тот же request_id второй раз не списывает и не создаёт.
    return jsonb_build_object(
      'status', 'duplicate',
      'kind', v_existing.kind,
      'provider_voice_id', v_existing.provider_voice_id,
      'credits_remaining', v_credits
    );
  end if;

  if p_kind in ('clone', 'save') then
    select count(*)::integer
      into v_voices
      from public.user_voices as voice
     where voice.user_id = p_user_id;
    if v_voices >= 3 then
      return jsonb_build_object(
        'status', 'voice_limit',
        'voice_limit', 3,
        'credits_remaining', v_credits
      );
    end if;
  end if;

  if v_credits < p_cost_credits then
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'credits_remaining', v_credits
    );
  end if;

  if p_cost_credits > 0 then
    update public.profiles as profile
       set credits = coalesce(profile.credits, 0) - p_cost_credits
     where profile.id = p_user_id
    returning profile.credits into v_credits;
  end if;

  insert into public.voice_studio_operations (
    user_id, request_key, kind, cost_credits, credits_after_debit,
    provider_voice_id
  ) values (
    p_user_id, v_request_key, p_kind, p_cost_credits, v_credits, v_voice_id
  );

  if p_kind in ('clone', 'save') then
    insert into public.user_voices (
      user_id, provider_voice_id, name, source
    ) values (
      p_user_id,
      v_voice_id,
      v_name,
      case when p_kind = 'clone' then 'clone' else 'design' end
    );
  end if;

  return jsonb_build_object(
    'status', 'charged',
    'credits_remaining', v_credits
  );
end;
$function$;

create or replace function public.list_user_voices(p_user_id uuid)
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
  return jsonb_build_object(
    'status', 'ok',
    'voices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', voice.provider_voice_id,
        'name', voice.name,
        'source', voice.source,
        'created_at', voice.created_at
      ) order by voice.created_at)
        from public.user_voices as voice
       where voice.user_id = p_user_id
    ), '[]'::jsonb)
  );
end;
$function$;

create or replace function public.user_voice_owned(
  p_user_id uuid,
  p_provider_voice_id text
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
  return jsonb_build_object(
    'owned', exists (
      select 1
        from public.user_voices as voice
       where voice.user_id = p_user_id
         and voice.provider_voice_id = p_provider_voice_id
    )
  );
end;
$function$;

-- Удаление бесплатное. Строку убираем после того, как провайдер удалил
-- голос (или ответил 404) — это делает функция voice-studio.
create or replace function public.delete_user_voice(
  p_user_id uuid,
  p_provider_voice_id text
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
  delete from public.user_voices as voice
   where voice.user_id = p_user_id
     and voice.provider_voice_id = p_provider_voice_id;
  return jsonb_build_object('status', case when found then 'deleted' else 'not_found' end);
end;
$function$;

revoke execute on function public.voice_studio_quote(uuid)
  from public, anon, authenticated;
revoke execute on function public.voice_studio_charge(
  uuid, text, text, integer, text, text
) from public, anon, authenticated;
revoke execute on function public.list_user_voices(uuid)
  from public, anon, authenticated;
revoke execute on function public.user_voice_owned(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.delete_user_voice(uuid, text)
  from public, anon, authenticated;

grant execute on function public.voice_studio_quote(uuid) to service_role;
grant execute on function public.voice_studio_charge(
  uuid, text, text, integer, text, text
) to service_role;
grant execute on function public.list_user_voices(uuid) to service_role;
grant execute on function public.user_voice_owned(uuid, text) to service_role;
grant execute on function public.delete_user_voice(uuid, text) to service_role;
