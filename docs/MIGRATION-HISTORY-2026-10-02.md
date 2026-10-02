# История миграций X5: локальные файлы и прод (2026-10-02)

> **Ничего из команд ниже не запускать без подтверждения владельца.**
> Документ только описывает, что *привело бы* историю в порядок. В этой ветке
> (`fix/migrations-20261002`) не переименован ни один исторический файл и не
> тронута история в проде.

Прод: проект `afwznqjpshybmqhlewmy`, PostgreSQL 17.6, в
`supabase_migrations.schema_migrations` 96 строк (снято 2026-10-02 read-only
запросом `select version, name from supabase_migrations.schema_migrations order by version`).
Локально (ветка от `release/ios`, плюс новый файл этой ветки) 81 файл:
31 с той же версией, 33 применены под другой версией, 6 применены вручную
вне истории, 8 применять нельзя, 3 надо применить руками. Прод: 31 + 33 + 32
версии, которых локально нет.

Сопоставление сделано не только по имени: для каждой пары сравнены сами SQL-
операторы локального файла с колонкой `statements` строки истории в проде
(доля операторов локального файла, найденных в проде дословно, после
нормализации пробелов и комментариев).

## Почему `supabase db push` сейчас опасен

* 33 локальных файла уже применены в проде, но под **другими** версиями
  (их накатывали руками). `db push` счёл бы их новыми и выполнил повторно:
  часть упадёт, часть откатит более новую логику.
* 32 версии есть только в проде, локального файла у них нет (4 из них —
  миграции веб-репозитория `trend_*`). `db push` остановится с ошибкой
  «Remote migration versions not found».
* Конфликт версий между репозиториями: `20261001120000` — это
  `course_video_bunny_mirror` в iOS-репо (ветка
  `feature/bunny-stream-course-video`) и `trend_video_templates` в веб-репо
  (в проде записан как `20261001123023`). Bunny-файл переименован в
  `20261002140000_course_video_bunny_mirror.sql` отдельным коммитом в ветке
  `fix/bunny-mirror-version-20261002` (от `feature/bunny-stream-course-video`,
  потому что в `release/ios` этого файла нет).

## Что применить руками и в каком порядке

Каждый файл идемпотентен и проверен двукратным прогоном
(`supabase/tests/20261002_kaspi_permanent_and_visits_test.sql`, Postgres 16 и 17).

| # | Файл | Зачем |
|---|------|-------|
| 1 | `supabase/migrations/20261002130000_kaspi_permanent_credit_grants.sql` | Живая `apply_kaspi_provider_command` начисляла купленные через Kaspi кредиты как сгорающие (1–3 мес.). Тело взято из прода, добавлен только флаг `x5.permanent_credit_grant_user`; возврат `refund_kaspi_credit_payment` снимает пакет с постоянного остатка (`x5.permanent_credit_adjustment_user`). Подтверждённых Kaspi-платежей в проде 0 — чинить балансы не нужно. |
| 2 | `supabase/migrations/20260903150000_kaspi_manual_transfers.sql` | Ручные переводы Kaspi; одобрение начисляет постоянные кредиты ровно один раз. Исправлена проверка роли в `configure_kaspi_manual_transfers` (старая отказывала даже service role). |
| 3 | `supabase/migrations/20260925090000_admin_analytics.sql` | Таблица `app_visit_events` (сайт уже пишет в неё и получает ошибку) и RPC `admin_analytics_*`. |

Команды (по одной, после каждой — проверка):

```powershell
# НЕ ЗАПУСКАТЬ БЕЗ ПОДТВЕРЖДЕНИЯ ВЛАДЕЛЬЦА
cd C:\Projects\clients\Marketologi\adilkhan\Apps\x5\ios
supabase db query --linked -f supabase/migrations/20261002130000_kaspi_permanent_credit_grants.sql
supabase db query --linked -f supabase/migrations/20260903150000_kaspi_manual_transfers.sql
supabase db query --linked -f supabase/migrations/20260925090000_admin_analytics.sql

# записать их в историю, чтобы будущий db push не выполнил их второй раз
supabase migration repair --linked --status applied 20261002130000
supabase migration repair --linked --status applied 20260903150000
supabase migration repair --linked --status applied 20260925090000
```

