-- App diagnostics collector for X5. Receives crash traces, lifecycle events,
-- and device info from the iOS client (DiagnosticLogger.swift, build 67+).
-- Anonymous inserts allowed — no PII collected. Read restricted to service
-- role (we query from CI via PostgREST).

create table if not exists public.app_diagnostics (
    id              bigserial primary key,
    created_at      timestamptz not null default now(),
    build_number    text,
    app_version     text,
    os_version      text,
    device_model    text,
    device_name     text,
    locale          text,
    event           text not null,
    kind            text,
    summary         text,
    stack           text,
    ts              text
);

create index if not exists app_diagnostics_created_at_idx
    on public.app_diagnostics (created_at desc);
create index if not exists app_diagnostics_event_idx
    on public.app_diagnostics (event);
create index if not exists app_diagnostics_build_idx
    on public.app_diagnostics (build_number);

alter table public.app_diagnostics enable row level security;

-- Anonymous users (the iOS client) can ONLY insert. They cannot read,
-- update, or delete — keeps the table append-only from the device side.
drop policy if exists "anon_insert_app_diagnostics" on public.app_diagnostics;
create policy "anon_insert_app_diagnostics"
    on public.app_diagnostics
    for insert
    to anon
    with check (true);
