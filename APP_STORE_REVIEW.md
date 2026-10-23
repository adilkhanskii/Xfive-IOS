# X5 v1.1 — App Store submission checklist (build 28+)

Это что нужно сделать для проходимости ревью. Каждая строка — конкретное действие. Подтверждай галочками.

---

## 0. Что уже сделано в коде

- ✅ Sign in with Apple (`X5/Views/LoginView.swift`)
- ✅ Sign in with Google via OAuth (build 25)
- ✅ Email/password (Supabase auth)
- ✅ Delete Account (Settings → Danger zone → Delete) — RPC `delete_own_account()`
- ✅ Privacy Policy / Terms / Support links на GitHub Pages
- ✅ Локализация ru / en / kk
- ✅ Portfolio (build 28)
- ✅ Verified Badge IAP scaffolding (`com.x5studio.app.verified.monthly`)
- ✅ Subscription IAP scaffolding (`com.x5studio.app.lite.monthly`, `com.x5studio.app.pro.monthly`, `com.x5studio.app.max.monthly`)

## 1. Зависимости от тебя (Apple Developer Account)

### 1.1 Pro подписка (в работе с другим помощником)

- [ ] ASC → Apps → X5 → Subscriptions → группа **X5 Pro** создана
- [ ] Продукты `com.x5studio.app.lite.monthly`, `com.x5studio.app.pro.monthly`, `com.x5studio.app.max.monthly` созданы, статус **Ready to Submit**
- [ ] Pricing: 1000 ₸ / 2000 ₸ / 5000 ₸ для KZ + US fallback
- [ ] Localizations: English (U.S.) + Russian
- [ ] Review screenshot загружен (1242×2688 или 1290×2796 .png/.jpg paywall)
- [ ] Sandbox Tester создан (с паролем, который ты вводишь сам)

### 1.2 Verified Badge подписка (новое)

- [ ] ASC → создать вторую подписку `com.x5studio.app.verified.monthly`
- [ ] Та же группа **X5 Pro** или новая (рекомендую отдельную «X5 Badges»)
- [ ] Pricing: 500 ₸ KZ + US fallback
- [ ] Localization (en + ru): «Verified Badge — get the blue ☑ next to your name»
- [ ] Review screenshot — экран `VerifiedBadgeView`

### 1.3 Привязать обе подписки к билду перед сабмитом

ASC → App Version 1.1 → **In-App Purchases & Subscriptions** → выбрать оба продукта.

## 2. Зависимости от тебя (Supabase Dashboard)

### 2.1 Применить новую миграцию

В Supabase SQL Editor выполнить целиком файл:
`supabase/migrations/20260502_portfolio_and_verified.sql`

Это создаст:
- таблицу `portfolio_items` + RLS
- storage-бакет `portfolio` (публичный)
- колонки `profiles.is_verified`, `profiles.verified_until`

### 2.2 Проверить что миграция чатов накатилась

```sql
SELECT count(*) FROM chats; SELECT count(*) FROM messages;
```

Если ошибка `relation does not exist` — выполнить `supabase/migrations/20260430_chats_messages.sql`.

### 2.3 Google OAuth

Authentication → Providers → Google: убедиться что Client ID/Secret настроены. Allowed redirect должен включать `x5://callback`.

## 3. App Store Connect metadata (App Information)

### 3.1 Build 143 override — использовать вместо старого marketplace-only текста

Перед любым upload в ASC сверить `APP_STORE_BUILD_143_AUDIT.md`.

Build 143 нельзя описывать как AI app или AI creator studio:
- главный экран теперь creator tools screen;
- есть image generation с prompt/reference images, но это второстепенный инструмент;
- в customer-facing metadata упоминать генерацию картинок только один раз;
- есть generated gallery, preview, edit, share и save to Photos;
- генерация работает по credits;
- Hub, chats, portfolio и CourseUP остаются основной частью продукта;
- Verified Badge в этом билде активируется кредитами, а не отдельным IAP.

**Subtitle**:
```
Creator workspace
```

**Promotional Text**:
```
Build your portfolio, learn in CourseUP, find specialists in Hub, post tasks, and chat with clients in one creator workspace.
```

**What's New in This Version**:
```
This update expands X5 into a fuller creator workspace.

New in this version:
- Updated Home screen with creator and marketing tools.
- Image generation for marketing creatives, logos, stories, posts, product photos and packaging ideas.
- Hub improvements for specialists, tasks and proposals.
- Direct chats with text, photos, voice messages, search, replies, pin, mute, archive, report and block controls.
- Portfolio improvements with photos, videos, likes, comments and pinned work.
- CourseUP video lessons and credit-based course purchases.
- Profile, onboarding, language, Face ID lock, push notification and subscription improvements.
```

**Keywords**:
```
creator,chat,hub,courses,portfolio,marketing,smm,freelance,kazakhstan,tasks,clients
```

**Screenshots for build 143**:
1. Login or onboarding
2. Home creator tools screen
3. Image generator with prompt/reference images/model/size/credits
4. Generated result viewer or Generated Gallery
5. Hub specialists/tasks
6. Chat thread
7. Portfolio/Profile
8. CourseUP course/lesson
9. X5 Pro paywall

### 3.2 Старый draft ниже оставить только как historical reference

**Promotional Text** (170 chars):
```
AI marketing studio for creators: caption generator, photo lab, courses, and a hub to hire (or get hired) — all in one app.
```

**What's New in This Version** (4000 chars):
```
v1.1
• Hub — find specialists or post a task
• Chats — message anyone in Hub directly
• Verified Badge — get the blue ☑ next to your name
• Portfolio — show your best work
• Sign in with Google
• Russian and Kazakh languages
• Big course banners and improved profile editor
```

