-- Server-side "no-rebuild" Bunny mirror for course lesson videos.
--
-- Works with the already released apps: the lesson keeps a plain `videoUrl`,
-- which is switched from the public Supabase `videos` object to
-- https://<bunny cdn>/<guid>/playlist.m3u8. Released iOS (build 243) and web
-- already play any .m3u8 adaptively. Bunny pull-zone token auth must stay OFF
-- for this mode (same exposure as today's public Supabase URLs).
--
-- Pipeline (Edge Function course-video-bunny-mirror, pg_cron every 5 min):
--   queued -> fetching (Bunny fetch from the public URL) -> encoding
--   -> swapped (lesson videoUrl now m3u8, playlist + segment verified)
--   -> storage_deleted (after a grace period, re-verified, never on failure)
-- A job is unique per (course, lesson, source_url): nothing runs twice.

begin;

create table if not exists public.course_video_mirror_jobs (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null,
  lesson_id text not null,
  source_url text not null,
  storage_path text not null,
  status text not null default 'queued'
    check (status in (
      'queued', 'fetching', 'encoding', 'swapped', 'storage_deleted',
      'failed', 'superseded'
    )),
  bunny_video_id uuid,
  hls_url text,
  source_bytes bigint,
  attempts integer not null default 0,
  last_error text,
  lease_until timestamptz,
  fetch_requested_at timestamptz,
  swapped_at timestamptz,
  storage_deleted_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (course_id, lesson_id, source_url)
);

create index if not exists course_video_mirror_jobs_status_idx
  on public.course_video_mirror_jobs (status, updated_at);

alter table public.course_video_mirror_jobs enable row level security;
revoke all on table public.course_video_mirror_jobs
  from public, anon, authenticated;
grant select, insert, update on table public.course_video_mirror_jobs
  to service_role;

-- Lessons whose videoUrl is a public object in the `videos` bucket.
create or replace function public.course_video_mirror_candidates(
  p_course_id uuid default null
)
returns table (
  course_id uuid,
  course_title text,
  lesson_id text,
  source_url text,
  storage_path text
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         c.title,
         lesson.value ->> 'id',
         lesson.value ->> 'videoUrl',
         substr(
           lesson.value ->> 'videoUrl',
           char_length(
             'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/'
           ) + 1
         )
    from public.courses as c
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(c.categories) = 'array'
                then c.categories else '[]'::jsonb end) as cat(value)
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(cat.value -> 'days') = 'array'
                then cat.value -> 'days' else '[]'::jsonb end) as day(value)
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(day.value -> 'lessons') = 'array'
                then day.value -> 'lessons' else '[]'::jsonb end) as lesson(value)
   where (p_course_id is null or c.id = p_course_id)
     and lesson.value ->> 'id' is not null
     and starts_with(
           lesson.value ->> 'videoUrl',
           'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/'
         );
$$;

