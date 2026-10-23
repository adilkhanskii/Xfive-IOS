-- Enforce the credit retention contract continuously:
--   * active verified badge: timed credits live for three months;
--   * no active verified badge: timed credits live for one month;
--   * purchased one-time packs remain in permanent_credits and never expire.
--
-- The function is already called by pg_cron every fifteen minutes. Besides
-- expiring due balances, it now repairs missing deadlines and notices a badge
-- that expired naturally without a profile update.
create or replace function public.x5_expire_old_credits()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  expired integer;
begin
  -- A newly active badge normally goes through the profile trigger. This also
  -- repairs imported or legacy rows whose stored retention mode drifted.
  update public.profiles as profile
     set credits_retention_months = 3,
         credits_expires_at = case
           when coalesce(profile.credits, 0) >
                greatest(coalesce(profile.permanent_credits, 0), 0)
             then now() + interval '3 months'
           else null
         end
   where public.x5_profile_has_active_verified_badge(
           profile.is_verified,
           profile.verified_until
         )
     and profile.credits_retention_months is distinct from 3;

  -- verified_until can pass without an UPDATE event. Detect that transition
  -- here and give the remaining timed balance one final regular-month window.
  update public.profiles as profile
     set credits_retention_months = 1,
         credits_expires_at = case
           when coalesce(profile.credits, 0) >
                greatest(coalesce(profile.permanent_credits, 0), 0)
             then least(
               coalesce(profile.credits_expires_at, now() + interval '1 month'),
               now() + interval '1 month'
             )
           else null
         end
   where not public.x5_profile_has_active_verified_badge(
               profile.is_verified,
               profile.verified_until
             )
     and profile.credits_retention_months is distinct from 1;

  -- Fail closed for any future legacy/import path that creates timed credits
  -- without a deadline. The row is repaired once, so the deadline never slides.
  update public.profiles as profile
     set credits_retention_months = case
           when public.x5_profile_has_active_verified_badge(
                  profile.is_verified,
                  profile.verified_until
                ) then 3
           else 1
         end,
         credits_expires_at = now() + make_interval(
           months => case
             when public.x5_profile_has_active_verified_badge(
                    profile.is_verified,
                    profile.verified_until
                  ) then 3
             else 1
           end
         )
   where coalesce(profile.credits, 0) >
         greatest(coalesce(profile.permanent_credits, 0), 0)
     and profile.credits_expires_at is null;

  update public.profiles as profile
     set credits = greatest(coalesce(profile.permanent_credits, 0), 0),
         credits_expires_at = null
   where coalesce(profile.credits, 0) >
         greatest(coalesce(profile.permanent_credits, 0), 0)
     and profile.credits_expires_at <= now();

  get diagnostics expired = row_count;
  return expired;
end;
$function$;

revoke execute on function public.x5_expire_old_credits()
  from public, anon, authenticated, service_role;

-- Legacy untimed balances predate the retention trigger. Active verified users
-- receive a fresh three-month window; regular legacy balances are dated from
-- profile creation and are expired immediately when their month has passed.
update public.profiles as profile
   set credits_retention_months = case
         when public.x5_profile_has_active_verified_badge(
                profile.is_verified,
                profile.verified_until
              ) then 3
         else 1
       end,
       credits_expires_at = case
         when public.x5_profile_has_active_verified_badge(
                profile.is_verified,
                profile.verified_until
              ) then now() + interval '3 months'
         else profile.created_at + interval '1 month'
       end
 where coalesce(profile.credits, 0) >
       greatest(coalesce(profile.permanent_credits, 0), 0)
   and profile.credits_expires_at is null;

select public.x5_expire_old_credits();
