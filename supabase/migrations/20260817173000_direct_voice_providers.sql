-- Direct official voice providers. Legacy Fal manifests remain readable so
-- already completed jobs and delayed callbacks continue to replay safely.

create or replace function public.x5_voice_result_manifest_valid(
  p_manifest jsonb,
  p_expected_path text
)
returns boolean
language sql
immutable
set search_path = ''
as $function$
  select p_manifest is not null
    and jsonb_typeof(p_manifest) = 'object'
    and p_manifest ?& array['version', 'provider', 'model', 'object']::text[]
    and p_manifest - array['version', 'provider', 'model', 'object']::text[] = '{}'::jsonb
    and p_manifest ->> 'version' = '1'
    and (
      (p_manifest ->> 'provider' = 'fal'
        and p_manifest ->> 'model' = 'fal-ai/elevenlabs/tts/eleven-v3')
      or (p_manifest ->> 'provider' = 'minimax'
        and p_manifest ->> 'model' = 'speech-2.8-turbo')
      or (p_manifest ->> 'provider' = 'elevenlabs'
        and p_manifest ->> 'model' = 'eleven_v3')
    )
    and jsonb_typeof(p_manifest -> 'object') = 'object'
    and (p_manifest -> 'object') ?& array['path', 'mimeType', 'sha256']::text[]
    and (p_manifest -> 'object') - array['path', 'mimeType', 'sha256']::text[] = '{}'::jsonb
    and p_manifest #>> '{object,path}' = p_expected_path
    and p_manifest #>> '{object,mimeType}' = 'audio/mpeg'
    and p_manifest #>> '{object,sha256}' ~ '^[0-9a-f]{64}$';
$function$;

revoke all on function public.x5_voice_result_manifest_valid(jsonb, text)
  from public, anon, authenticated;
grant execute on function public.x5_voice_result_manifest_valid(jsonb, text)
  to service_role;

create or replace function public.complete_voice_generation_request(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_attempt integer,
  p_claim_token text,
  p_result_manifest jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_expected_path text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select ledger.* into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if request.request_fingerprint <> p_request_fingerprint then
    return jsonb_build_object('status', 'idempotency_conflict');
  end if;
  if p_attempt is null
     or p_claim_token is null
     or p_claim_token !~ '^[A-Za-z0-9_-]{32,200}$'
     or request.attempt <> p_attempt
     or request.claim_token_hash <> pg_catalog.encode(
       pg_catalog.sha256(pg_catalog.convert_to(p_claim_token, 'UTF8')),
       'hex'
     ) then
    return jsonb_build_object('status', 'stale_attempt', 'attempt', request.attempt);
  end if;

  v_expected_path := p_user_id::text || '/explicit/' ||
    split_part(request.request_key, ':', 2) || '/' ||
    request.attempt::text || '/audio.mp3';
  if not public.x5_voice_result_manifest_valid(
    p_result_manifest, v_expected_path
  ) then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;

  if request.status = 'succeeded' then
    if request.result_manifest = p_result_manifest then
      return jsonb_build_object(
        'status', 'already_completed',
        'attempt', request.attempt,
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
    return jsonb_build_object('status', 'completion_conflict');
  end if;
  if request.status <> 'processing' then
    return jsonb_build_object('status', 'not_processing');
  end if;

  update public.voice_generation_requests as ledger
     set status = 'succeeded',
         result_manifest = p_result_manifest,
         error_code = null,
         updated_at = now(),
         completed_at = now(),
         refunded_at = null
   where ledger.id = request.id
  returning ledger.* into request;

  return jsonb_build_object(
    'status', 'completed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', request.result_manifest
  );
end;
$function$;

create or replace function public.complete_voice_generation_by_provider(
  p_user_id uuid,
  p_request_key text,
  p_request_fingerprint text,
  p_provider_request_id text,
  p_result_manifest jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  request public.voice_generation_requests%rowtype;
  v_expected_path text;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  select ledger.* into request
    from public.voice_generation_requests as ledger
   where ledger.user_id = p_user_id
     and ledger.request_key = p_request_key
   for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if exists (
    select 1 from public.account_deletion_jobs as deletion
     where deletion.user_id = request.user_id
       and deletion.status <> 'completed'
  ) then
    return jsonb_build_object('status', 'account_deleting');
  end if;
  if request.request_fingerprint <> p_request_fingerprint
     or request.provider_request_id is distinct from p_provider_request_id then
    return jsonb_build_object('status', 'provider_request_conflict');
  end if;

  v_expected_path := p_user_id::text || '/explicit/' ||
    split_part(request.request_key, ':', 2) || '/' ||
    request.attempt::text || '/audio.mp3';
  if not public.x5_voice_result_manifest_valid(
    p_result_manifest, v_expected_path
  ) then
    return jsonb_build_object('status', 'invalid_result_manifest');
  end if;

  if request.status = 'succeeded' then
    if request.result_manifest = p_result_manifest then
      return jsonb_build_object(
        'status', 'already_completed',
        'credits_remaining', request.credits_after_debit,
        'result_manifest', request.result_manifest
      );
    end if;
    return jsonb_build_object('status', 'completion_conflict');
  end if;
  if request.status = 'refunded' then
    return jsonb_build_object('status', 'already_refunded');
  end if;

  update public.voice_generation_requests as ledger
     set status = 'succeeded',
         result_manifest = p_result_manifest,
         error_code = null,
         updated_at = now(),
         completed_at = now(),
         refunded_at = null
   where ledger.id = request.id;
  return jsonb_build_object(
    'status', 'completed',
    'attempt', request.attempt,
    'credits_remaining', request.credits_after_debit,
    'result_manifest', p_result_manifest
  );
end;
$function$;
