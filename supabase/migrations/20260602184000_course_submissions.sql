create table if not exists public.course_submissions (
  id uuid primary key default gen_random_uuid(),
  author_id text not null default (auth.uid())::text,
  author_name text,
  author_email text,
  title text not null,
  description text default '',
  contact text,
  video_url text,
  marketing_hook text default '',
  cover_url text default '',
  price numeric default 0,
  categories jsonb default '[]'::jsonb,
  is_public boolean default true,
  is_free boolean default false,
  course_language text default 'ru',
  status text default 'pending',
  admin_comment text,
  reviewed_by text,
  reviewed_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.course_submissions
  add column if not exists contact text,
  add column if not exists video_url text;

create index if not exists course_submissions_created_at_idx
  on public.course_submissions (created_at desc);

create index if not exists course_submissions_author_id_idx
  on public.course_submissions (author_id);

alter table public.course_submissions enable row level security;

grant select, insert, update on public.course_submissions to authenticated;

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
  );
$$;

drop policy if exists "course submissions owner insert" on public.course_submissions;
create policy "course submissions owner insert"
  on public.course_submissions for insert
  to authenticated
  with check (author_id = (auth.uid())::text);

drop policy if exists "course submissions owner read" on public.course_submissions;
create policy "course submissions owner read"
  on public.course_submissions for select
  to authenticated
  using (author_id = (auth.uid())::text or public.x5_is_developer());

drop policy if exists "course submissions developer update" on public.course_submissions;
create policy "course submissions developer update"
  on public.course_submissions for update
  to authenticated
  using (public.x5_is_developer())
  with check (public.x5_is_developer());

insert into storage.buckets (id, name, public)
values ('videos', 'videos', true)
on conflict (id) do nothing;

drop policy if exists "course submission videos authenticated upload" on storage.objects;
create policy "course submission videos authenticated upload"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'videos' and name like 'course-submissions/%');

drop policy if exists "course submission videos authenticated update" on storage.objects;
create policy "course submission videos authenticated update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'videos' and name like 'course-submissions/%')
  with check (bucket_id = 'videos' and name like 'course-submissions/%');

drop policy if exists "course submission videos public read" on storage.objects;
create policy "course submission videos public read"
  on storage.objects for select
  to public
  using (bucket_id = 'videos' and name like 'course-submissions/%');
