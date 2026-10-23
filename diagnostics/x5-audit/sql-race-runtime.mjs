/**
 * Disposable SQL-only acceptance harness. No network, published ports, host
 * mounts, image pull, production endpoint, or real purchase is involved.
 * Payment business SQL is loaded verbatim from SOURCE_REV, not reimplemented.
 * Run: node diagnostics/x5-audit/sql-race-runtime.mjs
 * Fix check: node diagnostics/x5-audit/sql-race-runtime.mjs --with-fix
 */
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const sourceRev = '512f5463c97daa282ea66ea83050a7a489d1fc18';
assert(process.argv.slice(2).every(arg => arg === '--with-fix'), 'only --with-fix is supported');
const withFix = process.argv.includes('--with-fix');
const fixMigration = 'supabase/migrations/20260907070000_serialize_verified_profile_projection.sql';
const image = 'postgres:17';
const auditId = randomUUID();
const container = `x5-audit-payment-sql-${auditId.slice(0, 8)}`;
const reportPath = join(here, withFix ? 'sql-race-fixed-result.json' : 'sql-race-runtime-result.json');
const report = {
  startedAt: new Date().toISOString(), sourceRev, image, container,
  mode: withFix ? 'baseline_plus_working_tree_fix' : 'baseline_counterexample',
  scope: 'SQL-only; synthetic users and decoded-transaction RPC inputs; no Apple signature, StoreKit, bank or live backend validation',
  sourceManifest: [], checks: [], sessions: [], cleanup: null,
};
let created = false;