Проверка после применения (read-only):

```sql
select pg_get_functiondef('public.apply_kaspi_provider_command(text,text,text,text,numeric)'::regprocedure) like '%permanent_credit_grant_user%';
select relrowsecurity, relforcerowsecurity from pg_class where oid = 'public.app_visit_events'::regclass;
select policyname, cmd from pg_policies where tablename = 'app_visit_events';  -- только "visit events insert own" / INSERT
```

Ограничение отчётов `admin_analytics`: выручка считается только по
`iap_entitlements`. Покупки пакетов кредитов на iOS лежат в
`app_store_consumable_transactions` (в проде 22 покупки, 31 000 кредитов ≈
31 000 ₸), Kaspi — в `kaspi_credit_payments`/`kaspi_manual_payments`; ни то,
ни другое в отчёт не попадает. Цены App Store id (`com.x5studio.app.*`) в
`x5_product_price_kzt` добавлены; старые Google Play id `x5_pro_monthly`,
`x5_pro_yearly`, `x5_verified_monthly` оставлены с ценой 0 —
их цен нет ни в репозитории, ни в базе.

`20260813150000_kaspi_credit_payments.sql` повторно **не** применять: он вернёт
старую `apply_kaspi_provider_command` без флага постоянных кредитов.

## Список «не применять повторно» (аудит 2026-10-02)

| Версия | Причина |
|--------|---------|
| `20260724123000`, `20260724134000`, `20260726213000` | Уже в проде под другими версиями; повторный прогон откатит более новую логику. |
| `20260725193000`, `20260725201500`, `20260726163631`, `20260726184500` | Уже в проде под другими версиями; повторный прогон упадёт. |
| `20260801115000`, `20260801120000`, `20260801122000`, `20260801123000`, `20260726224500` | В проде отсутствуют, и применять их нельзя: сломают web push, медиа в чатах и удаление аккаунта. |

## Сопоставление: локальный файл → версия в проде

### Одинаковая версия (31 файл, ничего делать не нужно)

`20260430`, `20260502`, `20260502120000`, `20260511`, `20260512123500`,
`20260714`, `20260714153000`, `20260714154000`¹, `20260714155000`¹,
`20260714160000`, `20260714193243`, `20260714193519`, `20260714193941`,
`20260714194747`, `20260714212020`, `20260714215028`, `20260716060603`,
`20260726222900`, `20260726223000`, `20260813083000`, `20260813090000`,
`20260813150000`, `20260814003000`, `20260815170000`, `20260817150000`,
`20260817173000`, `20260817190000`, `20260825110000`, `20260825113000`,
`20260831132000`, `20260907070000`².

¹ Версия совпадает, но содержимое в проде отличается от локального файла
(совпадает 84% и 88% операторов) — в проде более ранняя или более поздняя
редакция. Не переприменять.
² У этой строки истории в проде пустые `statements`; сверить содержимое нельзя.

### Применены в проде под другой версией (33 файла)

