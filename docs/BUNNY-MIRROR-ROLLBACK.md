# Bunny mirror — карта отката (урок → старая ссылка)

Режим «без новой сборки»: функция `course-video-bunny-mirror` меняет `videoUrl` урока с объекта Supabase `videos` на `https://vz-d2ffe898-fa1.b-cdn.net/<guid>/playlist.m3u8`. Секретов здесь нет, только публичные ссылки.

Полная история после запуска — в таблице `public.course_video_mirror_jobs` (`source_url` → `hls_url`, `bunny_video_id`, статус). Откат урока: вернуть `videoUrl = source_url` (пока `status <> 'storage_deleted'`, файл ещё в Supabase).

## Снимок dry-run, 2026-10-01 (ещё не выполнялось)

Публичных курсов: 0. Кандидаты — только 2 скрытых тест-курса.

| Курс | Урок | Старая ссылка (videos/…) | Размер |
|---|---|---|---|
| 753cd9bd-2c7b-49c7-969e-badad92f55f5 «ТЕСТ — удалить» | lesson_46A652AC-8790-4B44-A304-940F1C22D31B | courses/753cd9bd-2c7b-49c7-969e-badad92f55f5/lesson_46A652AC-8790-4B44-A304-940F1C22D31B-141ef1f5e1980537.mp4 | 11.1 МБ |
| 497f610e-8612-4b08-8f21-67f91ec93501 «Тест» | lesson_E43F20F8-B2C6-4838-9E81-202864717743 | courses/497f610e-8612-4b08-8f21-67f91ec93501/lesson_E43F20F8-B2C6-4838-9E81-202864717743-c085d5f9502428d4.mp4 | 40.0 МБ |
| 497f610e-8612-4b08-8f21-67f91ec93501 «Тест» | lesson_22FC1A66-EFE9-4AB3-A99F-5F63C5FE1C87 | courses/497f610e-8612-4b08-8f21-67f91ec93501/lesson_22FC1A66-EFE9-4AB3-A99F-5F63C5FE1C87-76f458588fac57fc.mp4 | 40.0 МБ |

Префикс ссылок: `https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/`.

Не привязаны ни к одному уроку (функция их не трогает): 3 файла в `videos/courses/` (~64 МБ, в т.ч. курс `c02ca43f…`, которого нет) и 2 файла `course-submissions/` (45 МБ).

## Запуск (после подтверждения Диаса)

1. Секрет `COURSE_VIDEO_CRON_SECRET` (≥ 32 случайных символа) в Edge Secrets и тот же в Vault `x5_course_video_cron_secret`.
2. Применить `supabase/migrations/20261002140000_course_video_bunny_mirror.sql`.
3. `supabase functions deploy course-video-bunny-mirror --project-ref afwznqjpshybmqhlewmy`.
4. Тест-курс: POST `/functions/v1/course-video-bunny-mirror` с заголовком `X-X5-Reconcile-Secret` и телом `{"course_id":"753cd9bd-2c7b-49c7-969e-badad92f55f5"}` — повторять до `swapped`; затем `{"course_id":"…","delete_grace_minutes":0}` → `storage_deleted`. Проверить `curl` плейлист + сегмент.
5. Все курсы: `{"dry_run":true}` → без `course_id`. Удаление по умолчанию через 24 ч после замены ссылки (защита от редактора, который сохранит старую копию курса).
6. Cron: `select cron.schedule('x5-course-video-bunny-mirror','*/5 * * * *','select public.enqueue_course_video_bunny_mirror();');` — тогда новые загрузки из текущего приложения тоже уходят в Bunny, а Supabase очищается.

Токен-авторизацию Bunny в этом режиме НЕ включать: текущие приложения не умеют подписывать ссылки, видео перестанут играть.