create or replace function public.course_video_mirror_enqueue(
  p_course_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into public.course_video_mirror_jobs (
    course_id, lesson_id, source_url, storage_path
  )
  select candidate.course_id, candidate.lesson_id, candidate.source_url,
         candidate.storage_path
    from public.course_video_mirror_candidates(p_course_id) as candidate
  on conflict (course_id, lesson_id, source_url) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Leases up to p_limit in-flight jobs (5 minute lease).
create or replace function public.course_video_mirror_claim(
  p_course_id uuid default null,
  p_limit integer default 10
)
returns setof public.course_video_mirror_jobs
language sql
security definer
set search_path = ''
as $$
  update public.course_video_mirror_jobs as job
     set lease_until = clock_timestamp() + interval '5 minutes',
         updated_at = clock_timestamp()
   where job.id in (
     select candidate.id
       from public.course_video_mirror_jobs as candidate
      where candidate.status in ('queued', 'fetching', 'encoding', 'swapped')
        and (p_course_id is null or candidate.course_id = p_course_id)
        and (candidate.lease_until is null
             or candidate.lease_until < clock_timestamp())
      order by candidate.created_at
      limit greatest(1, least(coalesce(p_limit, 10), 50))
      for update skip locked
   )
  returning job.*;
$$;

create or replace function public.course_video_mirror_set(
  p_job_id uuid,
  p_status text,
  p_bunny_video_id uuid default null,
  p_hls_url text default null,
  p_source_bytes bigint default null,
  p_error text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.course_video_mirror_jobs
     set status = p_status,
         bunny_video_id = coalesce(p_bunny_video_id, bunny_video_id),
         hls_url = coalesce(p_hls_url, hls_url),
         source_bytes = coalesce(p_source_bytes, source_bytes),
         last_error = case when p_error is null then last_error
                           else left(p_error, 500) end,
         attempts = attempts + case when p_error is null then 0 else 1 end,
         fetch_requested_at = case when p_status = 'fetching'
                                   then coalesce(fetch_requested_at, clock_timestamp())
                                   else fetch_requested_at end,
         storage_deleted_at = case when p_status = 'storage_deleted'
                                   then clock_timestamp() else storage_deleted_at end,
         lease_until = null,
         updated_at = clock_timestamp()
   where id = p_job_id
     and status not in ('storage_deleted', 'superseded');
$$;

-- Atomically switches the lesson videoUrl from source_url to the m3u8.
-- Returns 'swapped', 'already_swapped' or 'superseded' (lesson changed).
create or replace function public.course_video_mirror_swap(
  p_job_id uuid,
  p_hls_url text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.course_video_mirror_jobs%rowtype;
  v_categories jsonb;
  v_lesson jsonb;
begin
  if coalesce(p_hls_url, '') !~ '^https://[a-z0-9.-]+\.b-cdn\.net/[0-9a-f-]{36}/playlist\.m3u8$' then
    raise exception 'invalid hls url';
  end if;
  select * into v_job from public.course_video_mirror_jobs
   where id = p_job_id for update;
  if not found then
    return 'missing';
  end if;

  select c.categories into v_categories
    from public.courses as c where c.id = v_job.course_id for update;
  if not found then
    update public.course_video_mirror_jobs
       set status = 'superseded', lease_until = null,
           last_error = 'course deleted', updated_at = clock_timestamp()
     where id = p_job_id;
    return 'superseded';
  end if;

  select lesson.value into v_lesson
    from jsonb_array_elements(case when jsonb_typeof(v_categories) = 'array'
                                   then v_categories else '[]'::jsonb end) cat(value)
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(cat.value -> 'days') = 'array'
                then cat.value -> 'days' else '[]'::jsonb end) day(value)
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(day.value -> 'lessons') = 'array'
                then day.value -> 'lessons' else '[]'::jsonb end) lesson(value)
   where lesson.value ->> 'id' = v_job.lesson_id
   limit 1;

  if v_lesson ->> 'videoUrl' = p_hls_url then
    update public.course_video_mirror_jobs
       set status = 'swapped', hls_url = p_hls_url,
           swapped_at = coalesce(swapped_at, clock_timestamp()),
           lease_until = null, updated_at = clock_timestamp()
     where id = p_job_id;
    return 'already_swapped';
  end if;
  if v_lesson is null or v_lesson ->> 'videoUrl' is distinct from v_job.source_url then
    -- The author replaced or removed the video meanwhile: keep the object.
    update public.course_video_mirror_jobs
       set status = 'superseded', lease_until = null,
           last_error = 'lesson video changed before swap',
           updated_at = clock_timestamp()
     where id = p_job_id;
    return 'superseded';
  end if;

  update public.courses as c
     set categories = (
       select jsonb_agg(
         case when jsonb_typeof(cat.value -> 'days') = 'array' then
           jsonb_set(cat.value, '{days}', (
             select coalesce(jsonb_agg(
               case when jsonb_typeof(day.value -> 'lessons') = 'array' then
                 jsonb_set(day.value, '{lessons}', (
                   select coalesce(jsonb_agg(
                     case when lesson.value ->> 'id' = v_job.lesson_id
                           and lesson.value ->> 'videoUrl' = v_job.source_url
                          then jsonb_set(lesson.value, '{videoUrl}', to_jsonb(p_hls_url))
                          else lesson.value end
                     order by lesson.ord), '[]'::jsonb)
                   from jsonb_array_elements(day.value -> 'lessons')
                        with ordinality lesson(value, ord)))
               else day.value end
               order by day.ord), '[]'::jsonb)
             from jsonb_array_elements(cat.value -> 'days')
                  with ordinality day(value, ord)))
         else cat.value end
         order by cat.ord)
       from jsonb_array_elements(v_categories) with ordinality cat(value, ord)
     ),
     updated_at = now()
   where c.id = v_job.course_id;

  update public.course_video_mirror_jobs
     set status = 'swapped', hls_url = p_hls_url,
         swapped_at = clock_timestamp(), lease_until = null,
         updated_at = clock_timestamp()
   where id = p_job_id;
  return 'swapped';
end;
$$;

-- Deletion guard: true only if no lesson anywhere still points at the object
-- and this job's lesson still plays the Bunny URL.
create or replace function public.course_video_mirror_can_delete(
  p_job_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select job.status = 'swapped'
       and job.hls_url is not null
       and not exists (
         select 1 from public.course_video_mirror_candidates(null) as other
          where other.source_url = job.source_url
       )
       and exists (
         select 1
           from public.courses as c
          cross join lateral jsonb_array_elements(
                  case when jsonb_typeof(c.categories) = 'array'
                       then c.categories else '[]'::jsonb end) cat(value)
          cross join lateral jsonb_array_elements(
                  case when jsonb_typeof(cat.value -> 'days') = 'array'
                       then cat.value -> 'days' else '[]'::jsonb end) day(value)
          cross join lateral jsonb_array_elements(
                  case when jsonb_typeof(day.value -> 'lessons') = 'array'
                       then day.value -> 'lessons' else '[]'::jsonb end) lesson(value)
          where c.id = job.course_id
            and lesson.value ->> 'id' = job.lesson_id
            and lesson.value ->> 'videoUrl' = job.hls_url
       )
      from public.course_video_mirror_jobs as job
     where job.id = p_job_id
  ), false);
