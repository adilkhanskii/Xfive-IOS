-- Repair legacy course rows where author_name contains a profile nickname but
-- author_id points at a different profile. A nickname must be non-empty and
-- unique case-insensitively before it is safe to use as an identity hint.
--
-- This intentionally contains no account or course IDs. Once repaired, the
-- linked profile matches the canonical author display and a repeat run is a
-- no-op.

begin;

-- Freeze nickname aliases for the short duration of this one-time repair.
-- Without this lock, another transaction could create a duplicate nickname
-- after the uniqueness CTE has read profiles but before the UPDATE commits.
lock table public.profiles in share mode;

with unique_nicknames as (
  select lower(btrim(p.nickname)) as normalized_nickname
  from public.profiles as p
  where nullif(btrim(p.nickname), '') is not null
  group by lower(btrim(p.nickname))
  having count(*) = 1
),
repair_candidates as (
  select
    c.id as course_id,
    c.author_id as current_author_id,
    c.author_name as current_author_name,
    matched_profile.id as profile_id,
    coalesce(
      nullif(btrim(matched_profile.name), ''),
      nullif(btrim(matched_profile.nickname), '')
    ) as canonical_author_name
  from public.courses as c
  join unique_nicknames
    on lower(btrim(c.author_name)) = unique_nicknames.normalized_nickname
  join public.profiles as matched_profile
    on lower(btrim(matched_profile.nickname)) =
       unique_nicknames.normalized_nickname
  left join public.profiles as current_profile
    on current_profile.id = c.author_id
  where nullif(btrim(c.author_name), '') is not null
    and (
      current_profile.id is null
      or not (
        coalesce(
          lower(btrim(c.author_name)) =
          lower(btrim(current_profile.name)),
          false
        )
        or coalesce(
          lower(btrim(c.author_name)) =
          lower(btrim(current_profile.nickname)),
          false
        )
      )
    )
)
update public.courses as c
set
  author_id = repair.profile_id,
  author_name = repair.canonical_author_name
from repair_candidates as repair
where c.id = repair.course_id
  -- Do not overwrite an editor's concurrent correction.
  and c.author_id is not distinct from repair.current_author_id
  and c.author_name is not distinct from repair.current_author_name
  and (
    c.author_id is distinct from repair.profile_id
    or c.author_name is distinct from repair.canonical_author_name
  );

commit;
