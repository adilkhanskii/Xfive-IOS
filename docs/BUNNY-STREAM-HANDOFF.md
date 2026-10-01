# Bunny Stream для видео уроков — передача и выкладка

Дата: 2026-10-01. Ветки: `ios` и `android-web` → `feature/bunny-stream-course-video`.
Ничего не выложено: SQL не применён, функции не задеплоены, в main не пушилось.

> **Сначала режим «без новой сборки» (решение Диаса):** `docs/BUNNY-MIRROR-ROLLBACK.md` + функция `course-video-bunny-mirror`. Пока уроки играют через простые `.m3u8` ссылки (текущие iOS 243 и сайт), токен-авторизацию Bunny (шаг 7) **не включать**. Подписанный режим ниже — следующий этап, после обновления приложений.

## Что сделано

| Часть | Где |
|---|---|
| Загрузка (TUS, оригинал без сжатия) | `supabase/functions/create-course-video-upload` — проверка JWT → RPC-брокер только для service_role (флаг, автор курса/разработчик, лимит) → видео в Bunny → подпись TUS |
| Просмотр | `supabase/functions/course-video-playback` — `course_video_playback_grant` (куплен курс/урок, бесплатный курс, превью, автор, разработчик) → HLS-ссылка с токеном, живёт 2 ч (или длина урока + 1 ч, максимум 12 ч) |
| Готовность и уборка | `supabase/functions/course-video-status` — вебхук Bunny (статус всегда перечитывается через API), опрос из редактора, cron раз в 10 мин: обновить зависшие, удалить брошенные/ошибочные/заменённые (только из своего журнала) |
| SQL (черновики) | `supabase/drafts/bunny-stream/` — журнал `course_video_assets`, RPC, флаг, cron, откат; `supabase/drafts/20261001093000_cleanup_http_and_cron_logs.sql` |
| iOS | флаг `bunny_course_video_upload` читается в рантайме; при выключенном флаге или 503 — старый путь Supabase (теперь всегда H.264 mp4 + faststart, даже до 47 МБ). Плеер: Bunny-урок → подписанный HLS в AVPlayer, при протухании ссылки — новая |
| Web/Android | `android-web/web`: hls.js (отдельный чанк), подписанный HLS, загрузка через tus-js-client при включённом флаге. Android = WebView на сайт, новый APK не нужен |
| Перенос старых видео | `scripts/bunny/migrate-course-videos-to-bunny.mjs` — по умолчанию dry-run |

Формат урока в `courses.categories`: `videoProvider: "bunny"`, `bunnyVideoId: "<guid>"`, `videoStatus`. Публичного `videoUrl` у Bunny-урока нет.

## Проверка перед включением токенов (важно)

Библиотека 625830 (`vz-d2ffe898-fa1.b-cdn.net`) уже содержит 14 видео / 11.4 ГБ. На 2026-10-01 в базе на Bunny ссылается только `system_config.lesson_videos` (4 старых embed-ссылки для уроков `tg_l3`, `vc_l4`, `lesson_1774950433112`, `lesson_1775731775986` — таких уроков нет ни в одном курсе). Уроки курсов на Bunny не ссылаются. iOS и web превращают старые iframe-ссылки в неподписанный HLS — после включения токенов такие ссылки перестанут играть, поэтому прямо перед включением повторить:

```sql
select table_name, (xpath('/row/c/text()', query_to_xml(format(
  'select count(*) c from public.%I t where t::text ~* %L', table_name,
  'vz-d2ffe898|mediadelivery\.net|625830'), false, true, '')))[1]::text::int n
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE';
```

Ожидается: только `system_config` = 1. Если появились уроки с `iframe.mediadelivery.net` — сначала перенести их на `bunnyVideoId`.

## Выкладка по шагам

