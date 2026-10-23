-- PostgREST exposes current JWT claims through request.jwt.claims/auth.jwt().
-- The legacy request.jwt.claim.role GUC is empty, so the privileged generation
-- accounting RPCs rejected valid service-role calls with 403.
--
-- Keep this patch idempotent: fresh databases already receive the corrected
-- definitions from the original migration, while production is upgraded in
-- place without changing function signatures or grants.
do $migration$
declare
  v_signature regprocedure;
  v_definition text;
  v_patched integer := 0;
begin
  foreach v_signature in array array[
    'public.claim_image_generation_request(uuid,text,text,boolean,integer,text)'::regprocedure,
    'public.complete_image_generation_request(uuid,text,text,integer,text,jsonb)'::regprocedure,
    'public.get_image_generation_request(uuid,text,text,integer,text)'::regprocedure,
    'public.fail_image_generation_request(uuid,text,text,integer,text,text)'::regprocedure
  ]
  loop
    v_definition := pg_get_functiondef(v_signature);

    if v_definition like '%request.jwt.claim.role%' then
      v_definition := replace(
        v_definition,
        'coalesce(current_setting(''request.jwt.claim.role'', true), '''') <>',
        'coalesce(auth.jwt() ->> ''role'', '''') <>'
      );

      if v_definition like '%request.jwt.claim.role%' then
        raise exception
          'unexpected_generation_service_role_guard:%',
          v_signature;
      end if;

      execute v_definition;
      v_patched := v_patched + 1;
    elsif v_definition not like '%auth.jwt() ->> ''role''%' then
      raise exception
        'unexpected_generation_service_role_guard:%',
        v_signature;
    end if;
  end loop;

  if v_patched not in (0, 4) then
    raise exception
      'unexpected_generation_service_role_guard_patch_count:%',
      v_patched;
  end if;
end
$migration$;
