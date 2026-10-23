begin;

-- Supabase projects may grant service_role broad table privileges through
-- default privileges. Revoke them explicitly before restoring the minimum
-- append-only/read-only access required by the verification RPCs.
revoke all privileges on table public.app_store_consumable_transactions
  from service_role;
grant select, insert on table public.app_store_consumable_transactions
  to service_role;

revoke all privileges on table public.app_store_sandbox_review_accounts
  from service_role;
grant select on table public.app_store_sandbox_review_accounts
  to service_role;

revoke all privileges on table public.app_store_sandbox_review_transactions
  from service_role;
grant select, insert on table public.app_store_sandbox_review_transactions
  to service_role;

commit;
