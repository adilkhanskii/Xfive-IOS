begin;

-- Cover private-ledger foreign keys so account deletion and event retention do
-- not require full-table scans as notification volume grows.
create index app_store_server_notification_state_user_idx
  on public.app_store_server_notification_state (user_id);
create index app_store_server_notification_state_last_event_idx
  on public.app_store_server_notification_state (last_event_id);
create index app_store_server_notification_adjustments_user_idx
  on public.app_store_server_notification_grant_adjustments (user_id);
create index app_store_server_notification_adjustments_event_idx
  on public.app_store_server_notification_grant_adjustments (event_id);

commit;
