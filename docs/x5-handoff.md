# X5: где работали и как продолжать

> Исторический документ для 1.1.2 (146), не инструкция текущего выпуска.
> Актуальные исходники, проверки и блокеры: [project-status.md](project-status.md)
> и [project-audit.md](project-audit.md). Старые статусы, ветки и провайдеры ниже
> не подтверждают состояние production на 7 сентября 2026 года.

## Текущий рабочий поток

- Ветка: `codex/x5-cleanup-from-142`
- Стабильная база для отката дизайна: `04c63ba`
- Последний загруженный TestFlight до этого документа: `1.1.2 (146)`
- Статус последней проверки TestFlight: `VALID`, `IN_BETA_TESTING`

## Главные правила дизайна

- База интерфейса: чистый черный фон, легкий сине-зеленый свет только как акцент.
- Кнопки и панели SwiftUI делать системными/native, не собирать фейковое стекло вручную.
- Главный экран генерации держать простым: базовая генерация, лого, сторис, пост, Instagram-упаковка, товар, упаковка, видео, стартап-чат.
- Лишние карточки на главном не добавлять без отдельного согласования.

## Где правили последний раз

- Логотип и иконка:
  - `X5/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
  - `X5/Assets.xcassets/X5PremiumLogo.imageset/X5PremiumLogo.png`
- Общий фон:
  - `X5/Theme/X5Style.swift`
  - `X5/Theme/X5Background.swift`
  - `X5/Assets.xcassets/LaunchBackground.colorset/Contents.json`
- Главный экран:
  - `X5/Views/Home/HomeView.swift`
- Генерация изображений и экономика:
  - `X5/Views/Home/ImageGeneratorView.swift`
  - `X5/Views/Home/HomeData.swift`
  - `supabase/functions/generate-image/index.ts`
  - `supabase/functions/generate-image/economy.mjs`
- Hub, профиль, онбординг:
  - `X5/Views/Hub/HubView.swift`
  - `X5/Views/ProfileView.swift`
  - `X5/Views/OnboardingView.swift`
  - `X5/Views/EditProfileView.swift`

## Генерация изображений

- iOS вызывает Supabase Edge Function: `generate-image`.
- Edge Function читает ключ из `GOOGLE_API_KEY` или `GEMINI_API_KEY`.
- Последняя публикация функции была через Supabase connector, версия функции: `14`.
- Если у клиента `Server error 400/500`, сначала проверить секреты Edge Function и payload модели.

## Проверка

```powershell
node --test supabase/functions/generate-image/economy.test.mjs
git diff --check
```

Для iOS сборки через GitHub:

```powershell
gh workflow run ios-build.yml --ref codex/x5-cleanup-from-142
gh run watch <run_id> --repo tooyakov-art/x5 --interval 30 --exit-status
```

Проверка TestFlight build:

```powershell
gh workflow run asc-tf-status.yml --ref codex/x5-cleanup-from-142 -f build_number=<build>
```

## Выкатка

1. Если нужен TestFlight, поднять `CURRENT_PROJECT_VERSION` в `project.yml`.
2. Сделать commit.
3. Push в GitHub.
4. Запустить `ios-build.yml`.
5. Проверить статус через `asc-tf-status.yml`.

## Важно

- Не коммитить локальную папку `.codex/`.
- Не менять список карточек на главном без причины.
- Не возвращать белые фоны: фон приложения должен оставаться черным.
