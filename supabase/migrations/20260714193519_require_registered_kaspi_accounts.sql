begin;

drop policy if exists buyer_insert_kaspi on public.kaspi_payments;
create policy buyer_insert_kaspi
on public.kaspi_payments
for insert
to authenticated
with check (
  coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) is false
  and buyer_id = (select auth.uid())
  and buyer_id <> author_id
  and status = 'pending'
  and reviewed_at is null
  and author_note is null
  and nullif(btrim(lesson_id), '') is null
  and exists (
    select 1
      from public.courses as course
     where course.id::text = kaspi_payments.course_id
       and course.author_id = kaspi_payments.author_id
       and course.is_public is true
       and course.is_free is false
       and course.price = kaspi_payments.amount_kzt
       and course.price > 0
  )
);

drop policy if exists see_own_kaspi on public.kaspi_payments;
create policy see_own_kaspi
on public.kaspi_payments
for select
to authenticated
using (
  coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) is false
  and (
    buyer_id = (select auth.uid())
    or author_id = (select auth.uid())
  )
);

create or replace function public.approve_kaspi_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_payment public.kaspi_payments%rowtype;
  v_course public.courses%rowtype;
  v_updated integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'registered_account_required');
  end if;

  select *
    into v_payment
    from public.kaspi_payments
   where id = p_payment_id
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_payment.author_id <> v_uid then
    return jsonb_build_object('ok', false, 'error', 'not_author');
  end if;
  if v_payment.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'already_reviewed');
  end if;
  if v_payment.buyer_id = v_payment.author_id
     or nullif(btrim(v_payment.lesson_id), '') is not null then
    return jsonb_build_object('ok', false, 'error', 'invalid_payment_details');
  end if;

  select *
    into v_course
    from public.courses
   where id::text = v_payment.course_id;

  if not found
     or v_course.author_id is distinct from v_payment.author_id
     or v_course.is_public is not true
     or v_course.is_free is not false
     or v_course.price is distinct from v_payment.amount_kzt
     or coalesce(v_course.price, 0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_payment_details');
  end if;

  update public.profiles
     set purchased_course_ids = (
       select array_agg(distinct item)
         from unnest(
           array_append(
             coalesce(purchased_course_ids, array[]::text[]),
             v_payment.course_id
           )
         ) as item
     )
   where id = v_payment.buyer_id;
  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    return jsonb_build_object('ok', false, 'error', 'buyer_profile_missing');
  end if;

  update public.kaspi_payments
     set status = 'approved',
         reviewed_at = now()
   where id = p_payment_id;

  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.reject_kaspi_payment(
  p_payment_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'registered_account_required');
  end if;

  update public.kaspi_payments
     set status = 'rejected',
         author_note = left(p_note, 2000),
         reviewed_at = now()
   where id = p_payment_id
     and author_id = v_uid
     and status = 'pending';

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found_or_not_author');
  end if;

  return jsonb_build_object('ok', true);
end;
$function$;

commit;
