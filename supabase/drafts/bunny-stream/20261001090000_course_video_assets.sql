-- DRAFT — NOT APPLIED. Bunny Stream course-video ledger, server-only broker,
-- readiness state, entitlement-checked playback grant and cleanup queue.
--
-- Apply only by following docs/BUNNY-STREAM-HANDOFF.md (staging first).
-- Supersedes the quarantined prototype
-- migrations/20260726233000_course_video_upload_slots.sql (never applied to
-- production as of 2026-10-01); this file drops its objects if present.
--
-- Security model:
--   * No API-facing role (public/anon/authenticated) receives EXECUTE on any
--     function below or any privilege on the ledger table. Only service_role
--     (Edge Functions) may call them. User identity is passed explicitly by the
--     Edge Function after it verified the caller's JWT with Supabase Auth.
--   * The upload switch lives in public.app_feature_flags
--     (key = 'bunny_course_video_upload'), seeded disabled.

begin;

-- ---------------------------------------------------------------------------
-- 0. Remove the quarantined prototype (no-op when it was never applied).
-- ---------------------------------------------------------------------------
drop function if exists public.claim_course_video_upload_slot(
  text, text, text, text, uuid
);
drop function if exists public.complete_course_video_upload_slot(
  text, text, uuid, uuid
);
drop table if exists public.course_video_upload_slots;

