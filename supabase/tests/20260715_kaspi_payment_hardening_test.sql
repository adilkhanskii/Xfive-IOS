begin;

select set_config(
  'x5.test_kaspi_attacker_id',
  (
    select id::text
      from public.profiles
     where id <> (
       select author_id
         from public.courses
        where id = '892fc2d1-f521-48a2-800f-a90eb9e1a852'::uuid
     )
     order by id
     limit 1
  ),
  true
);

select set_config(
  'x5.test_kaspi_author_id',
  (
    select author_id::text
      from public.courses
     where id = '892fc2d1-f521-48a2-800f-a90eb9e1a852'::uuid
  ),
  true
);

do $setup$
begin
  if nullif(current_setting('x5.test_kaspi_attacker_id', true), '') is null then
    raise exception 'kaspi_test_attacker_not_found';
  end if;
  if nullif(current_setting('x5.test_kaspi_author_id', true), '') is null then
    raise exception 'kaspi_test_author_not_found';
  end if;

  update public.profiles
     set purchased_course_ids = array[]::text[]
   where id = current_setting('x5.test_kaspi_attacker_id')::uuid;

  delete from public.kaspi_payments
   where id in (
     '55555555-5555-4555-8555-555555555551'::uuid,
     '55555555-5555-4555-8555-555555555552'::uuid,
     '55555555-5555-4555-8555-555555555553'::uuid,
     '55555555-5555-4555-8555-555555555554'::uuid
   );

  -- Model a forged row that could have been created before the hardening
  -- migration. Approval must still validate it instead of trusting stored
  -- client fields.
  insert into public.kaspi_payments (
    id,
    buyer_id,
    author_id,
    course_id,
    amount_kzt,
    status
  ) values (
    '55555555-5555-4555-8555-555555555552'::uuid,
    current_setting('x5.test_kaspi_attacker_id')::uuid,
    current_setting('x5.test_kaspi_attacker_id')::uuid,
    '892fc2d1-f521-48a2-800f-a90eb9e1a852',
    1,
    'pending'
  );
end;
$setup$;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  current_setting('x5.test_kaspi_attacker_id'),
  true
);

do $authenticated_tests$
declare
  v_insert_rejected boolean := false;
  v_anonymous_insert_rejected boolean := false;
  v_response jsonb;
begin
  -- A buyer must not be able to name themselves as the course author and
  -- fabricate a pending payment for an arbitrary amount.
  begin
    insert into public.kaspi_payments (
      id,
      buyer_id,
      author_id,
      course_id,
      amount_kzt,
      status
    ) values (
      '55555555-5555-4555-8555-555555555551'::uuid,
      auth.uid(),
      auth.uid(),
      '892fc2d1-f521-48a2-800f-a90eb9e1a852',
      1,
      'pending'
    );
  exception
    when insufficient_privilege or check_violation then
      v_insert_rejected := true;
  end;

  if not v_insert_rejected then
    raise exception 'forged_kaspi_insert_was_accepted';
  end if;

  v_response := public.approve_kaspi_payment(
    '55555555-5555-4555-8555-555555555552'::uuid
  );

  if coalesce((v_response ->> 'ok')::boolean, false) then
    raise exception 'forged_legacy_kaspi_payment_was_approved:%', v_response;
  end if;

  if exists (
    select 1
      from public.profiles
     where id = auth.uid()
       and '892fc2d1-f521-48a2-800f-a90eb9e1a852' = any(
         coalesce(purchased_course_ids, array[]::text[])
       )
  ) then
    raise exception 'forged_kaspi_payment_granted_course';
  end if;

  if has_function_privilege(
    'anon',
    'public.approve_kaspi_payment(uuid)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.reject_kaspi_payment(uuid,text)',
    'execute'
  ) then
    raise exception 'kaspi_review_rpc_is_anon_callable';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', auth.uid()::text,
      'role', 'authenticated',
      'is_anonymous', true
    )::text,
    true
  );

  begin
    insert into public.kaspi_payments (
      id,
      buyer_id,
      author_id,
      course_id,
      amount_kzt,
      status
    ) values (
      '55555555-5555-4555-8555-555555555554'::uuid,
      current_setting('x5.test_kaspi_attacker_id')::uuid,
      current_setting('x5.test_kaspi_author_id')::uuid,
      '892fc2d1-f521-48a2-800f-a90eb9e1a852',
      50000,
      'pending'
    );
  exception
    when insufficient_privilege or check_violation then
      v_anonymous_insert_rejected := true;
  end;

  if not v_anonymous_insert_rejected then
    raise exception 'anonymous_kaspi_insert_was_accepted';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', current_setting('x5.test_kaspi_attacker_id'),
      'role', 'authenticated',
      'is_anonymous', false
    )::text,
    true
  );

  -- Keep the intended manual Kaspi flow working: the buyer can submit only
  -- the exact public course/author/price tuple.
  insert into public.kaspi_payments (
    id,
    buyer_id,
    author_id,
    course_id,
    course_title,
    amount_kzt,
    status
  ) values (
    '55555555-5555-4555-8555-555555555553'::uuid,
    auth.uid(),
    current_setting('x5.test_kaspi_author_id')::uuid,
    '892fc2d1-f521-48a2-800f-a90eb9e1a852',
    'Kaspi hardening test',
    50000,
    'pending'
  );
end;
$authenticated_tests$;

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  current_setting('x5.test_kaspi_author_id'),
  true
);

do $author_tests$
declare
  v_response jsonb;
begin
  v_response := public.approve_kaspi_payment(
    '55555555-5555-4555-8555-555555555553'::uuid
  );

  if not coalesce((v_response ->> 'ok')::boolean, false) then
    raise exception 'valid_kaspi_payment_was_not_approved:%', v_response;
  end if;

  if not exists (
    select 1
      from public.profiles
     where id = current_setting('x5.test_kaspi_attacker_id')::uuid
       and '892fc2d1-f521-48a2-800f-a90eb9e1a852' = any(
         coalesce(purchased_course_ids, array[]::text[])
       )
  ) then
    raise exception 'valid_kaspi_payment_did_not_grant_course';
  end if;
end;
$author_tests$;

reset role;
rollback;

select 'kaspi_payment_hardening_validated_with_rollback' as status;
