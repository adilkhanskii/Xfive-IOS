-- Озвучка: обычный тариф MiniMax 30 кредитов за начатую 1000 символов,
-- премиум ElevenLabs eleven_v3 — 150. Старые записи по 60 остаются валидными
-- (60 кратно 30), поэтому меняем только допустимый диапазон цены:
-- 30..750 и кратно 30 (5000 символов × 150 = 750).
-- Остальная логика claim_voice_generation_request — без изменений (копия из
-- 20260726223000_voice_generation_exact_once.sql, правка только проверки цены).

alter table public.voice_generation_requests
  drop constraint voice_generation_requests_cost_valid;

alter table public.voice_generation_requests
  add constraint voice_generation_requests_cost_valid check (
    cost_credits between 30 and 750
    and cost_credits % 30 = 0
    and permanent_credits_debited between 0 and cost_credits
    and permanent_credit_debt_at_claim >= 0
  );

create or replace function public.claim_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_cost_credits integer,
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_inserted boolean := false;
  v_credits integer;
  v_permanent_before integer;
  v_permanent_after integer;
  v_permanent_debited integer;
  v_debt_at_claim integer;
  v_expiry_before timestamptz;
  v_expiry_after timestamptz;
  v_claim_token_hash text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  if p_user_id is null
     or p_request_key is null
     or p_request_fingerprint is null
     or p_cost_credits is null
     or p_cost_credits not between 30 and 750
     or p_cost_credits % 30 <> 0
     or p_request_key !~ '^explicit:[0-9a-f]{64}$'
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$' then
    return jsonb_build_object('status', 'invalid_request');
  end if;

  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;

  v_claim_token_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
    'hex'
  );

  begin
    insert into public.voice_generation_requests as ledger (
      user_id,
      request_key,
      request_fingerprint,
      status,
      cost_credits,
      claim_token_hash
    )
    values (
      p_user_id,
      p_request_key,
      p_request_fingerprint,
      'processing',
      p_cost_credits,
      v_claim_token_hash
    )
    on conflict (user_id, request_key) do nothing
    returning ledger.* into request;
    v_inserted := found;
  exception when foreign_key_violation then
    return jsonb_build_object('status', 'profile_not_found');
  end;

  if not v_inserted then
    select ledger.*
      into request
      from public.voice_generation_requests as ledger
     where ledger.user_id = p_user_id
       and ledger.request_key = p_request_key
     for update;

    if not found then
      return jsonb_build_object('status', 'credit_service_unavailable');
    end if;
    if request.request_fingerprint <> p_request_fingerprint
       or request.cost_credits <> p_cost_credits then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    if request.status = 'processing' then
      return jsonb_build_object(
        'status', 'in_progress',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'provider_request_id', request.provider_request_id,
        'submission_ambiguous',
          request.submission_ambiguous_at is not null
      );
    end if;
    if request.status = 'succeeded' then
      return jsonb_build_object(
        'status', 'replay',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
  end if;

  select
    coalesce(profile.credits, 0),
    greatest(coalesce(profile.permanent_credits, 0), 0),
    greatest(coalesce(profile.permanent_credit_debt, 0), 0),
    profile.credits_expires_at
    into v_credits, v_permanent_before, v_debt_at_claim, v_expiry_before
    from public.profiles as profile
   where profile.id = p_user_id
   for update;
  if not found then
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object('status', 'profile_not_found');
  end if;

  if exists (
    select 1
      from public.account_deletion_jobs as deletion
     where deletion.user_id = p_user_id
       and deletion.status <> 'completed'
  ) then
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object('status', 'account_deleting');
  end if;

  if v_credits < p_cost_credits then
    if v_inserted then
      delete from public.voice_generation_requests as ledger
       where ledger.id = request.id;
    end if;
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'credits_remaining', v_credits
    );
  end if;

  update public.profiles as profile
     set credits = coalesce(profile.credits, 0) - p_cost_credits
   where profile.id = p_user_id
  returning
    profile.credits,
    profile.permanent_credits,
    profile.credits_expires_at
    into v_credits, v_permanent_after, v_expiry_after;

  v_permanent_debited := greatest(
    v_permanent_before - greatest(coalesce(v_permanent_after, 0), 0),
    0
  );

  if v_inserted then
    update public.voice_generation_requests as ledger
       set credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           updated_at = now()
     where ledger.id = request.id
    returning ledger.* into request;
  else
    update public.voice_generation_requests as ledger
       set status = 'processing',
           credits_after_debit = v_credits,
           permanent_credits_debited = v_permanent_debited,
           permanent_credit_debt_at_claim = v_debt_at_claim,
           credits_expires_at_before_debit = v_expiry_before,
           credits_expires_at_after_debit = v_expiry_after,
           claim_token_hash = v_claim_token_hash,
           attempt = request.attempt + 1,
           provider_request_id = null,
           provider_submitted_at = null,
           submission_ambiguous_at = null,
           submission_rejected_at = null,
           result_manifest = null,
           error_code = null,
           updated_at = now(),
           completed_at = null,
           refunded_at = null
     where ledger.id = request.id
    returning ledger.* into request;
  end if;

  return jsonb_build_object(
    'status', 'claimed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit
  );
end;
$function$;

revoke execute on function public.claim_voice_generation_request(
  uuid, text, text, integer, text
) from public, anon, authenticated, service_role;
grant execute on function public.claim_voice_generation_request(
  uuid, text, text, integer, text
) to service_role;
