// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

const { buildPushDelivery, createPushWebhookHandler, secureEqual } =
  await import("./handler.mjs");

const SECRET = "push-webhook-secret-with-at-least-32-bytes";
const MESSAGE_ID = "11111111-1111-4111-8111-111111111111";
const NOTIFICATION_ID = "22222222-2222-4222-8222-222222222222";
const SENDER_ID = "33333333-3333-4333-8333-333333333333";
const RECIPIENT_ID = "44444444-4444-4444-8444-444444444444";
const SECOND_RECIPIENT_ID = "77777777-7777-4777-8777-777777777777";
const TASK_ID = "55555555-5555-4555-8555-555555555555";
const CHAT_ID = `${SENDER_ID}_${RECIPIENT_ID}`;

test("rejects an unsigned webhook before loading server data", async () => {
  let loaded = false;
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: async () => {
      loaded = true;
      return messageEvent();
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }, { secret: "" }));

  assert.equal(response.status, 401);
  assert.equal(loaded, false);
  assert.deepEqual(await response.json(), { error: "unauthorized" });
});

test("rejects the legacy spoofable message-row contract", async () => {
  let loaded = false;
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: async () => {
      loaded = true;
      return messageEvent();
    },
  }));

  const response = await handler(request({
    id: MESSAGE_ID,
    chat_id: "attacker_selected_chat",
    sender_id: SENDER_ID,
    recipient_id: RECIPIENT_ID,
    type: "text",
    content: "spoofed",
  }));

  assert.equal(response.status, 400);
  assert.equal(loaded, false);
  assert.deepEqual(await response.json(), { error: "invalid_payload" });
});

test("signed health gate proves the route without database or provider access", async () => {
  let loaded = false;
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: async () => {
      loaded = true;
      return messageEvent();
    },
  }));
  const response = await handler(
    new Request(
      "https://example.test/functions/v1/send-message-push?health=1",
      {
        method: "POST",
        headers: { "X-X5-Push-Webhook-Secret": SECRET },
      },
    ),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, healthy: true });
  assert.equal(loaded, false);
});

test("loads a message only by immutable id and emits exact deep-link ids", async () => {
  const calls = [];
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: async (eventType, eventID) => {
      calls.push(["load", eventType, eventID]);
      return messageEvent();
    },
    claimDispatch: async (parameters) => {
      calls.push(["claim", parameters]);
      return { status: "claimed" };
    },
    deliverPush: async (recipientID, delivery) => {
      calls.push(["deliver", recipientID, delivery]);
      return { status: "sent" };
    },
    completeDispatch: async (parameters) => {
      calls.push(["complete", parameters]);
      return { status: "completed" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));
  const payload = await response.json();

  assert.equal(response.status, 200);
  assert.deepEqual(payload, { ok: true, sent: 1, skipped: 0 });
  assert.deepEqual(calls[0], ["load", "message_inserted", MESSAGE_ID]);
  assert.equal(calls[1][1].p_event_id, MESSAGE_ID);
  assert.equal(calls[1][1].p_recipient_id, RECIPIENT_ID);
  assert.match(calls[1][1].p_lease_token, /^[0-9a-f-]{36}$/);

  const delivery = calls[2][2];
  assert.equal(delivery.apns.type, "message");
  assert.equal(delivery.apns.message_id, MESSAGE_ID);
  assert.equal(delivery.apns.chat_id, CHAT_ID);
  assert.equal(delivery.apns.task_id, TASK_ID);
  assert.equal(delivery.apns.sender_id, SENDER_ID);
  assert.equal(delivery.fcm.data.message_id, MESSAGE_ID);
  assert.equal(delivery.fcm.data.chat_id, CHAT_ID);
  assert.equal(delivery.fcm.data.task_id, TASK_ID);
  assert.equal(delivery.collapseID, MESSAGE_ID);
  assert.equal(calls[3][1].p_outcome, "sent");
});

test("derives task notification navigation from the stored notification", async () => {
  const event = notificationEvent();
  const delivery = buildPushDelivery(event);

  assert.equal(delivery.apns.type, "new_task_priority");
  assert.equal(delivery.apns.notification_id, NOTIFICATION_ID);
  assert.equal(delivery.apns.task_id, TASK_ID);
  assert.equal(delivery.apns.object_type, "task");
  assert.equal(delivery.apns.object_id, TASK_ID);
  assert.equal(delivery.fcm.data.notification_id, NOTIFICATION_ID);
  assert.equal(delivery.fcm.data.task_id, TASK_ID);
});

