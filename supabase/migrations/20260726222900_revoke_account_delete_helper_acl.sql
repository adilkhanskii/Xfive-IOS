-- Security hotfix independent of the queued-cleanup rollout. This helper uses
-- dynamic SQL under SECURITY DEFINER and must never be directly callable by an
-- API role. delete_own_account() can still invoke it as its owning definer.

revoke all on function public.x5_delete_eq_if_exists(text, text, uuid)
  from public, anon, authenticated, service_role;
