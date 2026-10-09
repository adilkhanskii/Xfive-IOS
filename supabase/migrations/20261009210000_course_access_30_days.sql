-- Доступ на 30 дней (Адильхан 09.10 19:01, Диас 19:09 «иди исправляй»):
-- покупка урока или курса открывает доступ на 30 дней, потом снова замок; купить можно заново.
--
-- Как устроено (старые сборки продолжают работать):
--  * Ключи доступа остаются в profiles.purchased_course_ids / purchased_lesson_ids — их читают все сборки.
--  * Срок — в новой таблице course_access_expiry (user_id, access_key, expires_at).
--    Ключ без строки здесь = старая покупка или приглашение = навсегда.
--  * Сервер (course_video_playback_grant) не выдаёт видео по истёкшему ключу сразу, без ожидания.
--  * pg_cron раз в час убирает истёкшие ключи из profiles — тогда замок видят и старые сборки.
--  * Новые сборки читают course_access_expiry и пишут «открыто до …».

begin;

create table if not exists public.course_access_expiry (
  user_id uuid not null references public.profiles(id) on delete cascade,
  -- '<course_id>' — весь курс, '<course_id>:<lesson_id>' — один урок (как в profiles)
  access_key text not null check (char_length(access_key) between 1 and 300),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, access_key)
);

alter table public.course_access_expiry enable row level security;

drop policy if exists "course access expiry own read" on public.course_access_expiry;
create policy "course access expiry own read" on public.course_access_expiry
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Писать срок может только сервер (функции покупки), не приложение.
revoke all on public.course_access_expiry from anon, authenticated;
grant select on public.course_access_expiry to authenticated;

create or replace function public.x5_access_expired(p_user_id uuid, p_access_key text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.course_access_expiry as e
     where e.user_id = p_user_id
       and e.access_key = p_access_key
       and e.expires_at <= now()
  );
$$;

-- Срок доступа = сейчас + 30 дней. Повторная покупка продлевает от момента покупки.
create or replace function public.x5_set_access_expiry(p_user_id uuid, p_access_key text)
returns timestamptz
language sql
volatile
security definer
set search_path to ''
as $$
  insert into public.course_access_expiry as e (user_id, access_key, expires_at, updated_at)
  values (p_user_id, p_access_key, now() + interval '30 days', now())
  on conflict (user_id, access_key)
  do update set expires_at = excluded.expires_at, updated_at = now()
  returning e.expires_at;
$$;

-- Убирает истёкшие ключи из profiles (p_user_id null — у всех). Вызывают покупки и pg_cron.
create or replace function public.x5_purge_expired_access(p_user_id uuid default null)
returns integer
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_count integer := 0;
begin
  with expired as (
    delete from public.course_access_expiry as e
     where e.expires_at <= now()
       and (p_user_id is null or e.user_id = p_user_id)
    returning e.user_id, e.access_key
  ), per_user as (
    select x.user_id, array_agg(x.access_key) as keys from expired as x group by x.user_id
  )
  update public.profiles as p
     set purchased_course_ids = array(
           select k from unnest(coalesce(p.purchased_course_ids, array[]::text[])) as k
            where k <> all (u.keys)),
         purchased_lesson_ids = array(
           select k from unnest(coalesce(p.purchased_lesson_ids, array[]::text[])) as k
            where k <> all (u.keys))
    from per_user as u
   where p.id = u.user_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Вызываются только из функций покупки/выдачи (security definer) и pg_cron.
