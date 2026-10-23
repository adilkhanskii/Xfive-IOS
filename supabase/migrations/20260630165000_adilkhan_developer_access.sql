create or replace function public.x5_is_developer()
returns boolean
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'tuakov.ursa@gmail.com',
    'tooyakov.art@gmail.com',
    'tooyakov.icloud@gmail.com',
    'tooyakov@icloud.com',
    'tuakov.ursa@icloud.com'
  )
  or coalesce((auth.uid())::text, '') in (
    'eee55a08-18d1-46e3-a303-1411d1bb9333',
    '9ae99a45-91ac-486a-b7ec-e6614b7bc257',
    '496071cf-7c5b-43e8-886e-9f43c4618f90'
  );
$$;

do $$
begin
  if to_regclass('public.courses') is not null then
    execute 'grant select, insert, update, delete on public.courses to authenticated';

    execute 'drop policy if exists "courses developer insert" on public.courses';
    execute 'create policy "courses developer insert" on public.courses for insert to authenticated with check (public.x5_is_developer())';

    execute 'drop policy if exists "courses developer update" on public.courses';
    execute 'create policy "courses developer update" on public.courses for update to authenticated using (public.x5_is_developer()) with check (public.x5_is_developer())';

    execute 'drop policy if exists "courses developer delete" on public.courses';
    execute 'create policy "courses developer delete" on public.courses for delete to authenticated using (public.x5_is_developer())';
  end if;
end $$;
