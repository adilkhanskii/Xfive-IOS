begin;

-- Read the exact incident rows, assert the repaired shape, and prove that the
-- repair predicates would update zero rows if run again. This validator never
-- discovers rows by a display title and never appends another module.
do $repair_validation$
declare
  v_target_id constant uuid := '892fc2d1-f521-48a2-800f-a90eb9e1a852'::uuid;
  v_source_id constant uuid := '4ca8d4bd-69bb-420b-81b3-bad8bd0737e1'::uuid;
  v_duplicate_ids constant uuid[] := array[
    '4ca8d4bd-69bb-420b-81b3-bad8bd0737e1'::uuid,
    '8f4bf6b8-885a-4824-b91e-1d64921512fc'::uuid,
    'c02ca43f-6e45-42e7-b500-85fb7e4d0230'::uuid
  ];
  v_recovered_module_id constant text := 'mod_1780406663282_0';
  v_existing_module_id constant text := 'cat_1773850477057';
  v_categories jsonb;
  v_source_categories jsonb;
  v_source_module jsonb;
  v_desired jsonb;
  v_author text;
  v_changed integer;
  v_count integer;
begin
  select categories, author_name
  into v_categories, v_author
  from public.courses
  where id = v_target_id
  for update;

  if not found then
    raise exception 'target_course_missing:%', v_target_id;
  end if;
  if v_author is distinct from 'DOPAMINE' then
    raise exception 'unexpected_target_author:%', v_author;
  end if;
  if jsonb_array_length(coalesce(v_categories, '[]'::jsonb)) <> 2
     or v_categories -> 0 ->> 'id' <> v_recovered_module_id
     or v_categories -> 0 ->> 'order' <> '1'
     or v_categories -> 1 ->> 'id' <> v_existing_module_id
     or v_categories -> 1 ->> 'order' <> '2' then
    raise exception 'target_is_not_in_repaired_module_order';
  end if;

  select categories
  into v_source_categories
  from public.courses
  where id = v_source_id
  for update;
  if not found then
    raise exception 'recovery_source_missing:%', v_source_id;
  end if;

  select count(*), (jsonb_agg(category) -> 0)
  into v_count, v_source_module
  from jsonb_array_elements(coalesce(v_source_categories, '[]'::jsonb)) as category
  where category ->> 'id' = v_recovered_module_id;
  if v_count <> 1 or v_source_module is null then
    raise exception 'exact_recovery_module_missing:%:%', v_source_id, v_recovered_module_id;
  end if;
  -- A later editor save may legitimately retain old lesson-commerce metadata
  -- or omit an empty videoUrl field. Compare the content-bearing hierarchy
  -- instead of requiring byte-for-byte equality with the hidden incident row.
  if (v_categories -> 0) - 'order' - 'days'
     is distinct from v_source_module - 'order' - 'days' then
    raise exception 'recovered_module_root_differs_from_incident_source';
  end if;

  select count(*)
  into v_count
  from (
    (
      select
        day ->> 'id' as day_id,
        day ->> 'title' as day_title,
        day ->> 'order' as day_order
      from jsonb_array_elements(coalesce(v_source_module -> 'days', '[]'::jsonb)) as day
      except
      select
        day ->> 'id',
        day ->> 'title',
        day ->> 'order'
      from jsonb_array_elements(coalesce(v_categories -> 0 -> 'days', '[]'::jsonb)) as day
    )
    union all
    (
      select
        day ->> 'id',
        day ->> 'title',
        day ->> 'order'
      from jsonb_array_elements(coalesce(v_categories -> 0 -> 'days', '[]'::jsonb)) as day
      except
      select
        day ->> 'id',
        day ->> 'title',
        day ->> 'order'
      from jsonb_array_elements(coalesce(v_source_module -> 'days', '[]'::jsonb)) as day
    )
  ) as day_diff;
  if v_count <> 0 then
    raise exception 'recovered_module_day_hierarchy_differs:%', v_count;
  end if;

  select count(*)
  into v_count
  from (
    (
      select
        day ->> 'id' as day_id,
        lesson ->> 'id' as lesson_id,
        lesson ->> 'title' as lesson_title,
        lesson ->> 'order' as lesson_order,
        lesson ->> 'duration' as lesson_duration,
        lesson ->> 'isFreePreview' as free_preview,
        nullif(btrim(coalesce(lesson ->> 'videoUrl', '')), '') as real_video_url
      from jsonb_array_elements(coalesce(v_source_module -> 'days', '[]'::jsonb)) as day
      cross join lateral jsonb_array_elements(coalesce(day -> 'lessons', '[]'::jsonb)) as lesson
      except
      select
        day ->> 'id',
        lesson ->> 'id',
        lesson ->> 'title',
        lesson ->> 'order',
        lesson ->> 'duration',
        lesson ->> 'isFreePreview',
        nullif(btrim(coalesce(lesson ->> 'videoUrl', '')), '')
      from jsonb_array_elements(coalesce(v_categories -> 0 -> 'days', '[]'::jsonb)) as day
      cross join lateral jsonb_array_elements(coalesce(day -> 'lessons', '[]'::jsonb)) as lesson
    )
    union all
    (
      select
        day ->> 'id',
        lesson ->> 'id',
        lesson ->> 'title',
        lesson ->> 'order',
        lesson ->> 'duration',
        lesson ->> 'isFreePreview',
        nullif(btrim(coalesce(lesson ->> 'videoUrl', '')), '')
      from jsonb_array_elements(coalesce(v_categories -> 0 -> 'days', '[]'::jsonb)) as day
      cross join lateral jsonb_array_elements(coalesce(day -> 'lessons', '[]'::jsonb)) as lesson
      except
      select
        day ->> 'id',
        lesson ->> 'id',
        lesson ->> 'title',
        lesson ->> 'order',
        lesson ->> 'duration',
        lesson ->> 'isFreePreview',
        nullif(btrim(coalesce(lesson ->> 'videoUrl', '')), '')
      from jsonb_array_elements(coalesce(v_source_module -> 'days', '[]'::jsonb)) as day
      cross join lateral jsonb_array_elements(coalesce(day -> 'lessons', '[]'::jsonb)) as lesson
    )
  ) as lesson_diff;
  if v_count <> 0 then
    raise exception 'recovered_module_lesson_hierarchy_differs:%', v_count;
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_categories -> 1 -> 'days') as day
    cross join lateral jsonb_array_elements(coalesce(day -> 'lessons', '[]'::jsonb)) as lesson
    where nullif(lesson ->> 'videoUrl', '') is not null
  ) then
    raise exception 'existing_module_video_missing';
  end if;

  select count(*)
  into v_count
  from public.courses
  where id = any(v_duplicate_ids);
  if v_count <> cardinality(v_duplicate_ids) then
    raise exception 'incident_duplicate_set_incomplete:expected=%,actual=%', cardinality(v_duplicate_ids), v_count;
  end if;

  select count(*)
  into v_count
  from public.courses
  where id = any(v_duplicate_ids)
    and is_public is false;
  if v_count <> cardinality(v_duplicate_ids) then
    raise exception 'incident_duplicates_not_all_hidden:expected=%,actual=%', cardinality(v_duplicate_ids), v_count;
  end if;

  v_desired := jsonb_build_array(
    jsonb_set(v_categories -> 0, '{order}', '1'::jsonb, true),
    jsonb_set(v_categories -> 1, '{order}', '2'::jsonb, true)
  );
  if v_desired is distinct from v_categories then
    raise exception 'repair_is_not_idempotent_for_target';
  end if;

  update public.courses
  set categories = v_desired,
      updated_at = now()
  where id = v_target_id
    and categories is distinct from v_desired;
  get diagnostics v_changed = row_count;
  if v_changed <> 0 then
    raise exception 'idempotence_probe_changed_target:%', v_changed;
  end if;

  update public.courses
  set is_public = false,
      updated_at = now()
  where id = any(v_duplicate_ids)
    and is_public is distinct from false;
  get diagnostics v_changed = row_count;
  if v_changed <> 0 then
    raise exception 'idempotence_probe_changed_duplicates:%', v_changed;
  end if;
end;
$repair_validation$;

rollback;

select 'validated_repaired_state_and_idempotence_with_rollback' as status;
