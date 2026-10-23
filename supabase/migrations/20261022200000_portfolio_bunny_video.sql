-- Видео портфолио — в Bunny Stream, не в Supabase Storage (Диас 22.10, tg 8616:
-- «любое видео — через Bunny»). Supabase хранит только данные: какой Bunny-ролик
-- чей. В portfolio_items.media_url для таких видео пишется `bunny-stream:<video_id>`.
-- Таблица — только для сервера (edge-функции под service_role), клиентам закрыта.

create table if not exists public.portfolio_video_assets (
  video_id uuid primary key,
  library_id text not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  upload_key text not null,
  request_fingerprint text not null,
  status text not null default 'uploading'
    check (status in ('uploading', 'deleted')),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, upload_key)
);

create index if not exists portfolio_video_assets_user_created_idx
  on public.portfolio_video_assets (user_id, created_at desc);

alter table public.portfolio_video_assets enable row level security;
revoke all on public.portfolio_video_assets from anon, authenticated;

-- Слот загрузки: повтор с тем же upload_key возвращает тот же ролик (TUS докачка),
-- лимит — 20 новых видео в час на человека.
create or replace function public.portfolio_video_claim_upload(
  p_user_id uuid,
  p_upload_key text,
  p_request_fingerprint text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.portfolio_video_assets%rowtype;
  recent integer;
begin
  if p_user_id is null or p_upload_key is null
     or p_upload_key !~ '^[A-Za-z0-9_-]{16,128}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select * into existing
  from public.portfolio_video_assets
  where user_id = p_user_id and upload_key = p_upload_key;

  if found then
    if existing.request_fingerprint <> p_request_fingerprint then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if existing.status = 'deleted' then
      return jsonb_build_object('status', 'expired');
    end if;
    return jsonb_build_object(
      'status', 'replay',
      'video_id', existing.video_id,
      'library_id', existing.library_id
    );
  end if;

  select count(*) into recent
  from public.portfolio_video_assets
  where user_id = p_user_id and created_at > now() - interval '1 hour';
  if recent >= 20 then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  return jsonb_build_object('status', 'claimed');
end;
$$;

create or replace function public.portfolio_video_record_upload(
  p_user_id uuid,
  p_upload_key text,
  p_request_fingerprint text,
  p_video_id uuid,
  p_library_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.portfolio_video_assets (
    video_id, library_id, user_id, upload_key, request_fingerprint
  ) values (
    p_video_id, p_library_id, p_user_id, p_upload_key, p_request_fingerprint
  )
  on conflict (user_id, upload_key) do nothing;

  if exists (
    select 1 from public.portfolio_video_assets
    where user_id = p_user_id and upload_key = p_upload_key
      and video_id = p_video_id
  ) then
    return jsonb_build_object('status', 'recorded');
  end if;
  return jsonb_build_object('status', 'conflict');
end;
$$;

-- Кто владелец Bunny-ролика (для автопроверки и показа).
create or replace function public.portfolio_video_owner(p_video_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object(
       'status', case when status = 'deleted' then 'deleted' else 'found' end,
       'user_id', user_id,
       'library_id', library_id)
     from public.portfolio_video_assets where video_id = p_video_id),
    jsonb_build_object('status', 'not_found')
  );
$$;

-- Показ: видно всем, если кейс одобрен; владельцу — всегда.
create or replace function public.portfolio_video_playback_grant(
  p_item_id uuid,
  p_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item public.portfolio_items%rowtype;
  asset public.portfolio_video_assets%rowtype;
  video_text text;
begin
  select * into item from public.portfolio_items where id = p_item_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if item.moderation_status <> 'approved'
     and (p_user_id is null or p_user_id <> item.user_id) then
    return jsonb_build_object('status', 'not_found');
  end if;
  if item.type <> 'video' or coalesce(item.media_url, '') !~
     '^bunny-stream:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('status', 'not_bunny');
  end if;
  video_text := substring(item.media_url from 14);
  select * into asset from public.portfolio_video_assets
  where video_id = video_text::uuid;
  if not found or asset.user_id <> item.user_id or asset.status = 'deleted' then
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object(
    'status', 'granted',
    'video_id', asset.video_id,
    'library_id', asset.library_id
  );
end;
$$;

create or replace function public.portfolio_video_mark_deleted(p_video_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.portfolio_video_assets
  set status = 'deleted', deleted_at = now()
  where video_id = p_video_id
  returning jsonb_build_object('status', 'deleted');
$$;

revoke all on function public.portfolio_video_claim_upload(uuid, text, text) from public, anon, authenticated;
revoke all on function public.portfolio_video_record_upload(uuid, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.portfolio_video_owner(uuid) from public, anon, authenticated;
revoke all on function public.portfolio_video_playback_grant(uuid, uuid) from public, anon, authenticated;
revoke all on function public.portfolio_video_mark_deleted(uuid) from public, anon, authenticated;
grant execute on function public.portfolio_video_claim_upload(uuid, text, text) to service_role;
grant execute on function public.portfolio_video_record_upload(uuid, text, text, uuid, text) to service_role;
grant execute on function public.portfolio_video_owner(uuid) to service_role;
grant execute on function public.portfolio_video_playback_grant(uuid, uuid) to service_role;
grant execute on function public.portfolio_video_mark_deleted(uuid) to service_role;