| Локальный файл | Версия и имя в проде | Совпадение операторов |
|---|---|---|
| `20260602170400_repair_chat_push_token_state.sql` | `20260602121218_repair_chat_push_token_state` | 92% |
| `20260602184000_course_submissions.sql` | `20260602135707_course_submissions_repair` | 100% |
| `20260603133500_portfolio_moderation.sql` | `20260603084038_portfolio_moderation` | 86% |
| `20260707110036_grant_adilkhan_course_creator_access.sql` | `20260707060156_grant_adilkhan_course_creator_access` | 97% |
| `20260715195621_lock_course_invites_and_submission_videos.sql` | `20260715201141_lock_course_invites_and_submission_videos` | 100% |
| `20260715215436_apple_consumable_credit_topups.sql` | `20260715224911_apple_consumable_credit_topups` | 98% |
| `20260715223938_app_store_sandbox_review_allowlist.sql` | `20260715224939_app_store_sandbox_review_allowlist` | 98% |
| `20260715225000_tighten_apple_store_ledger_grants.sql` | `20260715225157_tighten_apple_store_ledger_grants` | 100% |
| `20260715232004_accept_resigned_app_store_subscription_replays.sql` | `20260715233820_accept_resigned_app_store_subscription_replays` | 100% |
| `20260715232633_app_store_verified_revocations.sql` | `20260715233831_app_store_verified_revocations` | 100% |
| `20260716050000_app_store_consumable_refunds.sql` | `20260716014701_app_store_consumable_refunds` | 100% |
| `20260716060000_app_store_server_notifications.sql` | `20260716014712_app_store_server_notifications` | 100% |
| `20260716070000_app_store_server_notification_indexes.sql` | `20260716015122_app_store_server_notification_indexes` | 100% |
| `20260716181937_x5_store_backend_remediation.sql` | `20260716205800_x5_store_backend_remediation` | 100% |
| `20260716214926_image_generation_reliability.sql` | `20260716225124_image_generation_reliability` | 98% |
| `20260717080000_course_video_bucket_limits.sql` | `20260716213136_course_video_bucket_limits` | 100% |
| `20260717090000_google_play_store_entitlements_v2.sql` | `20260716222805_google_play_store_entitlements_v2` | 100% |
| `20260717093000_google_play_store_reconciliation.sql` | `20260716222810_google_play_store_reconciliation` | 100% |
| `20260720211606_legacy_subscription_server_notifications.sql` | `20260720225546_legacy_subscription_server_notifications` | 100% |
| `20260721010000_legacy_subscription_refunds.sql` | `20260720225704_legacy_subscription_refunds` | 100% |
| `20260724090000_fix_image_generation_service_role_guard.sql` | `20260724112240_fix_image_generation_service_role_guard` | 100% |
| `20260724123000_portfolio_automatic_moderation_queue.sql` | `20260724130927_portfolio_automatic_moderation_queue` | 100% |
| `20260724130000_repair_course_author_from_unique_nickname.sql` | `20260724130914_repair_course_author_from_unique_nickname` | 100% |
| `20260724134000_harden_portfolio_moderation_cas.sql` | `20260724133609_harden_portfolio_moderation_cas` | 100% |
| `20260725193000_startup_chat_idempotency.sql` | `20260726112723_startup_chat_idempotency` | 100% |
| `20260725201500_fruit_story_idempotency.sql` | `20260726120047_fruit_story_idempotency_20260726` | 100% |
| `20260726163631_video_generation_jobs.sql` | `20260726120013_video_generation_jobs_20260726` | 100% |
| `20260726170000_video_reconciliation_cron_secret.sql` | `20260726120801_video_reconciliation_cron_secret_20260726` | 100% |
| `20260726184500_video_openai_provider.sql` | `20260726124521_video_openai_provider_20260726` | 100% |
| `20260726193000_portfolio_automatic_only_moderation.sql` | `20260726164801_portfolio_automatic_only_moderation` | 100% |
| `20260726213000_repeatable_sandbox_consumables.sql` | `20260726163905_repeatable_sandbox_consumables` | 100% |
| `20260728010000_hub_tasks_immediately_visible.sql` | `20260728133038_hub_tasks_immediately_visible` | 100% |
| `20260728121500_portfolio_default_pending.sql` | `20260728134132_portfolio_default_pending` | 100% |

Где совпадение меньше 100%, авторитетна версия в проде (её можно выгрузить:
`select statements from supabase_migrations.schema_migrations where version = '…'`).

### Только локально, объекты уже есть в проде (применены вручную вне истории)

| Локальный файл | Что видно в проде |
|---|---|
| `20260517180500_followers.sql` | таблица `followers` есть; строки истории нет |
| `20260517193000_chat_read_push_state.sql` | функции `x5_message_preview`, `x5_handle_new_message`, `x5_mark_chat_read` есть; поглощён `20260602121218_repair_chat_push_token_state` (94% общих идентификаторов) |
| `20260517193100_generation_credits.sql` | `spend_generation_credits`/`refund_generation_credits` есть; 80% операторов совпадает с `20260531134703_credit_expiration_policy` |
| `20260601153500_task_priority_and_credit_expiry.sql` | `tasks.public_visible_at`, `task_notification_queue`, `x5_user_has_active_verified_badge` есть |
| `20260630165000_adilkhan_developer_access.sql` | `x5_is_developer`, политики `courses developer *` есть; 91% операторов совпадает с `20260707060156` |
| `20260801121000_portfolio_automatic_moderation_enforcement.sql` | триггер `portfolio_items_moderation_guard`, таблица `portfolio_moderation_jobs` есть, но совпадает только 34% операторов — повторно не применять без сравнения с продом |

