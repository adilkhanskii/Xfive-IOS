# X5 — клиентская приёмка, 7 сентября 2026

## Объект и границы

Канонический Git remote: `https://github.com/tooyakov-art/x5`.
Проверяемая копия: `work/x5-ios-payment-release`, исходный commit `512f546`;
ветка `codex/x5-ios-payments-239`. Именно этот commit был продвинут без force
в разрешённую релизную ветку `codex/x5-full-fix-20260801` и собран как 1.1.9 (239).
`work/x5` — другая линия (`9c98559`), содержащая неопубликованные Kaspi/уроки.
Она не является исходником сборки 239 и в этот аудит не подмешивается.
Проверяемые рабочие деревья исходно были чистыми. Использованы доступные навыки
ios-deployment/fastlane для сохранения существующего пути CI и fix-finding для
минимального исправления изоляции аккаунтов. Схема подписания не заменялась.

Приоритет подтверждён голосовыми Адильхана от 4 сентября и последующим
решением Диаса: iOS, разовые кредиты 1000/2000/5000 за столько же KZT,
галочка как ежемесячная подписка. Kaspi, новые оплаты в Hub и новые AI-функции
отложены. Остальные уже опубликованные функции входят в регрессионный охват,
но исторические пожелания не превращаются автоматически в новый объём релиза.

Роли: гость; обычный зарегистрированный пользователь; другой пользователь;
обладатель галочки; разрешённый администратор курсов; изолированный App Review
аккаунт. Последний не заменяет обычного пользователя в проверке sandbox-ограничений.

## Исходная проверка

- Windows, Deno 2.9.6; CI использует Deno 2.9.4 и macOS/Xcode 26.
- Python source/contract suite: **287 PASS** на `512f546`.
- `verify-app-store-transaction`: **58 PASS**, Deno frozen lock, включая handler,
  validation и сертификатные фикстуры. Это не реальные банковские платежи.
- `app-store-notifications`: **89 PASS**, включая проверку полного подписанного
  fixture и отклонение подмены. SQL source contracts не считаются выполненным SQL.
- Свежий ASC аудит `34090679439`: 1.1.9 (239) `WAITING_FOR_REVIEW`, бинарник
  `VALID`, выпуск `AFTER_APPROVAL`; 0 issues, 4 предупреждения о недоступном
  подтверждении скриншотов старых подписок. Номер сборки на устройстве клиента не подтверждён.
- Исторические проверки 5 сентября (не новый прогон): Apple Production API
  подтвердил четыре спорные транзакции 2–3 сентября, цены 1000/2000 KZT;
  фактическое банковское списание не установлено.

## Матрица обязательных сценариев

Статус строки означает полный указанный сценарий, не один зелёный слой.