test("completed dispatches are idempotently acknowledged without delivery", async () => {
  let delivered = false;
  const handler = createPushWebhookHandler(dependencies({
    claimDispatch: async () => ({ status: "replay", outcome: "sent" }),
    deliverPush: async () => {
      delivered = true;
      return { status: "sent" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 200);
  assert.equal(delivered, false);
  assert.deepEqual(await response.json(), { ok: true, sent: 0, skipped: 1 });
});

test("rate limiting happens before provider delivery", async () => {
  let delivered = false;
  const handler = createPushWebhookHandler(dependencies({
    claimDispatch: async () => ({ status: "rate_limited", retry_after: 17 }),
    deliverPush: async () => {
      delivered = true;
      return { status: "sent" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "17");
  assert.equal(delivered, false);
  assert.deepEqual(await response.json(), {
    error: "rate_limited",
    retry_after: 17,
  });
});

test("sent plus rate-limited recipient remains non-2xx for outbox retry", async () => {
  let delivered = 0;
  const event = messageEvent();
  event.recipientIDs = [RECIPIENT_ID, SECOND_RECIPIENT_ID];
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: () => event,
    claimDispatch: (parameters) =>
      parameters.p_recipient_id === RECIPIENT_ID
        ? { status: "claimed" }
        : { status: "rate_limited", retry_after: 23 },
    deliverPush: () => {
      delivered += 1;
      return { status: "sent" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "23");
  assert.equal(delivered, 1);
});

test("replay plus in-progress recipient remains non-2xx for outbox retry", async () => {
  const event = messageEvent();
  event.recipientIDs = [RECIPIENT_ID, SECOND_RECIPIENT_ID];
  const handler = createPushWebhookHandler(dependencies({
    loadCanonicalEvent: () => event,
    claimDispatch: (parameters) =>
      parameters.p_recipient_id === RECIPIENT_ID
        ? { status: "replay", outcome: "sent" }
        : { status: "in_progress", retry_after: 7 },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 503);
  assert.equal(response.headers.get("Retry-After"), "7");
  assert.deepEqual(await response.json(), {
    error: "push_in_progress",
    retry_after: 7,
  });
});

test("provider failures release the lease for a bounded retry", async () => {
  let released;
  const handler = createPushWebhookHandler(dependencies({
    deliverPush: async () => ({ status: "failed" }),
    releaseDispatch: async (parameters) => {
      released = parameters;
      return { status: "released" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 503);
  assert.equal(released.p_event_id, MESSAGE_ID);
  assert.equal(released.p_recipient_id, RECIPIENT_ID);
  assert.equal(released.p_error_code, "provider_failed");
  assert.deepEqual(await response.json(), {
    error: "push_temporarily_unavailable",
  });
});

test("no token is a terminal idempotent outcome", async () => {
  let completed;
  const handler = createPushWebhookHandler(dependencies({
    deliverPush: async () => ({ status: "no_target" }),
    completeDispatch: async (parameters) => {
      completed = parameters;
      return { status: "completed" };
    },
  }));

  const response = await handler(request({
    event_type: "message_inserted",
    event_id: MESSAGE_ID,
  }));

  assert.equal(response.status, 200);
  assert.equal(completed.p_outcome, "no_target");
});

test("secret comparison fails closed for short configured secrets", () => {
  assert.equal(secureEqual("same-short-secret", "same-short-secret"), false);
  assert.equal(secureEqual(SECRET, SECRET), true);
  assert.equal(secureEqual(`${SECRET}x`, SECRET), false);
});

function request(body, { secret = SECRET } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (secret) headers["X-X5-Push-Webhook-Secret"] = secret;
  return new Request(
    "https://example.test/functions/v1/send-message-push",
    { method: "POST", headers, body: JSON.stringify(body) },
  );
}

function dependencies(overrides = {}) {
  return {
    webhookSecret: SECRET,
    randomUUID: () => "66666666-6666-4666-8666-666666666666",
    loadCanonicalEvent: async () => messageEvent(),
    claimDispatch: async () => ({ status: "claimed" }),
    deliverPush: async () => ({ status: "sent" }),
    completeDispatch: async () => ({ status: "completed" }),
    releaseDispatch: async () => ({ status: "released" }),
    logger: { error() {} },
    ...overrides,
  };
}

function messageEvent() {
  return {
    eventType: "message_inserted",
    eventID: MESSAGE_ID,
    pushType: "message",
    actorID: SENDER_ID,
    recipientIDs: [RECIPIENT_ID],
    title: "Task title",
    subtitle: "Sender",
    body: "Canonical stored message",
    threadID: CHAT_ID,
    category: "MESSAGE",
    messageID: MESSAGE_ID,
    chatID: CHAT_ID,
    taskID: TASK_ID,
  };
}

function notificationEvent() {
  return {
    eventType: "notification_created",
    eventID: NOTIFICATION_ID,
    pushType: "new_task_priority",
    actorID: SENDER_ID,
    recipientIDs: [RECIPIENT_ID],
    title: "New task",
    body: "Stored notification body",
    threadID: TASK_ID,
    category: "SOCIAL",
    notificationID: NOTIFICATION_ID,
    objectType: "task",
    objectID: TASK_ID,
    taskID: TASK_ID,
  };
}