### Только локально, в проде нет — не применять

| Локальный файл | Примечание |
|---|---|
| `20260517194500_social_notifications.sql` | нет `portfolio_item_likes` и `x5_notify_new_task_followers` (таблица `notifications` пришла из другой миграции) |
| `20260518143000_portfolio_comments.sql` | нет `portfolio_item_comments` |
| `20260726224500_account_deletion_voice_cleanup.sql` | список аудита: сломает удаление аккаунта |
| `20260726233000_course_video_upload_slots.sql` | нет `course_video_upload_slots`; в `feature/bunny-stream-course-video` файл удалён (заменён Bunny) |
| `20260801115000_push_tokens_contract.sql`, `20260801120000_secure_push_dispatch.sql`, `20260801122000_secure_chat_attachments.sql`, `20260801123000_private_portfolio_media.sql` | список аудита: сломают web push и медиа в чатах |

**Подводный камень:** iOS-код (`X5/Services/PortfolioService.swift`) ходит в
`rest/v1/portfolio_item_likes` и `rest/v1/portfolio_item_comments`, которых в
проде нет, а исходник `create-course-video-upload` в `release/ios` вызывает
`claim_course_video_upload_slot`, которой тоже нет. Это отдельные баги, к
истории миграций не относятся.

### Только в проде, файла здесь нет (32 версии)

`20260529032127_add_adilkhan_developer_email`,
`20260529035159_adilkhan_developer_courseup_and_delete_account`,
`20260529042034_harden_is_x5_developer_search_path`,
`20260529053527_delete_account_storage_cleanup_v2`,
`20260529054505_delete_account_storage_api_manifest`,
`20260531134703_credit_expiration_policy`,
`20260602122109_repair_chat_task_columns_for_push`,
`20260603084216_portfolio_moderation_policy_repair`,
`20260603084300_portfolio_moderation_policy_cleanup`,
`20260603084803_portfolio_moderation_policy_owner_sync`,
`20260619125204_iap_claim_grants_credits`,
`20260619125309_profiles_subscription_type_plan_tiers`,
`20260619133527_iap_product_aliases`,
`20260620101631_iap_transfer_deleted_account`,
`20260707060308_harden_x5_developer_gate_security_invoker`,
`20260710101819_android_iap_entitlements_v2`,
`20260710101927_drop_duplicate_iap_user_index`,
`20260710104658_shared_chat_delivery`,
`20260710105752_deduplicate_chat_delivery`,
`20260715201307_add_course_runtime_fields`,
`20260715203023_redeem_course_invite_atomic`,
`20260715203032_secure_operational_tables`,
`20260715203948_lock_internal_security_definer_functions`,
`20260715204032_atomic_course_and_lesson_purchases`,
`20260715204435_fix_purchase_lesson_ambiguous_array`,
`20260724212148_course_owner_update_authorization`,
`20260724213048_restore_course_developer_update_authorization`,
`20260726180605_revoke_public_account_delete_helper`,
`20261001123023_trend_video_templates` (веб),
`20261001124225_trend_video_provider` (веб),
`20261001131758_trend_meme_templates` (веб),
`20261001145151_trend_segments` (веб).

## Команды, которые привели бы историю в порядок

> **НЕ ЗАПУСКАТЬ БЕЗ ПОДТВЕРЖДЕНИЯ ВЛАДЕЛЬЦА.** Шаги A–C меняют только файлы
> в git; шаг D пишет в таблицу истории прода (схему не меняет).

### A. Переименовать 33 файла в версии прода

