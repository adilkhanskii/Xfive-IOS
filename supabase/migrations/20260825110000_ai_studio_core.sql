-- Private AI Studio domain: durable generated assets, characters, presets,
-- provider health, influencer orchestration and exact-once lipsync accounting.

create table public.generated_assets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  asset_type text not null,
  status text not null default 'ready',
  bucket_id text not null,
  object_path text not null,
  mime_type text not null,
  source_kind text not null,
  source_id uuid,
  category text,
  title text,
  provider text,
  model text,
  width integer,
  height integer,
  duration_seconds numeric(8, 3),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint generated_assets_object_unique unique (bucket_id, object_path),
  constraint generated_assets_type_valid check (
    asset_type in ('image', 'audio', 'video')
  ),
  constraint generated_assets_status_valid check (
    status in ('pending', 'ready', 'failed')
  ),
  constraint generated_assets_source_valid check (
    source_kind in (
      'image_generation', 'voice_generation', 'video_generation',
      'lipsync_generation', 'user_upload'
    )
  ),
  constraint generated_assets_bucket_valid check (
    bucket_id ~ '^[a-z0-9][a-z0-9-]{1,62}$'
  ),
  constraint generated_assets_path_valid check (
    length(object_path) between 3 and 500
    and object_path not like '%..%'
    and object_path not like E'%\\%'
  ),
  constraint generated_assets_mime_valid check (
    mime_type in (
      'image/jpeg', 'image/png', 'image/webp',
      'audio/mpeg', 'audio/wav', 'audio/mp4',
      'video/mp4'
    )
  ),
  constraint generated_assets_metadata_valid check (
    jsonb_typeof(metadata) = 'object'
  )
);

create index generated_assets_owner_created_idx
  on public.generated_assets (user_id, created_at desc);
create index generated_assets_source_idx
  on public.generated_assets (source_kind, source_id)
  where source_id is not null;

alter table public.generated_assets enable row level security;
alter table public.generated_assets force row level security;
revoke all on table public.generated_assets
  from public, anon, authenticated, service_role;
grant select on table public.generated_assets to authenticated;

create policy generated_assets_owner_select
on public.generated_assets
for select
to authenticated
using ((select auth.uid()) = user_id and status = 'ready');

create table public.ai_characters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  character_kind text not null,
  gender text,
  age integer,
  origin text,
  face_description text,
  body_description text,
  skin_description text,
  hair_description text,
  outfit_description text,
  accessories_description text,
  extra_description text,
  image_model text not null default 'gpt-image-2',
  approved_image_asset_id uuid references public.generated_assets(id)
    on delete set null,
  voice_id text,
  voice_language text,
  voice_speed numeric(3, 1),
  approved_voice_asset_id uuid references public.generated_assets(id)
    on delete set null,
  status text not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_characters_name_valid check (
    length(btrim(name)) between 1 and 80
  ),
  constraint ai_characters_kind_valid check (
    character_kind in ('human', 'creature', 'hybrid')
  ),
  constraint ai_characters_age_valid check (
    age is null or age between 18 and 100
  ),
  constraint ai_characters_status_valid check (
    status in ('draft', 'image_approved', 'voice_approved', 'ready')
  ),
  constraint ai_characters_speed_valid check (
    voice_speed is null or voice_speed between 0.7 and 1.2
  )
);

create index ai_characters_owner_updated_idx
  on public.ai_characters (user_id, updated_at desc);

alter table public.ai_characters enable row level security;
alter table public.ai_characters force row level security;
revoke all on table public.ai_characters
  from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.ai_characters
  to authenticated;

create policy ai_characters_owner_all
on public.ai_characters
for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create table public.user_ai_presets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  tool_id text not null,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_ai_presets_owner_name_unique unique (user_id, name),
  constraint user_ai_presets_name_valid check (
    length(btrim(name)) between 1 and 80
  ),
  constraint user_ai_presets_tool_valid check (
    tool_id ~ '^[a-z0-9][a-z0-9_-]{1,63}$'
  ),
  constraint user_ai_presets_settings_valid check (
    jsonb_typeof(settings) = 'object'
  )
);

