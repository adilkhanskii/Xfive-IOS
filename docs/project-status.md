# X5 — точка продолжения

Обновлено: 2026-09-07. Полная клиентская приёмка пока НЕ завершена.

## Точный исходник и выпуск

- Каноническая копия: work/x5-ios-payment-release, ветка codex/x5-ios-payments-239,
  remote tooyakov-art/x5 (PUBLIC).
- work/x5 / 9c98559 содержит другую неопубликованную работу — не смешивать.
- По финальному ASC чтению 10:23 UTC версия **1.1.8 — READY_FOR_SALE**.
  Это не подтверждение установленной версии клиента; её номер ещё запрошен.
- Apple **1.1.9 (239)** / runtime 512f546 — WAITING_FOR_REVIEW, VALID,
  AFTER_APPROVAL. Свежий read-only audit: **34111162162**, 10:23 UTC, PASS.
- **1.1.9 (240)** / runtime 6707cad — загружена, VALID, IN_BETA_TESTING,
  доступна только существующим внутренним группам. Build **34097932983** PASS,
  status/assignment **34098808130** PASS. IPA validator: правильный bundle,
  version/build, **test_resources=0**.
- 7be1d2d меняет только ограниченный TestFlight helper 235→240; runtime тот же.
- e680c6d — security/CI/test-only изменения; application runtime не менялся.
- cc47728 проверял гипотезу hit-testing обложки, но UI остался FAIL.
  93946b9 убрал этот неподтверждённый runtime patch: `git diff 6707cad -- X5`
  пустой. Проверяется исходный runtime 240 с точным native scroll в тесте.
- 240 НЕ подменяла 239 в заявке Apple. Не отменять текущую заявку до проверки
  кандидата на iPhone. Версия на устройстве клиента не подтверждена.

## Исправлено и проверено

- D02–D04: обновление своего профиля после deferred StoreKit delivery,
  отдельная ошибка принадлежности покупки, отмена галочки без выдуманной ошибки.
- D05/D07: owner+epoch fencing профиля, кредита/Pro, async PATCH/upload/refresh,
  course retry, paid image series/voice callers. RED: d787034 / **34092042599**
  (2 новых tests, 5 assertion failures); GREEN: 88b3c85, 16 behavioral tests.
- D06: PostgreSQL race продления/cron подтверждён настоящими RPC в одноразовой
  изолированной PostgreSQL 17.11; фикс и duplicate/refund/other-owner PASS.
  Миграция **20260907070000** УЖЕ в production. Normalized body MD5
  44ccbde3b58a8f601bdba37eb680887b, EXECUTE anon/authenticated/service_role false.
  Балансы, ledger и цены не переписывались. Preflight и точечный rollback в repo;
  rollback в production НЕ выполнялся и вернул бы гонку. В отдельной synthetic
  БД exact rollback + forward reapply PASS: оба checksum совпали, данные не
  изменились. Финальный SQL прогон 09:54–09:55 UTC, 6 PASS + RACE_PREVENTED.
- D08: убраны синтетические курсы и выдуманные счётчики учеников; настоящий
  каталог/editor сохранены, empty/Refresh RU/EN/KK. Source RED→GREEN, real UI PASS.
- D09: unsigned simulator реально возвращал Keychain -34018. Исправлена только
  ad-hoc подпись CI; реальный Security round-trip и cold restart PASS. Никакого
  plaintext token fallback.

## Проверки кандидата

- Baseline: 287 Python + 58 verify-transaction + 89 notification Deno PASS.
- **34096274400 / 89b138d**: 263 XCTest, 1 skipped, 0 failures; оба настоящих
  read-only UI tests PASS (guest, login, Store, Hub, empty CourseUP/Refresh,
  cold restart). Unsigned Keychain diagnostic — намеренный RED, не product PASS.
- **34097968470 / 6707cad (240)**: unit/backend/private media job PASS; guest UI
  PASS, authenticated UI FAIL из-за перехваченного OS notification sheet tap
  Profile (D12). Screenshot подтверждает оставшийся Home, не ошибку платежа.
