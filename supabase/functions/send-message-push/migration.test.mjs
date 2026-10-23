import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../../migrations/20260801120000_secure_push_dispatch.sql",
    import.meta.url,
  ),
  "utf8",
);
const config = await readFile(
  new URL("../../config.toml", import.meta.url),
  "utf8",
);
const taskAudienceMigration = await readFile(
  new URL(
    "../../migrations/20260601153500_task_priority_and_credit_expiry.sql",
    import.meta.url,
  ),
  "utf8",
);
const taskFollowersMigration = await readFile(
  new URL(
    "../../migrations/20260517194500_social_notifications.sql",
    import.meta.url,
  ),
  "utf8",
);

test("message insert policy requires both sender identity and chat membership", () => {
  assert.match(
    migration,
    /create policy "messages insert by sender"[\s\S]*auth\.uid\(\)\)::text\s*=\s*sender_id::text[\s\S]*auth\.uid\(\)\)::text\s*=\s*any\(chat\.participants::text\[\]\)/i,
  );
});

test("database webhook uses a dedicated Vault secret and immutable identifiers only", () => {
  const enqueue = functionBody("x5_enqueue_push_webhook");
  const sender = functionBody("x5_send_push_outbox_row");
  assert.match(sender, /vault\.decrypted_secrets/i);
  assert.match(sender, /x5_push_webhook_secret/i);
  assert.match(sender, /'X-X5-Push-Webhook-Secret'/i);
  assert.match(
    sender,
    /body\s*:=\s*jsonb_build_object\(\s*'event_type'\s*,\s*v_outbox\.event_type\s*,\s*'event_id'\s*,\s*v_outbox\.event_id\s*\)/i,
  );
  assert.match(enqueue, /insert into public\.push_webhook_outbox/i);
  assert.doesNotMatch(
    sender,
    /service_role_key|recipient_id|actor_id|event_title|event_body/i,
  );
  assert.match(
    migration,
    /revoke all on function public\.x5_enqueue_push_webhook[\s\S]*from public, anon, authenticated, service_role/i,
  );
});

