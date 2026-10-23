begin;

alter table public.app_store_transactions
  drop constraint if exists app_store_transactions_known_environment;

alter table public.app_store_transactions
  add constraint app_store_transactions_production_environment
  check (environment = 'Production');

alter function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
)
rename to x5_apply_verified_app_store_transaction_production_internal;

revoke execute on function public.x5_apply_verified_app_store_transaction_production_internal(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated, service_role;

create function public.apply_verified_app_store_transaction(
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
  v_environment text := case lower(btrim(coalesce(p_environment, '')))
    when 'sandbox' then 'Sandbox'
    when 'production' then 'Production'
    else null
  end;
begin
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;

  -- This database contains spendable production credits. Free Sandbox and
  -- TestFlight renewals belong in a separate staging project.
  if v_environment <> 'Production' then
    raise exception using errcode = '22023', message = 'sandbox_not_allowed';
  end if;

  return public.x5_apply_verified_app_store_transaction_production_internal(
    p_user_id,
    p_transaction_id,
    p_original_transaction_id,
    p_product_id,
    v_environment,
    p_app_account_token,
    p_purchase_date,
    p_expires_date,
    p_signed_date,
    p_revocation_date
  );
end;
$function$;

comment on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) is
  'Production-only entry point for one server-verified App Store JWS transaction. Service role only; Sandbox must use a separate staging project.';

revoke execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated;

grant execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

commit;
