-- Defense in depth: every new portfolio row starts fail-closed even when a
-- trusted server-side insert omits the moderation status. Existing client
-- inserts are already forced to pending by x5_guard_portfolio_moderation_fields.
alter table public.portfolio_items
  alter column moderation_status set default 'pending';