```bash
git mv supabase/migrations/20260602170400_repair_chat_push_token_state.sql supabase/migrations/20260602121218_repair_chat_push_token_state.sql
git mv supabase/migrations/20260602184000_course_submissions.sql supabase/migrations/20260602135707_course_submissions_repair.sql
git mv supabase/migrations/20260603133500_portfolio_moderation.sql supabase/migrations/20260603084038_portfolio_moderation.sql
git mv supabase/migrations/20260707110036_grant_adilkhan_course_creator_access.sql supabase/migrations/20260707060156_grant_adilkhan_course_creator_access.sql
git mv supabase/migrations/20260715195621_lock_course_invites_and_submission_videos.sql supabase/migrations/20260715201141_lock_course_invites_and_submission_videos.sql
git mv supabase/migrations/20260715215436_apple_consumable_credit_topups.sql supabase/migrations/20260715224911_apple_consumable_credit_topups.sql
git mv supabase/migrations/20260715223938_app_store_sandbox_review_allowlist.sql supabase/migrations/20260715224939_app_store_sandbox_review_allowlist.sql
git mv supabase/migrations/20260715225000_tighten_apple_store_ledger_grants.sql supabase/migrations/20260715225157_tighten_apple_store_ledger_grants.sql
git mv supabase/migrations/20260715232004_accept_resigned_app_store_subscription_replays.sql supabase/migrations/20260715233820_accept_resigned_app_store_subscription_replays.sql
git mv supabase/migrations/20260715232633_app_store_verified_revocations.sql supabase/migrations/20260715233831_app_store_verified_revocations.sql
git mv supabase/migrations/20260716050000_app_store_consumable_refunds.sql supabase/migrations/20260716014701_app_store_consumable_refunds.sql
git mv supabase/migrations/20260716060000_app_store_server_notifications.sql supabase/migrations/20260716014712_app_store_server_notifications.sql
git mv supabase/migrations/20260716070000_app_store_server_notification_indexes.sql supabase/migrations/20260716015122_app_store_server_notification_indexes.sql
git mv supabase/migrations/20260716181937_x5_store_backend_remediation.sql supabase/migrations/20260716205800_x5_store_backend_remediation.sql
git mv supabase/migrations/20260716214926_image_generation_reliability.sql supabase/migrations/20260716225124_image_generation_reliability.sql
git mv supabase/migrations/20260717080000_course_video_bucket_limits.sql supabase/migrations/20260716213136_course_video_bucket_limits.sql
git mv supabase/migrations/20260717090000_google_play_store_entitlements_v2.sql supabase/migrations/20260716222805_google_play_store_entitlements_v2.sql
git mv supabase/migrations/20260717093000_google_play_store_reconciliation.sql supabase/migrations/20260716222810_google_play_store_reconciliation.sql
git mv supabase/migrations/20260720211606_legacy_subscription_server_notifications.sql supabase/migrations/20260720225546_legacy_subscription_server_notifications.sql
git mv supabase/migrations/20260721010000_legacy_subscription_refunds.sql supabase/migrations/20260720225704_legacy_subscription_refunds.sql
git mv supabase/migrations/20260724090000_fix_image_generation_service_role_guard.sql supabase/migrations/20260724112240_fix_image_generation_service_role_guard.sql
git mv supabase/migrations/20260724123000_portfolio_automatic_moderation_queue.sql supabase/migrations/20260724130927_portfolio_automatic_moderation_queue.sql
git mv supabase/migrations/20260724130000_repair_course_author_from_unique_nickname.sql supabase/migrations/20260724130914_repair_course_author_from_unique_nickname.sql
git mv supabase/migrations/20260724134000_harden_portfolio_moderation_cas.sql supabase/migrations/20260724133609_harden_portfolio_moderation_cas.sql
git mv supabase/migrations/20260725193000_startup_chat_idempotency.sql supabase/migrations/20260726112723_startup_chat_idempotency.sql
git mv supabase/migrations/20260725201500_fruit_story_idempotency.sql supabase/migrations/20260726120047_fruit_story_idempotency_20260726.sql
git mv supabase/migrations/20260726163631_video_generation_jobs.sql supabase/migrations/20260726120013_video_generation_jobs_20260726.sql
git mv supabase/migrations/20260726170000_video_reconciliation_cron_secret.sql supabase/migrations/20260726120801_video_reconciliation_cron_secret_20260726.sql
git mv supabase/migrations/20260726184500_video_openai_provider.sql supabase/migrations/20260726124521_video_openai_provider_20260726.sql
git mv supabase/migrations/20260726193000_portfolio_automatic_only_moderation.sql supabase/migrations/20260726164801_portfolio_automatic_only_moderation.sql
git mv supabase/migrations/20260726213000_repeatable_sandbox_consumables.sql supabase/migrations/20260726163905_repeatable_sandbox_consumables.sql
git mv supabase/migrations/20260728010000_hub_tasks_immediately_visible.sql supabase/migrations/20260728133038_hub_tasks_immediately_visible.sql
git mv supabase/migrations/20260728121500_portfolio_default_pending.sql supabase/migrations/20260728134132_portfolio_default_pending.sql
```

