-- Защищённый перенос старых уроков из открытого бакета `videos` в Bunny Stream
-- (Edge Function course-video-legacy-import, запуск ТОЛЬКО оператором).
--
-- Зачем: у старых уроков videoUrl = открытый mp4 в Supabase Storage, а
-- courses читается всеми — любой скачивает платный ролик без покупки.
-- Mirror-режим (20261002140000) подменял videoUrl на открытый m3u8; с токенами
-- Bunny он не годится. Здесь урок становится обычным Bunny-уроком
-- (videoProvider/bunnyVideoId/videoStatus, БЕЗ videoUrl), и видео выдаёт только
-- course-video-playback после проверки покупки (course_video_playback_grant).
--
-- Конвейер (по одному курсу, course_id обязателен):
--   queued -> fetching (Bunny тянет файл по открытому URL)
--   -> processing (строка course_video_assets source='migration'; ready ставят
--      webhook / reconcile / сама функция через course_video_record_provider_status)
--   -> swapped (asset ready + подписанный HLS проверен -> урок атомарно
--      переключён на Bunny, videoUrl убран)
--   -> original_archived / original_deleted (ОТДЕЛЬНАЯ явная команда)
-- Пока не swapped — урок играет по-старому, ничего не меняется.
-- Повторный запуск безопасен: задача уникальна по (course, lesson, source_url).

begin;

-- Приватный бакет для оригиналов: безопаснее, чем удалять сразу
-- (можно вернуть файл при откате). Политик нет — читает только service_role.
insert into storage.buckets (id, name, public, file_size_limit)
values ('course-video-originals', 'course-video-originals', false, 5368709120)
on conflict (id) do nothing;

create table if not exists public.course_video_legacy_import_jobs (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null,
  lesson_id text not null,
  source_url text not null,
  storage_path text not null,
  status text not null default 'queued'
    check (status in (
      'queued', 'fetching', 'processing', 'swapped',
      'original_archived', 'original_deleted',
      'failed', 'superseded', 'rolled_back'
    )),
  bunny_video_id uuid,
  source_bytes bigint,
  attempts integer not null default 0,
  last_error text,
  lease_until timestamptz,
  fetch_requested_at timestamptz,
  swapped_at timestamptz,
  original_removed_at timestamptz,
  archive_path text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (course_id, lesson_id, source_url)
);

create index if not exists course_video_legacy_import_jobs_course_idx
  on public.course_video_legacy_import_jobs (course_id, status);

alter table public.course_video_legacy_import_jobs enable row level security;
revoke all on table public.course_video_legacy_import_jobs
  from public, anon, authenticated;
grant select, insert, update on table public.course_video_legacy_import_jobs
  to service_role;