- D12: UITest явно отклоняет запрос уведомлений и проверяет selected Profile.
  **34100897057 / e680c6d** подтвердил этот переход, но Store виден и не принимает
  native tap. D14: причина ещё проверяется; это не доказанная ошибка оплаты.
  **34104187921 / cc47728**: UI FAIL, Store y=754.17 не меняется после глобальных
  app.swipeUp. Гипотеза про обложку не доказана. **34105246849 / 5e7abf4**
  тоже UI FAIL после slow swipe по произвольному первому ScrollView.
  Контроль без cover patch **34105686427 / 93946b9**: полный unit/backend job
  PASS (318 Python, 263 XCTest / 1 skip / 0 failures, 58 + 89 Deno), UI FAIL.
  **34106752594 / 893f281** остановился до жеста: первый ScrollView всего
  320×192, недостаточная видимая высота. Это не доказывает неисправность Profile.
  **34108314479 / 3c9f1ec**: guest PASS, auth UI FAIL; точно найдено OS AutoFill
  app.sheets[Save Password?], его scroll 320×192 не содержит Store. Parser PASS,
  полный test job SKIPPED. **34109636670 / fb98997** повторяет UI после точного
  Not Now с ожиданием закрытия этого окна, не сохраняя/не меняя пароль.
  Контейнер определяется по Store-потомку. Native isHittable/tap не заменены.
- **34109636670 завершился FAIL**: guest PASS и реальный login, но Profile native
  tap вычислил {-1,-1}, selected assertion не выполнился. После ошибки modal и
  keyboard отсутствуют; handler Save Password в этом прогоне не выполнялся.
  Причина D15 не доказана. Не обозначать это как ошибку клиентского магазина,
  не ослаблять тест до coordinate tap/искусственного перехода. Xcode 26.6 был и
  в прежнем успешном UI. Финальная A02/UI-приёмка BLOCKED, не PASS.
- Сейчас **318 Python PASS**. Один новый структурный тест предполагаемого cover
  fix удалён вместе с неподтверждённой гипотезой; native Store assertions сохранены.
- 1 skipped XCTest — real client course-video upload fixture
  x5-client-course-lesson.mp4 не предоставлен в CI. Не считать это PASS.

## Закрываемая граница секретов D11

- Repo PUBLIC, старые review credentials были plaintext в Git до этого аудита.
- Неизменные значения перенесены в X5_APP_REVIEW_EMAIL /
  X5_APP_REVIEW_PASSWORD GitHub Secrets. Файлы удалены из текущего исходника,
  не извлекать их обратно из истории для запуска.
- Fastlane/Deliverfile передают оба значения в памяти; metadata workflows
  проверяют их ДО Apple mutations. Printable Deliverfile DSL не используется:
  проверяется реальный pinned parser с Configuration set и отключённым summary.
  Гипотеза reviewer о пароле в ранней таблице НЕ подтвердилась: runtime рисует
  Hash пустой ячейкой, password в Runner Summary маскируется. Email там выводился;
  теперь summary отключён. Не записывать неподтверждённую password-утечку как баг.
  **34101572180 / cfb3d07**: настоящий pinned Fastlane parser PASS без Apple calls.
- Acceptance CI получает секреты только через protected environment, создаёт
  временные runner resources, затем очищает. Optional XcodeGen sources
  сохраняют normal build без review secret.
- 4 публичных screenshot artifacts этого аудита удалены; локальные ignored копии
  сохранены. Public CI больше не должен выгружать PNG/xcresult/runner bundles.
  Финансовые production агрегаты также только local ignored, не public evidence.
  Последние UI runs 34108314479 и 34109636670: опубликованных artifacts=0.
