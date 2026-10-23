# X5 iOS — Полный план на основе анализа веб-x5

## Что есть в веб-х5 (анализ src/views/, types.ts, supabase REST probe)

### Бэкенды
- **Supabase** (наш `afwznqjpshybmqhlewmy`) — основная БД и хранилище
  - `profiles` (29 рядов) — полная модель юзера: name, nickname, avatar, bio, plan, credits, purchased_course_ids, subscription_*, social_links, user_role, specialist_category[], show_in_hub, is_verified, language, push_token
  - `courses` (14) — иерархия `course → categories → days → lessons` в jsonb
  - `tasks` (3) — биржа заказов: title, description, budget, category, deadline, status, accepted_specialist_*
  - `task_responses` (1) — отклики на задачи
  - `followers` (5) — соц-граф
  - **Storage**: `videos/home/*.mp4` (баннеры и тулкарты на главной)
- **Bunny CDN** (`x5-cdn.b-cdn.net`) — видео уроков курсов (mp4)
- **Firebase Firestore** — то что НЕ перенесли в Supabase: `specialists` коллекция, чаты/сообщения, presence/online

### Mobile bottom tabs (mobile только, MAIN_TAB_VIEWS)
**5 вкладок в порядке:** `home`, `courses`, `chats_list`, `hire (Hub)`, `profile`

## Целевая структура iOS

| Tab | Содержимое | Статус |
|---|---|---|
| 🏠 **Home** | AI generation hub: баннер-карусель + сетка 14 тулкард (Photo/Video/Outfit Swap/Lipsync/Design/YT Download/Voice TTS/WhatsApp Bot/Instagram AI/Video Creative/Lawyer AI/Academy/CRM/Analytics) | Все кнопки → детальный экран "Coming soon" |
| 🎓 **Courses** | 14 курсов из Supabase, видео через AVPlayer | ✅ build 12 |
| 💬 **Chats** | Список переписок с специалистами | Нужны таблицы chats/messages в Supabase |
| 💼 **Hub** | 2 саб-вкладки: Specialists / Tasks | Specialists из profiles, Tasks из tasks |
| 👤 **Profile** | Profile + Settings + Subscription | Большая переделка |

---

## План работ (приоритет → детали)

### P0 (сейчас, не ломая 1.0.0)

**1. Доделать tabs-v2 ветку — переименовать Generate → Home, рекс-style верстка**
- Home: баннер-карусель (5 баннеров) + сетка 14 тулкард, все ведут в `ToolDetailView` с "Coming soon"
- Тулкарты используют видео-обложки прямо из Supabase Storage `https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/home/*.mp4`
- Уже есть: Courses live, базовый Chat, базовый Hub, Profile

**2. Профиль — расширить под profiles схему**
- Загрузить `profiles` row для текущего user_id (id == auth.uid())
- Показать: avatar, name, nickname, bio, plan badge (free/pro/black), credits, signup_number, social_links (telegram/whatsapp/instagram → tap to open), specialist_category, isVerified badge
- Переключатели: Public profile, Show in Hub
- Edit profile (имя, био, аватар через image picker → Supabase Storage)
- Существующие: Sign out, Delete Account, Privacy/Terms

**3. Auto-refresh JWT в SupabaseClient**
- Вернуть мой неотправленный фикс — refresh_token grant + retry on 401

### P1 (Hub — настоящая биржа)

**4. Hub Specialists**
- Запрос: `profiles?show_in_hub=eq.true&select=*&order=created_at.desc`
- Карточки: avatar, name, role/category, bio
- Tap → UserProfileView (другой экран)
- Поиск по имени, фильтр по category

**5. Hub Tasks**
- Запрос: `tasks?status=eq.open&select=*&order=created_at.desc`
- Карточка: title, budget, category, deadline, author_name+avatar
- Tap → TaskDetailView с откликами `task_responses?task_id=eq.X`
- Кнопка "Откликнуться" → INSERT в task_responses (требует auth)
- "Опубликовать задачу" → форма → INSERT в tasks
- "Стать специалистом" → форма (категории, прайс, описание) → UPDATE profiles SET show_in_hub=true, user_role='specialist'

### P2 (Chats — миграция с Firestore на Supabase)

**6. Создать в Supabase таблицы:**
```sql
CREATE TABLE chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  participants uuid[] NOT NULL,  -- [user_a_id, user_b_id]
  task_id uuid REFERENCES tasks(id),  -- если чат привязан к задаче
  last_message text,
  last_message_at timestamptz,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX ON chats USING GIN (participants);

CREATE TABLE messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid REFERENCES chats(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL,
  text text,
  attachment_url text,
  attachment_type text,
  read_by uuid[],
  created_at timestamptz DEFAULT now()
);
CREATE INDEX ON messages(chat_id, created_at);
```

**7. RLS policies:**
- chats: SELECT/UPDATE если auth.uid() = ANY(participants)
- messages: SELECT если auth.uid() ∈ chat.participants; INSERT если sender_id = auth.uid()

**8. iOS:**
- ChatsListView: подписка через Supabase Realtime на свои чаты
- ChatView: WebSocket-стрим сообщений + INSERT при отправке
- Online статус: можно через `profiles.last_seen` + heartbeat каждые 30 сек

### P3 (Subscription — реальный StoreKit)

**9. App Store Connect:**
- Создать subscription `com.x5studio.app.pro.monthly` ($9.99/mo)
- Утвердить tax/banking info
- Subscription group: "X5 Pro"

**10. iOS:**
- StoreKit 2: `Product.products(for:)`, `product.purchase()`, `Transaction.updates` listener
- Restore: `AppStore.sync()`
- Локальный кэш + serverside проверка

**11. Supabase Edge Function `/verify-receipt`:**
- Принимает JWS-token от iOS, валидирует через Apple `verifyReceipt`
- Если valid → UPDATE profiles SET plan='pro', subscription_*=...
- Webhook от Apple App Store Server Notifications V2 на `/asn-webhook` → renewal/expire

### P4 (AI tools — постепенно)

**12. Реализовать AI фичи поэтапно:**
- Photo gen — через Gemini API (как в веб geminiService)
- Video gen — Kling 3.0
- Lipsync — Higgsfield
- ...

Не блокеры для submission v1.1.

---

## Что в этой сессии сделать

Сейчас на ветке `tabs-v2` (не main, чтобы 1.0.0 не задеть):
1. Переделать GenerateView в HomeView с баннер-каруселью + 14 тулкард (✅ done concept, переоформить с видео-обложками)
2. ProfileView грузит данные из `profiles`, показывает план/кредиты/social
3. Hub: Specialists из profiles (show_in_hub=true) + Tasks из tasks (status=open)
4. Auto-refresh JWT
5. Очистка fake Pro state ✅ build 14

После — мерж в main, билд для review v1.1.0.
