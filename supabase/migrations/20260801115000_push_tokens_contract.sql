-- Canonical push token schema contract used by web, iOS, Android, and the
-- signed push dispatcher. This migration is intentionally idempotent for the
-- live table while making fresh environments converge on the same upsert key.

create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  token text not null,
  platform text not null default 'web',
  updated_at timestamptz default now(),
  constraint push_tokens_user_id_platform_key unique (user_id, platform)
);

do $preflight$
declare
  v_user_id_attnum smallint;
  v_platform_attnum smallint;
begin
  if not exists (
    select 1
      from pg_catalog.pg_attribute
     where attrelid = 'public.push_tokens'::regclass
       and attname = 'user_id'
       and atttypid = 'uuid'::regtype
       and attnotnull
       and not attisdropped
  ) or not exists (
    select 1
      from pg_catalog.pg_attribute
     where attrelid = 'public.push_tokens'::regclass
       and attname in ('token', 'platform')
       and atttypid = 'text'::regtype
       and attnotnull
       and not attisdropped
     group by attrelid
    having count(*) = 2
  ) then
    raise exception using
      errcode = '55000',
      message = 'push_tokens_schema_contract_mismatch';
  end if;

  if exists (
    select 1
      from public.push_tokens
     group by user_id, platform
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'push_tokens_user_platform_duplicates';
  end if;

  if exists (
    select 1
      from public.push_tokens
     where platform not in ('ios', 'android', 'web', 'expo')
  ) then
    raise exception using
      errcode = '23514',
      message = 'push_tokens_unknown_platform';
  end if;

  select attnum
    into v_user_id_attnum
    from pg_catalog.pg_attribute
   where attrelid = 'public.push_tokens'::regclass
     and attname = 'user_id'
     and not attisdropped;
  select attnum
    into v_platform_attnum
    from pg_catalog.pg_attribute
   where attrelid = 'public.push_tokens'::regclass
     and attname = 'platform'
     and not attisdropped;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.push_tokens'::regclass
       and contype in ('p', 'u')
       and conkey = array[v_user_id_attnum, v_platform_attnum]::smallint[]
  ) then
    alter table public.push_tokens
      add constraint x5_push_tokens_user_platform_unique
      unique (user_id, platform);
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.push_tokens'::regclass
       and conname = 'x5_push_tokens_platform_check'
  ) then
    alter table public.push_tokens
      add constraint x5_push_tokens_platform_check
      check (platform in ('ios', 'android', 'web', 'expo'));
  end if;
end;
$preflight$;

-- One provider token belongs to one current account. Resolve historical
-- duplicates deterministically (newest row wins) before adding the global
-- provider-token key, and exact-clear the legacy iOS mirror for displaced
-- accounts so the fallback dispatcher cannot keep delivering there.
with ranked as (
  select
    token_row.id,
    token_row.user_id,
    token_row.platform,
    token_row.token,
    first_value(token_row.user_id) over (
      partition by token_row.platform, token_row.token
      order by token_row.updated_at desc nulls last, token_row.id desc
    ) as keeper_user_id,
    row_number() over (
      partition by token_row.platform, token_row.token
      order by token_row.updated_at desc nulls last, token_row.id desc
    ) as duplicate_rank
  from public.push_tokens as token_row
), displaced_ios as (
  select distinct ranked.user_id, ranked.token
    from ranked
   where ranked.platform = 'ios'
     and ranked.duplicate_rank > 1
     and ranked.user_id <> ranked.keeper_user_id
)
update public.profiles as profile
   set push_token = null,
       push_token_updated_at = null
  from displaced_ios
 where profile.id = displaced_ios.user_id
   and profile.push_token = displaced_ios.token;

with ranked as (
  select
    token_row.id,
    row_number() over (
      partition by token_row.platform, token_row.token
      order by token_row.updated_at desc nulls last, token_row.id desc
    ) as duplicate_rank
  from public.push_tokens as token_row
)
delete from public.push_tokens as token_row
using ranked
where token_row.id = ranked.id
  and ranked.duplicate_rank > 1;

do $provider_token_unique$
declare
  v_platform_attnum smallint;
  v_token_attnum smallint;
begin
  select attnum into v_platform_attnum
    from pg_catalog.pg_attribute
   where attrelid = 'public.push_tokens'::regclass
     and attname = 'platform'
     and not attisdropped;
  select attnum into v_token_attnum
    from pg_catalog.pg_attribute
   where attrelid = 'public.push_tokens'::regclass
     and attname = 'token'
     and not attisdropped;

  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conrelid = 'public.push_tokens'::regclass
       and contype in ('p', 'u')
       and conkey = array[v_platform_attnum, v_token_attnum]::smallint[]
  ) then
    alter table public.push_tokens
      add constraint x5_push_tokens_platform_token_unique
      unique (platform, token);
  end if;
end;
$provider_token_unique$;

-- Reconcile the legacy iOS mirror before enforcing the same one-device /
-- one-account rule there. A canonical push_tokens owner always wins; orphaned
-- duplicate mirrors keep only their newest row. This also makes direct writes
-- from older clients fail safely instead of silently attaching one APNs token
-- to two accounts while those builds age out.
update public.profiles as profile
   set push_token = null,
       push_token_updated_at = null
 where profile.push_token is not null
   and exists (
     select 1
       from public.push_tokens as token_row
      where token_row.platform = 'ios'
        and token_row.token = profile.push_token
        and token_row.user_id <> profile.id
   );

