-- Seed demo content for App Review account (appreview@x5studio.app).
-- The demo user is empty by default; without seed data the reviewer
-- signs in, sees blank Portfolio + empty profile, and rejects under
-- Guideline 2.1.

update profiles set
  name = 'Demo Reviewer',
  nickname = 'demo_reviewer',
  bio = 'Demo account used by Apple App Review to evaluate X5.',
  show_in_hub = true,
  is_public = true,
  language = 'en'
where id = '2ac10013-b6c7-4b38-923b-19ee09d7df8f';

insert into portfolio_items (user_id, type, title, description, media_url)
select '2ac10013-b6c7-4b38-923b-19ee09d7df8f', 'image',
       t.title, t.description, t.url
from (values
  ('Studio session', 'Sample studio shoot used to demonstrate the portfolio gallery.', 'https://images.unsplash.com/photo-1492691527719-9d1e07e534b4?w=1080'),
  ('Brand campaign', 'Sample brand creative for the marketplace demo.', 'https://images.unsplash.com/photo-1519681393784-d120267933ba?w=1080'),
  ('Lifestyle shoot', 'Sample on-location lifestyle photography.', 'https://images.unsplash.com/photo-1503602642458-232111445657?w=1080')
) t(title, description, url)
on conflict do nothing;