- Старый файл пароля подтверждён также в текущем PUBLIC main (проверены только
  path/SHA/size без чтения значения в вывод) и остаётся в истории.
  **Rotation ещё обязательна** вместе
  с обновлением входа Apple Review; текущий пароль/аккаунт не менялся, история
  Git не переписывалась. D11 не объявлять полностью закрытым.
- [PR45](https://github.com/tooyakov-art/x5/pull/45) / 51d29c7 отдельно переносит
  минимальный secret fix в main: delete 2 txt, ignore, env/helper, pinned manual
  lane + synthetic parser test. Main 32ce53d не изменён; PR не merged, runtime
  1.1.2/153 не трогали. PR DRAFT; не merge вслепую: push main запускает старую публикацию.
  Значения старых credential не извлекались; новый tree собран отдельным Git index.

## Живые проверки и блокеры

- Scoped live API: login/own profile/own refresh PASS; 3 private payment tables
  HTTP 403, anonymous capabilities HTTP 401. Production ledger contracts
  согласованы, но это не доказательство списания денег банком.
- Store UI показывает три разных локализованных StoreKit цены; реальные покупки,
  pending/cancel/restore/renewal и обычный Sandbox E2E на iPhone не выполнялись.
- **34103277555 / a7a4e5a**, 08:56 UTC: свежие Apple KAZ цены 1000/2000/5000 KZT
  для соответствующих пакетов, все APPROVED. D13 устранил Apple mutations из
  audit-only режима; этот запуск только читал расписание. Это не доказательство
  банковского списания.
- CourseUP для review account не содержит опубликованного урока. Нельзя ради
  зелёного теста публиковать черновик или расширять права аккаунта.
- Portfolio/media/chat E2E нужен второй изолированный участник и разрешённый
  тестовый канал. Реальные сообщения никому не отправлялись.
- Images/influencer: provider_balance_or_quota. Lipsync: provider_not_configured.
  Voice/video health true — не доказательство успешной генерации.
- Supabase FREE не включает managed backups. Внешний backup неизвестен;
  владелец уже запрошен о существующем backup/подготовке платного тарифа.
  Подписку не покупать и полный production export не делать без согласования.

## Следующий шаг

1. Не повторять тот же UI прогон без нового основания. Сначала подтвердить номер
   клиентской версии и источник App Store/TestFlight (владелец уже запрошен).
   Для D15 нужен наблюдаемый iPhone либо отдельный simulator-контур; последняя
   ошибка 34109636670 — native Profile tap, не доказанный дефект платежа.
2. Runtime точно совпадает с IPA 240; не нужна новая сборка ради тестового жеста.
   При новом воспроизведённом runtime defect — новый свободный build number.
3. На разрешённом iPhone проверить внутреннюю **240**, normal Sandbox rejection,
   cancel/pending/restore и production purchase только в разрешённом платёжном
   сценарии. До этого полная платёжная/клиентская приёмка BLOCKED.
4. После принятого кандидата проверить свежий Apple state и заменить/отправить
   сборку разрешённым workflow. Сейчас 239 остаётся в очереди Apple.
5. Отдельно закрыть password rotation, backup/restore, доступ к course fixture,
   media participants и provider quota/config — не выдавать их за исправленные.
6. PR45 остаётся DRAFT. Сначала согласованно защитить старый main push→upload;
   затем проверить synthetic parser отдельно от Apple action и переносить cleanup.
   Не запускать manual asc-submit из main ради теста — он заканчивается ship.

## Воспроизведение

Команды из корня канонической копии:

- python -m unittest discover -s scripts/tests -p "test_*.py"
- node diagnostics/x5-audit/sql-race-runtime.mjs --with-fix
- gh workflow run ios-course-ci.yml --ref codex/x5-full-fix-20260801 -f scope=all
- gh workflow run asc-release-audit.yml --ref codex/x5-full-fix-20260801 -f action=audit

Windows Python: C:/Users/tuako/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe.
Подробная матрица: [project-audit.md](project-audit.md).
Доступ в Supabase Dashboard уже есть. Не запрашивать повторно пароль/ключ.
