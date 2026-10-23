-- Keep portfolio publication automatic-only and fail closed. Safe provider
-- verdicts are approved, unsafe verdicts are rejected, and provider/preparation
-- failures remain pending for a bounded automatic retry. Ordinary clients can
-- never write moderation fields or publish an unreviewed item.

create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault with schema vault;

-- The scheduled sweep uses a dedicated random secret. Never reuse the service
-- role key as an Edge webhook credential.
do $preflight$
declare
  v_secret_count bigint;
  v_sweep_secret text;
begin
  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_sweep_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_portfolio_moderation_sweep_secret';

  if v_secret_count <> 1
     or v_sweep_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_sweep_secret)) < 32 then
    raise exception using
      errcode = '55000',
      message = 'x5_portfolio_moderation_sweep_vault_secret_required';
  end if;
end;
$preflight$;

alter table public.portfolio_items
  alter column moderation_status set default 'pending';

alter table public.portfolio_items
  drop constraint if exists portfolio_items_moderation_status_check;
alter table public.portfolio_items
  add constraint portfolio_items_moderation_status_check
  check (moderation_status in ('pending', 'approved', 'rejected'));

-- A moderation result update must not invalidate its own compare-and-swap.
-- Only content changes create a new immutable moderation revision.
create or replace function public.x5_bump_portfolio_moderation_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_content_changed boolean;
begin
  if tg_op = 'INSERT' then
    new.moderation_revision := 1;
    return new;
  end if;

  v_content_changed :=
    coalesce(new.type, '') is distinct from coalesce(old.type, '')
    or coalesce(new.title, '') is distinct from coalesce(old.title, '')
    or coalesce(new.description, '') is distinct from coalesce(old.description, '')
    or coalesce(new.media_url, '') is distinct from coalesce(old.media_url, '')
    or coalesce(new.thumbnail_url, '') is distinct from coalesce(old.thumbnail_url, '')
    or coalesce(new.link, '') is distinct from coalesce(old.link, '');

  new.moderation_revision := case
    when v_content_changed then old.moderation_revision + 1
    else old.moderation_revision
  end;
  return new;
end;
$function$;

revoke all on function public.x5_bump_portfolio_moderation_revision()
  from public, anon, authenticated, service_role;

create or replace function public.x5_guard_portfolio_moderation_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_is_automatic_moderator boolean :=
    session_user = 'postgres'
    or coalesce(auth.jwt() ->> 'role', '') = 'service_role';
  v_content_changed boolean;
begin
  if v_is_automatic_moderator then
    if new.moderation_status in ('approved', 'rejected')
       and (
         tg_op = 'INSERT'
         or old.moderation_status is distinct from new.moderation_status
       ) then
      new.moderated_at := coalesce(new.moderated_at, clock_timestamp());
    elsif new.moderation_status = 'pending' then
      new.moderated_at := null;
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.moderation_status := 'pending';
    new.moderation_reason := null;
    new.moderation_result := '{}'::jsonb;
    new.moderation_model := null;
    new.moderation_error := null;
    new.moderated_at := null;
    return new;
  end if;

  v_content_changed :=
    coalesce(new.type, '') is distinct from coalesce(old.type, '')
    or coalesce(new.title, '') is distinct from coalesce(old.title, '')
    or coalesce(new.description, '') is distinct from coalesce(old.description, '')
    or coalesce(new.media_url, '') is distinct from coalesce(old.media_url, '')
    or coalesce(new.thumbnail_url, '') is distinct from coalesce(old.thumbnail_url, '')
    or coalesce(new.link, '') is distinct from coalesce(old.link, '');

  if v_content_changed then
    new.moderation_status := 'pending';
    new.moderation_reason := null;
    new.moderation_result := '{}'::jsonb;
    new.moderation_model := null;
    new.moderation_error := null;
    new.moderated_at := null;
  else
    new.moderation_status := old.moderation_status;
    new.moderation_reason := old.moderation_reason;
    new.moderation_result := old.moderation_result;
    new.moderation_model := old.moderation_model;
    new.moderation_error := old.moderation_error;
    new.moderated_at := old.moderated_at;
  end if;
  return new;