alter table public.user_ai_presets enable row level security;
alter table public.user_ai_presets force row level security;
revoke all on table public.user_ai_presets
  from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.user_ai_presets
  to authenticated;

create policy user_ai_presets_owner_all
on public.user_ai_presets
for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create table public.ai_provider_health (
  provider text not null,
  capability text not null,
  configured boolean not null default false,
  available boolean not null default false,
  model text,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error_code text,
  updated_at timestamptz not null default now(),
  primary key (provider, capability),
  constraint ai_provider_health_provider_valid check (
    provider ~ '^[a-z0-9][a-z0-9_-]{1,39}$'
  ),
  constraint ai_provider_health_capability_valid check (
    capability in ('image', 'voice', 'video', 'lipsync')
  ),
  constraint ai_provider_health_error_valid check (
    last_error_code is null or last_error_code ~ '^[a-z0-9_:-]{1,80}$'
  )
);

alter table public.ai_provider_health enable row level security;
alter table public.ai_provider_health force row level security;
revoke all on table public.ai_provider_health
  from public, anon, authenticated, service_role;
grant select on table public.ai_provider_health to authenticated;

create policy ai_provider_health_authenticated_select
on public.ai_provider_health
for select
to authenticated
using (true);

insert into public.ai_provider_health (
  provider, capability, configured, available, model, last_success_at
)
values
  ('openai', 'image', true, true, 'gpt-image-2', null),
  ('google', 'image', true, true, 'gemini-3.1-flash-image', null),
  ('minimax', 'voice', true, true, 'speech-2.8-turbo', null),
  ('byteplus', 'video', true, true, 'seedance-2.0-fast', now()),
  ('fal', 'lipsync', false, false, 'fal-ai/sync-lipsync', null)
on conflict (provider, capability) do nothing;

create table public.lipsync_generation_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  request_fingerprint text not null,
  video_asset_id uuid not null references public.generated_assets(id),
  audio_asset_id uuid not null references public.generated_assets(id),
  result_asset_id uuid references public.generated_assets(id)
    on delete set null,
  status text not null default 'queued',
  progress numeric(4, 3) not null default 0,
  duration_seconds integer not null,
  cost_credits integer not null,
  credits_after_debit integer,
  permanent_credits_debited integer not null default 0,
  permanent_credit_debt_at_claim integer not null default 0,
  credits_expires_at_before_debit timestamptz,
  credits_expires_at_after_debit timestamptz,
  claim_token_hash text not null,
  provider_request_id text,
  result_object_path text,
  result_sha256 text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  completed_at timestamptz,
  refunded_at timestamptz,
  constraint lipsync_generation_owner_request_unique
    unique (user_id, request_id),
  constraint lipsync_generation_provider_request_unique
    unique (provider_request_id),
  constraint lipsync_generation_fingerprint_valid check (
    request_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint lipsync_generation_status_valid check (
    status in ('queued', 'processing', 'completed', 'refunded')
  ),
  constraint lipsync_generation_progress_valid check (
    progress between 0 and 1
  ),
  constraint lipsync_generation_duration_valid check (
    duration_seconds between 1 and 60
  ),
  constraint lipsync_generation_cost_valid check (
    cost_credits between 50 and 6000
    and permanent_credits_debited between 0 and cost_credits
    and permanent_credit_debt_at_claim >= 0
  ),
  constraint lipsync_generation_claim_valid check (
    claim_token_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint lipsync_generation_provider_request_valid check (
    provider_request_id is null
    or provider_request_id ~ '^[A-Za-z0-9_-]{8,200}$'
  ),
  constraint lipsync_generation_error_valid check (
    error_code is null or error_code ~ '^[a-z0-9_:-]{1,80}$'
  )
);

create index lipsync_generation_owner_updated_idx
  on public.lipsync_generation_jobs (user_id, updated_at desc);
create index lipsync_generation_pending_idx
  on public.lipsync_generation_jobs (updated_at)
  where status in ('queued', 'processing');

alter table public.lipsync_generation_jobs enable row level security;
alter table public.lipsync_generation_jobs force row level security;
revoke all on table public.lipsync_generation_jobs
  from public, anon, authenticated, service_role;
grant select on table public.lipsync_generation_jobs to authenticated;

create policy lipsync_generation_owner_select
on public.lipsync_generation_jobs
for select
to authenticated
using ((select auth.uid()) = user_id);

create table public.ai_influencer_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  character_id uuid not null references public.ai_characters(id)
    on delete cascade,
  voice_asset_id uuid not null references public.generated_assets(id),
  video_job_id uuid references public.video_generation_jobs(id)
    on delete set null,
  base_video_asset_id uuid references public.generated_assets(id)
    on delete set null,
  lipsync_job_id uuid references public.lipsync_generation_jobs(id)
    on delete set null,
  result_asset_id uuid references public.generated_assets(id)
    on delete set null,
  status text not null default 'queued',
  scene text not null,
  aspect_ratio text not null,
  duration_seconds integer not null,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint ai_influencer_owner_request_unique unique (user_id, request_id),
  constraint ai_influencer_status_valid check (
    status in (
      'queued', 'video_rendering', 'lipsync_processing',
      'completed', 'failed'
    )
  ),
  constraint ai_influencer_aspect_valid check (
    aspect_ratio in ('9:16', '16:9')
  ),
  constraint ai_influencer_duration_valid check (
    duration_seconds in (5, 10)
  ),
  constraint ai_influencer_error_valid check (
    error_code is null or error_code ~ '^[a-z0-9_:-]{1,80}$'
  )
);

