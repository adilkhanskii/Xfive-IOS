-- Fail closed for portfolio media. Existing public-form URL strings remain
-- canonical object identifiers, but the bucket itself becomes private and
-- upgraded clients must obtain a signed URL. Pending, rejected and orphaned
-- objects can no longer be downloaded through their old public URL.

update storage.buckets
   set public = false
 where id = 'portfolio';

create or replace function public.x5_portfolio_object_is_referenced(
  p_name text
)
returns boolean
language sql
security definer
set search_path = ''
stable
as $function$
  select exists (
    select 1
      from public.portfolio_items as item
     where (
       coalesce(auth.jwt() ->> 'role', '') = 'service_role'
       or session_user = 'postgres'
       or (storage.foldername(p_name))[1] = (select auth.uid())::text
     )
       and (
         item.media_url = any(array[
       'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || p_name,
       'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || p_name
         ])
         or item.thumbnail_url = any(array[
          'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || p_name,
          'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || p_name
         ])
       )
  );
$function$;

create or replace function public.x5_portfolio_object_is_approved(
  p_name text
)
returns boolean
language sql
security definer
set search_path = ''
stable
as $function$
  select exists (
    select 1
      from public.portfolio_items as item
     where item.moderation_status = 'approved'
       and (
         item.media_url = any(array[
           'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || p_name,
           'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || p_name
         ])
         or item.thumbnail_url = any(array[
           'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || p_name,
           'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || p_name
         ])
       )
  );
$function$;

revoke all on function public.x5_portfolio_object_is_referenced(text)
  from public, anon, authenticated, service_role;
revoke all on function public.x5_portfolio_object_is_approved(text)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_portfolio_object_is_referenced(text)
  to authenticated, service_role;
grant execute on function public.x5_portfolio_object_is_approved(text)
  to anon, authenticated, service_role;

drop policy if exists "x5 storage public read" on storage.objects;
create policy "x5 storage public read"
on storage.objects for select
to public
using (bucket_id = any (array['course-covers', 'avatars']));

drop policy if exists "portfolio_media_owner_or_approved_select"
  on storage.objects;
create policy "portfolio_media_owner_or_approved_select"
on storage.objects for select
to anon, authenticated
using (
  bucket_id = 'portfolio'
  and (
    (
      (select auth.uid()) is not null
      and (storage.foldername(name))[1] = (select auth.uid())::text
    )
    or public.x5_portfolio_object_is_approved(name)
  )
);

-- Preserve avatar behavior from the immediately preceding chat migration and
-- restrict portfolio uploads to the installed UUID/timestamp filename layout.
drop policy if exists "x5 storage authenticated write" on storage.objects;
create policy "x5 storage authenticated write"
on storage.objects for insert
to authenticated
with check (
  (
    bucket_id = 'avatars'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and pg_catalog.cardinality(storage.foldername(name)) in (1, 2)
    and (
      pg_catalog.cardinality(storage.foldername(name)) = 1
      or (storage.foldername(name))[2] = 'thumbnails'
    )
    and storage.filename(name) ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$'
    and name not like '%..%'
    and name not like '%//%'
    and name not like '%\\%'
  )
);

drop policy if exists "x5 storage authenticated update" on storage.objects;
create policy "x5 storage authenticated update"
on storage.objects for update
to authenticated
using (
  bucket_id = 'avatars'
  and owner_id = (select auth.uid())::text
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'avatars'
  and owner_id = (select auth.uid())::text
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "x5 storage authenticated delete own" on storage.objects;
create policy "x5 storage authenticated delete own"
on storage.objects for delete
to authenticated
using (
  (
    bucket_id = 'avatars'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  or (
    bucket_id = 'portfolio'
    and owner_id = (select auth.uid())::text
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and not public.x5_portfolio_object_is_referenced(name)
  )
);

-- Return only names; object deletion still goes through the Storage API so
-- metadata and provider bytes remain consistent. Rejected-only references are
-- cleaned immediately; abandoned uploads/row deletions receive a 24-hour grace
-- period. Any approved or pending reference prevents deletion.
create or replace function public.x5_list_portfolio_cleanup_paths(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_paths jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    return jsonb_build_object('status', 'invalid_request', 'paths', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(candidate.name order by candidate.created_at), '[]'::jsonb)
    into v_paths
    from (
      select object.name, object.created_at
        from storage.objects as object
       where object.bucket_id = 'portfolio'
         and not exists (
           select 1
             from public.portfolio_items as item
            where item.moderation_status <> 'rejected'
              and (
                item.media_url = any(array[
                  'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || object.name,
                  'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || object.name
                ])
                or item.thumbnail_url = any(array[
                  'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || object.name,
                  'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || object.name
                ])
              )
         )
         and (
           object.created_at < clock_timestamp() - interval '24 hours'
           or exists (
             select 1
               from public.portfolio_items as rejected
              where rejected.moderation_status = 'rejected'
                and (
                  rejected.media_url = any(array[
                    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || object.name,
                    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || object.name
                  ])
                  or rejected.thumbnail_url = any(array[
                    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/portfolio/' || object.name,
                    'https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/portfolio/' || object.name
                  ])
                )
           )
         )
       order by object.created_at
       limit p_limit
    ) as candidate;

  return jsonb_build_object('status', 'ok', 'paths', v_paths);
end;
$function$;

revoke all on function public.x5_list_portfolio_cleanup_paths(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.x5_list_portfolio_cleanup_paths(integer)
  to service_role;
