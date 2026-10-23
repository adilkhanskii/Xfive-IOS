-- Keep the iOS course editor server-side gate in sync with the app UI.
-- Adilkhan's profile nickname is adilkhan_marketing, but access is granted by
-- immutable auth user id and auth email rather than editable profile fields.

create or replace function public.is_x5_developer()
returns boolean
language sql
stable
security invoker
set search_path to ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'adilkhanskii@gmail.com',
    'tuakov.ursa@gmail.com',
    'tuakov.ursa@icloud.com',
    'tooyakov.icloud@gmail.com',
    'tooyakov@icloud.com',
    'tooyakov.art@gmail.com',
    'h-a-n-1@mail.ru'
  )
  or coalesce((auth.uid())::text, '') in (
    'eee55a08-18d1-46e3-a303-1411d1bb9333',
    '9ae99a45-91ac-486a-b7ec-e6614b7bc257',
    '496071cf-7c5b-43e8-886e-9f43c4618f90'
  );
$$;

create or replace function public.x5_is_developer()
returns boolean
language sql
stable
as $$
  select public.is_x5_developer();
$$;

do $$
begin
  if to_regclass('public.courses') is not null then
    execute 'grant select, insert, update, delete on public.courses to authenticated';

    execute 'drop policy if exists "courses developer select" on public.courses';
    execute 'create policy "courses developer select" on public.courses for select to authenticated using (public.x5_is_developer())';

    execute 'drop policy if exists "courses developer insert" on public.courses';
    execute 'create policy "courses developer insert" on public.courses for insert to authenticated with check (public.x5_is_developer())';

    execute 'drop policy if exists "courses developer update" on public.courses';
    execute 'create policy "courses developer update" on public.courses for update to authenticated using (public.x5_is_developer()) with check (public.x5_is_developer())';

    execute 'drop policy if exists "courses developer delete" on public.courses';
    execute 'create policy "courses developer delete" on public.courses for delete to authenticated using (public.x5_is_developer())';
  end if;
end $$;

insert into storage.buckets (id, name, public)
values
  ('course-covers', 'course-covers', true),
  ('videos', 'videos', true)
on conflict (id) do update
set public = excluded.public;

drop policy if exists "course covers developer insert" on storage.objects;
create policy "course covers developer insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'course-covers' and public.is_x5_developer());

drop policy if exists "course covers developer update" on storage.objects;
create policy "course covers developer update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'course-covers' and public.is_x5_developer())
  with check (bucket_id = 'course-covers' and public.is_x5_developer());

drop policy if exists "course covers developer delete" on storage.objects;
create policy "course covers developer delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'course-covers' and public.is_x5_developer());

drop policy if exists "course covers public read" on storage.objects;
create policy "course covers public read"
  on storage.objects for select
  to public
  using (bucket_id = 'course-covers');

drop policy if exists "course lesson videos developer insert" on storage.objects;
create policy "course lesson videos developer insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'videos' and name like 'courses/%' and public.is_x5_developer());

drop policy if exists "course lesson videos developer update" on storage.objects;
create policy "course lesson videos developer update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'videos' and name like 'courses/%' and public.is_x5_developer())
  with check (bucket_id = 'videos' and name like 'courses/%' and public.is_x5_developer());

drop policy if exists "course lesson videos developer delete" on storage.objects;
create policy "course lesson videos developer delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'videos' and name like 'courses/%' and public.is_x5_developer());

drop policy if exists "course lesson videos public read" on storage.objects;
create policy "course lesson videos public read"
  on storage.objects for select
  to public
  using (bucket_id = 'videos' and name like 'courses/%');