alter table public.ai_influencer_jobs enable row level security;
alter table public.ai_influencer_jobs force row level security;
revoke all on table public.ai_influencer_jobs
  from public, anon, authenticated, service_role;
grant select on table public.ai_influencer_jobs to authenticated;

create policy ai_influencer_owner_select
on public.ai_influencer_jobs
for select
to authenticated
using ((select auth.uid()) = user_id);

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values
  (
    'ai-studio-inputs',
    'ai-studio-inputs',
    false,
    52428800,
    array[
      'image/jpeg', 'image/png', 'image/webp',
      'audio/mpeg', 'audio/wav', 'audio/mp4', 'video/mp4'
    ]::text[]
  ),
  (
    'lipsync-generation-results',
    'lipsync-generation-results',
    false,
    104857600,
    array['video/mp4']::text[]
  )
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.x5_generated_assets_from_image()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  item jsonb;
begin
  if new.status <> 'succeeded' or new.result_manifest is null then
    return new;
  end if;
  for item in select value from jsonb_array_elements(new.result_manifest -> 'objects')
  loop
    insert into public.generated_assets (
      user_id, asset_type, status, bucket_id, object_path, mime_type,
      source_kind, source_id, provider, model
    ) values (
      new.user_id, 'image', 'ready', 'image-generation-results',
      item ->> 'path', item ->> 'mimeType',
      'image_generation', new.id,
      new.result_manifest ->> 'provider', new.result_manifest ->> 'model'
    )
    on conflict (bucket_id, object_path) do update
      set status = 'ready', updated_at = now();
  end loop;
  return new;
end;
$function$;

create or replace function public.x5_generated_assets_from_voice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  item jsonb;
begin
  if new.status <> 'succeeded' or new.result_manifest is null then
    return new;
  end if;
  item := new.result_manifest -> 'object';
  insert into public.generated_assets (
    user_id, asset_type, status, bucket_id, object_path, mime_type,
    source_kind, source_id, provider, model
  ) values (
    new.user_id, 'audio', 'ready', 'voice-generation-results',
    item ->> 'path', item ->> 'mimeType',
    'voice_generation', new.id,
    new.result_manifest ->> 'provider', new.result_manifest ->> 'model'
  )
  on conflict (bucket_id, object_path) do update
    set status = 'ready', updated_at = now();
  return new;
end;
$function$;

