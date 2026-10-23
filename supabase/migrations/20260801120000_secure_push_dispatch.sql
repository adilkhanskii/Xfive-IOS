-- Replace spoofable anonymous push bodies with a database-only, signed event-id
-- contract. Provision the same random secret in Supabase Vault under
-- x5_push_webhook_secret and in the Edge Function as X5_PUSH_WEBHOOK_SECRET
-- before applying this migration. No secret value belongs in source control.

create extension if not exists pg_net;
create extension if not exists pg_cron;
create extension if not exists supabase_vault with schema vault;

do $preflight$
declare
  v_secret_count bigint;
  v_webhook_secret text;
begin
  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_webhook_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_push_webhook_secret';

  if v_secret_count <> 1
     or v_webhook_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_webhook_secret)) < 32 then
    raise exception using
      errcode = '55000',
      message = 'x5_push_webhook_vault_secret_required';
  end if;
end;
$preflight$;

-- A sender may insert only into a chat they actually participate in. The old
-- policy checked sender_id but allowed a user with a guessed chat id to create
-- a message in somebody else's chat.
drop policy if exists "messages insert by sender" on public.messages;
create policy "messages insert by sender"
on public.messages for insert
with check (
  (select auth.uid())::text = sender_id::text
  and exists (
    select 1
      from public.chats as chat
     where chat.id = messages.chat_id
       and (select auth.uid())::text = any(chat.participants::text[])
  )
);

create table if not exists public.push_dispatches (
  id uuid primary key default gen_random_uuid(),
  event_type text not null
    check (event_type in ('message_inserted', 'notification_created')),
  event_id uuid not null,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'processing'
    check (status in ('processing', 'retryable', 'completed')),
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer not null default 1
    check (attempt_count between 1 and 5),
  outcome text check (outcome in ('sent', 'no_target')),
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  unique (event_type, event_id, recipient_id),
  check (
    (
      status = 'processing'
      and lease_token is not null
      and lease_expires_at is not null
      and outcome is null
      and completed_at is null
    )
    or (
      status = 'retryable'
      and lease_token is null
      and lease_expires_at is null
      and outcome is null
      and completed_at is null
    )
    or (
      status = 'completed'
      and lease_token is null
      and lease_expires_at is null
      and outcome is not null
      and completed_at is not null
    )
  )
);

create index if not exists push_dispatches_recipient_created_idx
  on public.push_dispatches (recipient_id, created_at desc);
create index if not exists push_dispatches_cleanup_idx
  on public.push_dispatches (updated_at);

create table if not exists public.push_dispatch_attempts (
  dispatch_id uuid not null references public.push_dispatches(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  attempt_number integer not null check (attempt_number between 1 and 5),
  attempted_at timestamptz not null default clock_timestamp(),
  primary key (dispatch_id, attempt_number)
);

create index if not exists push_dispatch_attempts_recipient_time_idx
  on public.push_dispatch_attempts (recipient_id, attempted_at desc);

comment on table public.push_dispatches is
  'Private idempotency and bounded retry ledger for signed database push events.';
comment on table public.push_dispatch_attempts is
  'Private per-recipient push attempt ledger used for burst and daily limits.';

alter table public.push_dispatches enable row level security;
alter table public.push_dispatches force row level security;
alter table public.push_dispatch_attempts enable row level security;
alter table public.push_dispatch_attempts force row level security;
revoke all on table public.push_dispatches
  from public, anon, authenticated, service_role;
revoke all on table public.push_dispatch_attempts
  from public, anon, authenticated, service_role;

create or replace function public.claim_push_dispatch(
  p_event_type text,
  p_event_id uuid,
  p_recipient_id uuid,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_dispatch public.push_dispatches%rowtype;
  v_minute_count bigint;
  v_day_count bigint;
  v_oldest_minute_attempt timestamptz;
  v_utc_day_start timestamptz;
  v_retry_after integer;
  v_existing boolean := false;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null
     or p_recipient_id is null
     or p_lease_token is null then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_recipient_id::text, 904513)
  );

  select dispatch.*
    into v_dispatch
    from public.push_dispatches as dispatch
   where dispatch.event_type = p_event_type
     and dispatch.event_id = p_event_id
     and dispatch.recipient_id = p_recipient_id
   for update;
  v_existing := found;

  if v_existing then
    if v_dispatch.status = 'completed' then
      return jsonb_build_object(
        'status', 'replay',
        'outcome', v_dispatch.outcome
      );
    end if;
    if v_dispatch.status = 'processing'
       and v_dispatch.lease_expires_at > clock_timestamp() then
      v_retry_after := greatest(
        1,
        ceil(extract(epoch from (
          v_dispatch.lease_expires_at - clock_timestamp()
        )))::integer
      );
      return jsonb_build_object(
        'status', 'in_progress',
        'retry_after', v_retry_after
      );
    end if;
    if v_dispatch.attempt_count >= 5 then
      return jsonb_build_object('status', 'attempts_exhausted');
    end if;
  end if;

  v_utc_day_start := (
    pg_catalog.date_trunc('day', clock_timestamp() at time zone 'UTC')
    at time zone 'UTC'
  );
  select
    count(*) filter (
      where attempt.attempted_at >= clock_timestamp() - interval '1 minute'
    ),
    count(*) filter (where attempt.attempted_at >= v_utc_day_start),
    min(attempt.attempted_at) filter (
      where attempt.attempted_at >= clock_timestamp() - interval '1 minute'
    )
    into v_minute_count, v_day_count, v_oldest_minute_attempt
    from public.push_dispatch_attempts as attempt
   where attempt.recipient_id = p_recipient_id
     and attempt.attempted_at >= least(
       v_utc_day_start,
       clock_timestamp() - interval '1 minute'
     );

  if v_minute_count >= 30 then
    v_retry_after := greatest(
      1,
      ceil(extract(epoch from (
        v_oldest_minute_attempt + interval '1 minute' - clock_timestamp()
      )))::integer
    );
    return jsonb_build_object(
      'status', 'rate_limited',
      'retry_after', v_retry_after
    );
  end if;
  if v_day_count >= 500 then
    v_retry_after := greatest(
      1,
      ceil(extract(epoch from (
        v_utc_day_start + interval '1 day' - clock_timestamp()
      )))::integer
    );
    return jsonb_build_object(
      'status', 'rate_limited',
      'retry_after', v_retry_after
    );
  end if;

  if v_existing then
    update public.push_dispatches as dispatch
       set status = 'processing',
           lease_token = p_lease_token,
           lease_expires_at = clock_timestamp() + interval '45 seconds',
           attempt_count = dispatch.attempt_count + 1,
           last_error = null,
           updated_at = clock_timestamp()
     where dispatch.id = v_dispatch.id
     returning dispatch.* into v_dispatch;
  else
    insert into public.push_dispatches as dispatch (
      event_type,
      event_id,
      recipient_id,
      status,
      lease_token,
      lease_expires_at,
      attempt_count
    )
    values (
      p_event_type,
      p_event_id,
      p_recipient_id,
      'processing',
      p_lease_token,
      clock_timestamp() + interval '45 seconds',
      1
    )
    returning dispatch.* into v_dispatch;
  end if;

  insert into public.push_dispatch_attempts (
    dispatch_id,
    recipient_id,
    attempt_number
  )
  values (
    v_dispatch.id,
    p_recipient_id,
    v_dispatch.attempt_count
  );

  return jsonb_build_object(
    'status', 'claimed',
    'attempt', v_dispatch.attempt_count
  );
