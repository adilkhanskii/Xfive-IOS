begin;

-- Old manual/error states are provider failures, not moderation verdicts.
-- Keep those items private and eligible for the next automatic retry.
-- The row guard intentionally freezes moderation fields for ordinary roles,
-- so this migration must assume the same role as the automatic moderator.
select set_config('request.jwt.claim.role', 'service_role', true);

update public.portfolio_items
set moderation_status = 'pending',
    moderation_reason = 'Автоматическая проверка ожидает повтора',
    moderation_result = coalesce(moderation_result, '{}'::jsonb)
      || jsonb_build_object(
        'retryable', true,
        'retry_reason', coalesce(moderation_error, moderation_status)
      ),
    moderated_at = null
where moderation_status in ('manual_review', 'failed');

alter table public.portfolio_items
  drop constraint if exists portfolio_items_moderation_status_check;

alter table public.portfolio_items
  add constraint portfolio_items_moderation_status_check
  check (moderation_status in ('pending', 'approved', 'rejected'));

-- A pending item is visible only to its owner. There is no developer review
-- queue: only an automatic approved/rejected decision can publish or reject it.
drop policy if exists "portfolio public read" on public.portfolio_items;

create policy "portfolio public read"
on public.portfolio_items for select
to anon, authenticated
using (
  moderation_status = 'approved'
  or (select auth.uid()) = user_id
);

drop index if exists public.portfolio_items_moderation_queue_idx;

create index if not exists portfolio_items_moderation_retry_idx
on public.portfolio_items (created_at asc)
where moderation_status = 'pending';

commit;
