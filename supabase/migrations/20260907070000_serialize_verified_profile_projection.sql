-- Preserve a concurrently renewed badge when the reconciliation job runs.
-- No prices, ledger rows, entitlements or user balances are changed by this migration.
begin;

create or replace function public.x5_rebuild_app_store_verified_profile(
  p_user_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_verified_until timestamptz;
  v_grace_until timestamptz;
begin
  -- Lock before reading sources: a concurrent renewal/refund may have updated
  -- the ledger while we waited. The subsequent SELECT gets a fresh snapshot.
  perform 1 from public.profiles where id = p_user_id for update;
  if not found then return null; end if;
  v_now := clock_timestamp();

  select max(active_entitlement.expires_date)
    into v_verified_until
    from (
      select production.expires_date
        from public.app_store_transactions as production
       where production.user_id = p_user_id
         and production.product_id = 'com.x5studio.app.verified.monthly'
         and production.is_verified_product
          and production.credits_granted = 0
          and production.expires_date > v_now
          and public.x5_app_store_lifecycle_transaction_allows_entitlement(
            'Production', production.transaction_id
          )
         and not public.x5_app_store_notification_refund_active(
           'Production', production.transaction_id
         )
      union all
      select sandbox.expires_date
        from public.app_store_sandbox_review_transactions as sandbox
       where sandbox.user_id = p_user_id
         and sandbox.product_id = 'com.x5studio.app.verified.monthly'
         and sandbox.is_verified_product
          and sandbox.credits_granted = 0
          and sandbox.expires_date > v_now
          and public.x5_app_store_lifecycle_transaction_allows_entitlement(
            'Sandbox', sandbox.transaction_id
          )
         and not public.x5_app_store_notification_refund_active(
           'Sandbox', sandbox.transaction_id
         )
      union all
      select coalesce(android.expires_at, android.subscription_end_date)
        from public.iap_entitlements as android
       where android.user_id = p_user_id
         and lower(coalesce(android.platform, '')) = 'android'
         and android.product_id in (
           'x5_verified_monthly_v2', 'x5_verified_monthly'
         )
         and android.purchase_type = 'subscription'
         and android.purchase_token_hash is not null
         and btrim(android.purchase_token_hash) <> ''
         and android.claim_key is not null
         and btrim(android.claim_key) <> ''
         and android.app_account_token = android.user_id
         and coalesce(android.expires_at, android.subscription_end_date) > v_now
      union all
      select legacy_ios.subscription_end_date
        from public.iap_entitlements as legacy_ios
        join public.app_store_legacy_bindings as binding
          on binding.original_transaction_id =
             legacy_ios.original_transaction_id
         and binding.user_id = legacy_ios.user_id
         and binding.product_id = legacy_ios.product_id
         and binding.legacy_credited_at is not distinct from
             legacy_ios.credited_at
         and binding.legacy_subscription_end_date is not distinct from
             legacy_ios.subscription_end_date
         and binding.legacy_created_at is not distinct from
             legacy_ios.created_at
         and binding.app_account_token = coalesce(
           legacy_ios.legacy_app_account_token,
           legacy_ios.app_account_token,
           legacy_ios.user_id
         )
       where legacy_ios.user_id = p_user_id
         and lower(coalesce(legacy_ios.platform, '')) = 'ios'
         and legacy_ios.product_id = 'com.x5studio.app.verified.monthly'
         and legacy_ios.subscription_end_date > v_now
          and not exists (
           select 1
             from public.app_store_server_notification_state as refund_state
            where refund_state.environment = 'Production'
              and refund_state.user_id = legacy_ios.user_id
              and refund_state.product_id =
                  'com.x5studio.app.verified.monthly'
               and refund_state.original_transaction_id =
                   legacy_ios.original_transaction_id
               and refund_state.active
               and (
                 refund_state.transaction_id = legacy_ios.last_transaction_id
                 or refund_state.legacy_binding_used
               )
         )
         and not exists (
           select 1
             from public.app_store_transactions as migrated
            where migrated.original_transaction_id =
                  legacy_ios.original_transaction_id
              and migrated.user_id = legacy_ios.user_id
              and migrated.product_id =
                  'com.x5studio.app.verified.monthly'
         )
    ) as active_entitlement;

  v_grace_until := public.x5_active_app_store_grace_period(p_user_id);
  if v_grace_until is not null then
    v_verified_until := greatest(
      coalesce(v_verified_until, '-infinity'::timestamptz),
      v_grace_until
    );
  end if;

  update public.profiles
     set is_verified = v_verified_until is not null,
         verified_until = v_verified_until
   where id = p_user_id
     and (
       is_verified is distinct from (v_verified_until is not null)
       or verified_until is distinct from v_verified_until
     );

  return v_verified_until;
end;
$function$;

revoke execute on function public.x5_rebuild_app_store_verified_profile(uuid)
  from public, anon, authenticated, service_role;

commit;