| ID | Роль, требование и ожидаемый результат | Текущий статус | Доказательство / ограничение |
|---|---|---|---|
| A01 | Гость: запуск, email-вход, неверный ввод, возврат назад без зависания | PASS | Настоящий iPhone simulator, runtime 240/6707cad, последний run 34109636670 test01 PASS |
| A02 | Пользователь: вход, загрузка своего профиля, сохранённая сессия после перезапуска | BLOCKED | 89b138d, signed simulator 34096274400: login/profile/cold restart PASS, runtime тот же. Последняя финальная проверка 34109636670 остановилась на native Profile tap с hit point -1,-1 (D15); iPhone клиента не подключён |
| P01 | Обычный пользователь: разово купить выбранный пакет за соответствующую цену; баланс после перезапуска | BLOCKED | Три пакета/разные реальные StoreKit USD цены показаны в UI; новый платёж не проводился, нет подключённого Apple Sandbox аккаунта. Исторический API-аудит не доказывает банк |
| P02 | Отмена, pending, ошибка проверки: без ложного успеха и двойного начисления | NOT TESTED | Найдены D02–D04, кандидат 88b3c85; handler/SQL PASS, StoreKit UI E2E не выполнялся |
| P03 | Повтор, смена аккаунта, повторный webhook: выдача не дублируется и не переходит другому | NOT TESTED | Реальные SQL RPC на synthetic DB: concurrent replay/other-owner/refund PASS; D05/D07 behavioral XCTest PASS; полного StoreKit E2E нет |
| P04 | Галочка: ежемесячная подписка, восстановление, отмена продления, истечение, возврат | NOT TESTED | D06 воспроизведён, исправлен и deployed; 89 notification checks PASS; StoreKit renewal E2E не запускался |
| P05 | Обычный TestFlight не создаёт расходуемые кредиты; App Review изолирован | NOT TESTED | Историческая live-проверка и новый source contract PASS, не новый E2E |
| H01 | Регистрация/профиль/Hub: страны и города, назад, профессии и фильтры | NOT TESTED | Hub открыт в настоящем UI, профессии/порядок видны. Редактирование, регистрация и все фильтры не пройдены |
| C01 | CourseUP: открыть урок, качественное видео, доступное качество/сеть, повторное открытие | BLOCKED | Для review account нет опубликованного учебного материала. Честный empty/Refresh UI проверен (D08), playback и качество исходного ролика не доказаны; черновики не публиковались ради теста |
| F01 | Портфолио: свои/чужие публикации, приватное медиа, сохранённое после повторного входа | NOT TESTED | Другие аккаунты/загрузка только на разрешённой тестовой среде |
| M01 | Чат: отправка и доставка фото/видео/голоса адресату, повторное открытие | BLOCKED | Реальные отправки не разрешены этим этапом; тестовый адресат пока не задан |
| AI01 | Опубликованные AI-инструменты: понятный статус, реальный результат/сохранение или честная ошибка без списания | BLOCKED | Live capabilities: изображения/инфлюенсер provider_balance_or_quota; Lipsync provider_not_configured. voice/video true — только health, не генерация |
| S01 | Чужие приватные данные/платёжные таблицы закрыты; публичный Hub разрешён по политике | NOT TESTED | 3 private payment tables: живой authenticated HTTP 403. Полная межаккаунтная media/RLS-приёмка ещё не выполнена |
| R01 | Существующая заявка Apple: известный бинарник, выпуск только после одобрения | PASS | ASC audit 34111162162, 10:23 UTC: 239 VALID / WAITING_FOR_REVIEW / AFTER_APPROVAL. Это статус существующей заявки, не приёмка нового кандидата |
| R02 | Восстановление данных платёжной базы после аварии | BLOCKED | Supabase Backups: FREE, managed backup отсутствует. Внешний backup не подтверждён; restore production на тестовой среде не выполнен |
| R03 | Исправленный кандидат принят, отправлен Apple и подтверждён на устройстве клиента | BLOCKED | 240 VALID / IN_BETA_TESTING (34098808130), но не прикреплён к App Review; обязательные клиентские проверки ещё не закрыты. Версия клиента неизвестна |

## Реестр дефектов