После A обновить ссылки на старые имена (иначе упадут контрактные тесты):
`scripts/tests/test_portfolio_moderation_source.py` (20260724123000,
20260724134000, 20260726193000, 20260728121500),
`scripts/tests/test_course_author_data_repair_migration_source.py`
(20260724130000), `supabase/tests/image_generation_reliability_contract_test.mjs`
(20260716214926, 20260724090000),
`supabase/tests/google_play_store_entitlements_v2_contract_test.mjs`
(20260717090000), `supabase/tests/google_play_store_reconciliation_contract_test.mjs`
(20260717093000), `supabase/tests/video_generation_openai_provider_contract_test.mjs`
(20260726184500), `supabase/tests/hub_task_immediate_visibility_contract_test.mjs`
(20260728010000), `diagnostics/x5-audit/sql-race-runtime.mjs` (несколько),
`docs/superpowers/plans/2026-07-16-ios-consumable-refunds.md`. Проверка:
`git grep -n <старая версия>`.

### B. Убрать из `supabase/migrations` то, что применять нельзя

```bash
mkdir -p supabase/migrations-not-applied
git mv supabase/migrations/20260517194500_social_notifications.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260518143000_portfolio_comments.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260726224500_account_deletion_voice_cleanup.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260726233000_course_video_upload_slots.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260801115000_push_tokens_contract.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260801120000_secure_push_dispatch.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260801122000_secure_chat_attachments.sql supabase/migrations-not-applied/
git mv supabase/migrations/20260801123000_private_portfolio_media.sql supabase/migrations-not-applied/
```

(`supabase/BACKEND_RELEASE_READINESS.md` ссылается на 20260801* и
20260726224500 — поправить пути.)

### C. Достать файлы для 32 версий, которые есть только в проде

Выгрузка в отдельную папку, чтобы не перезаписать локальные файлы:

```bash
mkdir -p ../x5-history && cd ../x5-history
supabase init
supabase link --project-ref afwznqjpshybmqhlewmy
supabase migration fetch --linked
# скопировать в ios/supabase/migrations только 32 версии из списка выше
```

Четыре `trend_*` принадлежат веб-репо: пока оба репозитория пишут в одну базу,
каждый из них должен содержать файлы другого (или миграции надо держать в
одном репозитории — это правильное решение).

### D. Запись в историю прода

```bash
# НЕ ЗАПУСКАТЬ БЕЗ ПОДТВЕРЖДЕНИЯ ВЛАДЕЛЬЦА
# объекты уже в проде, файлы остаются, отмечаем как применённые без выполнения
supabase migration repair --linked --status applied 20260517180500 20260517193000 20260517193100 20260601153500 20260630165000 20260801121000
# после ручного применения трёх новых файлов (раздел выше)
supabase migration repair --linked --status applied 20261002130000 20260903150000 20260925090000
```

`--status reverted` для прод-только версий **не** использовать: это сотрёт их
строки из истории, и веб-репо начнёт считать свои миграции неприменёнными.

### E. Проверка

```bash
supabase migration list --linked   # локальные и удалённые версии должны совпасть построчно
```

`supabase db push --dry-run` — только после того, как `migration list` чистый.
