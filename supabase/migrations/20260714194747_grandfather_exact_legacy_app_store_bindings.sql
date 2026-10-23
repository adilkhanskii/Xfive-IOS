begin;

alter table public.iap_entitlements
  add column if not exists legacy_app_account_token uuid;

create table if not exists public.app_store_legacy_bindings (
  original_transaction_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  app_account_token uuid not null,
  product_id text not null,
  legacy_credited_at timestamptz not null,
  legacy_subscription_end_date timestamptz,
  legacy_created_at timestamptz,
  bound_at timestamptz,
  created_at timestamptz not null default now(),
  constraint app_store_legacy_bindings_original_nonempty
    check (btrim(original_transaction_id) <> ''),
  constraint app_store_legacy_bindings_known_product
    check (product_id in (
      'com.x5studio.app.lite.monthly',
      'com.x5studio.app.pro.monthly',
      'com.x5studio.app.max.monthly',
      'com.x5studio.app.verified.monthly'
    )),
  constraint app_store_legacy_bindings_exact_tuple_unique
    unique (original_transaction_id, user_id, app_account_token, product_id)
);

alter table public.app_store_legacy_bindings enable row level security;
alter table public.app_store_legacy_bindings force row level security;
revoke all on table public.app_store_legacy_bindings
  from public, anon, authenticated;
grant select, insert, update, delete on table public.app_store_legacy_bindings
  to service_role;

create or replace function public.apply_verified_app_store_transaction(
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
  v_effective_token uuid := p_app_account_token;
  v_binding public.app_store_legacy_bindings%rowtype;
  v_result jsonb;
begin
  if v_environment is null then
    raise exception using errcode = '22023', message = 'invalid_environment';
  end if;
  if v_environment <> 'Production' then
    raise exception using errcode = '22023', message = 'sandbox_not_allowed';
  end if;

  if p_app_account_token is not null
     and p_app_account_token <> p_user_id then
    select *
      into v_binding
      from public.app_store_legacy_bindings
     where original_transaction_id = nullif(btrim(p_original_transaction_id), '')
     for update;

    if not found then
      raise exception using errcode = '22023', message = 'account_token_mismatch';
    end if;
    if v_binding.user_id <> p_user_id then
      raise exception using errcode = '22023', message = 'owned_by_other';
    end if;
    if v_binding.app_account_token <> p_app_account_token
       or v_binding.product_id <> nullif(btrim(p_product_id), '') then
      raise exception using errcode = '22023', message = 'account_token_mismatch';
    end if;

    perform 1
      from public.iap_entitlements as legacy
     where legacy.original_transaction_id = v_binding.original_transaction_id
       and legacy.user_id = v_binding.user_id
       and legacy.product_id = v_binding.product_id
       and lower(coalesce(legacy.platform, '')) = 'ios'
       and legacy.credited_at is not distinct from v_binding.legacy_credited_at
       and legacy.subscription_end_date is not distinct from
           v_binding.legacy_subscription_end_date
       and legacy.created_at is not distinct from v_binding.legacy_created_at
       and coalesce(
         legacy.legacy_app_account_token,
         legacy.app_account_token
       ) = v_binding.app_account_token
     for update;

    if not found then
      raise exception using errcode = '22023', message = 'legacy_binding_mismatch';
    end if;

    -- Preserve the old random token only in the private allowlist/legacy audit
    -- column. The existing exact-once engine then uses its narrowly tested
    -- nil-token legacy path and cannot generalize this exception to new users.
    update public.iap_entitlements
       set legacy_app_account_token = coalesce(
             legacy_app_account_token,
             app_account_token
           ),
           app_account_token = null
     where original_transaction_id = v_binding.original_transaction_id
       and user_id = v_binding.user_id
       and product_id = v_binding.product_id
       and lower(coalesce(platform, '')) = 'ios';

    v_effective_token := null;
  end if;

  v_result := public.x5_apply_verified_app_store_transaction_production_internal(
    p_user_id,
    p_transaction_id,
    p_original_transaction_id,
    p_product_id,
    v_environment,
    v_effective_token,
    p_purchase_date,
    p_expires_date,
    p_signed_date,
    p_revocation_date
  );

  if p_app_account_token is not null
     and p_app_account_token <> p_user_id then
    update public.app_store_legacy_bindings
       set bound_at = coalesce(bound_at, now())
     where original_transaction_id = v_binding.original_transaction_id;
  end if;

  return v_result;
end;
$function$;

comment on table public.app_store_legacy_bindings is
  'Private exact tuple allowlist for the two pre-verification iOS chains. A row never grants by itself; a genuine matching Apple JWS is required for lazy binding.';

revoke execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function public.apply_verified_app_store_transaction(
  uuid, text, text, text, text, uuid,
  timestamptz, timestamptz, timestamptz, timestamptz
) to service_role;

commit;