revoke execute on function public.x5_set_access_expiry(uuid, text) from public, anon, authenticated;
revoke execute on function public.x5_purge_expired_access(uuid) from public, anon, authenticated;
revoke execute on function public.x5_access_expired(uuid, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.course_video_playback_grant(p_user_id uuid, p_course_id uuid, p_lesson_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_course public.courses%rowtype;
  v_lesson jsonb;
  v_video_id uuid;
  v_asset public.course_video_assets%rowtype;
  v_purchased_courses text[] := array[]::text[];
  v_purchased_lessons text[] := array[]::text[];
  v_privileged boolean := false;
  v_entitled boolean := false;
begin
  if p_course_id is null
     or coalesce(p_lesson_id, '') !~ '^[A-Za-z0-9._:-]+$'
     or char_length(p_lesson_id) > 256 then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;

  select * into v_course from public.courses as c where c.id = p_course_id;
  if not found then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;
  v_lesson := public.x5_course_find_lesson(v_course.categories, p_lesson_id);
  if v_lesson is null then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;
  if v_lesson ->> 'videoProvider' is distinct from 'bunny'
     or coalesce(v_lesson ->> 'bunnyVideoId', '') !~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('status', 'not_bunny_lesson');
  end if;
  v_video_id := (v_lesson ->> 'bunnyVideoId')::uuid;

  -- Every boolean is coalesced: a NULL here must never mean "allowed".
  v_privileged := coalesce(p_user_id is not null and (
    public.x5_is_developer_user(p_user_id)
    or v_course.author_id = p_user_id
  ), false);

  if v_privileged is not true then
    if p_user_id is not null then
      select coalesce(p.purchased_course_ids, array[]::text[]),
             coalesce(p.purchased_lesson_ids, array[]::text[])
        into v_purchased_courses, v_purchased_lessons
        from public.profiles as p where p.id = p_user_id;
    end if;
    v_entitled := coalesce(
      -- bought access survives the course being hidden later
      -- купленный доступ действует 30 дней; старые покупки (без срока) — навсегда
      (p_course_id::text = any(coalesce(v_purchased_courses, array[]::text[]))
        and not public.x5_access_expired(p_user_id, p_course_id::text))
      or ((p_course_id::text || ':' || p_lesson_id)
         = any(coalesce(v_purchased_lessons, array[]::text[]))
        and not public.x5_access_expired(p_user_id, p_course_id::text || ':' || p_lesson_id))
      or (coalesce(v_course.is_public, false) and (
            coalesce(v_lesson -> 'isFreePreview' = 'true'::jsonb, false)
            -- Бесплатный курс открывает только НЕплатные уроки: урок, который автор
            -- продаёт отдельно, закрыт и в курсе с ценой 0 (баг Адильхана 09.10).
            or ((coalesce(v_course.is_free, false) or coalesce(v_course.price, 0) <= 0)
                and not public.x5_lesson_is_sold_separately(v_lesson))
         )),
      false
    );
    if v_entitled is not true then
      return jsonb_build_object(
        'status',
        case when p_user_id is null then 'not_authenticated'
             else 'not_entitled' end
      );
    end if;
  end if;

  select * into v_asset from public.course_video_assets as a
   where a.bunny_video_id = v_video_id;
  -- An editor cannot point a lesson at another course's video.
  if not found or v_asset.course_id <> p_course_id then
    return jsonb_build_object('status', 'lesson_unavailable');
  end if;

  return case v_asset.status
    when 'ready' then jsonb_build_object(
      'status', 'granted',
      'video_id', v_video_id,
      'length_seconds', v_asset.length_seconds,
      'thumbnail_file_name', v_asset.thumbnail_file_name
    )
    when 'failed' then jsonb_build_object('status', 'failed')
    when 'awaiting_upload' then jsonb_build_object('status', 'processing')
    when 'processing' then jsonb_build_object('status', 'processing')
    else jsonb_build_object('status', 'lesson_unavailable')
  end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_course(p_course_id text, p_expected_price integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  buyer_id uuid := auth.uid();
  requested_course_id uuid;
  current_credits integer;
  purchased_ids text[];
  course_price integer;
  course_is_free boolean;
  course_is_public boolean;
  v_expires_at timestamptz;
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

  -- Истёкший доступ (30 дней) сначала убираем, чтобы курс можно было купить заново.
  perform public.x5_purge_expired_access(buyer_id);

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

  -- Доступ к курсу — на 30 дней (Адильхан 09.10), потом снова замок.
  v_expires_at := public.x5_set_access_expiry(buyer_id, requested_course_id::text);

  return jsonb_build_object(
    'status', 'purchased',
    'course_id', requested_course_id::text,
    'credits_remaining', current_credits - course_price,
    'course_price', course_price,
    'charged_amount', course_price,
    'access_expires_at', v_expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_lesson(p_course_id text, p_lesson_id text, p_expected_price integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  buyer_id uuid := auth.uid();
  requested_course_id uuid;
  requested_lesson_id text := nullif(btrim(p_lesson_id), '');
  current_credits integer;
  purchased_course_ids text[];
  owned_lesson_ids text[];
  lesson_key text;
  course_price integer;
  course_is_free boolean;
  course_is_public boolean;
  course_categories jsonb;
  lesson jsonb;
  lesson_candidate jsonb;
  lesson_match_count integer := 0;
  lesson_price_numeric numeric;
  lesson_price integer;
  v_expires_at timestamptz;
begin
  if buyer_id is null then
    return jsonb_build_object(
      'status', 'not_authenticated',
      'course_id', coalesce(p_course_id, ''),
      'lesson_id', coalesce(p_lesson_id, ''),
      'lesson_key', '',
      'credits_remaining', null,
      'lesson_price', null,
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
        'lesson_id', coalesce(p_lesson_id, ''),
        'lesson_key', '',
        'credits_remaining', null,
        'lesson_price', null,
        'charged_amount', 0
      );
  end;

  if requested_course_id is null then
    return jsonb_build_object(
      'status', 'course_unavailable',
      'course_id', coalesce(p_course_id, ''),
      'lesson_id', coalesce(p_lesson_id, ''),
      'lesson_key', '',
      'credits_remaining', null,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  if requested_lesson_id is null or char_length(requested_lesson_id) > 256 then
    return jsonb_build_object(
      'status', 'lesson_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', coalesce(requested_lesson_id, ''),
      'lesson_key', '',
      'credits_remaining', null,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  lesson_key := requested_course_id::text || ':' || requested_lesson_id;

  -- Истёкший доступ (30 дней) сначала убираем, чтобы урок можно было купить заново.
  perform public.x5_purge_expired_access(buyer_id);

  select coalesce(p.credits, 0),
         coalesce(p.purchased_course_ids, array[]::text[]),
         coalesce(p.purchased_lesson_ids, array[]::text[])
    into current_credits, purchased_course_ids, owned_lesson_ids
    from public.profiles as p
   where p.id = buyer_id
   for update;

  if not found then
    return jsonb_build_object(
      'status', 'profile_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', null,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  if requested_course_id::text = any(purchased_course_ids)
     or lesson_key = any(owned_lesson_ids) then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  select greatest(coalesce(c.price, 0), 0),
         coalesce(c.is_free, false),
         coalesce(c.is_public, false),
         coalesce(c.categories, '[]'::jsonb)
    into course_price, course_is_free, course_is_public, course_categories
    from public.courses as c
   where c.id = requested_course_id
   for share;

  if not found or not course_is_public then
    return jsonb_build_object(
      'status', 'course_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  -- Бесплатный курс = «уже твоё» только для обычных уроков. Урок, проданный отдельно,
  -- покупается и в курсе с ценой 0 (раньше тут отвечали already_owned без списания).
  if (course_is_free or course_price = 0)
     and not public.x5_lesson_is_sold_separately(
       public.x5_course_find_lesson(course_categories, requested_lesson_id)
     ) then
    return jsonb_build_object(
      'status', 'already_owned',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', 0,
      'charged_amount', 0
    );
  end if;

  if jsonb_typeof(course_categories) <> 'array' then
    return jsonb_build_object(
      'status', 'lesson_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  for lesson_candidate in
    select lesson_item.value
      from jsonb_array_elements(course_categories) as category_item(value)
      cross join lateral jsonb_array_elements(
        case
          when jsonb_typeof(category_item.value -> 'days') = 'array'
            then category_item.value -> 'days'
          else '[]'::jsonb
        end
      ) as day_item(value)
      cross join lateral jsonb_array_elements(
        case
          when jsonb_typeof(day_item.value -> 'lessons') = 'array'
            then day_item.value -> 'lessons'
          else '[]'::jsonb
        end
      ) as lesson_item(value)
     where lesson_item.value ->> 'id' = requested_lesson_id
  loop
    lesson_match_count := lesson_match_count + 1;
    if lesson_match_count = 1 then
      lesson := lesson_candidate;
    end if;
  end loop;

  if lesson_match_count <> 1
     or lesson -> 'sellSeparately' is distinct from 'true'::jsonb
     or lesson -> 'isFreePreview' is distinct from 'false'::jsonb
     or jsonb_typeof(lesson -> 'price') <> 'number'
     or lesson ->> 'price' !~ '^[0-9]+$' then
    return jsonb_build_object(
      'status', 'lesson_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  lesson_price_numeric := (lesson ->> 'price')::numeric;

  if lesson_price_numeric <= 0 or lesson_price_numeric > 2147483647 then
    return jsonb_build_object(
      'status', 'lesson_unavailable',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', null,
      'charged_amount', 0
    );
  end if;

  lesson_price := lesson_price_numeric::integer;

  if p_expected_price is null or p_expected_price < 0 or p_expected_price <> lesson_price then
    return jsonb_build_object(
      'status', 'price_changed',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', lesson_price,
      'charged_amount', 0
    );
  end if;

  if current_credits < lesson_price then
    return jsonb_build_object(
      'status', 'insufficient_credits',
      'course_id', requested_course_id::text,
      'lesson_id', requested_lesson_id,
      'lesson_key', lesson_key,
      'credits_remaining', current_credits,
      'lesson_price', lesson_price,
      'charged_amount', 0
    );
  end if;

  update public.profiles as p
     set credits = current_credits - lesson_price,
         purchased_lesson_ids = array_append(owned_lesson_ids, lesson_key)
   where p.id = buyer_id;

  -- Доступ к уроку — на 30 дней (Адильхан 09.10), потом снова замок.
  v_expires_at := public.x5_set_access_expiry(buyer_id, lesson_key);

  return jsonb_build_object(
    'status', 'purchased',
    'course_id', requested_course_id::text,
    'lesson_id', requested_lesson_id,
    'lesson_key', lesson_key,
    'credits_remaining', current_credits - lesson_price,
    'lesson_price', lesson_price,
    'charged_amount', lesson_price,
    'access_expires_at', v_expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.approve_kaspi_payment(p_payment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  perform public.x5_purge_expired_access(v_payment.buyer_id);

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

  -- Оплата курса через Kaspi — тоже доступ на 30 дней.
  perform public.x5_set_access_expiry(v_payment.buyer_id, v_payment.course_id);

  update public.kaspi_payments
     set status = 'approved',
         reviewed_at = now()
   where id = p_payment_id;

  return jsonb_build_object('ok', true);
end;
$function$;

-- Раз в час (в :07) убираем истёкшие ключи у всех — чтобы замок увидели и старые сборки.
select cron.schedule(
  'x5-purge-expired-course-access',
  '7 * * * *',
  $cron$select public.x5_purge_expired_access(null)$cron$
);

commit;

-- идея: напоминание за 3 дня до конца доступа (push «доступ к уроку заканчивается»).
