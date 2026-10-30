// Проверка миграций пачки 30.10 на PGlite (Postgres в памяти, только синтетика).
// Запуск: в пустой папке npm i @electric-sql/pglite@0.2.17, затем node <этот файл> (пути MIG ниже — поправить на свой checkout).
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import assert from 'assert/strict';

const MIG = 'C:/Projects/clients/Marketologi/adilkhan/Apps/x5-worktrees/b30-ios/supabase/';
const A = fs.readFileSync(MIG + 'migrations/20261030180000_task_multi_location_category.sql', 'utf8');
const B = fs.readFileSync(MIG + 'migrations/20261030181000_signup_bonus_first_1000.sql', 'utf8');
const R = fs.readFileSync(MIG + 'rollback/20261030_batch30_rollback.sql', 'utf8');

const db = new PGlite();
const q = async (sql, p) => (await db.query(sql, p)).rows;

// --- заглушка схемы прода (структура, без данных) ---
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth; create schema supabase_migrations;
create table supabase_migrations.schema_migrations(version text primary key);
create table auth.users(id uuid primary key, email text, email_confirmed_at timestamptz,
  is_anonymous boolean default false, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select current_user::text $$;
grant usage on schema auth, public to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
create table public.profiles(id uuid primary key, credits integer default 0, permanent_credits integer default 0,
  plan text, is_verified boolean, verified_until timestamptz, show_in_hub boolean, is_public boolean,
  specialist_category text[], signup_number bigint);
grant select, insert, update on public.profiles to authenticated;
create function public.x5_protect_profile_entitlements() returns trigger language plpgsql set search_path to '' as $$
begin
  if current_user not in ('anon','authenticated') then return new; end if;
  if tg_op = 'INSERT' then new.credits := 0; new.permanent_credits := 0;
  else new.credits := old.credits; new.permanent_credits := old.permanent_credits; end if;
  return new;
end $$;
create trigger a_x5_protect_profile_entitlements before insert or update on public.profiles
  for each row execute function public.x5_protect_profile_entitlements();
create function public.is_x5_developer() returns boolean language sql stable set search_path to '' as $$
  select coalesce(auth.uid() = 'eee55a08-18d1-46e3-a303-1411d1bb9333'::uuid, false) $$;
create function public.x5_profile_has_active_verified_badge(b boolean, u timestamptz) returns boolean language sql stable as $$ select coalesce(b,false) $$;
create table public.social_notifications(recipient uuid, kind text, ref text);
create function public.x5_enqueue_social_notification(r uuid, a uuid, k text, t text, b text, rt text, rid text) returns void
  language sql as $$ insert into public.social_notifications values (r, k, rid) $$;
create table public.task_notification_queue(task_id uuid, recipient_id uuid, actor_id uuid, due_at timestamptz, primary key(task_id, recipient_id));
create function public.x5_task_matches_specialist(p_task_category text, p_specialist_categories text[]) returns boolean language sql stable as $$
  select p_task_category is null or p_task_category = '' or p_specialist_categories is null
      or cardinality(p_specialist_categories) = 0 or p_task_category = any(p_specialist_categories) $$;
create table public.tasks(id uuid primary key default gen_random_uuid(), author_id uuid, title text, category text,
  status text default 'open', created_at timestamptz default now(), country_code text, city text,
  constraint tasks_city_length check (city is null or char_length(btrim(city)) between 2 and 120) not valid,
  constraint tasks_country_code_format check (country_code is null or country_code ~ '^[A-Z]{2}$') not valid);
create function public.x5_notify_new_task_audience() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin return new; end $$;
create trigger tasks_priority_notify after insert on public.tasks for each row execute function public.x5_notify_new_task_audience();
grant select, insert, update on public.tasks to authenticated;
`);

const U = { author: '11111111-1111-1111-1111-111111111111', spec: '22222222-2222-2222-2222-222222222222', other: '33333333-3333-3333-3333-333333333333' };
await q(`insert into public.profiles(id, show_in_hub, is_public, is_verified, specialist_category) values
  ($1, true, true, false, null), ($2, true, true, true, array['smm']), ($3, true, true, false, array['seo'])`, [U.author, U.spec, U.other]);
// «старые» задания до миграции
await q(`insert into public.tasks(author_id, title, category, country_code, city) values
  ($1,'old1','smm','KZ','Astana'), ($1,'old2',null,null,null)`, [U.author]);

// --- миграция A ---
await db.exec(A);
let rows = await q(`select title, country_codes, cities, categories from public.tasks order by title`);
assert.deepEqual(rows[0], { title: 'old1', country_codes: ['KZ'], cities: ['Astana'], categories: ['smm'] });
assert.deepEqual(rows[1], { title: 'old2', country_codes: [], cities: [], categories: [] });

// новый клиент: несколько стран/городов/категорий
await q(`insert into public.tasks(author_id, title, country_codes, cities, categories) values
  ($1,'new-multi', array['kz',' RU','KZ'], array['Astana','Almaty','Astana'], array['seo','smm'])`, [U.author]);
rows = await q(`select country_code, city, category, country_codes, cities, categories from public.tasks where title='new-multi'`);
assert.deepEqual(rows[0], { country_code: 'KZ', city: 'Astana', category: 'seo', country_codes: ['KZ','RU'], cities: ['Astana','Almaty'], categories: ['seo','smm'] });
// уведомления: обе категории (smm у проверенного spec → сразу, seo у other → в очередь)

// «все страны / все города»
await q(`insert into public.tasks(author_id, title, country_codes, cities, categories) values ($1,'new-all', '{}', '{}', array['ugc'])`, [U.author]);
rows = await q(`select country_code, city, category from public.tasks where title='new-all'`);
assert.deepEqual(rows[0], { country_code: null, city: null, category: 'ugc' });

// старый клиент вставляет одиночные поля
await q(`insert into public.tasks(author_id, title, category, country_code, city) values ($1,'old-client','video','UZ','Tashkent')`, [U.author]);
rows = await q(`select country_codes, cities, categories from public.tasks where title='old-client'`);
assert.deepEqual(rows[0], { country_codes: ['UZ'], cities: ['Tashkent'], categories: ['video'] });

// старый клиент правит одиночное поле у мульти-задания → массив сворачивается
await q(`update public.tasks set city='Shymkent' where title='new-multi'`);
rows = await q(`select city, cities, country_codes from public.tasks where title='new-multi'`);
assert.deepEqual(rows[0], { city: 'Shymkent', cities: ['Shymkent'], country_codes: ['KZ','RU'] });
// новый клиент правит массив → одиночное поле следует
await q(`update public.tasks set categories=array['design','seo'] where title='new-multi'`);
rows = await q(`select category from public.tasks where title='new-multi'`);
assert.equal(rows[0].category, 'design');
// старый клиент шлёт весь объект без изменений одиночных полей → массивы не трогаются
await q(`update public.tasks set title='new-multi', category='design', country_code='KZ' where title='new-multi'`);
rows = await q(`select country_codes, categories from public.tasks where title='new-multi'`);
assert.deepEqual(rows[0], { country_codes: ['KZ','RU'], categories: ['design','seo'] });

// ограничения
await assert.rejects(q(`insert into public.tasks(author_id,title,country_codes) values ($1,'bad',array['KAZ'])`, [U.author]));
await assert.rejects(q(`insert into public.tasks(author_id,title,cities) values ($1,'bad',array['A'])`, [U.author]));

// уведомления по любой категории: задание seo+smm → spec (smm, проверенный) сразу, other (seo) в очередь
await db.exec(`delete from public.social_notifications; delete from public.task_notification_queue;`);
const t = await q(`insert into public.tasks(author_id, title, categories) values ($1,'notify', array['seo','smm']) returning id`, [U.author]);
assert.equal((await q(`select count(*)::int n from public.social_notifications where recipient=$1`, [U.spec]))[0].n, 1);
assert.equal((await q(`select count(*)::int n from public.task_notification_queue where recipient_id=$1`, [U.other]))[0].n, 1);
// фильтр ленты как у новых клиентов
rows = await q(`select title from public.tasks where (cardinality(country_codes)=0 or country_codes @> array['RU']) and categories && array['smm','design'] order by title`);
console.log('feed RU & smm|design:', rows.map(r => r.title).join(','));

// повторный запуск
await db.exec(A);
console.log('A ok (+rerun)');

// --- миграция B ---
// существующий пользователь (до включения бонуса)
await q(`insert into auth.users(id,email,email_confirmed_at,created_at) values ($1,'old@x.kz',now(),now()-interval '1 day')`, [U.other]);
await db.exec(B);
const claim = async (uid, device, platform = 'ios') => {
  await db.exec(`set test.uid = '${uid}'; set role authenticated;`);
  try { return (await q(`select public.claim_signup_bonus($1,$2) r`, [device, platform]))[0].r; }
  finally { await db.exec(`reset role;`); }
};
const N = (i) => `aaaaaaaa-0000-0000-0000-${String(i).padStart(12, '0')}`;
const addUser = async (i, email, confirmed = true, anon = false) => {
  await q(`insert into auth.users(id,email,email_confirmed_at,is_anonymous) values ($1,$2,$3,$4)`, [N(i), email, confirmed ? new Date() : null, anon]);
  await q(`insert into public.profiles(id) values ($1)`, [N(i)]);
};
assert.equal((await claim(U.other, 'device-old-0000001')).status, 'not_eligible', 'existing user');
await addUser(1, 'a@x.kz');
let r = await claim(N(1), 'ios-device-1-xxxxxxxx');
assert.equal(r.status, 'granted'); assert.equal(r.balance, 200); assert.equal(r.granted_count, 1);
assert.equal((await claim(N(1), 'ios-device-1-xxxxxxxx')).status, 'already_granted');
await addUser(2, 'b@x.kz');
assert.equal((await claim(N(2), 'ios-device-1-xxxxxxxx')).status, 'device_used');
assert.equal((await claim(N(2), 'ios-device-2-xxxxxxxx', 'web')).status, 'granted');
await addUser(3, 'c@x.kz', false);
assert.equal((await claim(N(3), 'ios-device-3-xxxxxxxx')).status, 'email_not_confirmed');
await addUser(4, null, true, true);
assert.equal((await claim(N(4), 'ios-device-4-xxxxxxxx')).status, 'not_eligible');
assert.equal((await claim(N(1), 'short')).status, 'invalid_device');
// удалил аккаунт и зарегистрировался заново с той же почтой
await addUser(5, ' A@X.kz ');
assert.equal((await claim(N(5), 'ios-device-5-xxxxxxxx')).status, 'already_granted');
// лимит
await q(`update public.signup_bonus_settings set max_grants = 2`);
await addUser(6, 'f@x.kz');
assert.equal((await claim(N(6), 'ios-device-6-xxxxxxxx')).status, 'limit_reached');
await q(`update public.signup_bonus_settings set max_grants = 1000`);
// клиент не может сам выписать кредиты и прочитать таблицы
await db.exec(`set test.uid='${N(6)}'; set role authenticated;`);
await q(`update public.profiles set credits = 9999 where id = $1`, [N(6)]);
await assert.rejects(q(`select * from public.signup_bonus_grants`));
await assert.rejects(q(`select public.signup_bonus_stats()`));
await db.exec(`reset role;`);
assert.equal((await q(`select credits from public.profiles where id=$1`, [N(6)]))[0].credits, 0);
// счётчик для владельца
await db.exec(`set test.uid='eee55a08-18d1-46e3-a303-1411d1bb9333'; set role authenticated;`);
const stats = (await q(`select public.signup_bonus_stats() s`))[0].s;
await db.exec(`reset role;`);
assert.equal(stats.granted, 2); assert.equal(stats.max_grants, 1000);
await db.exec(B);
console.log('B ok (+rerun), stats', JSON.stringify({ granted: stats.granted, max: stats.max_grants }));

// --- откат и повтор ---
await q(`insert into supabase_migrations.schema_migrations values ('20261030180000'),('20261030181000')`);
await db.exec(R);
const cols = await q(`select column_name from information_schema.columns where table_name='tasks' and column_name in ('country_codes','cities','categories')`);
assert.equal(cols.length, 0);
rows = await q(`select title, country_code, city, category from public.tasks where title in ('new-multi','old1') order by title`);
console.log('after rollback:', JSON.stringify(rows));
await db.exec(A); await db.exec(B);
console.log('rollback ok, re-apply ok');