| ID | Вид / приоритет | Воспроизведение и причина | Ожидаемо / фактически | Статус |
|---|---|---|---|---|
| D01 | Подтверждённый дефект документации, P2 | Открыть README и docs/x5-handoff.md на 512f546 | Убраны неверные текущие версии/ветки/ElevenLabs и push main; история помечена архивной | PASS, docs этого аудита |
| D02 | Восстановление покупки, P1 | Отложенная Transaction.updates доставляет подтверждённую покупку после закрытия окна | Сервер начислял, но UI не обновлял профиль и оставлял pending-ошибку. Добавлено событие только после applied/finish, ровно один раз, без рекурсивного replay | PASS behavioral delivery/coalescing/retry XCTest 88b3c85; StoreKit E2E отдельно не доказан |
| D03 | Ошибка принадлежности покупки, P1 | Подписанная транзакция A проверяется с auth B | Handler HTTP 400/account_token_mismatch/без grant; UI ошибочно называл это временным сбоем. Теперь отдельная account mismatch ошибка | PASS source wiring; живой StoreKit сценарий NOT TESTED |
| D04 | Отмена галочки, P2 | Отменить purchase, false result и lastError=nil | UI придумывал «ошибку покупки». Теперь cancellation не создаёт ошибку/ошибочный haptic; реальные ошибки отслеживаются отдельно | PASS source wiring; живой StoreKit cancellation NOT TESTED |
| D05 | Изоляция аккаунтов, P1 | Удержать GET профиля A → загрузить B → отпустить A; отдельно logout до ответа | Старый A перезаписывал B/profile/cache; после logout профиль возвращался. Owner+session epoch защищают load/create/refetch/PATCH/avatar/credits и синхронный Pro | PASS: RED d787034 (2 теста, 5 assertions), GREEN 88b3c85 (16 session-isolation tests) |
| D06 | Гонка продления галочки, P1 | A удерживает реальное RPC продления; cron B ждёт профиль; A commit; B продолжает | Ledger оставался active, но профиль становился unverified. Теперь строка profiles блокируется ДО чтения источников | PASS на отдельной PostgreSQL 17.11; production deployed 20260907070000 и checksum/ACL проверены |
| D07 | Смена плательщика в отложенной операции, P1 | A course POST → switch B → 401 retry; либо frame 1 A → switch B → frame 2 | Независимый review обнаружил повторное чтение mutable token. Теперь owner+epoch проверяется до/после refresh, image series использует неизменный token и проверку между кадрами | PASS shared guard + actual course retry URLProtocol XCTest 88b3c85; image/voice caller wiring source PASS, платный E2E NOT TESTED |
| D08 | Выдуманный каталог/показатели CourseUP, P2 | Зайти CourseUP обычным review account: API пустой, UI рисует 6 «бесплатных» курсов с выдуманными учениками без видео | Удалены synthetic course factory и fake counters; неизвестный studentsCount не показывается; пустой каталог с Refresh, реальные editor paths сохранены | PASS: 3 source tests RED → GREEN; реальный signed UI 34096274400 empty + Refresh PASS |
| D09 | Ошибка подписи тестового runner, P2 | Реально войти → terminate → launch в unsigned simulator | OS SecItemAdd возвращал -34018 errSecMissingEntitlement. Ad-hoc simulator signing исправляет Keychain и cold restart без изменения production auth/security | PASS: 34096274400 unsigned probe RED, signed Keychain round-trip/unit/UI GREEN |
| D10 | Не подтверждена аварийная копия платёжной базы, P1 operational | Supabase project → Database → Backups | FREE не включает managed backups; отдельный защищённый backup/restore не найден и не подтверждён владельцем | BLOCKED: запрошено существующее backup либо решение о платном тарифе; подписка самовольно не покупалась |
| D11 | Секреты и приватные тестовые артефакты, P1 | Проверить visibility репозитория и источники review credentials | Репозиторий PUBLIC. В релизной ветке credentials перенесены в GitHub Secrets; CI hydrates только ephemeral UITest resources, public screenshot upload закрыт; четыре архива этого аудита удалены с сохранением локальных копий. Старый файл ещё есть в текущем main и истории | BLOCKED частично устранён: отдельный PR45 для main подготовлен, не merged; rotation старого review login ещё требуется. История и действующий вход Apple не менялись |
| D12 | Недетерминированный UI test, P2 | 6707cad после login: OS notification prompt перехватывает tap Profile, Store не найден | Screenshot подтверждает, что тест остаётся на Home. Добавлено явное отклонение разрешения и assertion selected Profile; app routing не переписывался | PASS для перехода: 34100897057 / e680c6d отклонил OS prompt и подтвердил Profile; отдельный Store hit-test затем FAIL (D14) |
| D13 | Audit-only workflow изменял Apple, P1 | На старом YAML выбрать credit_review_action=audit: до аудита выполнялись configure/notification steps | Режим audit теперь не выполняет mutations. Отдельный read-only клиент запрещает не-GET и проверяет активные KAZ цены, pagination и тип каждого consumable | PASS: source RED→GREEN и runtime tests; 34103277555 выполнил только чтение, три APPROVED пакета 1000/2000/5000 KZT |
| D14 | OS AutoFill блокирует UI-проверку Store, P2 тестового контура | Profile selected; Store есть под модальным окном, swipe не меняет положение | 34108314479 прямо зафиксировал app.sheets[Save Password?] с Not Now и внутренним scroll 320×192 без Store-потомков. Это не ScrollView профиля. Неподтверждённый cover patch отменён. fb98997 отклоняет только точное предложение сохранить пароль; Store сохраняет native tap/isHittable | BLOCKED live retest: 34109636670 не показал этот sheet и остановился раньше на Profile (D15). Сам handler имеет source review, но его исполнение не выдано за native PASS |
| D15 | Native Profile tap в симуляторе не завершён, причина не доказана, P1 приёмки | 34109636670: login PASS, OS notifications denied, Save Password sheet не появился за 5s, tap Profile | XCTest вычислил hit point {-1,-1}; isSelected не стал true. После ошибки app/system alerts/sheets/keyboards=0. Доказательства неисправности клиентского приложения либо изменения бизнес-логики нет | UI FAIL / клиентский сценарий BLOCKED. Нельзя засчитывать старый успешный прогон как новую финальную приёмку или менять runtime по геометрической гипотезе |

