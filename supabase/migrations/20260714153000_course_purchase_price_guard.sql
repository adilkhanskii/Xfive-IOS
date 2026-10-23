-- Prevent a course purchase from charging more than the price the user
-- confirmed in the UI. The profile row and course row stay locked until the
-- ownership grant and balance deduction complete.

begin;

drop function if exists public.purchase_course(text);

create or replace function public.purchase_course(
  p_course_id text,
  p_expected_price integer
)
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
      'credits_remaining', null,
      'course_price', null,
      'charged_amount', 0
    );
  end if;

  begin
    requested_course_id := nullif(btrim(p_course_id), '')::uuid;
  exception
    when invalid_text_representation then
      return jsonb_build_object(
        'status', 'course_unavailable',
        'course_id', coalesce(p_course_id, ''),
        'credits_remaining', null,
        'course_price', null,
        'charged_amount', 0
      );
  end;

  if requested_course_id is null then
    return jsonb_build_object(
      'status', 'course_unavailable',
      'course_id', coalesce(p_course_id, ''),
      'credits_remaining', null,
      'course_price', null,
      'charged_amount', 0
    );
  end if;

  select coalesce(p.credits, 0), coalesce(p.purchased_course_ids, array[]::text[])
    into current_credits, purchased_ids
    from public.profiles as p
   where p.id = buyer_id
   for update;

  if not found then
    return jsonb_build_object(
      'status', 'profile_unavailable',
      'course_id', requested_course_id::text,
      'credits_remaining', null,
      'course_price', null,
      'charged_amount', 0
    );
  end if;

  if requested_course_id::text = any(purchased_ids) then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits,
      'course_price', null,
      'charged_amount', 0
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
      'credits_remaining', current_credits,
      'course_price', null,
      'charged_amount', 0
    );
  end if;

  if course_is_free or course_price = 0 then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits,
      'course_price', course_price,
      'charged_amount', 0
    );
  end if;

  if p_expected_price is null or p_expected_price < 0 or p_expected_price <> course_price then
    return jsonb_build_object(
      'status', 'price_changed',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits,
      'course_price', course_price,
      'charged_amount', 0
    );
  end if;

  if current_credits < course_price then
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'course_id', requested_course_id::text,
      'credits_remaining', current_credits,
      'course_price', course_price,
      'charged_amount', 0
    );
  end if;

  update public.profiles as p
     set credits = current_credits - course_price,
         purchased_course_ids = array_append(purchased_ids, requested_course_id::text)
   where p.id = buyer_id;

  return jsonb_build_object(
    'status', 'purchased',
    'course_id', requested_course_id::text,
    'credits_remaining', current_credits - course_price,
    'course_price', course_price,
    'charged_amount', course_price
  );
end;
$$;

comment on function public.purchase_course(text, integer) is
  'Atomically purchases a public course at the exact user-confirmed price.';

revoke execute on function public.purchase_course(text, integer) from public, anon, authenticated;
grant execute on function public.purchase_course(text, integer) to authenticated;

commit;
