-- Run immediately before migration 20261002150000_verified_renewal_early_signing.
-- Read-only: it changes nothing. It stops the deployment if a renewal function
-- differs from the production body audited on 2026-10-02 (or from the fixed
-- body, so it also passes after the migration), or if existing rows would fail
-- the new date constraints.
-- The Windows SQL tools may send CRLF; line endings are not SQL behavior.
do $preflight$
declare
  v_strict text;
  v_badge text;
begin
  select md5(replace(prosrc, chr(13), '')) into v_strict
    from pg_proc
   where oid = 'public.x5_apply_verified_app_store_transaction_signed_date_strict_inte(uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure;
  if v_strict is distinct from '05a3dbdb4b4e32747ac4bc88096dcdca'
     and v_strict is distinct from '2bd744459c2965fa2ad1fc8eed9574ec' then
    raise exception 'App Store transaction engine changed since the 2026-10-02 audit (%): stop and re-audit, do not overwrite', v_strict;
  end if;

  select md5(replace(prosrc, chr(13), '')) into v_badge
    from pg_proc
   where oid = 'public.x5_apply_verified_app_store_badge_lifecycle_internal(uuid,text,text,timestamptz,uuid,text,text,text,text,uuid,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,timestamptz,integer)'::regprocedure;
  if v_badge is distinct from 'f4be4aecb4835df2de6cc97cfdf79f00'
     and v_badge is distinct from '88757d7e6b72a93dc4a6b37d3467138f' then
    raise exception 'Verified badge lifecycle changed since the 2026-10-02 audit (%): stop and re-audit, do not overwrite', v_badge;
  end if;

  if (
    select count(*) from pg_constraint
     where (conrelid = 'public.app_store_transactions'::regclass
            and conname = 'app_store_transactions_dates_valid')
        or (conrelid = 'public.app_store_verified_lifecycle_events'::regclass
            and conname = 'app_store_verified_lifecycle_events_dates')
  ) <> 2 then
    raise exception 'Renewal date constraints are missing: stop and re-audit';
  end if;

  if exists (
    select 1 from public.app_store_transactions
     where not (
       expires_date > purchase_date
       and signed_date >= purchase_date - interval '25 hours'
     )
  ) or exists (
    select 1 from public.app_store_verified_lifecycle_events
     where not (
       expires_date > purchase_date
       and transaction_signed_date >= purchase_date - interval '25 hours'
       and renewal_signed_date >= purchase_date - interval '25 hours'
       and notification_signed_date >=
           transaction_signed_date - interval '5 minutes'
       and notification_signed_date >=
           renewal_signed_date - interval '5 minutes'
     )
  ) then
    raise exception 'Existing rows violate the new date rules: stop and re-audit';
  end if;
end;
$preflight$;

select 'verified_renewal_preflight_passed' as result;