$$;

-- An editor saving an old copy can put the Supabase URL back after a swap.
-- Such jobs return to 'swapped' handling: the function re-swaps them.
create or replace function public.course_video_mirror_reopen_reverted()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.course_video_mirror_jobs as job
     set status = 'encoding', lease_until = null,
         last_error = 'lesson reverted to storage url; re-swapping',
         updated_at = clock_timestamp()
   where job.status = 'swapped'
     and exists (
       select 1 from public.course_video_mirror_candidates(job.course_id) cand
        where cand.lesson_id = job.lesson_id
          and cand.source_url = job.source_url
     );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.course_video_mirror_candidates(uuid)',
    'public.course_video_mirror_enqueue(uuid)',
    'public.course_video_mirror_claim(uuid, integer)',
    'public.course_video_mirror_set(uuid, text, uuid, text, bigint, text)',
    'public.course_video_mirror_swap(uuid, text)',
    'public.course_video_mirror_can_delete(uuid)',
    'public.course_video_mirror_reopen_reverted()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to service_role', v_signature);
  end loop;
end;
$$;

-- pg_cron: every 5 minutes, only when there is work. Secret from Vault
-- 'x5_course_video_cron_secret' (same value as Edge secret
-- COURSE_VIDEO_CRON_SECRET). No secret value in this file.
create or replace function public.enqueue_course_video_bunny_mirror()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_secret text;
  v_secret_count bigint;
  v_request_id bigint;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;
  if not exists (select 1 from public.course_video_mirror_candidates(null))
     and not exists (
       select 1 from public.course_video_mirror_jobs
        where status in ('queued', 'fetching', 'encoding', 'swapped')
     ) then
    return null;
  end if;

  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_course_video_cron_secret';
  if v_secret_count <> 1 or v_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_secret)) < 32 then
    raise exception using errcode = 'P0001',
      message = 'course_video_cron_secret_unavailable';
  end if;

  select net.http_post(
    url := 'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/course-video-bunny-mirror',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-X5-Reconcile-Secret', v_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) into v_request_id;
  return v_request_id;
end;
$function$;

revoke execute on function public.enqueue_course_video_bunny_mirror()
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_course_video_bunny_mirror()
  to postgres;

-- Scheduling is a separate, explicit step (see docs/BUNNY-STREAM-HANDOFF.md):
--   select cron.schedule('x5-course-video-bunny-mirror', '*/5 * * * *',
--     'select public.enqueue_course_video_bunny_mirror();');

commit;
