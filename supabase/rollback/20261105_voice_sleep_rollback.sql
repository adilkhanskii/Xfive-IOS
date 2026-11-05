-- Откат 20261105210000_voice_sleep.sql.
-- ВНИМАНИЕ: спящие голоса (asleep = true) у ElevenLabs удалены; после отката
-- они перестанут работать. Перед откатом разбудить их озвучкой или удалить.
drop function if exists public.mark_user_voice_awake(text, text);
drop function if exists public.mark_user_voice_asleep(text, text, integer);
drop function if exists public.user_voice_sleep_candidates(text, integer);
drop function if exists public.set_user_voice_sample(text, text);
drop function if exists public.touch_user_voice(text);
drop function if exists public.user_voice_state(uuid, text);
drop index if exists public.user_voices_awake_lru_idx;
alter table public.user_voices
  drop constraint if exists user_voices_asleep_has_sample,
  drop constraint if exists user_voices_sample_path_valid,
  drop constraint if exists user_voices_live_voice_id_valid,
  drop column if exists last_used_at,
  drop column if exists sample_path,
  drop column if exists asleep,
  drop column if exists live_voice_id;
-- bucket voice-samples оставляем (записи пользователей); удалить вручную, если нужно.
delete from supabase_migrations.schema_migrations where version = '20261105210000';