end;
$function$;

revoke all on function public.x5_guard_portfolio_moderation_fields()
  from public, anon, authenticated, service_role;

drop trigger if exists portfolio_items_moderation_guard
  on public.portfolio_items;
create trigger portfolio_items_moderation_guard
before insert or update on public.portfolio_items
for each row execute function public.x5_guard_portfolio_moderation_fields();

drop policy if exists "portfolio owner write" on public.portfolio_items;
drop policy if exists "portfolio public read" on public.portfolio_items;
drop policy if exists "portfolio_select" on public.portfolio_items;
drop policy if exists "portfolio_insert" on public.portfolio_items;
drop policy if exists "portfolio_update" on public.portfolio_items;
drop policy if exists "portfolio_delete" on public.portfolio_items;
drop policy if exists "portfolio_owner_insert" on public.portfolio_items;
drop policy if exists "portfolio_owner_update" on public.portfolio_items;
drop policy if exists "portfolio_owner_delete" on public.portfolio_items;
drop policy if exists "portfolio_moderator_update" on public.portfolio_items;

create policy "portfolio public read"
on public.portfolio_items for select
to anon, authenticated
using (
  moderation_status = 'approved'
  or (select auth.uid()) = user_id
);

create policy "portfolio_owner_insert"
on public.portfolio_items for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and moderation_status = 'pending'
);

create policy "portfolio_owner_update"
on public.portfolio_items for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "portfolio_owner_delete"
on public.portfolio_items for delete
to authenticated
using ((select auth.uid()) = user_id);

drop index if exists public.portfolio_items_moderation_queue_idx;
create index if not exists portfolio_items_moderation_retry_idx
on public.portfolio_items (created_at asc)
where moderation_status = 'pending';

comment on column public.portfolio_items.moderation_status is
  'Automatic-only state: safe=approved, unsafe=rejected, provider failure=pending.';

-- Private durable retry state. Keeping leases and provider errors off the
-- public item row prevents clients from manipulating or observing the queue.
create table if not exists public.portfolio_moderation_jobs (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.portfolio_items(id) on delete cascade,
  moderation_revision bigint not null check (moderation_revision >= 1),
  status text not null default 'pending'
    check (status in (
      'pending', 'in_flight', 'completed', 'exhausted', 'superseded'
    )),
  attempt_count integer not null default 0
    check (attempt_count between 0 and 5),
  next_retry_at timestamptz not null default clock_timestamp(),
  lease_token_hash text,
  lease_until timestamptz,
  last_attempt_at timestamptz,
  last_error text,
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (item_id, moderation_revision),
  check (
    (status = 'in_flight' and lease_token_hash is not null and lease_until is not null)
    or status <> 'in_flight'
  )
);

create index if not exists portfolio_moderation_jobs_due_idx
on public.portfolio_moderation_jobs (next_retry_at, created_at)
where status in ('pending', 'in_flight');

alter table public.portfolio_moderation_jobs enable row level security;
alter table public.portfolio_moderation_jobs force row level security;
revoke all on table public.portfolio_moderation_jobs
  from public, anon, authenticated, service_role;

comment on table public.portfolio_moderation_jobs is
  'Private automatic moderation queue with bounded retries and hashed leases.';

create or replace function public.x5_enqueue_portfolio_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.portfolio_moderation_jobs as job
     set status = 'superseded',
         lease_token_hash = null,
         lease_until = null,
         completed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where job.item_id = new.id
     and job.moderation_revision <> new.moderation_revision
     and job.status in ('pending', 'in_flight');

  if new.moderation_status = 'pending' then
    insert into public.portfolio_moderation_jobs (
      item_id,
      moderation_revision,
      status,
      next_retry_at
    )
    values (
      new.id,
      new.moderation_revision,
      'pending',
      clock_timestamp()
    )
    on conflict (item_id, moderation_revision) do nothing;
  end if;
  return new;