function command(executable, args, input, timeout = 30000) {
  const result = spawnSync(executable, args, {
    cwd: repo, encoding: 'utf8', input, windowsHide: true,
    timeout, maxBuffer: 12 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${executable} ${args[0]} failed: ${result.error?.message ?? result.status}\n${result.stderr ?? ''}\n${result.stdout ?? ''}`);
  }
  return result.stdout.trim();
}

function sql(text) {
  return command('docker', ['exec', '-i', container, 'psql', '-X', '-qAt',
    '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'x5_audit'],
  `SET statement_timeout = '20s';\n${text}\n`, 25000);
}

function jsonSql(text) {
  const output = sql(text);
  return JSON.parse(output.split(/\r?\n/).filter(Boolean).at(-1));
}

function source(path) {
  const content = command('git', ['show', `${sourceRev}:${path}`]);
  report.sourceManifest.push({path, sha256: createHash('sha256').update(content).digest('hex'),
    hashNormalization:'leading/trailing whitespace trimmed; SQL statements unchanged'});
  return content;
}

function extractFunction(content, name) {
  const start = content.indexOf(`create or replace function public.${name}(`);
  assert(start >= 0, `missing real function ${name}`);
  const tail = content.slice(start);
  const tag = /\bas\s+(\$[A-Za-z_0-9]*\$)/i.exec(tail);
  assert(tag, `missing SQL dollar body: ${name}`);
  const end = tail.indexOf(tag[1], tag.index + tag[0].length);
  assert(end >= 0);
  const statement = tail.slice(0, end + tag[1].length + 1);
  assert(statement.endsWith(';'));
  return statement;
}

function bootstrap() {
  sql(readFileSync(join(here, 'fixture-infrastructure.sql'), 'utf8'));
  const helper = source('supabase/migrations/20260601153500_task_priority_and_credit_expiry.sql');
  sql(extractFunction(helper, 'x5_profile_has_active_verified_badge'));
  sql(extractFunction(helper, 'x5_prepare_credit_retention'));
  const triggerStart = helper.indexOf('create trigger profiles_credit_retention');
  assert(triggerStart >= 0);
  sql(helper.slice(triggerStart, helper.indexOf(';', triggerStart) + 1));
  const files = [
    '20260714154000_entitlement_hardening.sql',
    '20260714160000_verified_app_store_transaction_ledger.sql',
    '20260714193941_reject_sandbox_app_store_transactions.sql',
    '20260714194747_grandfather_exact_legacy_app_store_bindings.sql',
    '20260715215436_apple_consumable_credit_topups.sql',
    '20260715223938_app_store_sandbox_review_allowlist.sql',
    '20260715232004_accept_resigned_app_store_subscription_replays.sql',
    '20260715232633_app_store_verified_revocations.sql',
    '20260716050000_app_store_consumable_refunds.sql',
    '20260716060000_app_store_server_notifications.sql',
    '20260716070000_app_store_server_notification_indexes.sql',
    '20260716181937_x5_store_backend_remediation.sql',
    '20260720211606_legacy_subscription_server_notifications.sql',
    '20260721010000_legacy_subscription_refunds.sql',
    '20260726213000_repeatable_sandbox_consumables.sql',
    '20260817190000_credit_retention_enforcement.sql',
    '20260831132000_lock_testflight_sandbox_purchases.sql',
  ];
  for (const file of files) {
    sql(source(`supabase/migrations/${file}`));
    console.log(`migration_loaded ${file}`);
  }
  if (withFix) {
    const fixSql = readFileSync(join(repo, fixMigration), 'utf8');
    report.fixMigration = {path:fixMigration,source:'working_tree',
      sha256:createHash('sha256').update(fixSql).digest('hex')};
    sql(fixSql);
    console.log(`fix_migration_loaded ${fixMigration}`);
  }
  report.databaseVersion = sql('select version();');
  report.transactionIsolation = sql('show default_transaction_isolation;');
}

const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function session(name) {
  const child = spawn('docker', ['exec', '-i', container, 'psql', '-X', '-qAt',
    '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'x5_audit'],
  {cwd: repo, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']});
  const entry = {name, stdout: '', stderr: '', exitCode: null};
  report.sessions.push(entry);
  child.stdout.on('data', chunk => { entry.stdout += chunk; });
  child.stderr.on('data', chunk => { entry.stderr += chunk; });
  const completed = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => {
      entry.exitCode = code;
      if (code === 0) resolve(entry);
      else reject(new Error(`session ${name} failed: ${entry.stderr}`));
    });
  });
  // Mark rejection handled until the explicit await later in the schedule.
  completed.catch(() => {});
  const send = text => child.stdin.write(`${text}\n`);
  send(`set application_name = ${quote(name)}; set statement_timeout = '20s';`);
  return {
    entry, send,
    finish(text = '') { child.stdin.end(`${text}\n\\q\n`); return completed; },
    async waitFor(marker) {
      const deadline = Date.now() + 15000;
      while (!entry.stdout.includes(marker)) {
        if (entry.exitCode !== null) throw new Error(`session exited before ${marker}: ${entry.stderr}`);
        if (Date.now() > deadline) throw new Error(`session timed out before ${marker}: ${entry.stderr}`);
        await sleep(40);
      }
    },
  };
}

async function waitBlocked(name) {
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    const rows = jsonSql(`select coalesce(jsonb_agg(jsonb_build_object(
      'applicationName', application_name, 'pid', pid,
      'waitEventType', wait_event_type, 'waitEvent', wait_event,
      'blockers', pg_blocking_pids(pid))), '[]'::jsonb)
      from pg_stat_activity where datname = 'x5_audit'
      and application_name = ${quote(name)};`);
    const blocked = rows.find(row => row.waitEventType === 'Lock' && row.blockers.length);
    if (blocked) return blocked;
    await sleep(60);
  }
  throw new Error(`expected controlled database lock was not observed: ${name}`);
}

function user(id) {
  sql(`insert into auth.users(id,email) values (${quote(id)}, ${quote(`${id}@example.invalid`)});
    insert into public.profiles(id,email) values (${quote(id)}, ${quote(`${id}@example.invalid`)});`);
}

function seedExpiredBadge(id, chain) {
  user(id);
  sql(`-- Synthetic expired entitlement fixture, not a real purchase.
    insert into public.app_store_entitlement_owners(original_transaction_id,user_id,app_account_token)
      values (${quote(chain)},${quote(id)},${quote(id)});
    insert into public.app_store_transactions(transaction_id,original_transaction_id,user_id,
      product_id,environment,app_account_token,purchase_date,expires_date,signed_date,
      credits_granted,is_verified_product)
      values (${quote(`${chain}-old`)},${quote(chain)},${quote(id)},
      'com.x5studio.app.verified.monthly','Production',${quote(id)},
      clock_timestamp()-interval '31 days',clock_timestamp()-interval '1 minute',
      clock_timestamp()-interval '31 days',0,true);
    update public.profiles set is_verified=true, verified_until=clock_timestamp()-interval '1 minute'
      where id=${quote(id)};`);
}

function badgeGrant(id, chain, tx) {
  return `set role service_role;
    select public.apply_verified_app_store_transaction(
    ${quote(id)},${quote(tx)},${quote(chain)},'com.x5studio.app.verified.monthly',
    'Production',${quote(id)},clock_timestamp()-interval '10 seconds',
    clock_timestamp()+interval '30 days',clock_timestamp(),null);
    reset role;`;
}

function badgeLedger(tx) {
  return jsonSql(`select to_jsonb(t) from public.app_store_transactions t
    where transaction_id=${quote(tx)};`);
}

function profile(id) {
  return jsonSql(`select jsonb_build_object('userId',id,'credits',credits,
    'permanentCredits',permanent_credits,'isVerified',is_verified,'verifiedUntil',verified_until,
    'activeLedgerRows',(select count(*) from public.app_store_transactions
      where user_id=profiles.id and expires_date>clock_timestamp()))
    from public.profiles where id=${quote(id)};`);
}

async function badgeRace() {
  const raceUser = '11111111-1111-4111-8111-111111111111';
  const controlUser = '22222222-2222-4222-8222-222222222222';
  seedExpiredBadge(raceUser, 'x5-audit-race-chain');
  seedExpiredBadge(controlUser, 'x5-audit-control-chain');

  const controlGrant = jsonSql(badgeGrant(controlUser, 'x5-audit-control-chain', 'x5-audit-control-renewal'));
  sql(`select public.x5_rebuild_app_store_verified_profile(${quote(controlUser)});`);
  const control = profile(controlUser);
  assert.equal(controlGrant.status, 'applied');
  assert.equal(control.isVerified, true);
  assert.equal(control.activeLedgerRows, 1);
  report.checks.push({id:'badge_sequential_control',result:'PASS',grant:controlGrant,
    exactLedgerInputs:badgeLedger('x5-audit-control-renewal'),profile:control});

  const a = session('x5-audit-renewal-a');
  a.send(`begin isolation level read committed;
    ${badgeGrant(raceUser, 'x5-audit-race-chain', 'x5-audit-race-renewal')}
    \\echo X5_AUDIT_A_GRANTED`);
  await a.waitFor('X5_AUDIT_A_GRANTED');
  const aPid=Number(sql("select pid from pg_stat_activity where application_name='x5-audit-renewal-a';"));

  const b = session('x5-audit-reconcile-b');
  b.send('select public.x5_reconcile_store_profiles(10000);');
  const lockEvidence = await waitBlocked('x5-audit-reconcile-b');
  assert(lockEvidence.blockers.includes(aPid));
  lockEvidence.expectedBlockingSession={applicationName:a.entry.name,pid:aPid};
  const beforeCommit = profile(raceUser);
  assert.equal(beforeCommit.activeLedgerRows, 0);
  await a.finish('commit;');
  await b.finish();
  const afterRace = profile(raceUser);
  const exactLedgerInputs = badgeLedger('x5-audit-race-renewal');
  const confirmed = afterRace.activeLedgerRows === 1 && !afterRace.isVerified && afterRace.verifiedUntil === null;
  const prevented = afterRace.activeLedgerRows === 1 && afterRace.isVerified &&
    afterRace.verifiedUntil === exactLedgerInputs.expires_date;
  report.checks.push({id:'badge_reconcile_vs_uncommitted_renewal',
    result:withFix ? (prevented ? 'RACE_PREVENTED' : 'FIX_REGRESSION') :
      (confirmed ? 'RACE_CONFIRMED' : 'RACE_NOT_REPRODUCED'),
    lockEvidence,beforeCommit,afterRace,exactLedgerInputs});
  if (withFix) assert(prevented, 'fixed projection did not preserve the exact committed renewal');
  else assert(confirmed, 'source race hypothesis was not reproduced');

  sql(`select public.x5_rebuild_app_store_verified_profile(${quote(raceUser)});`);
  const healed = profile(raceUser);
  assert.equal(healed.isVerified, true);
  assert.equal(healed.activeLedgerRows, 1);
  report.checks.push({id:'badge_subsequent_rebuild_control',result:'PASS',profile:healed});
}

function consumableGrant(id, tx, credits, token = id) {
  return `set role service_role;
    select public.apply_verified_app_store_consumable(
    ${quote(id)},${quote(tx)},${quote(tx)},${quote(`com.x5studio.app.credits.${credits}`)},
    'Production',${quote(token)},'2026-09-01T00:00:00Z','2026-09-01T00:00:01Z',null,1);
    reset role;`;
}

async function exactOnce() {
  const buyer = '33333333-3333-4333-8333-333333333333';
  const other = '44444444-4444-4444-8444-444444444444';
  user(buyer); user(other);
  for (const credits of [1000,2000,5000]) {
    const tx = `x5-audit-pack-${credits}`;
    const grant = jsonSql(consumableGrant(buyer,tx,credits));
    assert.equal(grant.status,'applied');
    assert.equal(grant.credits_granted,credits);
  }
  const afterPacks = profile(buyer);
  assert.equal(afterPacks.credits,8000);
  assert.equal(afterPacks.permanentCredits,8000);
  report.checks.push({id:'P01_SQL_server_catalog_1000_2000_5000',result:'PASS',profile:afterPacks,
    exactLedgerInputs:jsonSql(`select jsonb_agg(to_jsonb(t) order by transaction_id)
      from public.app_store_consumable_transactions t where user_id=${quote(buyer)};`)});

  const tx='x5-audit-pack-concurrent';
  const a=session('x5-audit-consumable-a');
  a.send(`begin; ${consumableGrant(buyer,tx,1000)} \\echo X5_AUDIT_CREDIT_GRANTED`);
  await a.waitFor('X5_AUDIT_CREDIT_GRANTED');
  const b=session('x5-audit-consumable-b');
  b.send(consumableGrant(buyer,tx,1000));
  const lockEvidence=await waitBlocked('x5-audit-consumable-b');
  await a.finish('commit;');
  await b.finish();
  assert(b.entry.stdout.includes('already_applied'));
  for(let attempt=0;attempt<3;attempt++) {
    const replay=jsonSql(consumableGrant(buyer,tx,1000));
    assert.equal(replay.status,'already_applied');
  }
  assert.equal(profile(buyer).credits,9000);
  assert.equal(Number(sql(`select count(*) from public.app_store_consumable_transactions where transaction_id=${quote(tx)};`)),1);
  const rejections=[];
  for (const token of [buyer,other]) {
    try { sql(consumableGrant(other,tx,1000,token)); throw new Error('cross-account unexpectedly granted'); }
    catch(error) {
      assert(/account_token_mismatch|owned_by_other/.test(error.message),error.message);
      rejections.push(error.message.includes('account_token_mismatch')?'account_token_mismatch':'owned_by_other');
    }
  }
  assert.equal(profile(other).credits,0);
  report.checks.push({id:'P03_SQL_concurrent_delivery_replay_and_cross_account',result:'PASS',
    lockEvidence,rejections,buyer:profile(buyer),other:profile(other),ledgerRows:1});

  const refundEvent='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const refund=`set role service_role; select public.apply_verified_app_store_server_notification(
    ${quote(refundEvent)},'REFUND','2026-09-02T00:00:02Z',${quote(buyer)},
    ${quote(tx)},${quote(tx)},'com.x5studio.app.credits.1000','Production',${quote(buyer)},
    '2026-09-01T00:00:00Z',null,'2026-09-02T00:00:01Z','2026-09-02T00:00:00Z',100000,1); reset role;`;
  const firstRefund=jsonSql(refund);
  const refundReplay=jsonSql(refund);
  assert.equal(firstRefund.status,'applied');
  assert.equal(refundReplay.status,'already_applied');
  assert.equal(profile(buyer).credits,8000);
  const reversal=`set role service_role; select public.apply_verified_app_store_server_notification(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','REFUND_REVERSED','2026-09-03T00:00:02Z',${quote(buyer)},
    ${quote(tx)},${quote(tx)},'com.x5studio.app.credits.1000','Production',${quote(buyer)},
    '2026-09-01T00:00:00Z',null,'2026-09-03T00:00:01Z',null,null,1); reset role;`;
  const reversed=jsonSql(reversal);
  const reversalReplay=jsonSql(reversal);
  assert.equal(reversed.status,'applied');
  assert.equal(reversalReplay.status,'already_applied');
  assert.equal(profile(buyer).credits,9000);
  report.checks.push({id:'P03_SQL_refund_and_reversal_webhook_replay',result:'PASS',
    firstRefund,refundReplay,reversed,reversalReplay,profile:profile(buyer),
    exactEvents:jsonSql(`select jsonb_agg(to_jsonb(e) order by transaction_signed_date)
      from public.app_store_server_notification_events e where transaction_id=${quote(tx)};`)});
}

function verifyDDLRecovery() {
  // Prove the emergency function rollback on synthetic data only. This is NOT
  // a database backup/restore test and never invokes the rolled-back race.
  const fingerprint = () => sql(`select md5(jsonb_build_object(
    'profiles',(select jsonb_agg(to_jsonb(p) order by id) from public.profiles p),
    'consumables',(select jsonb_agg(to_jsonb(t) order by transaction_id) from public.app_store_consumable_transactions t),
    'subscriptions',(select jsonb_agg(to_jsonb(t) order by transaction_id) from public.app_store_transactions t),
    'events',(select jsonb_agg(to_jsonb(e) order by event_id) from public.app_store_server_notification_events e)
  )::text);`);
  const bodyHash = () => sql(`select md5(replace(prosrc, chr(13), '')) from pg_proc
    where oid='public.x5_rebuild_app_store_verified_profile(uuid)'::regprocedure;`);
  const expectedOld = 'f8bb9d553246003b47aa2fd5b4e030dc';
  const expectedNew = '44ccbde3b58a8f601bdba37eb680887b';
  const before = fingerprint();
  assert.equal(bodyHash(), expectedNew);
  const path = 'supabase/rollback/20260907_verified_projection.sql';
  const rollbackSQL = readFileSync(join(repo, path), 'utf8');
  report.rollbackSource = {path, source:'working_tree',
    sha256:createHash('sha256').update(rollbackSQL).digest('hex')};
  sql(rollbackSQL);
  assert.equal(bodyHash(), expectedOld);
  assert.equal(fingerprint(), before, 'rollback changed synthetic user or payment data');
  sql(readFileSync(join(repo, fixMigration), 'utf8'));
  assert.equal(bodyHash(), expectedNew);
  assert.equal(fingerprint(), before, 'reapplying the fix changed synthetic user or payment data');
  report.checks.push({id:'D06_SQL_function_rollback_and_forward_reapply',result:'PASS',
    oldBodyHash:expectedOld,newBodyHash:expectedNew,dataFingerprintUnchanged:true,
    scope:'synthetic database only; not disaster recovery or production rollback'});
}

try {
  report.imageId=command('docker',['image','inspect',image,'--format','{{.Id}}']);
  assert.match(container,/^x5-audit-payment-sql-[a-f0-9]{8}$/);
  // A CLI timeout can occur AFTER Docker creates the container. Always inspect
  // the unique audit label in finally, including an uncertain run response.
  created=true;
  command('docker',['run','--detach','--pull=never','--name',container,
    '--network','none','--label',`x5.audit.id=${auditId}`,
    '--env','POSTGRES_HOST_AUTH_METHOD=trust','--env','POSTGRES_DB=x5_audit',
    '--tmpfs','/var/lib/postgresql/data:rw,size=256m','--memory','512m',
    '--cpus','1','--pids-limit','256',image],undefined,60000);
  const deadline=Date.now()+25000;
  let ready=false;
  while(Date.now()<deadline) {
    try { sql('select 1;'); ready=true; break; } catch { await sleep(200); }
  }
  assert(ready,'disposable postgres did not become ready');
  report.isolation=JSON.parse(command('docker',['inspect',container,'--format',
    '{{json .HostConfig}}']));
  // Keep only relevant nonsecret safety configuration in the report.
  report.isolation={networkMode:report.isolation.NetworkMode,
    portBindings:report.isolation.PortBindings,binds:report.isolation.Binds,
    tmpfs:report.isolation.Tmpfs,memory:report.isolation.Memory};
  assert.equal(report.isolation.networkMode,'none');
  assert(!report.isolation.portBindings || Object.keys(report.isolation.portBindings).length===0);
  assert(!report.isolation.binds || report.isolation.binds.length===0);
  bootstrap();
  await badgeRace();
  await exactOnce();
  if (withFix) verifyDDLRecovery();
  report.outcome='completed';
} catch(error) {
  report.outcome='blocked_or_failed';
  report.error=error.stack;
  process.exitCode=1;
} finally {
  if(created) {
    try {
      const found=command('docker',['inspect',container,'--format','{{index .Config.Labels "x5.audit.id"}}']);
      assert.equal(found,auditId,'refusing to remove a container not owned by this audit');
      command('docker',['rm','--force',container],undefined,60000);
      report.cleanup={removed:true,container,scope:'only this audit-owned disposable container and its tmpfs data'};
    } catch(error) { report.cleanup={removed:false,error:error.message}; process.exitCode=1; }
  }
  report.finishedAt=new Date().toISOString();
  writeFileSync(reportPath,`${JSON.stringify(report,null,2)}\n`);
  console.log(JSON.stringify({outcome:report.outcome,checks:report.checks,cleanup:report.cleanup,error:report.error,reportPath},null,2));
}
