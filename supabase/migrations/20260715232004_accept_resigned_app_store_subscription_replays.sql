begin;

-- Preserve the original, fully validated grant engine behind a private name.
-- The stable internal entry point below adds compatibility for Apple re-signing
-- the exact same transaction with a newer signedDate. All validation still
-- runs in the original engine before this wrapper handles its replay conflict.
alter function public.x5_apply_verified_app_store_transaction_production_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
)
rename to x5_apply_verified_app_store_transaction_signed_date_strict_internal;

alter function public.x5_apply_verified_app_store_transaction_signed_date_strict_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) owner to postgres;

revoke execute on function public.x5_apply_verified_app_store_transaction_signed_date_strict_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create function public.x5_apply_verified_app_store_transaction_production_internal(
  p_user_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_app_account_token uuid,
  p_purchase_date timestamptz,
  p_expires_date timestamptz,
  p_signed_date timestamptz,
  p_revocation_date timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_transaction_id text := nullif(btrim(p_transaction_id), '');
  v_original_transaction_id text := nullif(btrim(p_original_transaction_id), '');
  v_product_id text := nullif(btrim(p_product_id), '');
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'sandbox' then 'Sandbox'
    when 'production' then 'Production'
    else null
  end;
  v_existing public.app_store_transactions%rowtype;
  v_error_message text;
begin
  begin
    return public.x5_apply_verified_app_store_transaction_signed_date_strict_internal(
      p_user_id,
      p_transaction_id,
      p_original_transaction_id,
      p_product_id,
      p_environment,
      p_app_account_token,
      p_purchase_date,
      p_expires_date,
      p_signed_date,
      p_revocation_date
    );
  exception when sqlstate '22023' then
    get stacked diagnostics v_error_message = message_text;
    if v_error_message <> 'transaction_id_conflict' then
      raise;
    end if;
  end;

  -- The strict engine has already validated the profile, product, dates,
  -- environment, revocation state, and account-token rules. Its only obsolete
  -- replay predicate is signed_date. Re-read the immutable ledger tuple and
  -- ignore exactly that one field; the original signed date remains unchanged.
  select *
    into v_existing
    from public.app_store_transactions
   where transaction_id = v_transaction_id
   for update;

  if not found
     or v_existing.user_id <> p_user_id
     or v_existing.original_transaction_id <> v_original_transaction_id
     or v_existing.product_id <> v_product_id
     or v_existing.environment <> v_environment
     or v_existing.app_account_token is distinct from p_app_account_token
     or v_existing.purchase_date <> p_purchase_date
     or v_existing.expires_date <> p_expires_date then
    raise exception using errcode = '22023', message = 'transaction_id_conflict';
  end if;

  return jsonb_build_object(
    'status', 'already_applied',
    'credits_granted', v_existing.credits_granted,
    'subscription_end_date', v_existing.expires_date,
    'is_verified', v_existing.is_verified_product
  );
end;
$function$;

comment on function public.x5_apply_verified_app_store_transaction_production_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) is
  'Private production subscription grant engine. Exact Apple transaction replays may carry a newer signedDate; every immutable identity and entitlement field remains strict.';

alter function public.x5_apply_verified_app_store_transaction_production_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) owner to postgres;

revoke execute on function public.x5_apply_verified_app_store_transaction_production_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

-- These are immutable audit/ownership ledgers to API roles. The narrowly
-- required owner timestamp/binding updates continue only inside postgres-owned
-- SECURITY DEFINER functions with an empty search_path.
alter table public.app_store_transactions owner to postgres;
alter table public.app_store_entitlement_owners owner to postgres;
alter table public.app_store_legacy_bindings owner to postgres;

revoke all privileges on table public.app_store_transactions
  from service_role;
grant select, insert on table public.app_store_transactions
  to service_role;

revoke all privileges on table public.app_store_entitlement_owners
  from service_role;
grant select, insert on table public.app_store_entitlement_owners
  to service_role;

revoke all privileges on table public.app_store_legacy_bindings
  from service_role;
grant select, insert on table public.app_store_legacy_bindings
  to service_role;

commit;