end;
$function$;

revoke all on function public.x5_enqueue_portfolio_moderation()
  from public, anon, authenticated, service_role;

drop trigger if exists portfolio_items_moderation_enqueue
  on public.portfolio_items;
create trigger portfolio_items_moderation_enqueue
after insert or update of type, title, description, media_url, thumbnail_url, link
on public.portfolio_items
for each row execute function public.x5_enqueue_portfolio_moderation();

insert into public.portfolio_moderation_jobs (
  item_id,
  moderation_revision,
  status,
  next_retry_at
)
select
  item.id,
  item.moderation_revision,
  'pending',
  clock_timestamp()
from public.portfolio_items as item
where item.moderation_status = 'pending'
on conflict (item_id, moderation_revision) do nothing;

create or replace function public.x5_claim_portfolio_moderation_job(
  p_item_id uuid,
  p_moderation_revision bigint,
  p_owner_id uuid,
  p_lease_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_job public.portfolio_moderation_jobs%rowtype;
  v_item public.portfolio_items%rowtype;
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_item_id is null
     or p_moderation_revision is null
     or p_moderation_revision < 1
     or p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );

  select item.*
    into v_item
    from public.portfolio_items as item
   where item.id = p_item_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if p_owner_id is not null and v_item.user_id <> p_owner_id then
    return jsonb_build_object('status', 'forbidden');
  end if;
  if v_item.moderation_revision <> p_moderation_revision
     or v_item.moderation_status <> 'pending' then
    update public.portfolio_moderation_jobs as job
       set status = 'superseded',
           lease_token_hash = null,
           lease_until = null,
           completed_at = clock_timestamp(),
           updated_at = clock_timestamp()
     where job.item_id = p_item_id
       and job.moderation_revision = p_moderation_revision
       and job.status in ('pending', 'in_flight');
    return jsonb_build_object('status', 'stale_item');
  end if;

  select job.*
    into v_job
    from public.portfolio_moderation_jobs as job
   where job.item_id = p_item_id
     and job.moderation_revision = p_moderation_revision
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_job.status = 'completed' then
    return jsonb_build_object('status', 'already_completed');
  end if;
  if v_job.status in ('exhausted', 'superseded') then
    return jsonb_build_object('status', v_job.status);
  end if;
  if v_job.status = 'in_flight'
     and v_job.lease_until > clock_timestamp() then
    return jsonb_build_object(
      'status', 'in_progress',
      'retry_after', greatest(
        1,
        ceil(extract(epoch from (
          v_job.lease_until - clock_timestamp()
        )))::integer
      )
    );
  end if;
  -- A worker can disappear after claiming the fifth attempt. Once that final
  -- lease expires, converge the job to a terminal state instead of leaving an
  -- unclaimable in_flight row forever. The portfolio item remains private and
  -- pending, with an explicit machine-readable exhaustion marker.
  if v_job.attempt_count >= 5 then
    update public.portfolio_items as item
       set moderation_status = 'pending',
           moderation_reason = 'Автоматическая проверка исчерпала попытки',
           moderation_result = coalesce(item.moderation_result, '{}'::jsonb)
             || jsonb_build_object('retry_exhausted', true),
           moderation_error = left(
             coalesce(v_job.last_error, 'final_attempt_lease_expired'),
             2000
           ),
           moderated_at = null
     where item.id = v_item.id
       and item.moderation_revision = v_job.moderation_revision
       and item.moderation_status = 'pending';

    update public.portfolio_moderation_jobs as job
       set status = 'exhausted',
           lease_token_hash = null,
           lease_until = null,
           last_error = coalesce(
             job.last_error,
             'final_attempt_lease_expired'
           ),
           completed_at = clock_timestamp(),
           updated_at = clock_timestamp()
     where job.id = v_job.id;
    return jsonb_build_object('status', 'exhausted');
  end if;
  if v_job.status = 'pending'
     and v_job.next_retry_at > clock_timestamp() then
    return jsonb_build_object(
      'status', 'not_due',
      'retry_after', greatest(
        1,
        ceil(extract(epoch from (
          v_job.next_retry_at - clock_timestamp()
        )))::integer
      )
    );
  end if;

  update public.portfolio_moderation_jobs as job
     set status = 'in_flight',
         attempt_count = job.attempt_count + 1,
         lease_token_hash = v_hash,
         lease_until = clock_timestamp() + interval '2 minutes',
         last_attempt_at = clock_timestamp(),
         last_error = null,
         updated_at = clock_timestamp()
   where job.id = v_job.id
  returning job.* into v_job;

  return jsonb_build_object(
    'status', 'claimed',
    'job_id', v_job.id,
    'attempt', v_job.attempt_count,
    'item', to_jsonb(v_item)
  );