## Доказательства и слои проверки

- [Baseline race XCTest](https://github.com/tooyakov-art/x5/actions/runs/34092042599):
  `d787034` — тестовый seam без исправления, 246 XCTest, 1 skipped, 5 assertion
  failures только в двух новых account-race тестах. Позитивный concurrent same-user
  load PASS. Это выполненный код iOS, не source grep и не гипотеза.
- UI того же run: guest PASS; authenticated тест остановился до login из-за
  отсутствия txt-ресурса в test bundle. Исправлен XcodeGen `buildPhase: resources`
  только для UITest runner; demo credentials не добавлялись в application target.
- [Кандидат полного CI/UI](https://github.com/tooyakov-art/x5/actions/runs/34093991702):
  `88b3c85`: backend/source/pinned TUSKit + 262 XCTest (1 skipped, 0 failures)
  PASS; отдельно private portfolio media regression PASS. UI guest PASS;
  настоящий review login, home/profile/store/Hub/CourseUP PASS до перезапуска,
  cold restart FAIL. Поэтому весь run не называется зелёным.
- Реальный StoreKit UI 88b3c85, en_US simulator: 1000 — $1.99, 2000 — $2.99,
  5000 — $8.99. Цены действительно разные и локализованы StoreKit. Это не
  доказательство сегодняшних KZT цен/дебета карты; покупка не нажималась.
- [CI 34096274400](https://github.com/tooyakov-art/x5/actions/runs/34096274400)
  на `89b138d`: 263 XCTest (1 skipped, 0 failures); signed OS Keychain round-trip
  PASS; оба настоящих UI сценария PASS, включая empty/Refresh и cold restart.
  Unsigned OS probe намеренно RED (-34018), шаг диагностический, не product PASS.
- [Runtime 240 CI](https://github.com/tooyakov-art/x5/actions/runs/34097968470)
  на `6707cad`: main unit/backend/private-media job PASS; authenticated UI FAIL
  на переходе Profile из-за недismissed notification prompt (D12), guest PASS.
- [Сборка/загрузка 240](https://github.com/tooyakov-art/x5/actions/runs/34097932983)
  PASS: реальный export IPA содержит com.x5studio.app / 1.1.9 / 240,
  test_resources=0; Apple upload succeeded 08:01 UTC.
- [TestFlight 240](https://github.com/tooyakov-art/x5/actions/runs/34098808130)
  VALID / IN_BETA_TESTING, назначена только существующим внутренним группам.
  Apple Review остаётся на 239; не отменять её до принятого кандидата.
- 294 Python contracts PASS локально на `88b3c85`. Добавлены wiring tests, но они
  не заменяют behavioral XCTest. Тест ожидавший буквальный `auth.userId` изменён
  обоснованно: теперь проверяется capture `deliveryUserID` ДО await и совпадение
  аккаунта в delivery callback; ownership-проверка не ослаблена.
- 297 Python contracts PASS на `89b138d`. Старое expectation
  `isDev && isEditableCourse` заменено обоснованно: synthetic rows удалены,
  обе ветки настоящих карточек проверяются на developer-only edit/context menu
  и CourseDetailView; проверка editor access не удалена.
- [SQL harness](../diagnostics/x5-audit/README.md) использует 17 неизменённых
  миграций baseline и инфраструктурные fixtures; business RPC не замоканы.
  [RED](../diagnostics/x5-audit/sql-race-runtime-result.json) содержит реальный
  `pg_blocking_pids`/ожидание Lock и `RACE_CONFIRMED`; [GREEN](../diagnostics/x5-audit/sql-race-fixed-result.json)
  повторённый 09:54–09:55 UTC содержит `RACE_PREVENTED` и 6 PASS. Контейнер только X5,
  network none, без ports/binds, tmpfs; удаление проверено. Финальный run exit 0.
- SQL сумма трёх пакетов = 8000; concurrent duplicate + 3 replay = ещё 1000,
  одна строка ledger. Другой владелец = 0. Refund -1000 / replay 0 /
  refund reversal +1000 / replay 0. Это не подтверждение списания банком.
- На той же изолированной БД выполнен точный emergency DDL rollback и возврат
  исправления: оба body checksum совпали, отпечатки profiles/ledger/events
  не изменились. Production rollback НЕ выполнялся. Это не backup/restore.
  Первая версия этого дополнительного теста ошибочно ссылалась на колонку
  notification_uuid; существующая схема использует event_id. Ошибка harness
  исправлена, полный SQL прогон повторён с exit 0; это не дефект приложения.
- Live API 2026-09-07 06:48 UTC: обычный password login выделенного App Review,
  собственный профиль, refresh того же пользователя; три
  закрытые payment tables HTTP 403, anonymous ai-capabilities HTTP 401.
  Course count 0, own portfolio count 0. Скрипт не использует service role,
  не покупает, не генерирует и не печатает credentials/tokens/чужие строки.
- Дополнительно выполнен read-only SELECT согласованности production ledger:
  размер пакета, quantity и owner token соответствуют проверяемому контракту.
  Финансовые агрегаты остаются только в локальном ignored evidence, не в PUBLIC Git.
  Это НЕ проверка банковского списания и НЕ новый Apple price schedule audit.
- Новый secret-boundary contract: 5 tests / 8 failures на старой схеме → GREEN;
  synthetic hydration/cleanup/missing-secret tests включены в полный Python suite.
- [Pinned Fastlane runtime](https://github.com/tooyakov-art/x5/actions/runs/34101572180)
  cfb3d07: Ruby 3.3.12 / Fastlane 2.237.0, настоящий parser без Apple requests.
  Оба синтетических поля сохраняются в config, не выводятся; missing secret
  fail-closed. Гипотеза password stdout опровергнута, email disclosure устранён.
- [Текущие KAZ цены](https://github.com/tooyakov-art/x5/actions/runs/34103277555),
  2026-09-07 08:56 UTC, a7a4e5a: 1000 / 2000 / 5000 credits стоят соответственно
  1000 / 2000 / 5000 KZT; все consumables APPROVED. Это отдельная свежая проверка
  расписания Apple, а не проверка банковского списания. Configure и notification
  mutation steps пропущены в audit-only режиме.
- [Apple release audit](https://github.com/tooyakov-art/x5/actions/runs/34101720626):
  239 VALID / WAITING_FOR_REVIEW / AFTER_APPROVAL, 0 issues и четыре прежних
  предупреждения о недоступных subscription screenshots. 240 не заменяла 239.
  Финальный read-only [34111162162](https://github.com/tooyakov-art/x5/actions/runs/34111162162),
  10:23 UTC, подтвердил тот же build 239 и WAITING_FOR_REVIEW, 0 issues / 4 warnings.
  Версия 1.1.8 имеет READY_FOR_SALE; на устройстве клиента версия пока неизвестна.
- cc47728: 319 Python tests PASS. Source guard covers RED (2 failures) → GREEN;
  это структурная защита, не самостоятельное доказательство устранения D14.
  Native UI 34104187921 остался FAIL; наличие модификатора не засчитывается
  как исправленный клиентский дефект. Следующий прогон проверяет целевой scroll.
- 93946b9 возвращает обе обложки к исходному runtime 240 и удаляет только новый
  структурный тест этой неподтверждённой гипотезы. Native isHittable/tap assertions
  остаются строгими. `git diff 6707cad -- X5` пустой, 318 Python PASS; контроль
  того же target/velocity на исходном runtime — 34105686427: UI FAIL,
  полный unit/backend job PASS (318 Python, 263 XCTest / 1 skip / 0 failures,
  58 verify-transaction + 89 notification Deno). 34106752594 / 893f281 UI FAIL
  до native drag из-за неверифицированного первого scroll 320×192.
  В 3c9f1ec диагностика app/SpringBoard modal и Store-потомков не выводит
  произвольный текст/профильные поля. Run 34108314479 — только UI + secret parser,
  не новый полный unit/backend прогон: guest PASS, auth UI FAIL на AutoFill
  Save Password? sheet. fb98997 отказывается сохранять credentials на runner
  через точный Not Now и проверяет исчезновение окна. Повтор — 34109636670.
- [Последний native UI](https://github.com/tooyakov-art/x5/actions/runs/34109636670),
  fb98997 / Xcode 26.6 / ad-hoc signed iPhone simulator: guest PASS, реальный
  login завершён; Profile native tap вычислил {-1,-1}, selected assertion FAIL.
  Ни одного modal/keyboard после ошибки нет. Старый GREEN 34096274400 также
  использовал Xcode 26.6, поэтому версия toolchain не доказана причиной.
  Parser job PASS, основной unit/backend job SKIPPED по scope=acceptance.
  Последний полный unit/backend GREEN остаётся 34105686427 / 93946b9.
  Повторные прогоны не дали устойчивой финальной UI-приёмки; нужен разрешённый
  iPhone или отдельный наблюдаемый simulator-контур. Не ослаблять native assertions.
- Отдельный read-only запрос GitHub подтвердил: default branch main PUBLIC,
  старый review password file всё ещё присутствует (только path/SHA/size,
  значение не выводилось). Удаление его из релизной ветки не закрывает утечку;
  до согласованной rotation и обновления Apple Review D11 остаётся BLOCKED.
- [Изолированный cleanup PR45](https://github.com/tooyakov-art/x5/pull/45),
  51d29c7 к main 32ce53d: только 7 security/config/test paths. Два review txt
  удалены из PR-дерева без чтения/checkout их содержимого; env-backed helper,
  fail-closed manual lane, Fastlane 2.237.0 и synthetic parser test.
  PR переведён в DRAFT, main НЕ изменён, application/runtime/version не переносились. Merge пока
  запрещён без отдельной защиты старого push→TestFlight workflow main (1.1.2/153).
  Git-data write API вернул 404; новая ветка создана через действующий Git transport
  с отдельным временным index, не затрагивая рабочее дерево/индекс релизной ветки.
  Это не rotation и не удаление credential из истории. Подготовщик по умолчанию
  read-only: diagnostics/x5-audit/prepare-main-secret-cleanup.py; повторный
  --create отказывается работать при существующей cleanup-ветке.
  На PR head нет Actions/check-runs — это НЕ CI PASS. Его asc-submit нельзя
  запускать ради parser test: workflow после теста выполняет реальную Apple action.
  Для проверки использовать отдельный synthetic-only контур без ASC ключей.

### Независимая проверка

Read-only payment reviewer выделил D02–D06; основной агент подтвердил source,
handler и SQL/runtime воспроизведением. Отдельный profile investigator проверил
место общей границы до редактирования. Свежий candidate reviewer, не писавший
patch, обнаружил D07 в retry/series/voice callers. Эти прямые пути включены в
исправление и регрессионные тесты; это один независимый review cycle. Его
положительные source checks не выдаются за XCTest/production E2E.

### Production-изменение D06

Проект Supabase `afwznqjpshybmqhlewmy`, main PRODUCTION, проверенный кабинет
X5 Marketing. Старая функция точно совпала с воспроизведённой:
normalized `md5(prosrc)=f8bb9d553246003b47aa2fd5b4e030dc`, row lock отсутствовал.
В атомарной транзакции применена ТОЛЬКО
`20260907070000_serialize_verified_profile_projection.sql`; запись migration
сохранена. Повторное чтение: `44ccbde3b58a8f601bdba37eb680887b`, EXECUTE у
anon/authenticated/service_role = false/false/false. Другие миграции из другой
ветки не применялись. Пользовательские балансы/ledger/prices не переписывались.

Первая попытка безопасно откатилась на checksum guard: браузер Windows отправил
CRLF вместо LF. Отдельный SELECT подтвердил старый hash и отсутствие migration.
Повтор сравнивал нормализованные переносы, при этом точный SQL был сверен через
clipboard; checksum guard не убирался. [Preflight](../supabase/deploy/20260907_verified_projection_preflight.sql)
и [точечный rollback](../supabase/rollback/20260907_verified_projection.sql)
сохранены. Rollback в production НЕ запускался и вернул бы известную гонку.

## Остаточные ограничения

- Банковское списание и обычная Sandbox/TestFlight покупка на реальном iPhone
  не проверялись этим запуском; новая покупка/списание не делались.
- UI CI не содержит Apple sandbox account, поэтому StoreKit sheets/pending/
  cancel/renewal здесь не становятся доказанным E2E по одним unit tests.
- Для CourseUP нужен подтверждённый опубликованный учебный материал.
  Не повышать права App Review ради обхода RLS и не публиковать черновик.
- Для media/чатов нужен изолированный второй тестовый участник и разрешённый
  канал отправки. Наличие парсера/200 не доказывает доставку адресату.
- Нет полной ASVS-сертификации: охват — мобильный account boundary, платежи,
  серверные ACL, подписанные Apple fixtures, URLProtocol/SQL recovery и текущие
  опубликованные интерфейсы. Внешний pentest/все приватные upload permutations
  не выполнялись. Dependency graph не обновлялся без необходимости.
- Изображения остановлены квотой, Lipsync не настроен. Новая подписка/пополнение
  сервисов и расширение AI Studio не входят в payment release.
- Нет managed резервной копии Supabase (страница Backups прямо указывает FREE).
  Внешнее хранилище/резервирование пока неизвестно; не объявлять их отсутствующими
  без проверки. Новый платный тариф требует решения владельца. DDL rollback
  функции не заменяет backup пользовательских данных и проверенный restore.
- Один XCTest осознанно skipped: production-upload preparation исходного
  клиентского x5-client-course-lesson.mp4; разрешённый fixture не передан в CI.
  Остальные тесты подготовки видео не заменяют этот исходный файл.
- Смена ранее раскрытого review password ещё не выполнена: требуется защищённое
  обновление аккаунта и соответствующего Apple Review login. Удаление текущего
  файла не очищает историю Git и не заменяет rotation.

## Ограничения и правила результата

Не выдавать оплату Apple за банковскую выписку, не очищать остатки пользователей.
Не менять production ради теста, не повторять платные вызовы и не посылать клиенту
сообщения. Новые проверки помечаются датой, версией и типом (unit/contract,
scratch SQL, simulator UI, live API). Пока обязательные строки BLOCKED/NOT TESTED,
проект целиком не объявляется готовым к приёмке.

Независимый D11 reviewer указал на возможный stdout пароля в Fastlane. Проверка
реального Fastlane 2.237.0 опровергла именно этот вывод: Hash ячейка ранней таблицы
пустая, Runner Summary маскирует password, но печатает email. Не считать
source-гипотезу доказанной уязвимостью. Проверяем оба пути synthetic-only тестом;
в итоговом helper summary выключен, оба credentials передаются через config.set.
Исходное наличие plaintext password в PUBLIC Git и необходимость rotation
независимо подтверждены. Собственный повторный просмотр не называется независимым.