-- ---------------------------------------------------------------------------
-- 1. Runtime flag (disabled). Clients read it; the claim RPC enforces it.
-- ---------------------------------------------------------------------------
insert into public.app_feature_flags (key, label, enabled, message, updated_at)
values (
  'bunny_course_video_upload',
  'Bunny Stream course video upload',
  false,
  null,
  now()
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- Same two accounts as public.is_x5_developer(), but for an explicit user id
-- (service_role calls have no auth.uid()).
create or replace function public.x5_is_developer_user(p_user_id uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    p_user_id in (
      'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
      'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
    ),
    false
  );
$$;

-- Returns p_categories with every lesson whose p_match_key equals
-- p_match_value rewritten as (lesson - p_remove_keys) || p_patch.
-- Order of categories/days/lessons and all unknown fields are preserved.
create or replace function public.x5_course_lessons_patch(
  p_categories jsonb,
  p_match_key text,
  p_match_value text,
  p_patch jsonb,
  p_remove_keys text[] default '{}'::text[]
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_categories) <> 'array' then p_categories
    else (
      select coalesce(jsonb_agg(
        case
          when jsonb_typeof(cat.value) = 'object'
           and jsonb_typeof(cat.value -> 'days') = 'array' then
            jsonb_set(cat.value, '{days}', (
              select coalesce(jsonb_agg(
                case
                  when jsonb_typeof(day.value) = 'object'
                   and jsonb_typeof(day.value -> 'lessons') = 'array' then
                    jsonb_set(day.value, '{lessons}', (
                      select coalesce(jsonb_agg(
                        case
                          when jsonb_typeof(lesson.value) = 'object'
                           and lesson.value ->> p_match_key = p_match_value
                            then (lesson.value
                                   - coalesce(p_remove_keys, '{}'::text[]))
                                 || coalesce(p_patch, '{}'::jsonb)
                          else lesson.value
                        end
                        order by lesson.ord
                      ), '[]'::jsonb)
                      from jsonb_array_elements(day.value -> 'lessons')
                           with ordinality as lesson(value, ord)
                    ))
                  else day.value
                end
                order by day.ord
              ), '[]'::jsonb)
              from jsonb_array_elements(cat.value -> 'days')
                   with ordinality as day(value, ord)
            ))
          else cat.value
        end
        order by cat.ord
      ), '[]'::jsonb)
      from jsonb_array_elements(p_categories) with ordinality as cat(value, ord)
    )
  end;
$$;

-- Finds exactly one lesson object by id inside courses.categories.
create or replace function public.x5_course_find_lesson(
  p_categories jsonb,
  p_lesson_id text
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with matches as (
    select lesson_item.value
      from jsonb_array_elements(
             case when jsonb_typeof(p_categories) = 'array'
                  then p_categories else '[]'::jsonb end
           ) as category_item(value)
      cross join lateral jsonb_array_elements(
             case when jsonb_typeof(category_item.value -> 'days') = 'array'
                  then category_item.value -> 'days' else '[]'::jsonb end
           ) as day_item(value)
      cross join lateral jsonb_array_elements(
             case when jsonb_typeof(day_item.value -> 'lessons') = 'array'
                  then day_item.value -> 'lessons' else '[]'::jsonb end
           ) as lesson_item(value)
     where lesson_item.value ->> 'id' = p_lesson_id
  )
  select case when (select count(*) from matches) = 1
              then (select value from matches)
              else null end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Ledger
-- ---------------------------------------------------------------------------
create table if not exists public.course_video_assets (
  id uuid primary key default gen_random_uuid(),
  -- Course is intentionally not a FK: when a course row is deleted the asset
  -- becomes unreferenced and the reconciler deletes it from Bunny.
  course_id uuid not null,
  lesson_id text not null
    check (lesson_id ~ '^[A-Za-z0-9._:-]+$' and char_length(lesson_id) <= 256),
  uploader_id uuid references auth.users(id) on delete set null,
  upload_key text not null
    check (upload_key ~ '^[A-Za-z0-9_-]{16,128}$'),
  request_fingerprint text not null
    check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  source text not null default 'upload'
    check (source in ('upload', 'migration')),
  status text not null default 'creating'
    check (status in (
      'creating',        -- slot claimed, Bunny object not yet confirmed
      'awaiting_upload', -- Bunny object exists, TUS upload signed
      'processing',      -- Bunny received bytes and is encoding
      'ready',           -- playable HLS
      'failed',          -- Bunny reported an encoding/upload error
      'abandoned',       -- claim never produced a Bunny object (operator check)
      'deleting',        -- reconciler is removing it from Bunny
      'deleted'
    )),
  lease_token uuid,
  lease_expires_at timestamptz,
  bunny_library_id text check (bunny_library_id ~ '^[1-9][0-9]*$'),
  bunny_video_id uuid unique,
  provider_status integer,
  encode_progress integer,
  length_seconds integer,
  available_resolutions text,
  width integer,
  height integer,
  thumbnail_file_name text
    check (thumbnail_file_name is null
           or thumbnail_file_name ~ '^[A-Za-z0-9._-]{1,128}$'),
  source_bytes bigint check (source_bytes is null or source_bytes > 0),
  legacy_video_url text,
  last_checked_at timestamptz,
  ready_at timestamptz,
  failed_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (uploader_id, upload_key),
  check (status in ('creating', 'abandoned') or bunny_video_id is not null)
);

create index if not exists course_video_assets_rate_idx
  on public.course_video_assets (uploader_id, created_at desc);
create index if not exists course_video_assets_course_idx
  on public.course_video_assets (course_id, lesson_id);
create index if not exists course_video_assets_reconcile_idx
  on public.course_video_assets (status, updated_at)
  where status not in ('deleted');

alter table public.course_video_assets enable row level security;
revoke all on table public.course_video_assets
  from public, anon, authenticated;
grant select, insert, update on table public.course_video_assets
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Upload broker RPCs (service_role only)
-- ---------------------------------------------------------------------------
create or replace function public.course_video_claim_upload(
  p_user_id uuid,
  p_course_id uuid,
  p_lesson_id text,
  p_upload_key text,
  p_request_fingerprint text,
  p_lease_token uuid,
  p_source_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.course_video_assets%rowtype;
  v_author_id uuid;
  v_is_developer boolean;
  v_recent_count integer;
  v_limit integer := 20;
begin
  if p_user_id is null then
    return jsonb_build_object('status', 'not_authenticated');
  end if;
  if p_course_id is null
     or coalesce(p_lesson_id, '') !~ '^[A-Za-z0-9._:-]+$'
     or char_length(p_lesson_id) > 256
     or coalesce(p_upload_key, '') !~ '^[A-Za-z0-9_-]{16,128}$'
     or coalesce(p_request_fingerprint, '') !~ '^[0-9a-f]{64}$'
     or p_lease_token is null
     or p_source_bytes is null or p_source_bytes <= 0 then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if not coalesce((
    select f.enabled from public.app_feature_flags as f
     where f.key = 'bunny_course_video_upload'
  ), false) then
    return jsonb_build_object('status', 'disabled');
  end if;

  v_is_developer := public.x5_is_developer_user(p_user_id);
  select c.author_id into v_author_id
    from public.courses as c where c.id = p_course_id;
  if not found then
    -- New, unsaved courses are created only by developers (courses RLS).
    if not v_is_developer then
      return jsonb_build_object('status', 'course_unavailable');
    end if;
  elsif not v_is_developer and v_author_id is distinct from p_user_id then
    return jsonb_build_object('status', 'not_authorized');
  end if;
  if v_is_developer then
    v_limit := 60;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('course_video:' || p_user_id::text, 0)
  );

  select * into v_existing
    from public.course_video_assets as a
   where a.uploader_id = p_user_id and a.upload_key = p_upload_key
   for update;

  if found then
    if v_existing.request_fingerprint <> p_request_fingerprint
       or v_existing.course_id <> p_course_id
       or v_existing.lesson_id <> p_lesson_id then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if v_existing.status in ('deleting', 'deleted', 'failed', 'abandoned') then
      return jsonb_build_object('status', 'expired');
    end if;
    if v_existing.bunny_video_id is not null then
      return jsonb_build_object(
        'status', 'replay',
        'video_id', v_existing.bunny_video_id,
        'asset_status', v_existing.status
      );
    end if;
    if v_existing.lease_expires_at > clock_timestamp() then
      return jsonb_build_object('status', 'in_progress');
    end if;
    update public.course_video_assets
       set lease_token = p_lease_token,
           lease_expires_at = clock_timestamp() + interval '10 minutes',
           updated_at = clock_timestamp()
     where id = v_existing.id;
    return jsonb_build_object('status', 'claimed', 'reclaimed', true);
  end if;

  select count(*) into v_recent_count
    from public.course_video_assets as a
   where a.uploader_id = p_user_id
     and a.created_at >= clock_timestamp() - interval '10 minutes';
  if v_recent_count >= v_limit then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  insert into public.course_video_assets (
    course_id, lesson_id, uploader_id, upload_key, request_fingerprint,
    status, lease_token, lease_expires_at, source_bytes
  ) values (
    p_course_id, p_lesson_id, p_user_id, p_upload_key, p_request_fingerprint,
    'creating', p_lease_token, clock_timestamp() + interval '10 minutes',
    p_source_bytes
  );
  return jsonb_build_object('status', 'claimed', 'reclaimed', false);
end;
$$;

create or replace function public.course_video_complete_upload(
  p_user_id uuid,
  p_upload_key text,
  p_request_fingerprint text,
  p_lease_token uuid,
  p_video_id uuid,
  p_library_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.course_video_assets%rowtype;
begin
  if p_user_id is null or p_video_id is null or p_lease_token is null
     or coalesce(p_library_id, '') !~ '^[1-9][0-9]*$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select * into v_existing
    from public.course_video_assets as a
   where a.uploader_id = p_user_id and a.upload_key = p_upload_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_existing.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if v_existing.bunny_video_id is not null then
    if v_existing.bunny_video_id = p_video_id then
      return jsonb_build_object(
        'status', 'already_completed', 'video_id', p_video_id
      );
    end if;
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if v_existing.lease_token is distinct from p_lease_token
     or v_existing.lease_expires_at <= clock_timestamp() then
    return jsonb_build_object('status', 'stale_lease');
  end if;

  update public.course_video_assets
     set status = 'awaiting_upload',
         bunny_video_id = p_video_id,
         bunny_library_id = p_library_id,
         lease_token = null,
         lease_expires_at = null,
         updated_at = clock_timestamp()
   where id = v_existing.id;
  return jsonb_build_object('status', 'completed', 'video_id', p_video_id);
end;
$$;

-- Migration script entry point: registers an already created Bunny object
-- for an existing lesson (source = 'migration').
create or replace function public.course_video_register_migrated(
  p_course_id uuid,
  p_lesson_id text,
  p_video_id uuid,
  p_library_id text,
  p_legacy_video_url text,
  p_source_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fingerprint text;
begin
  if p_course_id is null or p_video_id is null
     or coalesce(p_lesson_id, '') !~ '^[A-Za-z0-9._:-]+$'
     or char_length(p_lesson_id) > 256
     or coalesce(p_library_id, '') !~ '^[1-9][0-9]*$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  v_fingerprint := encode(
    sha256(convert_to(p_course_id::text || ':' || p_lesson_id || ':' ||
      coalesce(p_legacy_video_url, ''), 'UTF8')),
    'hex'
  );
  insert into public.course_video_assets (
    course_id, lesson_id, uploader_id, upload_key, request_fingerprint,
    source, status, bunny_library_id, bunny_video_id, legacy_video_url,
    source_bytes
  ) values (
    p_course_id, p_lesson_id, null,
    'migration_' || substr(v_fingerprint, 1, 48), v_fingerprint,
    'migration', 'awaiting_upload', p_library_id, p_video_id,
    p_legacy_video_url, p_source_bytes
  )
  on conflict (bunny_video_id) do nothing;
  return jsonb_build_object('status', 'registered', 'video_id', p_video_id);
end;
$$;

-- Writes the Bunny reference into the lesson JSON. When p_keep_legacy is
-- false the old videoUrl is removed (phase 2, after old app versions expire).
create or replace function public.course_video_attach_to_lesson(
  p_course_id uuid,
  p_lesson_id text,
  p_video_id uuid,
  p_keep_legacy boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_categories jsonb;
  v_lesson jsonb;
  v_asset public.course_video_assets%rowtype;
begin
  select * into v_asset from public.course_video_assets as a
   where a.bunny_video_id = p_video_id;
  if not found or v_asset.course_id <> p_course_id
     or v_asset.lesson_id <> p_lesson_id then
    return jsonb_build_object('status', 'asset_mismatch');
  end if;

  select c.categories into v_categories
    from public.courses as c where c.id = p_course_id for update;
  if not found then
    return jsonb_build_object('status', 'course_unavailable');
  end if;
  v_lesson := public.x5_course_find_lesson(v_categories, p_lesson_id);
  if v_lesson is null then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;

  update public.courses as c
     set categories = public.x5_course_lessons_patch(
           v_categories, 'id', p_lesson_id,
           jsonb_build_object(
             'videoProvider', 'bunny',
             'bunnyVideoId', p_video_id::text,
             'videoStatus', case when v_asset.status = 'ready'
                                 then 'ready' else 'processing' end
           ),
           case when p_keep_legacy then '{}'::text[]
                else array['videoUrl'] end
         )
   where c.id = p_course_id;
  return jsonb_build_object('status', 'attached', 'video_id', p_video_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Readiness (webhook / polling / reconcile) RPCs
-- ---------------------------------------------------------------------------
-- Bunny video object status: 0 created, 1 uploaded, 2 processing,
-- 3 transcoding, 4 finished, 5 error, 6 upload failed,
-- 7 JIT segmenting, 8 JIT playlists created.
create or replace function public.course_video_record_provider_status(
  p_video_id uuid,
  p_provider_status integer,
  p_encode_progress integer,
  p_length_seconds integer,
  p_available_resolutions text,
  p_thumbnail_file_name text,
  p_width integer,
  p_height integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset public.course_video_assets%rowtype;
  v_new_status text;
  v_lesson_status text;
begin
  select * into v_asset from public.course_video_assets as a
   where a.bunny_video_id = p_video_id for update;
  if not found then
    return jsonb_build_object('status', 'unknown_video');
  end if;
  if v_asset.status in ('deleting', 'deleted') then
    return jsonb_build_object('status', 'ignored', 'asset_status', v_asset.status);
  end if;

  v_new_status := case
    when p_provider_status in (4, 8) then 'ready'
    when p_provider_status in (5, 6) then 'failed'
    when p_provider_status in (1, 2, 3, 7) then 'processing'
    else v_asset.status -- 0: still waiting for bytes
  end;
  if v_new_status = 'creating' then
    v_new_status := 'awaiting_upload';
  end if;

  update public.course_video_assets
     set status = v_new_status,
         provider_status = p_provider_status,
         encode_progress = greatest(0, least(100, p_encode_progress)),
         length_seconds = nullif(greatest(coalesce(p_length_seconds, 0), 0), 0),
         available_resolutions = left(p_available_resolutions, 200),
         width = p_width,
         height = p_height,
         thumbnail_file_name = case
           when p_thumbnail_file_name ~ '^[A-Za-z0-9._-]{1,128}$'
             then p_thumbnail_file_name else thumbnail_file_name end,
         last_checked_at = clock_timestamp(),
         ready_at = case when v_new_status = 'ready'
                         then coalesce(ready_at, clock_timestamp()) else ready_at end,
         failed_at = case when v_new_status = 'failed'
                          then coalesce(failed_at, clock_timestamp()) else null end,
         updated_at = clock_timestamp()
   where id = v_asset.id;

  -- Mirror the state into the lesson JSON as a display hint. The ledger stays
  -- the source of truth for playback.
  if v_new_status is distinct from v_asset.status
     and v_new_status in ('ready', 'failed', 'processing') then
    v_lesson_status := v_new_status;
    update public.courses as c
       set categories = public.x5_course_lessons_patch(
             c.categories, 'bunnyVideoId', p_video_id::text,
             jsonb_build_object('videoStatus', v_lesson_status), '{}'::text[]
           )
     where c.id = v_asset.course_id
       and jsonb_path_exists(
             c.categories,
             '$[*].days[*].lessons[*] ? (@.bunnyVideoId == $id)',
             jsonb_build_object('id', p_video_id::text)
           );
  end if;

  return jsonb_build_object(
    'status', 'recorded',
    'asset_status', v_new_status,
    'course_id', v_asset.course_id,
    'lesson_id', v_asset.lesson_id
  );
end;
$$;

-- Polling by the uploader / course author / developer.
create or replace function public.course_video_owner_lookup(
  p_user_id uuid,
  p_video_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_asset public.course_video_assets%rowtype;
  v_author_id uuid;
begin
  select * into v_asset from public.course_video_assets as a
   where a.bunny_video_id = p_video_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  select c.author_id into v_author_id
    from public.courses as c where c.id = v_asset.course_id;
  if not coalesce(public.x5_is_developer_user(p_user_id)
          or v_asset.uploader_id = p_user_id
          or v_author_id = p_user_id, false) then
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object(
    'status', 'found',
    'asset_status', v_asset.status,
    'encode_progress', v_asset.encode_progress,
    'length_seconds', v_asset.length_seconds,
    'last_checked_at', v_asset.last_checked_at
  );
end;
$$;

-- Returns work for the reconciler: refresh stale in-flight assets and delete
-- abandoned / failed / unreferenced ones. Marks delete candidates 'deleting'.
create or replace function public.course_video_reconcile_batch(
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  v_refresh jsonb;
  v_delete jsonb;
  v_abandoned integer;
begin
  -- Claims that never produced a Bunny object: operator reconciliation via the
  -- Bunny dashboard title search ("X5 lesson <course> <lesson> <key>").
  update public.course_video_assets
     set status = 'abandoned', lease_token = null, lease_expires_at = null,
         updated_at = clock_timestamp()
   where status = 'creating'
     and bunny_video_id is null
     and created_at < clock_timestamp() - interval '1 hour';
  get diagnostics v_abandoned = row_count;

  with candidates as (
    select a.id
      from public.course_video_assets as a
     where (
             -- signed upload expired long ago, Bunny never got bytes
             (a.status = 'awaiting_upload'
              and coalesce(a.provider_status, 0) in (0, 6)
              and a.created_at < clock_timestamp() - interval '48 hours')
          or (a.status = 'failed'
              and coalesce(a.failed_at, a.updated_at)
                  < clock_timestamp() - interval '3 days')
          or (a.status = 'ready'
              and coalesce(a.ready_at, a.updated_at)
                  < clock_timestamp() - interval '7 days'
              and not exists (
                select 1 from public.courses as c
                 where c.id = a.course_id
                   and jsonb_path_exists(
                         c.categories,
                         '$[*].days[*].lessons[*] ? (@.bunnyVideoId == $id)',
                         jsonb_build_object('id', a.bunny_video_id::text)
                       )
              ))
          -- previous delete attempt did not finish
          or (a.status = 'deleting'
              and a.updated_at < clock_timestamp() - interval '30 minutes')
           )
     order by a.updated_at
     limit v_limit
     for update skip locked
  ), marked as (
    update public.course_video_assets as a
       set status = 'deleting', updated_at = clock_timestamp()
      from candidates
     where a.id = candidates.id
    returning a.bunny_video_id
  )
  select coalesce(jsonb_agg(bunny_video_id), '[]'::jsonb) into v_delete
    from marked;

  select coalesce(jsonb_agg(a.bunny_video_id), '[]'::jsonb) into v_refresh
    from (
      select a.bunny_video_id
        from public.course_video_assets as a
       where a.status in ('awaiting_upload', 'processing')
         and a.bunny_video_id is not null
         and coalesce(a.last_checked_at, a.created_at)
             < clock_timestamp() - interval '5 minutes'
       order by coalesce(a.last_checked_at, a.created_at)
       limit v_limit
    ) as a;

  return jsonb_build_object(
    'refresh', v_refresh,
    'delete', v_delete,
    'abandoned', v_abandoned
  );
end;
$$;

create or replace function public.course_video_mark_deleted(p_video_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.course_video_assets
     set status = 'deleted', deleted_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where bunny_video_id = p_video_id and status = 'deleting';
  return jsonb_build_object('status', case when found then 'deleted'
                                           else 'not_deleting' end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Playback entitlement grant (mirrors iOS CourseAccessPolicy + server
--    purchase_course / purchase_lesson semantics).
-- ---------------------------------------------------------------------------
create or replace function public.course_video_playback_grant(
  p_user_id uuid,
  p_course_id uuid,
  p_lesson_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_course public.courses%rowtype;
  v_lesson jsonb;
  v_video_id uuid;
  v_asset public.course_video_assets%rowtype;
  v_purchased_courses text[] := array[]::text[];
  v_purchased_lessons text[] := array[]::text[];
  v_privileged boolean := false;
  v_entitled boolean := false;
begin
  if p_course_id is null
     or coalesce(p_lesson_id, '') !~ '^[A-Za-z0-9._:-]+$'
     or char_length(p_lesson_id) > 256 then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;

  select * into v_course from public.courses as c where c.id = p_course_id;
  if not found then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;
  v_lesson := public.x5_course_find_lesson(v_course.categories, p_lesson_id);
  if v_lesson is null then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;
  if v_lesson ->> 'videoProvider' is distinct from 'bunny'
     or coalesce(v_lesson ->> 'bunnyVideoId', '') !~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('status', 'not_bunny_lesson');
  end if;
  v_video_id := (v_lesson ->> 'bunnyVideoId')::uuid;

  -- Every boolean is coalesced: a NULL here must never mean "allowed".
  v_privileged := coalesce(p_user_id is not null and (
    public.x5_is_developer_user(p_user_id)
    or v_course.author_id = p_user_id
  ), false);

  if v_privileged is not true then
    if p_user_id is not null then
      select coalesce(p.purchased_course_ids, array[]::text[]),
             coalesce(p.purchased_lesson_ids, array[]::text[])
        into v_purchased_courses, v_purchased_lessons
        from public.profiles as p where p.id = p_user_id;
    end if;
    v_entitled := coalesce(
      -- bought access survives the course being hidden later
      p_course_id::text = any(coalesce(v_purchased_courses, array[]::text[]))
      or (p_course_id::text || ':' || p_lesson_id)
         = any(coalesce(v_purchased_lessons, array[]::text[]))
      or (coalesce(v_course.is_public, false) and (
            coalesce(v_course.is_free, false)
            or coalesce(v_course.price, 0) <= 0
            or coalesce(v_lesson -> 'isFreePreview' = 'true'::jsonb, false)
         )),
      false
    );
    if v_entitled is not true then
      return jsonb_build_object(
        'status',
        case when p_user_id is null then 'not_authenticated'
             else 'not_entitled' end
      );
    end if;
  end if;

  select * into v_asset from public.course_video_assets as a
   where a.bunny_video_id = v_video_id;
  -- An editor cannot point a lesson at another course's video.
  if not found or v_asset.course_id <> p_course_id then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;

  return case v_asset.status
    when 'ready' then jsonb_build_object(
      'status', 'granted',
      'video_id', v_video_id,
      'length_seconds', v_asset.length_seconds,
      'thumbnail_file_name', v_asset.thumbnail_file_name
    )
    when 'failed' then jsonb_build_object('status', 'failed')
    when 'awaiting_upload' then jsonb_build_object('status', 'processing')
    when 'processing' then jsonb_build_object('status', 'processing')
    else jsonb_build_object('status', 'lesson_unavailable')
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Privileges: service_role only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.x5_is_developer_user(uuid)',
    'public.x5_course_lessons_patch(jsonb, text, text, jsonb, text[])',
    'public.x5_course_find_lesson(jsonb, text)',
    'public.course_video_claim_upload(uuid, uuid, text, text, text, uuid, bigint)',
    'public.course_video_complete_upload(uuid, text, text, uuid, uuid, text)',
    'public.course_video_register_migrated(uuid, text, uuid, text, text, bigint)',
    'public.course_video_attach_to_lesson(uuid, text, uuid, boolean)',
    'public.course_video_record_provider_status(uuid, integer, integer, integer, text, text, integer, integer)',
    'public.course_video_owner_lookup(uuid, uuid)',
    'public.course_video_reconcile_batch(integer)',
    'public.course_video_mark_deleted(uuid)',
    'public.course_video_playback_grant(uuid, uuid, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to service_role', v_signature);
  end loop;
end;
$$;

commit;