end;
$function$;

create or replace function public.x5_claim_next_portfolio_moderation_job(
  p_lease_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_candidate record;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select job.item_id, job.moderation_revision
    into v_candidate
    from public.portfolio_moderation_jobs as job
    join public.portfolio_items as item
      on item.id = job.item_id
   where job.attempt_count < 5
     and (
       (job.status = 'pending' and job.next_retry_at <= clock_timestamp())
       or (
         job.status = 'in_flight'
         and job.lease_until <= clock_timestamp()
       )
     )
   order by job.next_retry_at, job.created_at
   for update of item skip locked
   limit 1;
  if not found then
    return jsonb_build_object('status', 'empty');
  end if;

  return public.x5_claim_portfolio_moderation_job(
    v_candidate.item_id,
    v_candidate.moderation_revision,
    null,
    p_lease_token
  );
end;
$function$;

create or replace function public.x5_complete_portfolio_moderation_job(
  p_job_id uuid,
  p_lease_token text,
  p_status text,
  p_reason text,
  p_result jsonb,
  p_model text,
  p_error text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_job public.portfolio_moderation_jobs%rowtype;
  v_item public.portfolio_items%rowtype;
  v_hash text;
  v_delay interval;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_job_id is null
     or p_lease_token is null
     or p_lease_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or p_status not in ('pending', 'approved', 'rejected') then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_lease_token, 'UTF8')),
    'hex'
  );
  -- Read the item id first without a row lock, then lock item -> job. Content
  -- updates and the enqueue trigger use the same order, avoiding a queue/item
  -- deadlock while the final job re-read still protects lease CAS.
  select job.*
    into v_job
    from public.portfolio_moderation_jobs as job
   where job.id = p_job_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select item.*
    into v_item
    from public.portfolio_items as item
   where item.id = v_job.item_id
   for update;
  if not found then
    return jsonb_build_object('status', 'stale_item');
  end if;

  select job.*
    into v_job
    from public.portfolio_moderation_jobs as job
   where job.id = p_job_id
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_job.status in ('completed', 'exhausted', 'superseded') then
    if v_job.lease_token_hash = v_hash then
      return jsonb_build_object('status', 'already_' || v_job.status);
    end if;
    return jsonb_build_object('status', 'stale_lease');
  end if;
  if v_job.status <> 'in_flight'
     or v_job.lease_token_hash <> v_hash
     or v_job.lease_until <= clock_timestamp() then
    return jsonb_build_object('status', 'stale_lease');
  end if;

  if v_item.moderation_revision <> v_job.moderation_revision
     or v_item.moderation_status <> 'pending' then
    update public.portfolio_moderation_jobs as job
       set status = 'superseded',
           lease_until = null,
           completed_at = clock_timestamp(),
           updated_at = clock_timestamp()
     where job.id = v_job.id;
    return jsonb_build_object('status', 'stale_item');
  end if;

  if p_status = 'pending' then
    update public.portfolio_items as item
       set moderation_status = 'pending',
           moderation_reason = coalesce(
             p_reason,
             'Автоматическая проверка ожидает повтора'
           ),
           moderation_result = coalesce(p_result, '{}'::jsonb)
             || case when v_job.attempt_count >= 5
                  then jsonb_build_object('retry_exhausted', true)
                  else '{}'::jsonb
                end,
           moderation_model = p_model,
           moderation_error = left(coalesce(p_error, 'retryable_failure'), 2000),
           moderated_at = null
     where item.id = v_item.id
       and item.moderation_revision = v_job.moderation_revision;

    if v_job.attempt_count >= 5 then
      update public.portfolio_moderation_jobs as job
         set status = 'exhausted',
             lease_until = null,
             last_error = left(coalesce(p_error, 'retryable_failure'), 2000),
             completed_at = clock_timestamp(),
             updated_at = clock_timestamp()
       where job.id = v_job.id;
      return jsonb_build_object('status', 'exhausted');
    end if;

    v_delay := case v_job.attempt_count
      when 1 then interval '1 minute'
      when 2 then interval '5 minutes'
      when 3 then interval '15 minutes'
      else interval '1 hour'
    end;
    update public.portfolio_moderation_jobs as job
       set status = 'pending',
           next_retry_at = clock_timestamp() + v_delay,
           lease_token_hash = null,
           lease_until = null,
           last_error = left(coalesce(p_error, 'retryable_failure'), 2000),
           updated_at = clock_timestamp()
     where job.id = v_job.id;
    return jsonb_build_object(
      'status', 'retry_scheduled',
      'attempt', v_job.attempt_count,
      'retry_after', ceil(extract(epoch from v_delay))::integer
    );
  end if;

  update public.portfolio_items as item
     set moderation_status = p_status,
         moderation_reason = p_reason,
         moderation_result = coalesce(p_result, '{}'::jsonb),
         moderation_model = p_model,
         moderation_error = p_error,
         moderated_at = clock_timestamp()
   where item.id = v_item.id
     and item.moderation_revision = v_job.moderation_revision;

  update public.portfolio_moderation_jobs as job
     set status = 'completed',
         lease_until = null,
         last_error = null,
         completed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where job.id = v_job.id;
  return jsonb_build_object('status', 'completed', 'outcome', p_status);