with ranked_profiles as (
  select
    profile.id,
    row_number() over (
      partition by profile.push_token
      order by profile.push_token_updated_at desc nulls last, profile.id desc
    ) as duplicate_rank
  from public.profiles as profile
  where profile.push_token is not null
)
update public.profiles as profile
   set push_token = null,
       push_token_updated_at = null
  from ranked_profiles
 where profile.id = ranked_profiles.id
   and ranked_profiles.duplicate_rank > 1;

create unique index if not exists x5_profiles_push_token_unique
  on public.profiles (push_token)
  where push_token is not null;

alter table public.push_tokens enable row level security;

drop policy if exists "Users manage own tokens" on public.push_tokens;
drop policy if exists "Users can manage own tokens" on public.push_tokens;
drop policy if exists x5_push_tokens_select_own on public.push_tokens;
drop policy if exists x5_push_tokens_insert_own on public.push_tokens;
drop policy if exists x5_push_tokens_update_own on public.push_tokens;
drop policy if exists x5_push_tokens_delete_own on public.push_tokens;

create policy x5_push_tokens_select_own
on public.push_tokens for select
to authenticated
using ((select auth.uid()) = user_id);

create policy x5_push_tokens_insert_own
on public.push_tokens for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and platform in ('ios', 'android', 'web', 'expo')
);

create policy x5_push_tokens_update_own
on public.push_tokens for update
to authenticated
using ((select auth.uid()) = user_id)
with check (
  (select auth.uid()) = user_id
  and platform in ('ios', 'android', 'web', 'expo')
);

create policy x5_push_tokens_delete_own
on public.push_tokens for delete
to authenticated
using ((select auth.uid()) = user_id);

revoke all on table public.push_tokens from public, anon, authenticated;
grant select on table public.push_tokens to authenticated;
grant select, insert, update, delete on table public.push_tokens to service_role;

comment on table public.push_tokens is
  'One current provider token per user/platform and one account per provider token; legacy expo rows remain read-only.';
comment on policy x5_push_tokens_delete_own on public.push_tokens is
  'Owner boundary for logout cleanup; clients delete the exact user_id, platform, and token tuple.';

create or replace function public.x5_register_push_token(
  p_user_id uuid,
  p_platform text,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_displaced_user_id uuid;
  v_lock_user_id uuid;
  v_updated_at timestamptz := clock_timestamp();
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_platform not in ('ios', 'android', 'web')
     or p_token is null
     or pg_catalog.length(p_token) < 20
     or pg_catalog.length(p_token) > 4096 then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  -- Registrations are low-volume. A registry lock closes cross-token account
  -- switch races; the narrower token and user/platform locks document and
  -- serialize the exact logical keys for future sharding.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('x5_push_token_registry', 818118)
  );
  -- Token ownership is serialized first. Then every affected user/platform
  -- key is locked in UUID order, making account switches deadlock-safe.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'push-token:' || p_platform || ':' || p_token,
      818120
    )
  );
  select token_row.user_id
    into v_displaced_user_id
    from public.push_tokens as token_row
   where token_row.platform = p_platform
     and token_row.token = p_token
   for update;

  for v_lock_user_id in
    select distinct affected.user_id
      from unnest(array[p_user_id, v_displaced_user_id]) as affected(user_id)
     where affected.user_id is not null
     order by affected.user_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'push-user-platform:' || v_lock_user_id::text || ':' || p_platform,
        818121
      )
    );
  end loop;

  delete from public.push_tokens as token_row
   where token_row.platform = p_platform
     and token_row.token = p_token
     and token_row.user_id <> p_user_id;

  if p_platform = 'ios' then
    update public.profiles as profile
       set push_token = null,
           push_token_updated_at = null
     where profile.id <> p_user_id
       and profile.push_token = p_token;
  end if;

  insert into public.push_tokens as token_row (
    user_id,
    platform,
    token,
    updated_at
  ) values (
    p_user_id,
    p_platform,
    p_token,
    v_updated_at
  )
  on conflict (user_id, platform) do update
     set token = excluded.token,
         updated_at = excluded.updated_at;

  if p_platform = 'ios' then
    update public.profiles as profile
       set push_token = p_token,
           push_token_updated_at = v_updated_at
     where profile.id = p_user_id;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'updated_at', v_updated_at,
    'reassigned', v_displaced_user_id is not null
      and v_displaced_user_id <> p_user_id
  );
end;
$function$;

revoke all on function public.x5_register_push_token(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_register_push_token(uuid, text, text)
  to service_role;

-- Logout uses one server-side transaction. A stale device token can never
-- delete a newer registration, and the legacy profile mirror is cleared only
-- when it still contains that exact iOS token.
create or replace function public.x5_unregister_push_token(
  p_user_id uuid,
  p_platform text,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_deleted integer;
  v_profile_cleared integer := 0;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_user_id is null
     or p_platform not in ('ios', 'android', 'web')
     or p_token is null
     or pg_catalog.length(p_token) < 20
     or pg_catalog.length(p_token) > 4096 then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('x5_push_token_registry', 818118)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'push-token:' || p_platform || ':' || p_token,
      818120
    )
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'push-user-platform:' || p_user_id::text || ':' || p_platform,
      818121
    )
  );

  delete from public.push_tokens as token_row
   where token_row.user_id = p_user_id
     and token_row.platform = p_platform
     and token_row.token = p_token;
  get diagnostics v_deleted = row_count;

  if p_platform = 'ios' then
    update public.profiles as profile
       set push_token = null,
           push_token_updated_at = null
     where profile.id = p_user_id
       and profile.push_token = p_token;
    get diagnostics v_profile_cleared = row_count;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'deleted', v_deleted = 1,
    'profile_cleared', v_profile_cleared = 1
  );
end;
$function$;

revoke all on function public.x5_unregister_push_token(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_unregister_push_token(uuid, text, text)
  to service_role;
