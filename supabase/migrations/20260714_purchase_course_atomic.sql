-- Verified against the linked X5 project on 2026-07-14:
--   public.courses.id              uuid
--   public.courses.price           integer nullable
--   public.profiles.id             uuid
--   public.profiles.credits        integer nullable
--   public.profiles.purchased_course_ids text[] nullable
-- The public API accepts text to match existing clients, then validates and
-- converts it to uuid before touching any row.

create or replace function public.purchase_course(p_course_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  buyer_id uuid := auth.uid();
  requested_course_id uuid;
  current_credits integer;
  purchased_ids text[];
  course_price integer;
  course_is_free boolean;
  course_is_public boolean;
begin
  if buyer_id is null then
    return jsonb_build_object(
      'status', 'not_authenticated',
      'course_id', coalesce(p_course_id, ''),
      'credits_remaining', null
    );
  end if;

  begin
    requested_course_id := nullif(btrim(p_course_id), '')::uuid;
  exception
    when invalid_text_representation then
      return jsonb_build_object(
        'status', 'course_unavailable',
        'course_id', coalesce(p_course_id, ''),
        'credits_remaining', null
      );
  end;

  if requested_course_id is null then
    return jsonb_build_object(
      'status', 'course_unavailable',
      'course_id', coalesce(p_course_id, ''),
      'credits_remaining', null
    );
  end if;

  -- Serialize purchases for this buyer. This makes the ownership check and
  -- balance deduction idempotent even when two requests arrive together.
  select coalesce(p.credits, 0), coalesce(p.purchased_course_ids, array[]::text[])
    into current_credits, purchased_ids
    from public.profiles as p
   where p.id = buyer_id
   for update;

  if not found then
    return jsonb_build_object(
      'status', 'profile_unavailable',
      'course_id', requested_course_id::text,
      'credits_remaining', null
    );
  end if;

  -- A retry after a successful purchase must succeed without another charge,
  -- even if the course was hidden between the two requests.
  if requested_course_id::text = any(purchased_ids) then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits
    );
  end if;

  select greatest(coalesce(c.price, 0), 0),
         coalesce(c.is_free, false),
         coalesce(c.is_public, false)
    into course_price, course_is_free, course_is_public
    from public.courses as c
   where c.id = requested_course_id
   for share;

  if not found or not course_is_public then
    return jsonb_build_object(
      'status', 'course_unavailable',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits
    );
  end if;

  -- Free courses are already unlocked by CourseAccessPolicy and never charge.
  if course_is_free or course_price = 0 then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits
    );
  end if;

  if current_credits < course_price then
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits
    );
  end if;

  update public.profiles as p
     set credits = current_credits - course_price,
         purchased_course_ids = array_append(purchased_ids, requested_course_id::text)
   where p.id = buyer_id;

  return jsonb_build_object(
    'status', 'purchased',
    'course_id', requested_course_id::text,
    'credits_remaining', current_credits - course_price
  );
end;
$$;

comment on function public.purchase_course(text) is
  'Atomically purchases a public course for auth.uid() using profile credits.';

revoke execute on function public.purchase_course(text) from public, anon, authenticated;
grant execute on function public.purchase_course(text) to authenticated;