create or replace function public.x5_generated_assets_from_video()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status <> 'completed' or new.result_object_path is null then
    return new;
  end if;
  insert into public.generated_assets (
    user_id, asset_type, status, bucket_id, object_path, mime_type,
    source_kind, source_id, provider
  ) values (
    new.user_id, 'video', 'ready', 'video-generation-results',
    new.result_object_path, 'video/mp4',
    'video_generation', new.id, new.provider_name
  )
  on conflict (bucket_id, object_path) do update
    set status = 'ready', updated_at = now();
  return new;
end;
$function$;

revoke execute on function public.x5_generated_assets_from_image()
  from public, anon, authenticated, service_role;
revoke execute on function public.x5_generated_assets_from_voice()
  from public, anon, authenticated, service_role;
revoke execute on function public.x5_generated_assets_from_video()
  from public, anon, authenticated, service_role;

create trigger x5_generated_assets_image_trigger
after insert or update of status, result_manifest
on public.image_generation_requests
for each row
when (new.status = 'succeeded')
execute function public.x5_generated_assets_from_image();

create trigger x5_generated_assets_voice_trigger
after insert or update of status, result_manifest
on public.voice_generation_requests
for each row
when (new.status = 'succeeded')
execute function public.x5_generated_assets_from_voice();

create trigger x5_generated_assets_video_trigger
after insert or update of status, result_object_path
on public.video_generation_jobs
for each row
when (new.status = 'completed')
execute function public.x5_generated_assets_from_video();

-- Backfill the durable gallery for previously generated media.
do $block$
declare
  row record;
  item jsonb;
begin
  for row in
    select * from public.image_generation_requests
    where status = 'succeeded' and result_manifest is not null
  loop
    for item in select value from jsonb_array_elements(row.result_manifest -> 'objects')
    loop
      insert into public.generated_assets (
        user_id, asset_type, status, bucket_id, object_path, mime_type,
        source_kind, source_id, provider, model
      ) values (
        row.user_id, 'image', 'ready', 'image-generation-results',
        item ->> 'path', item ->> 'mimeType', 'image_generation', row.id,
        row.result_manifest ->> 'provider', row.result_manifest ->> 'model'
      ) on conflict (bucket_id, object_path) do nothing;
    end loop;
  end loop;

  for row in
    select * from public.voice_generation_requests
    where status = 'succeeded' and result_manifest is not null
  loop
    item := row.result_manifest -> 'object';
    insert into public.generated_assets (
      user_id, asset_type, status, bucket_id, object_path, mime_type,
      source_kind, source_id, provider, model
    ) values (
      row.user_id, 'audio', 'ready', 'voice-generation-results',
      item ->> 'path', item ->> 'mimeType', 'voice_generation', row.id,
      row.result_manifest ->> 'provider', row.result_manifest ->> 'model'
    ) on conflict (bucket_id, object_path) do nothing;
  end loop;

  for row in
    select * from public.video_generation_jobs
    where status = 'completed' and result_object_path is not null
  loop
    insert into public.generated_assets (
      user_id, asset_type, status, bucket_id, object_path, mime_type,
      source_kind, source_id, provider
    ) values (
      row.user_id, 'video', 'ready', 'video-generation-results',
      row.result_object_path, 'video/mp4', 'video_generation', row.id,
      row.provider_name
    ) on conflict (bucket_id, object_path) do nothing;
  end loop;
end;
$block$;

