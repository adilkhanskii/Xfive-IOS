-- Edge functions use the service role after authenticating and pinning every
-- row to the caller. Browser clients still receive only the narrow RLS grants.
grant select, insert, update, delete on table public.generated_assets
  to service_role;
grant select, insert, update, delete on table public.ai_characters
  to service_role;
grant select, insert, update, delete on table public.user_ai_presets
  to service_role;
grant select, insert, update on table public.ai_provider_health
  to service_role;
grant select on table public.lipsync_generation_jobs to service_role;
grant select, insert, update on table public.ai_influencer_jobs
  to service_role;
