begin;

do $test$
declare
  v_developer_count integer;
  v_review_count integer;
begin
  select count(*)
    into v_developer_count
    from public.app_store_sandbox_review_accounts
   where account_kind = 'developer'
     and enabled
     and max_credit_balance = 2000000000;

  if v_developer_count <> 2 then
    raise exception
      'sandbox_developer_consumables_are_not_repeatable:%',
      v_developer_count;
  end if;

  select count(*)
    into v_review_count
    from public.app_store_sandbox_review_accounts
   where account_kind = 'app_review'
     and enabled
     and max_credit_balance between 8000 and 10000;

  if v_review_count <> 1 then
    raise exception
      'app_review_credit_guard_changed:%',
      v_review_count;
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conrelid =
       'public.app_store_sandbox_review_accounts'::regclass
       and conname = 'app_store_sandbox_review_accounts_credit_cap'
       and pg_get_constraintdef(oid) ilike '%account_kind%'
       and pg_get_constraintdef(oid) ilike '%2000000000%'
  ) then
    raise exception 'sandbox_credit_cap_is_not_role_scoped';
  end if;
end;
$test$;

rollback;

select
  'repeatable_sandbox_consumables_keep_app_review_guard' as status;
