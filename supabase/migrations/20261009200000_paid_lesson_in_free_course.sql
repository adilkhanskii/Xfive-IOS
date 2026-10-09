-- Платный урок в бесплатном курсе (Адильхан 09.10, «урок сделал платным — с другого аккаунта открывается»).
-- Было: цена курса 0 → сервер отдавал видео ЛЮБОГО урока, а покупка урока отвечала «уже твоё» без списания.
-- Стало: урок с sellSeparately + цена > 0 + не превью закрыт, пока его не купили (или весь курс),
-- и purchase_lesson его продаёт. Автор и разработчик видят всё, как раньше.
-- Совместимость: старые сборки покажут урок открытым, но видео не выдастся (403 not_entitled) — деньги защищены.

create or replace function public.x5_lesson_is_sold_separately(p_lesson jsonb)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select coalesce(
    p_lesson -> 'sellSeparately' = 'true'::jsonb
    and coalesce(p_lesson -> 'isFreePreview', 'false'::jsonb) <> 'true'::jsonb
    and jsonb_typeof(p_lesson -> 'price') = 'number'
    and (p_lesson ->> 'price')::numeric > 0,
    false
  );
$$;

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
      p_course_id::text = any(coalesce(v_purchased_courses, array[]::text[]))
      or (p_course_id::text || ':' || p_lesson_id)
         = any(coalesce(v_purchased_lessons, array[]::text[]))
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

  return jsonb_build_object(
    'status', 'purchased',
    'course_id', requested_course_id::text,
    'lesson_id', requested_lesson_id,
    'lesson_key', lesson_key,
    'credits_remaining', current_credits - lesson_price,
    'lesson_price', lesson_price,
    'charged_amount', lesson_price
  );
end;
$function$;

-- идея: доступ на 30 дней (запрос Адильхана 19:01) — отдельная таблица lesson_unlocks(expires_at), это новая функция.