end;
$function$;

create or replace function public.complete_push_dispatch(
  p_event_type text,
  p_event_id uuid,
  p_recipient_id uuid,
  p_lease_token uuid,
  p_outcome text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_dispatch public.push_dispatches%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null
     or p_recipient_id is null
     or p_lease_token is null
     or p_outcome not in ('sent', 'no_target') then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select dispatch.*
    into v_dispatch
    from public.push_dispatches as dispatch
   where dispatch.event_type = p_event_type
     and dispatch.event_id = p_event_id
     and dispatch.recipient_id = p_recipient_id
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_dispatch.status = 'completed' then
    if v_dispatch.outcome = p_outcome then
      return jsonb_build_object('status', 'already_completed');
    end if;
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if v_dispatch.status <> 'processing'
     or v_dispatch.lease_token <> p_lease_token then
    return jsonb_build_object('status', 'stale_lease');
  end if;

  update public.push_dispatches as dispatch
     set status = 'completed',
         lease_token = null,
         lease_expires_at = null,
         outcome = p_outcome,
         last_error = null,
         updated_at = clock_timestamp(),
         completed_at = clock_timestamp()
   where dispatch.id = v_dispatch.id;
  return jsonb_build_object('status', 'completed');
end;
$function$;

create or replace function public.release_push_dispatch(
  p_event_type text,
  p_event_id uuid,
  p_recipient_id uuid,
  p_lease_token uuid,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_updated integer;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null
     or p_recipient_id is null
     or p_lease_token is null
     or coalesce(p_error_code, '') !~ '^[a-z0-9_:-]{1,120}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  update public.push_dispatches as dispatch
     set status = 'retryable',
         lease_token = null,
         lease_expires_at = null,
         last_error = p_error_code,
         updated_at = clock_timestamp()
   where dispatch.event_type = p_event_type
     and dispatch.event_id = p_event_id
     and dispatch.recipient_id = p_recipient_id
     and dispatch.status = 'processing'
     and dispatch.lease_token = p_lease_token;
  get diagnostics v_updated = row_count;
  return jsonb_build_object(
    'status', case when v_updated = 1 then 'released' else 'stale_lease' end
  );
end;
$function$;

revoke all on function public.claim_push_dispatch(text, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.complete_push_dispatch(text, uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.release_push_dispatch(text, uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.claim_push_dispatch(text, uuid, uuid, uuid)
  to service_role;
grant execute on function public.complete_push_dispatch(text, uuid, uuid, uuid, text)
  to service_role;
grant execute on function public.release_push_dispatch(text, uuid, uuid, uuid, text)
  to service_role;

-- Durable per-provider-target outcomes prevent a successful device from being
-- called again when a second device fails transiently. Only a SHA-256 target
-- fingerprint is stored; raw APNs/FCM tokens remain in their canonical tables.
create table if not exists public.push_target_deliveries (
  dispatch_id uuid not null references public.push_dispatches(id) on delete cascade,
  target_key text not null check (target_key ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'in_flight', 'sent', 'permanent_failure')),
  attempt_count integer not null default 0
    check (attempt_count between 0 and 5),
  rate_limit_count integer not null default 0
    check (rate_limit_count between 0 and 10),
  lease_token_hash text,
  lease_until timestamptz,
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  primary key (dispatch_id, target_key),
  check (
    (status = 'in_flight' and lease_token_hash is not null and lease_until is not null)
    or status <> 'in_flight'
  )
);

create index if not exists push_target_deliveries_cleanup_idx
  on public.push_target_deliveries (updated_at);
alter table public.push_target_deliveries enable row level security;
alter table public.push_target_deliveries force row level security;
revoke all on table public.push_target_deliveries
  from public, anon, authenticated, service_role;

comment on table public.push_target_deliveries is
  'Private per-target push outcome ledger keyed by a non-reversible token fingerprint.';

create or replace function public.claim_push_target_delivery(
  p_event_type text,
  p_event_id uuid,
  p_recipient_id uuid,
  p_dispatch_lease_token uuid,
  p_target_key text,
  p_target_lease_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_dispatch public.push_dispatches%rowtype;
  v_target public.push_target_deliveries%rowtype;
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null
     or p_recipient_id is null
     or p_dispatch_lease_token is null
     or coalesce(p_target_key, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_target_lease_token, '') !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  select dispatch.*
    into v_dispatch
    from public.push_dispatches as dispatch
   where dispatch.event_type = p_event_type
     and dispatch.event_id = p_event_id
     and dispatch.recipient_id = p_recipient_id
   for update;
  if not found
     or v_dispatch.status <> 'processing'
     or v_dispatch.lease_token <> p_dispatch_lease_token
     or v_dispatch.lease_expires_at <= clock_timestamp() then
    return jsonb_build_object('status', 'stale_dispatch_lease');
  end if;

  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_target_lease_token, 'UTF8')),
    'hex'
  );
  select target.*
    into v_target
    from public.push_target_deliveries as target
   where target.dispatch_id = v_dispatch.id
     and target.target_key = p_target_key
   for update;

  if found then
    if v_target.status = 'sent' then
      return jsonb_build_object('status', 'already_sent');
    end if;
    if v_target.status = 'permanent_failure' then
      return jsonb_build_object('status', 'already_permanent');
    end if;
    if v_target.status = 'in_flight'
       and v_target.lease_until > clock_timestamp() then
      return jsonb_build_object('status', 'in_progress');
    end if;
    if v_target.attempt_count >= 5 then
      return jsonb_build_object('status', 'attempts_exhausted');
    end if;

    update public.push_target_deliveries as target
       set status = 'in_flight',
           attempt_count = target.attempt_count + 1,
           lease_token_hash = v_hash,
           lease_until = clock_timestamp() + interval '90 seconds',
           last_error = null,
           updated_at = clock_timestamp()
     where target.dispatch_id = v_dispatch.id
       and target.target_key = p_target_key
    returning target.* into v_target;
  else
    insert into public.push_target_deliveries as target (
      dispatch_id,
      target_key,
      status,
      attempt_count,
      lease_token_hash,
      lease_until
    ) values (
      v_dispatch.id,
      p_target_key,
      'in_flight',
      1,
      v_hash,
      clock_timestamp() + interval '90 seconds'
    )
    returning target.* into v_target;
  end if;

  return jsonb_build_object(
    'status', 'claimed',
    'attempt', v_target.attempt_count
  );
end;
$function$;

create or replace function public.complete_push_target_delivery(
  p_event_type text,
  p_event_id uuid,
  p_recipient_id uuid,
  p_target_key text,
  p_target_lease_token text,
  p_outcome text,
  p_error_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_target public.push_target_deliveries%rowtype;
  v_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null
     or p_recipient_id is null
     or coalesce(p_target_key, '') !~ '^[0-9a-f]{64}$'
     or coalesce(p_target_lease_token, '') !~ '^[A-Za-z0-9_-]{32,200}$'
     or p_outcome not in ('sent', 'permanent_failure', 'transient_failure')
     or (
       p_error_code is not null
       and p_error_code !~ '^[a-z0-9_:-]{1,120}$'
     ) then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  v_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_target_lease_token, 'UTF8')),
    'hex'
  );
  select target.*
    into v_target
    from public.push_target_deliveries as target
    join public.push_dispatches as dispatch
      on dispatch.id = target.dispatch_id
   where dispatch.event_type = p_event_type
     and dispatch.event_id = p_event_id
     and dispatch.recipient_id = p_recipient_id
     and target.target_key = p_target_key
   for update of target;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_target.status in ('sent', 'permanent_failure') then
    if v_target.status = p_outcome then
      return jsonb_build_object('status', 'already_completed');
    end if;
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if v_target.status <> 'in_flight'
     or v_target.lease_token_hash <> v_hash then
    return jsonb_build_object('status', 'stale_lease');
  end if;

  if p_outcome = 'transient_failure' then
    update public.push_target_deliveries as target
       set status = 'pending',
           lease_token_hash = null,
           lease_until = null,
           last_error = coalesce(p_error_code, 'provider_transient'),
           updated_at = clock_timestamp()
     where target.dispatch_id = v_target.dispatch_id
       and target.target_key = v_target.target_key;
    return jsonb_build_object('status', 'retryable');
  end if;

  update public.push_target_deliveries as target
     set status = p_outcome,
         lease_token_hash = null,
         lease_until = null,
         last_error = p_error_code,
         completed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where target.dispatch_id = v_target.dispatch_id
     and target.target_key = v_target.target_key;
  return jsonb_build_object('status', 'completed');