create or replace function public.generated_asset_by_object_service(
  p_bucket_id text,
  p_object_path text
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select coalesce(
    (
      select jsonb_build_object(
        'status', 'found',
        'id', asset.id,
        'user_id', asset.user_id,
        'asset_type', asset.asset_type,
        'bucket_id', asset.bucket_id,
        'object_path', asset.object_path,
        'mime_type', asset.mime_type,
        'source_kind', asset.source_kind,
        'source_id', asset.source_id
      )
      from public.generated_assets as asset
      where asset.bucket_id = p_bucket_id
        and asset.object_path = p_object_path
        and asset.status = 'ready'
      limit 1
    ),
    jsonb_build_object('status', 'not_found')
  )
  where coalesce(auth.jwt() ->> 'role', '') = 'service_role'
     or session_user = 'postgres';
$function$;

create or replace function public.decorate_generated_assets(
  p_user_id uuid,
  p_bucket_id text,
  p_object_paths text[],
  p_category text,
  p_title text,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  ids jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then
    p_metadata := '{}'::jsonb;
  end if;
  update public.generated_assets as asset
     set category = nullif(left(btrim(coalesce(p_category, '')), 80), ''),
         title = nullif(left(btrim(coalesce(p_title, '')), 500), ''),
         metadata = asset.metadata || p_metadata,
         updated_at = now()
   where asset.user_id = p_user_id
     and asset.bucket_id = p_bucket_id
     and asset.object_path = any(coalesce(p_object_paths, array[]::text[]));
  select coalesce(jsonb_agg(asset.id order by asset.object_path), '[]'::jsonb)
    into ids
    from public.generated_assets as asset
   where asset.user_id = p_user_id
     and asset.bucket_id = p_bucket_id
     and asset.object_path = any(coalesce(p_object_paths, array[]::text[]));
  return jsonb_build_object('status', 'ok', 'asset_ids', ids);
end;
$function$;

create or replace function public.record_ai_provider_health(
  p_provider text,
  p_capability text,
  p_success boolean,
  p_model text default null,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  provider_name text := lower(left(btrim(coalesce(p_provider, '')), 40));
  capability_name text := lower(btrim(coalesce(p_capability, '')));
  error_name text := lower(left(btrim(coalesce(p_error_code, '')), 80));
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if provider_name !~ '^[a-z0-9][a-z0-9_-]{1,39}$'
     or capability_name not in ('image', 'voice', 'video', 'lipsync') then
    return;
  end if;
  if error_name !~ '^[a-z0-9_:-]{1,80}$' then error_name := null; end if;
  insert into public.ai_provider_health as health (
    provider, capability, configured, available, model,
    last_success_at, last_failure_at, last_error_code, updated_at
  ) values (
    provider_name, capability_name, true, p_success,
    nullif(left(btrim(coalesce(p_model, '')), 100), ''),
    case when p_success then now() else null end,
    case when p_success then null else now() end,
    case when p_success then null else error_name end,
    now()
  )
  on conflict (provider, capability) do update
    set configured = true,
        available = p_success,
        model = coalesce(excluded.model, health.model),
        last_success_at = case
          when p_success then now() else health.last_success_at end,
        last_failure_at = case
          when p_success then health.last_failure_at else now() end,
        last_error_code = case when p_success then null else error_name end,
        updated_at = now();
end;
$function$;

create or replace function public.claim_lipsync_generation_job(
  p_user_id uuid,
  p_request_id uuid,
  p_request_fingerprint text,
  p_video_asset_id uuid,
  p_audio_asset_id uuid,
  p_duration_seconds integer,
  p_cost_credits integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  v_inserted boolean := false;
  v_credits integer;
  v_permanent_before integer;
  v_permanent_after integer;
  v_expiry_before timestamptz;
  v_expiry_after timestamptz;
  v_debt_at_claim integer;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null or p_request_id is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_duration_seconds not between 1 and 60
     or p_cost_credits not between 50 and 6000
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;
  if not exists (
    select 1 from public.generated_assets as asset
    where asset.id = p_video_asset_id and asset.user_id = p_user_id
      and asset.asset_type = 'video' and asset.status = 'ready'
  ) or not exists (
    select 1 from public.generated_assets as asset
    where asset.id = p_audio_asset_id and asset.user_id = p_user_id
      and asset.asset_type = 'audio' and asset.status = 'ready'
  ) then
    return jsonb_build_object('status', 'asset_not_found');
  end if;

  insert into public.lipsync_generation_jobs as ledger (
    user_id, request_id, request_fingerprint,
    video_asset_id, audio_asset_id, duration_seconds, cost_credits,
    claim_token_hash
  ) values (
    p_user_id, p_request_id, p_request_fingerprint,
    p_video_asset_id, p_audio_asset_id, p_duration_seconds, p_cost_credits,
    pg_catalog.encode(
      pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')), 'hex'
    )
  )
  on conflict (user_id, request_id) do nothing
  returning ledger.* into job;
  v_inserted := found;

  if not v_inserted then
    select ledger.* into job
      from public.lipsync_generation_jobs as ledger
     where ledger.user_id = p_user_id and ledger.request_id = p_request_id
     for update;
    if job.request_fingerprint <> p_request_fingerprint
       or job.video_asset_id <> p_video_asset_id
       or job.audio_asset_id <> p_audio_asset_id
       or job.cost_credits <> p_cost_credits then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    return jsonb_build_object(
      'status', 'replay', 'job_id', job.id, 'job_status', job.status,
      'progress', job.progress, 'credits_remaining', job.credits_after_debit,
      'result_asset_id', job.result_asset_id,
      'refunded', job.refunded_at is not null
    );
  end if;

  select coalesce(profile.credits, 0),
         greatest(coalesce(profile.permanent_credits, 0), 0),
         greatest(coalesce(profile.permanent_credit_debt, 0), 0),
         profile.credits_expires_at
    into v_credits, v_permanent_before, v_debt_at_claim, v_expiry_before
    from public.profiles as profile
   where profile.id = p_user_id for update;
  if not found then
    delete from public.lipsync_generation_jobs where id = job.id;
    return jsonb_build_object('status', 'profile_not_found');
  end if;
  if v_credits < p_cost_credits then
    delete from public.lipsync_generation_jobs where id = job.id;
    return jsonb_build_object(
      'status', 'insufficient_credits', 'credits_remaining', v_credits
    );
  end if;

  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) - p_cost_credits
   where profile.id = p_user_id
  returning profile.credits, profile.permanent_credits,
            profile.credits_expires_at
       into v_credits, v_permanent_after, v_expiry_after;

  update public.lipsync_generation_jobs as ledger
     set credits_after_debit = v_credits,
         permanent_credits_debited = greatest(
           v_permanent_before - greatest(coalesce(v_permanent_after, 0), 0), 0
         ),
         permanent_credit_debt_at_claim = v_debt_at_claim,
         credits_expires_at_before_debit = v_expiry_before,
         credits_expires_at_after_debit = v_expiry_after,
         updated_at = now()
   where ledger.id = job.id
  returning ledger.* into job;

  return jsonb_build_object(
    'status', 'claimed', 'job_id', job.id,
    'credits_remaining', job.credits_after_debit
  );
end;
$function$;

create or replace function public.mark_lipsync_generation_submitted(
  p_job_id uuid,
  p_user_id uuid,
  p_claim_token text,
  p_provider_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select * into job from public.lipsync_generation_jobs
   where id = p_job_id and user_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if job.provider_request_id = p_provider_request_id then
    return jsonb_build_object('status', 'already_submitted');
  end if;
  if job.status <> 'queued' or job.provider_request_id is not null
     or p_provider_request_id !~ '^[A-Za-z0-9_-]{8,200}$'
     or job.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')), 'hex'
     ) then
    return jsonb_build_object('status', 'state_conflict');
  end if;
  update public.lipsync_generation_jobs
     set provider_request_id = p_provider_request_id,
         status = 'processing', progress = 0.1,
         submitted_at = now(), updated_at = now()
   where id = job.id;
  return jsonb_build_object('status', 'submitted');
end;
$function$;

create or replace function public.get_lipsync_generation_job_service(
  p_job_id uuid,
  p_user_id uuid default null,
  p_provider_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  video_asset public.generated_assets%rowtype;
  audio_asset public.generated_assets%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select * into job from public.lipsync_generation_jobs as ledger
   where (p_job_id is null or ledger.id = p_job_id)
     and (p_user_id is null or ledger.user_id = p_user_id)
     and (p_provider_request_id is null
       or ledger.provider_request_id = p_provider_request_id)
   limit 1;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  select * into video_asset from public.generated_assets
    where id = job.video_asset_id;
  select * into audio_asset from public.generated_assets
    where id = job.audio_asset_id;
  return jsonb_strip_nulls(jsonb_build_object(
    'status', 'found', 'id', job.id, 'user_id', job.user_id,
    'job_status', job.status, 'progress', job.progress,
    'cost_credits', job.cost_credits,
    'credits_remaining', job.credits_after_debit,
    'provider_request_id', job.provider_request_id,
    'video_bucket_id', video_asset.bucket_id,
    'video_object_path', video_asset.object_path,
    'audio_bucket_id', audio_asset.bucket_id,
    'audio_object_path', audio_asset.object_path,
    'result_asset_id', job.result_asset_id,
    'result_object_path', job.result_object_path,
    'error_code', job.error_code,
    'created_at', job.created_at, 'updated_at', job.updated_at,
    'refunded', job.refunded_at is not null
  ));
end;
$function$;

create or replace function public.x5_apply_lipsync_credit_restoration()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  marker text := nullif(
    current_setting('x5.lipsync_restore_request', true), ''
  );
  new_debt integer;
  debt_repaid integer;
  permanent_restored integer;
begin
  if current_user <> 'postgres' or marker is null
     or marker !~* '^[0-9a-f-]{36}$' then return new; end if;
  select * into job from public.lipsync_generation_jobs
   where id = marker::uuid and user_id = new.id
     and status in ('queued', 'processing');
  if not found then return new; end if;
  new_debt := greatest(
    greatest(coalesce(old.permanent_credit_debt, 0), 0)
      - job.permanent_credit_debt_at_claim, 0
  );
  debt_repaid := least(job.permanent_credits_debited, new_debt);
  permanent_restored := job.permanent_credits_debited - debt_repaid;
  new.permanent_credit_debt := greatest(
    coalesce(old.permanent_credit_debt, 0) - debt_repaid, 0
  );
  new.permanent_credits := least(
    greatest(coalesce(new.credits, 0), 0),
    greatest(coalesce(old.permanent_credits, 0), 0) + permanent_restored
  );
  if old.credits_expires_at is not distinct from
       job.credits_expires_at_after_debit then
    new.credits_expires_at := job.credits_expires_at_before_debit;
  else
    new.credits_expires_at := old.credits_expires_at;
  end if;
  if coalesce(new.credits, 0) - new.permanent_credits <= 0 then
    new.credits_expires_at := null;
  end if;
  return new;
end;
$function$;

revoke execute on function public.x5_apply_lipsync_credit_restoration()
  from public, anon, authenticated, service_role;

create trigger zz_x5_restore_lipsync_credits
before update of credits, permanent_credits,
  permanent_credit_debt, credits_expires_at
on public.profiles
for each row
execute function public.x5_apply_lipsync_credit_restoration();

create or replace function public.x5_restore_lipsync_credits(p_job_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  credits_after integer;
begin
  select * into job from public.lipsync_generation_jobs
   where id = p_job_id for update;
  if not found or job.status not in ('queued', 'processing') then
    raise exception using errcode = 'P0001', message = 'lipsync_not_processing';
  end if;
  perform pg_catalog.set_config(
    'x5.lipsync_restore_request', job.id::text, true
  );
  update public.profiles
     set credits = coalesce(credits, 0) + job.cost_credits
   where id = job.user_id
  returning credits into credits_after;
  perform pg_catalog.set_config('x5.lipsync_restore_request', '', true);
  if not found then
    raise exception using errcode = 'P0001', message = 'profile_missing';
  end if;
  return credits_after;
exception when others then
  perform pg_catalog.set_config('x5.lipsync_restore_request', '', true);
  raise;
end;
$function$;

revoke execute on function public.x5_restore_lipsync_credits(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.fail_lipsync_generation_job(
  p_job_id uuid,
  p_provider_request_id text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  credits_after integer;
  error_name text := lower(left(btrim(coalesce(p_error_code, '')), 80));
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select * into job from public.lipsync_generation_jobs
   where id = p_job_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if job.status = 'completed' then
    return jsonb_build_object('status', 'already_completed');
  end if;
  if job.status = 'refunded' then
    return jsonb_build_object(
      'status', 'already_refunded',
      'credits_remaining', (
        select coalesce(credits, 0) from public.profiles where id = job.user_id
      )
    );
  end if;
  if job.provider_request_id is not null
     and job.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'provider_conflict');
  end if;
  if error_name !~ '^[a-z0-9_:-]{1,80}$' then
    error_name := 'lipsync_failed';
  end if;
  credits_after := public.x5_restore_lipsync_credits(job.id);
  update public.lipsync_generation_jobs
     set status = 'refunded', progress = 1, error_code = error_name,
         updated_at = now(), refunded_at = now(), completed_at = null
   where id = job.id;
  return jsonb_build_object(
    'status', 'refunded', 'credits_remaining', credits_after
  );
end;
$function$;

create or replace function public.complete_lipsync_generation_job(
  p_job_id uuid,
  p_provider_request_id text,
  p_result_object_path text,
  p_result_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  job public.lipsync_generation_jobs%rowtype;
  asset_id uuid;
  expected_path text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select * into job from public.lipsync_generation_jobs
   where id = p_job_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if job.status = 'completed' then
    return jsonb_build_object(
      'status', 'already_completed', 'result_asset_id', job.result_asset_id,
      'credits_remaining', job.credits_after_debit
    );
  end if;
  if job.status not in ('queued', 'processing')
     or job.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'state_conflict');
  end if;
  expected_path := job.user_id::text || '/' || job.id::text || '/output.mp4';
  if p_result_object_path <> expected_path
     or p_result_sha256 !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status', 'invalid_result');
  end if;
  insert into public.generated_assets (
    user_id, asset_type, status, bucket_id, object_path, mime_type,
    source_kind, source_id, provider, model
  ) values (
    job.user_id, 'video', 'ready', 'lipsync-generation-results',
    p_result_object_path, 'video/mp4', 'lipsync_generation', job.id,
    'fal', 'fal-ai/sync-lipsync'
  )
  on conflict (bucket_id, object_path) do update
    set status = 'ready', updated_at = now()
  returning id into asset_id;
  update public.lipsync_generation_jobs
     set status = 'completed', progress = 1,
         result_asset_id = asset_id,
         result_object_path = p_result_object_path,
         result_sha256 = p_result_sha256,
         error_code = null, updated_at = now(), completed_at = now()
   where id = job.id;
  return jsonb_build_object(
    'status', 'completed', 'result_asset_id', asset_id,
    'credits_remaining', job.credits_after_debit
  );
end;
$function$;

revoke execute on function public.generated_asset_by_object_service(text, text)
  from public, anon, authenticated, service_role;
revoke execute on function public.decorate_generated_assets(
  uuid, text, text[], text, text, jsonb
) from public, anon, authenticated, service_role;
revoke execute on function public.record_ai_provider_health(
  text, text, boolean, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.claim_lipsync_generation_job(
  uuid, uuid, text, uuid, uuid, integer, integer, text
) from public, anon, authenticated, service_role;
revoke execute on function public.mark_lipsync_generation_submitted(
  uuid, uuid, text, text
) from public, anon, authenticated, service_role;
revoke execute on function public.get_lipsync_generation_job_service(
  uuid, uuid, text
) from public, anon, authenticated, service_role;
revoke execute on function public.fail_lipsync_generation_job(uuid, text, text)
  from public, anon, authenticated, service_role;
revoke execute on function public.complete_lipsync_generation_job(
  uuid, text, text, text
) from public, anon, authenticated, service_role;

grant execute on function public.generated_asset_by_object_service(text, text)
  to service_role;
grant execute on function public.decorate_generated_assets(
  uuid, text, text[], text, text, jsonb
) to service_role;
grant execute on function public.record_ai_provider_health(
  text, text, boolean, text, text
) to service_role;
grant execute on function public.claim_lipsync_generation_job(
  uuid, uuid, text, uuid, uuid, integer, integer, text
) to service_role;
grant execute on function public.mark_lipsync_generation_submitted(
  uuid, uuid, text, text
) to service_role;
grant execute on function public.get_lipsync_generation_job_service(
  uuid, uuid, text
) to service_role;
grant execute on function public.fail_lipsync_generation_job(uuid, text, text)
  to service_role;
grant execute on function public.complete_lipsync_generation_job(
  uuid, text, text, text
) to service_role;
