-- Run in the same transaction, immediately before the matching migration.
-- Observed production body matches the isolated PostgreSQL counterexample.
do $preflight$
begin
  -- The Windows SQL editor may send CRLF; line endings are not SQL behavior.
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid =
      'public.x5_rebuild_app_store_verified_profile(uuid)'::regprocedure)
      <> 'f8bb9d553246003b47aa2fd5b4e030dc' then
    raise exception 'Verified projection changed: stop and re-audit, do not overwrite';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations
             where version = '20260907070000') then
    raise exception 'Migration already recorded: inspect rather than replay';
  end if;
end;
$preflight$;