end;
$function$;

revoke all on function public.x5_claim_portfolio_moderation_job(
  uuid, bigint, uuid, text
) from public, anon, authenticated, service_role;
revoke all on function public.x5_claim_next_portfolio_moderation_job(text)
  from public, anon, authenticated, service_role;
revoke all on function public.x5_complete_portfolio_moderation_job(
  uuid, text, text, text, jsonb, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.x5_claim_portfolio_moderation_job(
  uuid, bigint, uuid, text
) to service_role;
grant execute on function public.x5_claim_next_portfolio_moderation_job(text)
  to service_role;
grant execute on function public.x5_complete_portfolio_moderation_job(
  uuid, text, text, text, jsonb, text, text
) to service_role;

create or replace function public.x5_dispatch_portfolio_moderation_sweep()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_secret_count bigint;
  v_sweep_secret text;
  v_request_id bigint;
begin
  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_sweep_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_portfolio_moderation_sweep_secret';
  if v_secret_count <> 1
     or v_sweep_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_sweep_secret)) < 32 then
    raise warning 'x5_portfolio_moderation_sweep_secret_unavailable';
    return null;
  end if;

  select net.http_post(
    url :=
      'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/moderate-portfolio?sweep=1',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-X5-Portfolio-Moderation-Secret', v_sweep_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  ) into v_request_id;
  return v_request_id;
exception when others then
  raise warning 'x5_portfolio_moderation_sweep_enqueue_failed';
  return null;
end;
$function$;

revoke all on function public.x5_dispatch_portfolio_moderation_sweep()
  from public, anon, authenticated, service_role;
grant execute on function public.x5_dispatch_portfolio_moderation_sweep()
  to postgres;

do $portfolio_moderation_cron$
begin
  begin
    perform cron.unschedule('x5-portfolio-moderation-sweep');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-portfolio-moderation-sweep',
    '* * * * *',
    'select public.x5_dispatch_portfolio_moderation_sweep();'
  );
end;
$portfolio_moderation_cron$;