-- Ставит в очередь уроки ОДНОГО курса с videoUrl в открытом бакете.
-- Кандидатов берём из уже существующей course_video_mirror_candidates.
-- p_retry_failed: вернуть упавшие задачи этого курса в очередь (новая попытка).
create or replace function public.course_video_legacy_import_enqueue(
  p_course_id uuid,
  p_retry_failed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_retried integer := 0;
  v_enqueued integer;
begin
  if p_course_id is null then
    -- По умолчанию ничего не делаем: курс выбирает оператор.
    raise exception using errcode = '22023', message = 'course_id_required';
  end if;

  if coalesce(p_retry_failed, false) then
    update public.course_video_legacy_import_jobs as job
       set status = 'queued', bunny_video_id = null, fetch_requested_at = null,
           lease_until = null, last_error = 'retry: ' || coalesce(job.last_error, ''),
           updated_at = clock_timestamp()
     where job.course_id = p_course_id
       and job.status = 'failed'
       -- урок всё ещё на том же открытом файле
       and exists (
         select 1 from public.course_video_mirror_candidates(p_course_id) cand
          where cand.lesson_id = job.lesson_id
            and cand.source_url = job.source_url
       );
    get diagnostics v_retried = row_count;
  end if;

  insert into public.course_video_legacy_import_jobs (
    course_id, lesson_id, source_url, storage_path
  )
  select cand.course_id, cand.lesson_id, cand.source_url, cand.storage_path
    from public.course_video_mirror_candidates(p_course_id) as cand
  on conflict (course_id, lesson_id, source_url) do nothing;
  get diagnostics v_enqueued = row_count;

  return jsonb_build_object('enqueued', v_enqueued, 'retried', v_retried);
end;
$$;

-- Берёт в работу задачи курса (аренда 5 минут, как в mirror), без swapped:
-- удаление оригиналов — отдельная команда.
create or replace function public.course_video_legacy_import_claim(
  p_course_id uuid,
  p_limit integer default 10
)
returns setof public.course_video_legacy_import_jobs
language sql
security definer
set search_path = ''
as $$
  update public.course_video_legacy_import_jobs as job
     set lease_until = clock_timestamp() + interval '5 minutes',
         updated_at = clock_timestamp()
   where job.id in (
     select candidate.id
       from public.course_video_legacy_import_jobs as candidate
      where candidate.course_id = p_course_id
        and candidate.status in ('queued', 'fetching', 'processing')
        and (candidate.lease_until is null
             or candidate.lease_until < clock_timestamp())
      order by candidate.created_at
      limit greatest(1, least(coalesce(p_limit, 10), 50))
      for update skip locked
   )
  returning job.*;
$$;

-- Промежуточные статусы. swapped/original_* ставят только swap/mark_removed.
create or replace function public.course_video_legacy_import_set(
  p_job_id uuid,
  p_status text,
  p_source_bytes bigint default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('queued', 'fetching', 'processing', 'failed') then
    raise exception using errcode = '22023', message = 'invalid_status';
  end if;
  update public.course_video_legacy_import_jobs
     set status = p_status,
         source_bytes = coalesce(p_source_bytes, source_bytes),
         last_error = case when p_error is null then last_error
                           else left(p_error, 500) end,
         attempts = attempts + case when p_error is null then 0 else 1 end,
         fetch_requested_at = case when p_status = 'fetching'
                                   then coalesce(fetch_requested_at, clock_timestamp())
                                   else fetch_requested_at end,
         lease_until = null,
         updated_at = clock_timestamp()
   where id = p_job_id
     and status in ('queued', 'fetching', 'processing');
end;
$$;

-- Bunny создал видео: в одной транзакции пишем строку course_video_assets
-- (через существующую course_video_register_migrated) и переводим задачу
-- в processing. Чужая строка с тем же GUID -> задача failed.
create or replace function public.course_video_legacy_import_register(
  p_job_id uuid,
  p_video_id uuid,
  p_library_id text,
  p_source_bytes bigint default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.course_video_legacy_import_jobs%rowtype;
  v_result jsonb;
  v_asset public.course_video_assets%rowtype;
begin
  select * into v_job from public.course_video_legacy_import_jobs
   where id = p_job_id for update;
  if not found then
    return 'missing';
  end if;
  if v_job.status not in ('queued', 'fetching') then
    return 'wrong_state';
  end if;

  v_result := public.course_video_register_migrated(
    v_job.course_id, v_job.lesson_id, p_video_id, p_library_id,
    v_job.source_url, coalesce(p_source_bytes, v_job.source_bytes)
  );
  select * into v_asset from public.course_video_assets
   where bunny_video_id = p_video_id;
  if v_result ->> 'status' is distinct from 'registered'
     or not found
     or v_asset.course_id <> v_job.course_id
     or v_asset.lesson_id <> v_job.lesson_id then
    update public.course_video_legacy_import_jobs
       set status = 'failed', lease_until = null,
           last_error = 'asset register failed: ' || coalesce(v_result ->> 'status', 'null'),
           attempts = attempts + 1, updated_at = clock_timestamp()
     where id = p_job_id;
    return 'failed';
  end if;

  update public.course_video_legacy_import_jobs
     set status = 'processing', bunny_video_id = p_video_id,
         source_bytes = coalesce(p_source_bytes, source_bytes),
         lease_until = null, updated_at = clock_timestamp()
   where id = p_job_id;
  return 'processing';
end;
$$;

-- Главный шаг: asset ready -> урок атомарно становится Bunny-уроком,
-- videoUrl убирается (иначе открытая ссылка останется в JSON).
-- Ответ: swapped | already_swapped | not_ready | superseded | failed | missing.
create or replace function public.course_video_legacy_import_swap(
  p_job_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.course_video_legacy_import_jobs%rowtype;
  v_asset public.course_video_assets%rowtype;
  v_categories jsonb;
  v_lesson jsonb;
  v_result jsonb;
begin
  select * into v_job from public.course_video_legacy_import_jobs
   where id = p_job_id for update;
  if not found then
    return 'missing';
  end if;
  if v_job.status in ('swapped', 'original_archived', 'original_deleted') then
    return 'already_swapped';
  end if;
  if v_job.status <> 'processing' or v_job.bunny_video_id is null then
    return 'not_ready';
  end if;

  select * into v_asset from public.course_video_assets
   where bunny_video_id = v_job.bunny_video_id for update;
  if not found or v_asset.course_id <> v_job.course_id
     or v_asset.lesson_id <> v_job.lesson_id then
    update public.course_video_legacy_import_jobs
       set status = 'failed', lease_until = null,
           last_error = 'asset missing or mismatched', updated_at = clock_timestamp()
     where id = p_job_id;
    return 'failed';
  end if;
  if v_asset.status <> 'ready' then
    return 'not_ready';
  end if;

  -- Блокируем курс: редактор не перепишет JSON между проверкой и заменой.
  select c.categories into v_categories
    from public.courses as c where c.id = v_job.course_id for update;
  if not found then
    update public.course_video_legacy_import_jobs
       set status = 'superseded', lease_until = null,
           last_error = 'course deleted', updated_at = clock_timestamp()
     where id = p_job_id;
    return 'superseded';
  end if;

  v_lesson := public.x5_course_find_lesson(v_categories, v_job.lesson_id);
  if v_lesson is null
     or v_lesson ->> 'videoUrl' is distinct from v_job.source_url then
    -- Автор заменил/убрал видео (или урок задвоился): не трогаем урок.
    update public.course_video_legacy_import_jobs
       set status = 'superseded', lease_until = null,
           last_error = 'lesson video changed before swap',
           updated_at = clock_timestamp()
     where id = p_job_id;
    return 'superseded';
  end if;

  -- Переиспользуем существующую запись в урок (videoStatus = 'ready',
  -- т.к. asset ready; p_keep_legacy = false убирает videoUrl).
  v_result := public.course_video_attach_to_lesson(
    v_job.course_id, v_job.lesson_id, v_job.bunny_video_id, false
  );
  if v_result ->> 'status' is distinct from 'attached' then
    raise exception 'attach failed: %', coalesce(v_result ->> 'status', 'null');
  end if;

  update public.course_video_legacy_import_jobs
     set status = 'swapped', swapped_at = clock_timestamp(),
         lease_until = null, last_error = null, updated_at = clock_timestamp()
   where id = p_job_id;
  return 'swapped';
end;
$$;

-- Проверка перед удалением/переносом оригинала. Только в папке этого курса,
-- урок уже Bunny+ready без videoUrl, ни один курс больше не ссылается на файл,
-- прошло p_grace_minutes после swap.
create or replace function public.course_video_legacy_import_can_remove(
  p_job_id uuid,
  p_grace_minutes integer default 1440
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_job public.course_video_legacy_import_jobs%rowtype;
  v_asset public.course_video_assets%rowtype;
  v_lesson jsonb;
begin
  select * into v_job from public.course_video_legacy_import_jobs
   where id = p_job_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'missing');
  end if;
  if v_job.status <> 'swapped' then
    return jsonb_build_object('ok', false, 'reason', 'status_' || v_job.status);
  end if;
  if v_job.swapped_at is null
     or v_job.swapped_at > clock_timestamp()
        - make_interval(mins => greatest(0, coalesce(p_grace_minutes, 1440))) then
    return jsonb_build_object('ok', false, 'reason', 'grace_period');
  end if;
  if not starts_with(v_job.storage_path, 'courses/' || v_job.course_id::text || '/')
     or v_job.storage_path like '%..%' then
    return jsonb_build_object('ok', false, 'reason', 'unexpected_path');
  end if;

  select * into v_asset from public.course_video_assets
   where bunny_video_id = v_job.bunny_video_id;
  if not found or v_asset.status <> 'ready'
     or v_asset.course_id <> v_job.course_id
     or v_asset.lesson_id <> v_job.lesson_id then
    return jsonb_build_object('ok', false, 'reason', 'asset_not_ready');
  end if;

  select public.x5_course_find_lesson(c.categories, v_job.lesson_id)
    into v_lesson
    from public.courses as c where c.id = v_job.course_id;
  if v_lesson is null
     or v_lesson ->> 'videoProvider' is distinct from 'bunny'
     or v_lesson ->> 'bunnyVideoId' is distinct from v_job.bunny_video_id::text
     or v_lesson ->> 'videoStatus' is distinct from 'ready'
     or v_lesson ? 'videoUrl' then
    return jsonb_build_object('ok', false, 'reason', 'lesson_not_bunny');
  end if;

  -- Любое упоминание файла в любом курсе (обложки, копии уроков) -> не трогаем.
  if exists (
    select 1 from public.courses as c
     where strpos(c::text, v_job.storage_path) > 0
  ) then
    return jsonb_build_object('ok', false, 'reason', 'still_referenced');
  end if;

  return jsonb_build_object(
    'ok', true,
    'storage_path', v_job.storage_path,
    'bunny_video_id', v_job.bunny_video_id,
    'source_bytes', v_job.source_bytes
  );
end;
$$;

create or replace function public.course_video_legacy_import_mark_removed(
  p_job_id uuid,
  p_action text,
  p_archive_path text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_action not in ('archived', 'deleted') then
    raise exception using errcode = '22023', message = 'invalid_action';
  end if;
  update public.course_video_legacy_import_jobs
     set status = 'original_' || p_action,
         archive_path = case when p_action = 'archived' then p_archive_path
                             else archive_path end,
         original_removed_at = clock_timestamp(),
         lease_until = null, updated_at = clock_timestamp()
   where id = p_job_id and status = 'swapped';
  return case when found then 'original_' || p_action else 'not_swapped' end;
end;
$$;

-- Для оператора и dry-run: задачи курса без служебных полей аренды.
create or replace function public.course_video_legacy_import_status(
  p_course_id uuid
)
returns table (
  id uuid,
  lesson_id text,
  status text,
  bunny_video_id uuid,
  storage_path text,
  source_url text,
  source_bytes bigint,
  asset_status text,
  attempts integer,
  last_error text,
  swapped_at timestamptz,
  original_removed_at timestamptz,
  archive_path text,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select job.id, job.lesson_id, job.status, job.bunny_video_id,
         job.storage_path, job.source_url, job.source_bytes, asset.status,
         job.attempts, job.last_error, job.swapped_at,
         job.original_removed_at, job.archive_path, job.updated_at
    from public.course_video_legacy_import_jobs as job
    left join public.course_video_assets as asset
      on asset.bunny_video_id = job.bunny_video_id
   where job.course_id = p_course_id
   order by job.created_at;
$$;

-- Откат урока: вернуть videoUrl на оригинал и убрать Bunny-поля.
-- Только если оригинал снова лежит в открытом бакете (иначе урок сломается)
-- и урок всё ещё на нашем Bunny-видео. Asset станет «ничьим», reconcile
-- удалит его из Bunny через 7 дней.
create or replace function public.course_video_legacy_import_rollback(
  p_job_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.course_video_legacy_import_jobs%rowtype;
  v_categories jsonb;
  v_lesson jsonb;
begin
  select * into v_job from public.course_video_legacy_import_jobs
   where id = p_job_id for update;
  if not found then
    return 'missing';
  end if;
  if v_job.status in ('queued', 'fetching', 'processing', 'failed') then
    -- Урок ещё не менялся: просто останавливаем задачу.
    update public.course_video_legacy_import_jobs
       set status = 'rolled_back', lease_until = null,
           updated_at = clock_timestamp()
     where id = p_job_id;
    return 'stopped';
  end if;
  if v_job.status not in ('swapped', 'original_archived', 'original_deleted') then
    return 'nothing_to_rollback';
  end if;
  if not exists (
    select 1 from storage.objects as o
     where o.bucket_id = 'videos' and o.name = v_job.storage_path
  ) then
    return 'original_missing';
  end if;

  select c.categories into v_categories
    from public.courses as c where c.id = v_job.course_id for update;
  if not found then
    return 'course_missing';
  end if;
  v_lesson := public.x5_course_find_lesson(v_categories, v_job.lesson_id);
  if v_lesson is null
     or v_lesson ->> 'bunnyVideoId' is distinct from v_job.bunny_video_id::text then
    return 'lesson_changed';
  end if;

  update public.courses as c
     set categories = public.x5_course_lessons_patch(
           v_categories, 'id', v_job.lesson_id,
           jsonb_build_object('videoUrl', v_job.source_url),
           array['videoProvider', 'bunnyVideoId', 'videoStatus']
         )
   where c.id = v_job.course_id;

  update public.course_video_legacy_import_jobs
     set status = 'rolled_back', lease_until = null,
         updated_at = clock_timestamp()
   where id = p_job_id;
  return 'rolled_back';
end;
$$;

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.course_video_legacy_import_enqueue(uuid, boolean)',
    'public.course_video_legacy_import_claim(uuid, integer)',
    'public.course_video_legacy_import_set(uuid, text, bigint, text)',
    'public.course_video_legacy_import_register(uuid, uuid, text, bigint)',
    'public.course_video_legacy_import_swap(uuid)',
    'public.course_video_legacy_import_can_remove(uuid, integer)',
    'public.course_video_legacy_import_mark_removed(uuid, text, text)',
    'public.course_video_legacy_import_status(uuid)',
    'public.course_video_legacy_import_rollback(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to service_role', v_signature);
  end loop;
end;
$$;

commit;
