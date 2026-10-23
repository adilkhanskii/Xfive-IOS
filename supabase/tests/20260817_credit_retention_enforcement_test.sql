begin;

select set_config(
  'x5.credit_retention_test_user',
  (select id::text from public.profiles order by id limit 1),
  true
);

do $fixture_required$
begin
  if nullif(
       current_setting('x5.credit_retention_test_user', true),
       ''
     ) is null then
    raise exception 'credit_retention_profile_fixture_required';
  end if;
end;
$fixture_required$;

do $credit_retention_contract$
declare
  v_uid uuid := current_setting('x5.credit_retention_test_user')::uuid;
  v_profile public.profiles%rowtype;
begin
  update public.profiles
     set credits = 0,
         permanent_credits = 0,
         permanent_credit_debt = 0,
         is_verified = false,
         verified_until = null,
         credits_expires_at = null,
         credits_retention_months = 1
   where id = v_uid;

  perform pg_catalog.set_config(
    'x5.permanent_credit_grant_user',
    v_uid::text,
    true
  );
  update public.profiles set credits = 100 where id = v_uid;
  perform pg_catalog.set_config('x5.permanent_credit_grant_user', '', true);

  -- Add an expiring balance above the purchased permanent floor.
  update public.profiles set credits = 200 where id = v_uid;
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.permanent_credits <> 100
     or v_profile.credits_retention_months <> 1
     or v_profile.credits_expires_at not between
          now() + interval '27 days' and now() + interval '32 days' then
    raise exception 'regular_credit_retention_is_not_one_month';
  end if;

  -- Buying/activating the badge extends the timed balance to three months.
  update public.profiles
     set is_verified = true,
         verified_until = now() + interval '1 month'
   where id = v_uid;
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.credits_retention_months <> 3
     or v_profile.credits_expires_at not between
          now() + interval '89 days' and now() + interval '93 days' then
    raise exception 'verified_credit_retention_is_not_three_months';
  end if;

  -- Simulate verified_until passing without an UPDATE. The scheduled worker
  -- must downgrade the row and cap the remaining window at one month.
  update public.profiles
     set verified_until = now() - interval '1 minute'
   where id = v_uid;
  update public.profiles
     set credits_retention_months = 3,
         credits_expires_at = now() + interval '2 months'
   where id = v_uid;
  perform public.x5_expire_old_credits();
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.credits_retention_months <> 1
     or v_profile.credits_expires_at > now() + interval '1 month 1 minute' then
    raise exception 'expired_badge_did_not_downgrade_retention';
  end if;

  -- Missing deadlines are repaired once instead of creating immortal credits.
  update public.profiles set credits_expires_at = null where id = v_uid;
  perform public.x5_expire_old_credits();
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.credits_expires_at not between
       now() + interval '27 days' and now() + interval '32 days' then
    raise exception 'missing_credit_deadline_was_not_repaired';
  end if;

  -- On expiry only the timed part burns; the purchased floor remains.
  update public.profiles
     set credits_expires_at = now() - interval '1 minute'
   where id = v_uid;
  perform public.x5_expire_old_credits();
  select * into v_profile from public.profiles where id = v_uid;
  if v_profile.credits <> 100
     or v_profile.permanent_credits <> 100
     or v_profile.credits_expires_at is not null then
    raise exception 'credit_expiry_erased_permanent_pack';
  end if;
end;
$credit_retention_contract$;

rollback;
