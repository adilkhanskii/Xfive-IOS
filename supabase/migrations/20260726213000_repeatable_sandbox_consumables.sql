-- TestFlight consumables are Apple-signed Sandbox transactions. The two
-- immutable developer accounts use them for end-to-end purchase testing, so a
-- small balance ceiling incorrectly turns later one-time purchases into 403s.
-- Keep the bounded App Review account unchanged while giving only those two
-- developer accounts enough headroom for repeated consumable QA.

alter table public.app_store_sandbox_review_accounts
  drop constraint if exists app_store_sandbox_review_accounts_credit_cap;

update public.app_store_sandbox_review_accounts
   set max_credit_balance = 2000000000
 where account_kind = 'developer'
   and user_id in (
     'f3eea23f-0aeb-405b-ab35-2c53173b7a8f'::uuid,
     'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid
   );

alter table public.app_store_sandbox_review_accounts
  add constraint app_store_sandbox_review_accounts_credit_cap
  check (
    (
      account_kind = 'app_review'
      and max_credit_balance between 8000 and 10000
    ) or (
      account_kind = 'developer'
      and max_credit_balance = 2000000000
    )
  );

comment on constraint app_store_sandbox_review_accounts_credit_cap
  on public.app_store_sandbox_review_accounts is
  'App Review remains capped; only the two immutable developer accounts have high TestFlight consumable headroom.';
