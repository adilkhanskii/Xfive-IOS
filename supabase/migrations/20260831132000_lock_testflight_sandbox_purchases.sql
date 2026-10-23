begin;

-- TestFlight purchases are Apple-signed Sandbox transactions and never charge
-- real money. They must not mint spendable credits for owner/client accounts.
-- Keep only the dedicated App Review login so Apple can verify the approved
-- in-app purchases during review without opening a free-credit path to testers.
delete from public.app_store_sandbox_review_accounts
 where account_kind = 'developer';

insert into public.app_store_sandbox_review_accounts (
  user_id,
  canonical_email,
  enabled,
  max_credit_balance,
  account_kind
)
select
  account.id,
  'appreview@x5studio.app',
  true,
  10000,
  'app_review'
from auth.users as account
where lower(account.email) = 'appreview@x5studio.app'
on conflict (user_id) do update
set canonical_email = excluded.canonical_email,
    enabled = true,
    max_credit_balance = 10000,
    account_kind = 'app_review';

do $block$
begin
  if not exists (
    select 1
      from public.app_store_sandbox_review_accounts as review
      join auth.users as account on account.id = review.user_id
     where review.account_kind = 'app_review'
       and review.enabled
       and review.max_credit_balance = 10000
       and lower(review.canonical_email) = 'appreview@x5studio.app'
       and lower(account.email) = 'appreview@x5studio.app'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'dedicated_app_review_account_missing';
  end if;
end;
$block$;

alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_credit_cap;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_account_kind;
alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_exact_scope;

alter table public.app_store_sandbox_review_accounts
  add constraint app_store_sandbox_review_accounts_account_kind
    check (account_kind = 'app_review'),
  add constraint app_store_sandbox_review_accounts_exact_scope
    check (
      lower(canonical_email) = 'appreview@x5studio.app'
      and enabled
    ),
  add constraint app_store_sandbox_review_accounts_credit_cap
    check (max_credit_balance between 8000 and 10000);

comment on table public.app_store_sandbox_review_accounts is
  'Private allowlist containing only the dedicated Apple App Review login. TestFlight developer accounts cannot receive Sandbox credits.';

commit;