1. **Ревью и мерж** веток в рабочие (release) ветки. CI: `ios-course-ci.yml` уже проверяет три функции (deno fmt/lint/check + node --test).
2. **Секреты функций** (Supabase → Edge Functions → Secrets). Уже есть: `BUNNY_STREAM_LIBRARY_ID`, `BUNNY_STREAM_API_KEY`, `BUNNY_STREAM_CDN_HOSTNAME`, `BUNNY_STREAM_TOKEN_KEY`. Добавить: `COURSE_VIDEO_CRON_SECRET` (случайная строка ≥ 32 символов). По желанию: `BUNNY_STREAM_WEBHOOK_SECRET`.
3. **Vault**: секрет `x5_course_video_cron_secret` с тем же значением, что `COURSE_VIDEO_CRON_SECRET`.
4. **SQL**: применить `drafts/bunny-stream/20261001090000_course_video_assets.sql` (флаг создаётся выключенным; прототип `course_video_upload_slots` удаляется, если был).
5. **Функции**: `supabase functions deploy create-course-video-upload course-video-playback course-video-status --project-ref afwznqjpshybmqhlewmy` (из папки `ios`; `config.toml` выключает JWT у шлюза для playback/status — проверка внутри).
6. **Bunny, вручную у клиента** (библиотека 625830):
   - Encoding: разрешения 480p, 720p, 1080p (240/360 по желанию).
   - Webhook URL: `https://afwznqjpshybmqhlewmy.supabase.co/functions/v1/course-video-status` (+ `?secret=<BUNNY_STREAM_WEBHOOK_SECRET>`, если задан).
   - Security: «Block direct URL file access» и список referrer не должны блокировать приложение (у нативного плеера нет referrer). CORS для `.m3u8/.ts` должен быть включён (нужно для hls.js на сайте).
7. **Токены (последний ручной шаг перед реальными уроками)**: повторить проверку выше → включить CDN Token Authentication на pull zone `vz-d2ffe898-fa1`, ключ = `BUNNY_STREAM_TOKEN_KEY`. Проверить: прямая ссылка `https://vz-d2ffe898-fa1.b-cdn.net/<guid>/playlist.m3u8` → 403; ссылка из `course-video-playback` → 200 на плейлист и на один сегмент. Если подписанная ссылка не открывается — до исправления поставить `BUNNY_STREAM_PLAYBACK_SIGNING=none` и **не включать флаг загрузки** (иначе платные уроки будут открыты).
8. **Cron**: применить `drafts/bunny-stream/20261001091000_course_video_reconcile_cron.sql`.
9. **Проверка на скрытом тест-курсе** `753cd9bd-…` : включить флаг → загрузить видео с iOS (TestFlight) и с сайта → статус «обрабатывается» → вебхук → «готово» → смотреть как автор, как покупатель, как чужой (должен быть «Урок закрыт»), как гость (только превью).
10. **Клиенты**: выложить сайт (Android получит сразу), выпустить iOS-сборку.
11. **Флаг для всех**: `update public.app_feature_flags set enabled = true, updated_at = now() where key = 'bunny_course_video_upload';` — лучше после того, как большинство обновит iOS (старые сборки Bunny-уроки не покажут).
12. **Перенос старых видео** (сейчас их 2, оба в тест-курсах): `node scripts/bunny/migrate-course-videos-to-bunny.mjs` (dry-run) → `--apply` (videoUrl остаётся для старых сборок) → когда всё `ready` и старые сборки ушли: `--strip-legacy --apply` → через 2+ недели `--strip-legacy --delete-storage --apply`. Откат: `--rollback <manifest.json> --apply`. Ключи только из локального окружения (`SUPABASE_SERVICE_ROLE_KEY`, `BUNNY_STREAM_API_KEY`), в файлы не писать. Если Bunny не примет потоковую загрузку без длины — альтернатива: Bunny «Fetch video» по публичной ссылке.
13. **Логи (независимо)**: применить `drafts/20261001093000_cleanup_http_and_cron_logs.sql`, после первого запуска один раз `vacuum (full, analyze) net._http_response; vacuum (full, analyze) cron.job_run_details;` в тихое время (~170 МБ вернутся).

## Откат

- Быстрый: выключить флаг → новые загрузки снова идут в Supabase. Уже загруженные Bunny-уроки продолжают играть.
- Полный: `--rollback` скрипта переноса → `drafts/bunny-stream/rollback_course_video_assets.sql`. Bunny-видео не удаляются автоматически при откате SQL.
- Токены Bunny выключать только если ни один платный урок не на Bunny.

## Риски

- Swift не собирался (нет Xcode на Windows) — первая сборка в CI/Xcode может потребовать мелких правок.
- Подпись токена сделана по алгоритму из документации Bunny (directory token); реальная проверка — шаг 7.
- Старые iOS-сборки и закешированный сайт не играют Bunny-уроки без `videoUrl`.
- `videoStatus` в уроке — подсказка; редактор может перезаписать её старым значением, источник правды — журнал `course_video_assets`.
- Видео заявок (submissions) остаются в Supabase Storage.
- Модерации видео уроков нет: загружать могут только автор курса и 2 разработчика.