**Description** (заменить старую):
```
X5 is a marketing studio for creators and entrepreneurs in one app.

What you can do:
• Generate marketing captions, ad headlines, and content ideas with AI
• Take and edit product photos with AI lookbook / branding modes
• Browse a video courses library (CourseUP)
• Hire vetted specialists in Hub — designers, marketers, developers
• Post tasks and get responses from the community
• Build your own portfolio and personal brand

Subscriptions (auto-renewable):
• X5 Pro — unlocks all AI tools and adds monthly credits that can be spent on courses and creator tools
• Verified Badge — blue ☑ that signals trust and ranks your profile higher in Hub

Subscription auto-renews monthly until cancelled. Manage in iOS Settings → Apple ID → Subscriptions.

Privacy: https://tooyakov-art.github.io/x5site/privacy.html
Terms:   https://tooyakov-art.github.io/x5site/terms.html
```

**Keywords** (100 chars):
```
ai,marketing,captions,content,creators,smm,instagram,tiktok,hire,freelance,hub,studio,photo,courses
```

### 3.2 App Privacy

В разделе **App Privacy** обновить декларацию:

| Data | Linked to user | Purpose |
|---|---|---|
| Email Address | yes | App Functionality |
| Name | yes | App Functionality |
| Photos | yes | App Functionality (avatar, portfolio) |
| User-generated content | yes | App Functionality (chats, portfolio, tasks) |
| Purchase History | yes | App Functionality (subscription state) |
| User ID | yes | App Functionality |
| Crash data | no | Analytics |

Tracking: **No**.

### 3.3 Age Rating

- User-generated content (chats, portfolio) → ставит ограничение **12+**.
- Без насилия, гэмблинга, алкоголя.

### 3.4 Screenshots (обязательно)

Минимум 3 на каждый размер: **6.7"** (iPhone 16 Pro Max) и **6.5"** (iPhone 11 Pro Max).

Что показать:
1. Login (Apple + Google + Email)
2. Home / AI tool screen
3. CourseUP с большим баннером
4. Hub с specialist карточками
5. Чат — telegram-style header
6. Profile с verified ☑ + portfolio grid
7. Paywall (X5 Pro)

Если нет физического iPhone — скачай build из TestFlight на симулятор Mac у знакомого, или на любом iPhone друга.

## 4. App Review Notes (этот текст вставить в Review Information)

```
Hello App Review Team,

X5 is a marketing/creator studio with AI tools, video courses, and a hub to hire freelancers.

Sign-in: three options — Sign in with Apple, Sign in with Google, and Email/Password.
The reviewer can use any. No demo account is required.

Subscriptions:
• X5 Lite (com.x5studio.app.lite.monthly) — auto-renewable monthly, 1000 credits.
• X5 Pro (com.x5studio.app.pro.monthly) — auto-renewable monthly, 2000 credits.
• X5 Max (com.x5studio.app.max.monthly) — auto-renewable monthly, 5000 credits.
• Verified Badge (com.x5studio.app.verified.monthly) — auto-renewable monthly, blue ☑ next to user's name.

Account deletion (Guideline 5.1.1(v)):
1. Profile tab → top-right gear icon → Settings.
2. Scroll to "Danger zone".
3. Tap "Delete Account" → confirm twice.
Result: account is permanently removed via public.delete_own_account() on Supabase. Takes ~3 seconds.

User-generated content (Hub, chats, portfolio):
• Users can flag inappropriate content via the support email (support@x5studio.app).
• A blocking mechanism is implemented in chats — long-press a chat to block.
• Tasks and posts are reviewed manually by us before going live in Hub if reported.

Privacy: https://tooyakov-art.github.io/x5site/privacy.html
Terms:   https://tooyakov-art.github.io/x5site/terms.html
Support: support@x5studio.app

Thank you.
```

## 5. Likely rejections + fixes

| Guideline | Risk | Mitigation |
|---|---|---|
| **1.2 User-generated content** | Hub/chats без модерации | Добавить кнопку Report + Block (см. ниже) |
| **3.1.2 Subscriptions** | Описание подписки на paywall неполное | Уже есть `paywall_cancel_anytime` + Terms link |
| **5.1.1(v) Account deletion** | Reviewer не найдёт | Доступно из Settings, видно сразу |
| **4.2 Minimum Functionality** | "Слишком тонкое" | Покажи в видео-демо: AI-инструменты + чаты + курсы — обширный функционал |
| **2.1 Crash** | Реальный баг | Тестировать каждый билд на устройстве перед сабмитом |
| **3.1.1 IAP** | Подписка не настроена в ASC, в коде уже есть код продукта | Не сабмитить пока ASC config не закончен |

## 6. Перед сабмитом — финальный smoke

На устройстве с TestFlight build:

- [ ] Login (Apple + Google + Email — все три работают)
- [ ] Logout → Login снова — данные на месте
- [ ] Settings → Language → переключить ru/en/kk — мгновенно меняется
- [ ] Edit Profile → залить аватар → видно на главной
- [ ] Edit Profile → добавить соцсеть → сохранить → видно в моём профиле
- [ ] Hub → открыть specialist карточку → нажать "Send message" → откроется чат с пустой шапкой
- [ ] Hub → 💬 на карточке → открывается чат сразу
- [ ] Чат → отправить сообщение → видно в списке чатов
- [ ] Profile → "Получить галочку" → открывается VerifiedBadgeView с ценой (если ASC настроен)
- [ ] CourseUP → большие баннеры, тап → детали курса
- [ ] Settings → Delete Account → отменить дважды (не подтверждать)
- [ ] Settings → "Очистить кэш" → toast "Кэш очищен"

Если хоть одна точка падает — фиксить и push новый билд, пока не зелёный.