test("pg_net delivery has a durable bounded retry outbox", () => {
  assert.match(
    migration,
    /create table if not exists public\.push_webhook_outbox/i,
  );
  assert.match(migration, /unique \(event_type, event_id\)/i);
  assert.match(migration, /attempt_count between 0 and 5/i);
  assert.match(
    migration,
    /status in \('pending', 'in_flight', 'delivered', 'dead'\)/i,
  );
  const processor = functionBody("x5_process_push_webhook_outbox");
  assert.match(processor, /left join net\._http_response/i);
  assert.match(processor, /status_code between 200 and 299/i);
  assert.match(processor, /attempt_count >= 5 then 'dead'/i);
  assert.match(processor, /x5_send_push_outbox_row\(v_item\.id\)/i);
  assert.match(
    migration,
    /cron\.schedule\(\s*'x5-process-push-webhook-outbox'[\s\S]*x5_process_push_webhook_outbox\(100\)/i,
  );
});

test("completed/dead outbox and task event ledgers have bounded retention", () => {
  const cleanup = functionBody("x5_cleanup_push_dispatches");
  assert.match(
    cleanup,
    /delete from public\.push_webhook_outbox[\s\S]*status in \('delivered', 'dead'\)[\s\S]*interval '30 days'/i,
  );
  assert.match(
    cleanup,
    /delete from public\.task_notification_events[\s\S]*interval '30 days'/i,
  );
  assert.match(
    migration,
    /cron\.schedule\(\s*'x5-clean-push-dispatches'[\s\S]*x5_cleanup_push_dispatches/i,
  );
});

test("push dispatch ledger is private, leased, idempotent and rate limited", () => {
  assert.match(
    migration,
    /alter table public\.push_dispatches force row level security/i,
  );
  assert.match(migration, /unique \(event_type, event_id, recipient_id\)/i);
  assert.match(migration, /lease_expires_at/i);
  assert.match(migration, /v_minute_count\s*>=\s*30/i);
  assert.match(migration, /v_day_count\s*>=\s*500/i);
  assert.match(
    migration,
    /grant execute on function public\.claim_push_dispatch[\s\S]*to service_role/i,
  );
  const claimGrant = migration.match(
    /grant execute on function public\.claim_push_dispatch\([^;]+;/i,
  )?.[0] || "";
  assert.match(claimGrant, /to service_role/i);
  assert.doesNotMatch(claimGrant, /\b(?:anon|authenticated)\b/i);
});

test("social triggers dispatch only the inserted canonical notification id", () => {
  const enqueue = functionBody("x5_enqueue_social_notification");
  assert.match(enqueue, /returning id into v_notification_id/i);
  assert.match(
    enqueue,
    /x5_enqueue_push_webhook\(\s*'notification_created'\s*,\s*v_notification_id\s*\)/i,
  );
  assert.doesNotMatch(enqueue, /net\.http_post/i);
});

test("new task database triggers route canonical notifications through signed outbox", () => {
  assert.match(
    taskAudienceMigration,
    /x5_notify_new_task_audience[\s\S]*x5_enqueue_social_notification\([\s\S]*'new_task_priority'/i,
  );
  assert.match(
    taskFollowersMigration,
    /x5_notify_new_task_followers[\s\S]*x5_enqueue_social_notification\([\s\S]*'followed_user_posted'/i,
  );
  const social = functionBody("x5_enqueue_social_notification");
  assert.match(social, /x5_enqueue_push_webhook\(\s*'notification_created'/i);
});

test("task response presentation identity is overwritten from profiles", () => {
  const canonicalize = functionBody("x5_canonicalize_task_response");
  assert.match(canonicalize, /from public\.profiles as profile/i);
  assert.match(canonicalize, /where profile\.id = new\.specialist_id/i);
  assert.match(canonicalize, /new\.specialist_name := v_specialist_name/i);
  assert.match(canonicalize, /new\.specialist_avatar := v_specialist_avatar/i);
  assert.match(
    migration,
    /create trigger task_responses_canonicalize_identity[\s\S]*before insert on public\.task_responses/i,
  );
});

test("response and acceptance events derive task relationships and enqueue once", () => {
  const response = functionBody("x5_notify_task_response_inserted");
  assert.match(
    response,
    /from public\.tasks as task[\s\S]*task\.id = new\.task_id/i,
  );
  assert.match(response, /'task_response'[\s\S]*new\.id[\s\S]*new\.task_id/i);

  const accepted = functionBody("x5_emit_task_acceptance_notification");
  assert.match(accepted, /join public\.task_responses as response/i);
  assert.match(accepted, /task\.accepted_response_id = response\.id/i);
  assert.match(
    accepted,
    /task\.accepted_specialist_id = response\.specialist_id/i,
  );
  assert.match(accepted, /'task_response_accepted'/i);
  assert.match(
    migration,
    /primary key \(event_type, event_id, recipient_id\)/i,
  );
});

test("accept response RPC is author-only, atomic and ignores client specialist metadata", () => {
  const rpc = functionBody("x5_accept_task_response");
  const sync = functionBody("x5_sync_task_acceptance");
  const guard = functionBody("x5_prepare_task_acceptance");
  assert.match(rpc, /p_task_id uuid[\s\S]*p_response_id uuid/i);
  assert.match(rpc, /for update/i);
  assert.match(rpc, /v_task\.author_id <> v_user_id/i);
  assert.match(
    rpc,
    /response\.id = p_response_id[\s\S]*response\.task_id = p_task_id/i,
  );
  assert.match(
    rpc,
    /set accepted_response_id = v_response\.id[\s\S]*status = 'in_progress'/i,
  );
  assert.match(
    sync,
    /set status = case[\s\S]*response\.id = new\.accepted_response_id then 'accepted'[\s\S]*else 'rejected'[\s\S]*where response\.task_id = new\.id/i,
  );
  assert.doesNotMatch(rpc, /p_specialist|p_.*name/i);
  assert.match(
    guard,
    /v_acceptance_changed[\s\S]*old\.author_id <> auth\.uid\(\)[\s\S]*new\.author_id <> auth\.uid\(\)[\s\S]*task_author_required/i,
  );
  assert.match(
    guard,
    /v_acceptance_changed[\s\S]*coalesce\(old\.status, 'open'\) <> 'open'[\s\S]*task_not_open/i,
  );
  assert.match(
    guard,
    /response\.id = new\.accepted_response_id[\s\S]*response\.task_id = new\.id/i,
  );
});

test("per-target outcomes are durable, private and concurrency safe", () => {
  assert.match(
    migration,
    /create table if not exists public\.push_target_deliveries/i,
  );
  assert.match(
    migration,
    /target_key text not null check \(target_key ~ '\^\[0-9a-f\]\{64\}\$'\)/i,
  );
  assert.match(migration, /force row level security/i);
  const claim = functionBody("claim_push_target_delivery");
  assert.match(claim, /for update/i);
  assert.match(claim, /dispatch\.lease_token <> p_dispatch_lease_token/i);
  assert.match(claim, /status', 'already_sent'/i);
  assert.match(claim, /status', 'already_permanent'/i);
  assert.match(claim, /pg_catalog\.sha256/i);
  const complete = functionBody("complete_push_target_delivery");
  assert.match(complete, /'transient_failure'/i);
  assert.match(complete, /set status = 'pending'/i);
  assert.match(complete, /set status = p_outcome/i);
  assert.doesNotMatch(
    migration,
    /push_target_deliveries[\s\S]{0,200}token text/i,
  );
});

test("outbox honors bounded Retry-After without burning delivery attempts", () => {
  assert.match(migration, /rate_limit_count integer not null default 0/i);
  assert.match(migration, /rate_limit_count between 0 and 10/i);
  const parser = functionBody("x5_push_retry_after_seconds");
  assert.match(parser, /lower\(header\.key\) = 'retry-after'/i);
  assert.match(parser, /v_value ~ '\^\[0-9\]\{1,10\}\$'/i);
  assert.match(parser, /v_value::timestamptz/i);
  assert.match(parser, /v_cap constant integer := 172800/i);
  const processor = functionBody("x5_process_push_webhook_outbox");
  assert.match(processor, /v_item\.status_code = 429/i);
  assert.match(processor, /x5_push_retry_after_seconds/i);
  assert.match(
    processor,
    /attempt_count = greatest\(outbox\.attempt_count - 1, 0\)/i,
  );
  assert.match(
    processor,
    /rate_limit_count = least\(outbox\.rate_limit_count \+ 1, 10\)/i,
  );
  assert.match(processor, /make_interval\(secs => v_retry_after\)/i);
  assert.match(processor, /outbox\.rate_limit_count >= 10 then 'dead'/i);
});

test("Edge gateway JWT verification is explicitly replaced by dedicated secret auth", () => {
  assert.match(
    config,
    /\[functions\.send-message-push\]\s*verify_jwt\s*=\s*false/i,
  );
});

function functionBody(name) {
  const matches = [...migration.matchAll(
    new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$function\\$;`,
      "gi",
    ),
  )];
  assert.ok(matches.length > 0, `${name} missing`);
  return matches.at(-1)[0];
}