end;
$function$;

revoke all on function public.claim_push_target_delivery(
  text, uuid, uuid, uuid, text, text
) from public, anon, authenticated, service_role;
revoke all on function public.complete_push_target_delivery(
  text, uuid, uuid, text, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.claim_push_target_delivery(
  text, uuid, uuid, uuid, text, text
) to service_role;
grant execute on function public.complete_push_target_delivery(
  text, uuid, uuid, text, text, text, text
) to service_role;

create table if not exists public.push_webhook_outbox (
  id uuid primary key default gen_random_uuid(),
  event_type text not null
    check (event_type in ('message_inserted', 'notification_created')),
  event_id uuid not null,
  status text not null default 'pending'
    check (status in ('pending', 'in_flight', 'delivered', 'dead')),
  attempt_count integer not null default 0
    check (attempt_count between 0 and 5),
  next_attempt_at timestamptz not null default clock_timestamp(),
  request_id bigint,
  last_attempt_at timestamptz,
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  delivered_at timestamptz,
  unique (event_type, event_id),
  check (
    (status = 'pending' and request_id is null and delivered_at is null)
    or (status = 'in_flight' and request_id is not null
        and last_attempt_at is not null and delivered_at is null)
    or (status = 'delivered' and request_id is null
        and delivered_at is not null)
    or (status = 'dead' and request_id is null and delivered_at is null)
  )
);

create index if not exists push_webhook_outbox_due_idx
  on public.push_webhook_outbox (next_attempt_at, created_at)
  where status = 'pending';
create index if not exists push_webhook_outbox_in_flight_idx
  on public.push_webhook_outbox (last_attempt_at)
  where status = 'in_flight';
create index if not exists push_webhook_outbox_cleanup_idx
  on public.push_webhook_outbox (updated_at);

comment on table public.push_webhook_outbox is
  'Private durable outbox for signed pg_net delivery with bounded retry and response reconciliation.';

alter table public.push_webhook_outbox enable row level security;
alter table public.push_webhook_outbox force row level security;
revoke all on table public.push_webhook_outbox
  from public, anon, authenticated, service_role;

create or replace function public.x5_send_push_outbox_row(
  p_outbox_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_outbox public.push_webhook_outbox%rowtype;
  v_webhook_secret text;
  v_secret_count bigint;
  v_request_id bigint;
  v_attempt integer;
begin
  select outbox.*
    into v_outbox
    from public.push_webhook_outbox as outbox
   where outbox.id = p_outbox_id
   for update;

  if not found
     or v_outbox.status <> 'pending'
     or v_outbox.next_attempt_at > clock_timestamp()
     or v_outbox.attempt_count >= 5 then
    return v_outbox.request_id;
  end if;

  select pg_catalog.count(*), pg_catalog.min(secret.decrypted_secret)
    into v_secret_count, v_webhook_secret
    from vault.decrypted_secrets as secret
   where secret.name = 'x5_push_webhook_secret';

  if v_secret_count <> 1
     or v_webhook_secret is null
     or pg_catalog.length(pg_catalog.btrim(v_webhook_secret)) < 32 then
    update public.push_webhook_outbox as outbox
       set next_attempt_at = clock_timestamp() + interval '1 minute',
           last_error = 'webhook_secret_unavailable',
           updated_at = clock_timestamp()
     where outbox.id = v_outbox.id;
    raise warning 'x5_push_webhook_secret_unavailable';
    return null;
  end if;

  v_attempt := v_outbox.attempt_count + 1;
  begin
    select net.http_post(
      url :=
        'https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/send-message-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-X5-Push-Webhook-Secret', v_webhook_secret
      ),
      body := jsonb_build_object(
        'event_type', v_outbox.event_type,
        'event_id', v_outbox.event_id
      ),
      timeout_milliseconds := 10000
    ) into v_request_id;
  exception when others then
    update public.push_webhook_outbox as outbox
       set status = case when v_attempt >= 5 then 'dead' else 'pending' end,
           attempt_count = v_attempt,
           next_attempt_at = clock_timestamp() + case v_attempt
             when 1 then interval '15 seconds'
             when 2 then interval '30 seconds'
             when 3 then interval '1 minute'
             else interval '2 minutes'
           end,
           request_id = null,
           last_attempt_at = clock_timestamp(),
           last_error = 'pg_net_enqueue_failed',
           updated_at = clock_timestamp()
     where outbox.id = v_outbox.id;
    raise warning 'x5_push_pg_net_enqueue_failed';
    return null;
  end;

  if v_request_id is null then
    update public.push_webhook_outbox as outbox
       set status = case when v_attempt >= 5 then 'dead' else 'pending' end,
           attempt_count = v_attempt,
           next_attempt_at = clock_timestamp() + case v_attempt
             when 1 then interval '15 seconds'
             when 2 then interval '30 seconds'
             when 3 then interval '1 minute'
             else interval '2 minutes'
           end,
           request_id = null,
           last_attempt_at = clock_timestamp(),
           last_error = 'pg_net_request_id_missing',
           updated_at = clock_timestamp()
     where outbox.id = v_outbox.id;
    return null;
  end if;

  update public.push_webhook_outbox as outbox
     set status = 'in_flight',
         attempt_count = v_attempt,
         request_id = v_request_id,
         last_attempt_at = clock_timestamp(),
         last_error = null,
         updated_at = clock_timestamp()
   where outbox.id = v_outbox.id;
  return v_request_id;
end;
$function$;

revoke all on function public.x5_send_push_outbox_row(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.x5_enqueue_push_webhook(
  p_event_type text,
  p_event_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_outbox_id uuid;
  v_request_id bigint;
begin
  if p_event_type not in ('message_inserted', 'notification_created')
     or p_event_id is null then
    raise exception using errcode = '22023', message = 'invalid_push_event';
  end if;

  insert into public.push_webhook_outbox (
    event_type,
    event_id
  )
  values (
    p_event_type,
    p_event_id
  )
  on conflict (event_type, event_id) do nothing
  returning id into v_outbox_id;

  if v_outbox_id is null then
    select outbox.id, outbox.request_id
      into v_outbox_id, v_request_id
      from public.push_webhook_outbox as outbox
     where outbox.event_type = p_event_type
       and outbox.event_id = p_event_id;
  end if;

  if v_outbox_id is null then
    raise warning 'x5_push_outbox_enqueue_failed';
    return null;
  end if;

  v_request_id := coalesce(
    public.x5_send_push_outbox_row(v_outbox_id),
    v_request_id
  );
  return v_request_id;
end;
$function$;

revoke all on function public.x5_enqueue_push_webhook(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_enqueue_push_webhook(text, uuid)
  to postgres;

-- Parse only the standard Retry-After forms: bounded decimal seconds or an
-- HTTP-date. Malformed, past or excessively distant values fail closed to the
-- ordinary bounded backoff path. The 48-hour cap covers the UTC daily limit
-- without allowing an upstream header to stall an event indefinitely.
create or replace function public.x5_push_retry_after_seconds(
  p_headers jsonb,
  p_now timestamptz default clock_timestamp()
)
returns integer
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_value text;
  v_seconds numeric;
  v_date timestamptz;
  v_cap constant integer := 172800;
begin
  if p_headers is null or jsonb_typeof(p_headers) <> 'object' then
    return null;
  end if;
  select header.value
    into v_value
    from jsonb_each_text(p_headers) as header(key, value)
   where pg_catalog.lower(header.key) = 'retry-after'
   limit 1;
  v_value := pg_catalog.btrim(coalesce(v_value, ''));
  if v_value = '' then return null; end if;

  if v_value ~ '^[0-9]{1,10}$' then
    v_seconds := v_value::numeric;
    if v_seconds < 1 then return 1; end if;
    return least(pg_catalog.ceil(v_seconds)::integer, v_cap);
  end if;

  begin
    v_date := v_value::timestamptz;
  exception when others then
    return null;
  end;
  v_seconds := pg_catalog.extract(epoch from (v_date - p_now));
  if v_seconds <= 0 then return 1; end if;
  return least(pg_catalog.ceil(v_seconds)::integer, v_cap);
end;
$function$;

revoke all on function public.x5_push_retry_after_seconds(jsonb, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function public.x5_process_push_webhook_outbox(
  p_limit integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_item record;
  v_processed integer := 0;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_retry_status text;
  v_retry_at timestamptz;
  v_error_code text;
  v_retry_after integer;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;

  for v_item in
    select outbox.id,
           outbox.attempt_count,
           outbox.last_attempt_at,
           response.id as response_id,
           response.status_code,
           response.headers,
           response.timed_out,
           response.error_msg
      from public.push_webhook_outbox as outbox
      left join net._http_response as response
        on response.id = outbox.request_id
     where outbox.status = 'in_flight'
       and (
         response.id is not null
         or outbox.last_attempt_at <= clock_timestamp() - interval '2 minutes'
       )
     order by outbox.last_attempt_at asc
     limit v_limit
     for update of outbox skip locked
  loop
    if v_item.response_id is not null
       and coalesce(v_item.timed_out, false) = false
       and v_item.error_msg is null
       and v_item.status_code between 200 and 299 then
      update public.push_webhook_outbox as outbox
         set status = 'delivered',
             request_id = null,
             last_error = null,
             delivered_at = clock_timestamp(),
             updated_at = clock_timestamp()
       where outbox.id = v_item.id;
    elsif v_item.status_code = 429
       and v_item.response_id is not null
       and coalesce(v_item.timed_out, false) = false
       and v_item.error_msg is null
       and public.x5_push_retry_after_seconds(
         v_item.headers,
         clock_timestamp()
       ) is not null then
      v_retry_after := public.x5_push_retry_after_seconds(
        v_item.headers,
        clock_timestamp()
      );
      update public.push_webhook_outbox as outbox
         set status = case
               when outbox.rate_limit_count >= 10 then 'dead'
               else 'pending'
             end,
             -- The Edge rate limiter performed no provider delivery. Do not
             -- consume one of the five ordinary delivery attempts.
             attempt_count = greatest(outbox.attempt_count - 1, 0),
             rate_limit_count = least(outbox.rate_limit_count + 1, 10),
             next_attempt_at = clock_timestamp()
               + pg_catalog.make_interval(secs => v_retry_after),
             request_id = null,
             last_error = 'webhook_rate_limited',
             updated_at = clock_timestamp()
       where outbox.id = v_item.id;
    else
      v_retry_status := case
        when v_item.attempt_count >= 5 then 'dead'
        else 'pending'
      end;
      v_retry_at := clock_timestamp() + case v_item.attempt_count
        when 1 then interval '15 seconds'
        when 2 then interval '30 seconds'
        when 3 then interval '1 minute'
        else interval '2 minutes'
      end;
      v_error_code := case
        when v_item.response_id is null then 'pg_net_response_timeout'
        when coalesce(v_item.timed_out, false) then 'webhook_timeout'
        when v_item.error_msg is not null then 'webhook_network_error'
        else 'webhook_http_' || coalesce(v_item.status_code::text, 'unknown')
      end;

      update public.push_webhook_outbox as outbox
         set status = v_retry_status,
             next_attempt_at = v_retry_at,
             request_id = null,
             last_error = v_error_code,
             updated_at = clock_timestamp()
       where outbox.id = v_item.id;
    end if;
    v_processed := v_processed + 1;
  end loop;

  for v_item in
    select outbox.id
      from public.push_webhook_outbox as outbox
     where outbox.status = 'pending'
       and outbox.attempt_count < 5
       and outbox.next_attempt_at <= clock_timestamp()
     order by outbox.next_attempt_at asc, outbox.created_at asc
     limit greatest(v_limit - v_processed, 0)
     for update skip locked
  loop
    perform public.x5_send_push_outbox_row(v_item.id);
    v_processed := v_processed + 1;
  end loop;

  return v_processed;
end;
$function$;

revoke all on function public.x5_process_push_webhook_outbox(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_process_push_webhook_outbox(integer)
  to postgres;

do $push_outbox_cron$
begin
  begin
    perform cron.unschedule('x5-process-push-webhook-outbox');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-process-push-webhook-outbox',
    '* * * * *',
    'select public.x5_process_push_webhook_outbox(100);'
  );
end;
$push_outbox_cron$;

create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform public.x5_enqueue_push_webhook('message_inserted', new.id);
  return new;
end;
$function$;

drop trigger if exists messages_push_notify on public.messages;
create trigger messages_push_notify
after insert on public.messages
for each row execute function public.notify_new_message();

revoke all on function public.notify_new_message()
  from public, anon, authenticated, service_role;

create or replace function public.x5_enqueue_social_notification(
  recipient_id uuid,
  actor_id uuid,
  event_type text,
  event_title text,
  event_body text,
  event_object_type text,
  event_object_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_notification_id uuid;
begin
  if recipient_id is null
     or actor_id is null
     or recipient_id = actor_id then
    return;
  end if;

  insert into public.notifications (
    user_id,
    actor_id,
    type,
    title,
    body,
    object_type,
    object_id
  )
  values (
    recipient_id,
    actor_id,
    event_type,
    event_title,
    event_body,
    event_object_type,
    event_object_id
  )
  returning id into v_notification_id;

  perform public.x5_enqueue_push_webhook(
    'notification_created',
    v_notification_id
  );
end;
$function$;

revoke all on function public.x5_enqueue_social_notification(
  uuid, uuid, text, text, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.x5_enqueue_social_notification(
  uuid, uuid, text, text, text, text, text
) to postgres;

-- Hub response/acceptance notifications are database events, not client
-- requests. The client supplies only the row it is allowed to create; every
-- recipient, actor, title and deep-link object below is re-derived from the
-- canonical task/response/profile relationship.
drop policy if exists "responses_insert" on public.task_responses;
create policy "responses_insert"
on public.task_responses for insert
with check (
  (select auth.uid()) = specialist_id
  and coalesce(status, 'pending') in ('pending', 'open')
  and exists (
    select 1
      from public.tasks as task
     where task.id = task_responses.task_id
       and task.author_id <> (select auth.uid())
       and coalesce(task.status, 'open') = 'open'
  )
);

-- Acceptance is performed through x5_accept_task_response. There was no live
-- UPDATE policy on task_responses; deliberately keep direct response updates
-- closed instead of adding a spoofable client-side acceptance path.
drop policy if exists "responses_update" on public.task_responses;
drop policy if exists "task_responses_update" on public.task_responses;

create or replace function public.x5_canonicalize_task_response()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_specialist_name text;
  v_specialist_avatar text;
begin
  select coalesce(nullif(pg_catalog.btrim(profile.name), ''),
                  nullif(pg_catalog.btrim(profile.nickname), ''),
                  'Специалист'),
         profile.avatar
    into v_specialist_name, v_specialist_avatar
    from public.profiles as profile
   where profile.id = new.specialist_id;

  if not found then
    raise exception using errcode = '23503', message = 'specialist_profile_required';
  end if;

  -- Clients may keep sending these legacy presentation fields, but the
  -- database always overwrites them from the authenticated profile row.
  new.specialist_name := v_specialist_name;
  new.specialist_avatar := v_specialist_avatar;
  return new;
end;
$function$;

revoke all on function public.x5_canonicalize_task_response()
  from public, anon, authenticated, service_role;

drop trigger if exists task_responses_canonicalize_identity
  on public.task_responses;
create trigger task_responses_canonicalize_identity
before insert on public.task_responses
for each row execute function public.x5_canonicalize_task_response();

create table if not exists public.task_notification_events (
  event_type text not null
    check (event_type in ('task_response', 'task_response_accepted')),
  event_id uuid not null,
  task_id uuid not null references public.tasks(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (event_type, event_id, recipient_id)
);

create index if not exists task_notification_events_cleanup_idx
  on public.task_notification_events (created_at);

comment on table public.task_notification_events is
  'Private exactly-once ledger for canonical Hub response and acceptance notifications.';

alter table public.task_notification_events enable row level security;
alter table public.task_notification_events force row level security;
revoke all on table public.task_notification_events
  from public, anon, authenticated, service_role;

create or replace function public.x5_enqueue_task_notification_once(
  p_event_type text,
  p_event_id uuid,
  p_task_id uuid,
  p_recipient_id uuid,
  p_actor_id uuid,
  p_title text,
  p_body text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_inserted_event_id uuid;
begin
  if p_event_type not in ('task_response', 'task_response_accepted')
     or p_event_id is null
     or p_task_id is null
     or p_recipient_id is null
     or p_actor_id is null
     or p_recipient_id = p_actor_id then
    return false;
  end if;

  insert into public.task_notification_events (
    event_type,
    event_id,
    task_id,
    recipient_id
  )
  values (
    p_event_type,
    p_event_id,
    p_task_id,
    p_recipient_id
  )
  on conflict (event_type, event_id, recipient_id) do nothing
  returning event_id into v_inserted_event_id;

  if v_inserted_event_id is null then
    return false;
  end if;

  perform public.x5_enqueue_social_notification(
    p_recipient_id,
    p_actor_id,
    p_event_type,
    pg_catalog.left(coalesce(nullif(pg_catalog.btrim(p_title), ''), 'X5 Hub'), 120),
    pg_catalog.left(coalesce(nullif(pg_catalog.btrim(p_body), ''), 'Обновление проекта'), 500),
    'task',
    p_task_id::text
  );
  return true;
end;
$function$;

revoke all on function public.x5_enqueue_task_notification_once(
  text, uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated, service_role;

create or replace function public.x5_notify_task_response_inserted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_author_id uuid;
  v_task_title text;
  v_actor_name text;
begin
  select task.author_id, task.title
    into v_author_id, v_task_title
    from public.tasks as task
   where task.id = new.task_id;

  if v_author_id is null
     or new.specialist_id is null
     or v_author_id = new.specialist_id then
    return new;
  end if;

  select coalesce(nullif(pg_catalog.btrim(profile.name), ''),
                  nullif(pg_catalog.btrim(profile.nickname), ''),
                  'Специалист')
    into v_actor_name
    from public.profiles as profile
   where profile.id = new.specialist_id;

  perform public.x5_enqueue_task_notification_once(
    'task_response',
    new.id,
    new.task_id,
    v_author_id,
    new.specialist_id,
    'Новый отклик на проект',
    coalesce(v_actor_name, 'Специалист')
      || ' откликнулся на проект «'
      || coalesce(nullif(pg_catalog.btrim(v_task_title), ''), 'Без названия')
      || '».'
  );
  return new;
end;
$function$;

revoke all on function public.x5_notify_task_response_inserted()
  from public, anon, authenticated, service_role;

drop trigger if exists task_responses_push_notify on public.task_responses;
create trigger task_responses_push_notify
after insert on public.task_responses
for each row execute function public.x5_notify_task_response_inserted();

create or replace function public.x5_prepare_task_acceptance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_specialist_id uuid;
  v_specialist_name text;
  v_acceptance_changed boolean;
begin
  if tg_op = 'INSERT' and new.accepted_response_id is not null then
    raise exception using errcode = '22023', message = 'task_must_start_unaccepted';
  end if;

  if tg_op = 'UPDATE'
     and old.accepted_response_id is not null
     and new.accepted_response_id is distinct from old.accepted_response_id then
    raise exception using errcode = '23514', message = 'task_acceptance_is_immutable';
  end if;

  v_acceptance_changed :=
    tg_op = 'UPDATE'
    and old.accepted_response_id is null
    and new.accepted_response_id is not null;

  if v_acceptance_changed then
    if auth.uid() is null
       or old.author_id <> auth.uid()
       or new.author_id <> auth.uid() then
      raise exception using errcode = '42501', message = 'task_author_required';
    end if;
    if coalesce(old.status, 'open') <> 'open' then
      raise exception using errcode = '23514', message = 'task_not_open';
    end if;
  end if;

  if new.accepted_response_id is null then
    new.accepted_specialist_id := null;
    new.accepted_specialist_name := null;
    if coalesce(new.status, 'open') = 'in_progress' then
      raise exception using errcode = '23514', message = 'accepted_response_required';
    end if;
    return new;
  end if;

  select response.specialist_id,
         coalesce(nullif(pg_catalog.btrim(profile.name), ''),
                  nullif(pg_catalog.btrim(profile.nickname), ''),
                  'Специалист')
    into v_specialist_id, v_specialist_name
    from public.task_responses as response
    left join public.profiles as profile
      on profile.id = response.specialist_id
   where response.id = new.accepted_response_id
     and response.task_id = new.id;

  if v_specialist_id is null then
    raise exception using errcode = '23503', message = 'task_response_not_found';
  end if;

  new.accepted_specialist_id := v_specialist_id;
  new.accepted_specialist_name := v_specialist_name;
  if v_acceptance_changed then
    new.status := 'in_progress';
  end if;
  return new;
end;
$function$;

revoke all on function public.x5_prepare_task_acceptance()
  from public, anon, authenticated, service_role;

drop trigger if exists tasks_prepare_acceptance on public.tasks;
create trigger tasks_prepare_acceptance
before insert or update of accepted_response_id, accepted_specialist_id,
  accepted_specialist_name, status on public.tasks
for each row execute function public.x5_prepare_task_acceptance();

create or replace function public.x5_emit_task_acceptance_notification(
  p_task_id uuid,
  p_response_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_author_id uuid;
  v_task_title text;
  v_specialist_id uuid;
begin
  select task.author_id, task.title, response.specialist_id
    into v_author_id, v_task_title, v_specialist_id
    from public.tasks as task
    join public.task_responses as response
      on response.id = p_response_id
     and response.task_id = task.id
   where task.id = p_task_id
     and task.accepted_response_id = response.id
     and task.accepted_specialist_id = response.specialist_id
     and coalesce(task.status, '') in ('in_progress', 'done');

  if v_author_id is null or v_specialist_id is null then
    return false;
  end if;

  return public.x5_enqueue_task_notification_once(
    'task_response_accepted',
    p_response_id,
    p_task_id,
    v_specialist_id,
    v_author_id,
    'Ваш отклик принят',
    'Автор принял ваш отклик на проект «'
      || coalesce(nullif(pg_catalog.btrim(v_task_title), ''), 'Без названия')
      || '».'
  );
end;
$function$;

revoke all on function public.x5_emit_task_acceptance_notification(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.x5_sync_task_acceptance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.task_responses as response
     set status = case
       when response.id = new.accepted_response_id then 'accepted'
       else 'rejected'
     end
   where response.task_id = new.id
     and response.status is distinct from case
       when response.id = new.accepted_response_id then 'accepted'
       else 'rejected'
     end;

  perform public.x5_emit_task_acceptance_notification(
    new.id,
    new.accepted_response_id
  );
  return new;
end;
$function$;

revoke all on function public.x5_sync_task_acceptance()
  from public, anon, authenticated, service_role;

drop trigger if exists tasks_sync_acceptance on public.tasks;
create trigger tasks_sync_acceptance
after update of accepted_response_id on public.tasks
for each row
when (
  old.accepted_response_id is distinct from new.accepted_response_id
  and new.accepted_response_id is not null
)
execute function public.x5_sync_task_acceptance();

create or replace function public.x5_notify_task_response_accepted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.status is distinct from new.status and new.status = 'accepted' then
    perform public.x5_emit_task_acceptance_notification(new.task_id, new.id);
  end if;
  return new;
end;
$function$;

revoke all on function public.x5_notify_task_response_accepted()
  from public, anon, authenticated, service_role;

drop trigger if exists task_responses_acceptance_push_notify
  on public.task_responses;
create trigger task_responses_acceptance_push_notify
after update of status on public.task_responses
for each row execute function public.x5_notify_task_response_accepted();

create or replace function public.x5_accept_task_response(
  p_task_id uuid,
  p_response_id uuid
)
returns public.tasks
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_task public.tasks%rowtype;
  v_response public.task_responses%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_task_id is null or p_response_id is null then
    raise exception using errcode = '22023', message = 'task_and_response_required';
  end if;

  select task.*
    into v_task
    from public.tasks as task
   where task.id = p_task_id
   for update;

  if not found or v_task.author_id <> v_user_id then
    raise exception using errcode = '42501', message = 'task_author_required';
  end if;

  select response.*
    into v_response
    from public.task_responses as response
   where response.id = p_response_id
     and response.task_id = p_task_id
   for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'task_response_not_found';
  end if;

  if v_task.accepted_response_id = p_response_id
     and v_task.accepted_specialist_id = v_response.specialist_id
     and coalesce(v_task.status, '') in ('in_progress', 'done') then
    return v_task;
  end if;

  if v_task.accepted_response_id is not null
     or coalesce(v_task.status, 'open') <> 'open' then
    raise exception using errcode = '23514', message = 'task_not_open';
  end if;

  update public.tasks as task
     set accepted_response_id = v_response.id,
         status = 'in_progress'
   where task.id = p_task_id
   returning task.* into v_task;

  return v_task;
end;
$function$;

revoke all on function public.x5_accept_task_response(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_accept_task_response(uuid, uuid)
  to authenticated;

create or replace function public.x5_cleanup_push_dispatches()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_dispatches_deleted integer;
  v_outbox_deleted integer;
  v_task_events_deleted integer;
begin
  if session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'postgres_required';
  end if;
  delete from public.push_dispatches as dispatch
   where dispatch.updated_at < clock_timestamp() - interval '30 days';
  get diagnostics v_dispatches_deleted = row_count;

  delete from public.push_webhook_outbox as outbox
   where outbox.status in ('delivered', 'dead')
     and outbox.updated_at < clock_timestamp() - interval '30 days';
  get diagnostics v_outbox_deleted = row_count;

  delete from public.task_notification_events as task_event
   where task_event.created_at < clock_timestamp() - interval '30 days';
  get diagnostics v_task_events_deleted = row_count;

  return v_dispatches_deleted + v_outbox_deleted + v_task_events_deleted;
end;
$function$;

revoke all on function public.x5_cleanup_push_dispatches()
  from public, anon, authenticated, service_role;
grant execute on function public.x5_cleanup_push_dispatches()
  to postgres;

do $cron$
begin
  begin
    perform cron.unschedule('x5-clean-push-dispatches');
  exception when others then
    null;
  end;
  perform cron.schedule(
    'x5-clean-push-dispatches',
    '23 3 * * *',
    'select public.x5_cleanup_push_dispatches();'
  );
end;
$cron$;
