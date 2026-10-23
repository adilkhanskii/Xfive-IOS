-- Emergency rollback only. Restores the old, known renewal-race behavior.
-- Does NOT change ledger rows, prices, credits or current profile values.
begin;
set local lock_timeout = '5s';
do $rollback$
declare
  old_definition text;
  new_definition text;
  current_body text;
  removed_block text := E'  -- Lock before reading sources: a concurrent renewal/refund may have updated\n  -- the ledger while we waited. The subsequent SELECT gets a fresh snapshot.\n  perform 1 from public.profiles where id = p_user_id for update;\n  if not found then return null; end if;\n  v_now := clock_timestamp();\n\n';
begin
  select replace(pg_get_functiondef(oid), chr(13), ''), replace(prosrc, chr(13), '')
    into old_definition, current_body
    from pg_proc where oid = 'public.x5_rebuild_app_store_verified_profile(uuid)'::regprocedure;
  if md5(current_body) <> '44ccbde3b58a8f601bdba37eb680887b' then
    raise exception 'Unexpected projection revision; rollback aborted';
  end if;
  new_definition := replace(old_definition, removed_block, '');
  if new_definition = old_definition then raise exception 'No exact rollback match'; end if;
  execute new_definition;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid =
      'public.x5_rebuild_app_store_verified_profile(uuid)'::regprocedure)
      <> 'f8bb9d553246003b47aa2fd5b4e030dc' then
    raise exception 'Rollback checksum mismatch';
  end if;
end;
$rollback$;
-- Keep the deployment history. Record a separate forward rollback migration
-- if this emergency script is ever used; do not delete migration history.
commit;
