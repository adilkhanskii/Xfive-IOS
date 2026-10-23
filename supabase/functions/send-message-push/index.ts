// Database-only push dispatcher. The public Edge route is authenticated with a
// dedicated random webhook secret and accepts only immutable event identifiers.
// Recipient, actor, notification text, chat and task targets are loaded from the
// database with the service role and never trusted from the request body.

import { createClient } from "@supabase/supabase-js";
import { create as jwtCreate, getNumericDate } from "djwt";
import { createPushWebhookHandler } from "./handler.mjs";
import {
  buildFCMV1Request,
  normalizeFCMServiceAccount,
} from "./fcm-provider.mjs";
import {
  deliverPushTargets,
  normalizePushPlatform,
} from "./delivery-policy.mjs";

const APNS_HOST_PROD = "https://api.push.apple.com";
const APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface MessageRow {
  id: string;
  chat_id: string;
  sender_id: string;
  type: string;
  content: string | null;
}

interface ChatRow {
  id: string;
  participants: string[];
  task_id: string | null;
  task_title: string | null;
}

interface NotificationRow {
  id: string;
  user_id: string;
  actor_id: string | null;
  type: string;
  title: string;
  body: string | null;
  object_type: string | null;
  object_id: string | null;
}

interface PushTarget {
  platform: "ios" | "android" | "web";
  token: string;
  records: PushTokenRecord[];
}

interface PushTokenRecord {
  source: "profile" | "push_tokens";
  storedToken: string;
  storedPlatform?: string;
}

interface FCMMessage {
  title: string;
  body: string;
  data: Record<string, string>;
  link?: string;
}

interface PushDelivery {
  eventID: string;
  collapseID: string;
  apns: unknown;
  fcm: FCMMessage;
}

const supabaseURL = requiredEnvironment("SUPABASE_URL");
const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const webhookSecret = requiredEnvironment("X5_PUSH_WEBHOOK_SECRET");
const admin = createClient(supabaseURL, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
let cachedFCMToken: { value: string; expiresAt: number } | null = null;

Deno.serve(createPushWebhookHandler({
  webhookSecret,
  randomUUID: () => crypto.randomUUID(),
  logger: console,
  loadCanonicalEvent,
  claimDispatch: (parameters: Record<string, unknown>) =>
    callRPC("claim_push_dispatch", parameters),
  completeDispatch: (parameters: Record<string, unknown>) =>
    callRPC("complete_push_dispatch", parameters),
  releaseDispatch: (parameters: Record<string, unknown>) =>
    callRPC("release_push_dispatch", parameters),
  deliverPush,
}));

async function callRPC(
  name: string,
  parameters: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await admin.rpc(name, parameters);
  if (error) throw new Error(`${name}_failed`);
  return data;
}

async function loadCanonicalEvent(eventType: string, eventID: string) {
  if (eventType === "message_inserted") {
    return await loadMessageEvent(eventID);
  }
  if (eventType === "notification_created") {
    return await loadNotificationEvent(eventID);
  }
  return null;
}

async function loadMessageEvent(eventID: string) {
  const { data: message, error: messageError } = await admin
    .from("messages")
    .select("id, chat_id, sender_id, type, content")
    .eq("id", eventID)
    .maybeSingle<MessageRow>();
  if (messageError) throw new Error("message_lookup_failed");
  if (!message) return null;

  const { data: chat, error: chatError } = await admin
    .from("chats")
    .select("id, participants, task_id, task_title")
    .eq("id", message.chat_id)
    .maybeSingle<ChatRow>();
  if (chatError) throw new Error("chat_lookup_failed");
  if (!chat) throw new Error("message_chat_missing");

  const participants = Array.isArray(chat.participants)
    ? [
      ...new Set(chat.participants.map((value) => String(value).toLowerCase())),
    ]
    : [];
  const senderID = String(message.sender_id || "").toLowerCase();
  if (!participants.includes(senderID)) {
    throw new Error("message_sender_not_participant");
  }
  const recipientIDs = participants.filter((participant) =>
    participant !== senderID
  );
  if (recipientIDs.length === 0) return null;

  const { data: sender, error: senderError } = await admin
    .from("profiles")
    .select("name, nickname")
    .eq("id", senderID)
    .maybeSingle();
  if (senderError) throw new Error("message_sender_lookup_failed");
  const senderName = displayName(sender);
  const taskTitle = String(chat.task_title || "").trim();

  return {
    eventType: "message_inserted",
    eventID: String(message.id).toLowerCase(),
    pushType: "message",
    actorID: senderID,
    recipientIDs,
    title: taskTitle || senderName,
    subtitle: taskTitle ? senderName : undefined,
    body: messagePreview(message.type, message.content),
    threadID: chat.id,
    category: "MESSAGE",
    messageID: String(message.id).toLowerCase(),
    chatID: chat.id,
    taskID: normalizeUUID(chat.task_id),
  };
}

async function loadNotificationEvent(eventID: string) {
  const { data: notification, error: notificationError } = await admin
    .from("notifications")
    .select("id, user_id, actor_id, type, title, body, object_type, object_id")
    .eq("id", eventID)
    .maybeSingle<NotificationRow>();
  if (notificationError) throw new Error("notification_lookup_failed");
  if (!notification?.actor_id) return null;

  const actorID = String(notification.actor_id).toLowerCase();
  const recipientID = String(notification.user_id || "").toLowerCase();
  if (actorID === recipientID) return null;
  const { data: actor, error: actorError } = await admin
    .from("profiles")
    .select("name, nickname")
    .eq("id", actorID)
    .maybeSingle();
  if (actorError) throw new Error("notification_actor_lookup_failed");

  const objectType = String(notification.object_type || "").trim() || undefined;
  const objectID = String(notification.object_id || "").trim() || undefined;
  const taskID = objectType === "task" ? normalizeUUID(objectID) : undefined;
  return {
    eventType: "notification_created",
    eventID: String(notification.id).toLowerCase(),
    pushType: String(notification.type || ""),
    actorID,
    recipientIDs: [recipientID],
    title: notification.title || displayName(actor),
    body: notification.body ||
      defaultSocialBody(notification.type, displayName(actor)),
    threadID: objectID || notification.type,
    category: "SOCIAL",
    notificationID: String(notification.id).toLowerCase(),
    objectType,
    objectID,
    taskID,
  };
}

async function deliverPush(
  recipientID: string,
  delivery: PushDelivery,
  dispatch: Record<string, unknown>,
): Promise<{ status: "sent" | "no_target" | "failed" }> {
  const tokenLookup = await loadPushTargets(recipientID);
  const outcome = await deliverPushTargets({
    targets: tokenLookup.targets,
    delivery,
    logger: console,
    sendTarget: async (target: PushTarget) =>
      target.platform === "ios"
        ? await sendAPNs(
          target.token,
          delivery.apns,
          delivery.eventID,
          delivery.collapseID,
        )
        : await sendFCM(
          target.token,
          target.platform === "web"
            ? { ...delivery.fcm, link: webPushLink(delivery.fcm.data) }
            : delivery.fcm,
          delivery.collapseID,
          target.platform,
        ),
    disableTarget: async (target: PushTarget) => {
      await disableInvalidPushTarget(recipientID, target);
    },
    claimTarget: async (target: PushTarget) => {
      const targetKey = await pushTargetKey(target);
      const targetLeaseToken = randomTargetLeaseToken();
      const claim = await callRPC("claim_push_target_delivery", {
        p_event_type: dispatch.p_event_type,
        p_event_id: dispatch.p_event_id,
        p_recipient_id: recipientID,
        p_dispatch_lease_token: dispatch.p_lease_token,
        p_target_key: targetKey,
        p_target_lease_token: targetLeaseToken,
      }) as Record<string, unknown>;
      return {
        status: String(claim?.status || ""),
        targetKey,
        targetLeaseToken,
      };
    },
    recordTargetOutcome: async (
      _target: PushTarget,
      claim: { targetKey: string; targetLeaseToken: string },
      outcome: "sent" | "permanent_failure" | "transient_failure",
      errorCode?: string,
    ) => {
      const result = await callRPC("complete_push_target_delivery", {
        p_event_type: dispatch.p_event_type,
        p_event_id: dispatch.p_event_id,
        p_recipient_id: recipientID,
        p_target_key: claim.targetKey,
        p_target_lease_token: claim.targetLeaseToken,
        p_outcome: outcome,
        p_error_code: errorCode ?? null,
      }) as Record<string, unknown>;
      if (
        !["completed", "already_completed", "retryable"].includes(
          String(result?.status || ""),
        )
      ) {
        throw new Error("push_target_completion_failed");
      }
    },
  });
  if (!["sent", "no_target", "failed"].includes(outcome.status)) {
    throw new Error("push_delivery_outcome_invalid");
  }
  return outcome as { status: "sent" | "no_target" | "failed" };
}

async function pushTargetKey(target: PushTarget): Promise<string> {
  const value = new TextEncoder().encode(`${target.platform}\0${target.token}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", value));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function randomTargetLeaseToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

async function loadPushTargets(
  userID: string,
): Promise<{ targets: PushTarget[] }> {
  const targets: PushTarget[] = [];
  const byKey = new Map<string, PushTarget>();
  const addTarget = (
    platform: "ios" | "android" | "web",
    storedToken: string | undefined,
    record: Omit<PushTokenRecord, "storedToken">,
  ) => {
    const token = platform === "ios"
      ? cleanAPNsToken(storedToken)
      : cleanFCMToken(storedToken);
    if (!token || !storedToken) return;
    const key = `${platform}:${token}`;
    const sourceRecord: PushTokenRecord = { ...record, storedToken };
    const existing = byKey.get(key);
    if (existing) {
      existing.records.push(sourceRecord);
      return;
    }
    const target: PushTarget = { platform, token, records: [sourceRecord] };
    byKey.set(key, target);
    targets.push(target);
  };

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("push_token")
    .eq("id", userID)
    .maybeSingle();
  if (profileError) throw new Error("profile_token_lookup_failed");
  addTarget("ios", profile?.push_token as string | undefined, {
    source: "profile",
  });

  const { data: tokenRows, error: tokenError } = await admin
    .from("push_tokens")
    .select("token, platform, updated_at")
    .eq("user_id", userID)
    .order("updated_at", { ascending: false })
    .limit(10);
  if (tokenError) throw new Error("push_token_lookup_failed");

  for (const row of tokenRows || []) {
    const normalizedPlatform = normalizePushPlatform(row?.platform);
    if (
      normalizedPlatform !== "ios" &&
      normalizedPlatform !== "android" &&
      normalizedPlatform !== "web"
    ) continue;
    const platform: "ios" | "android" | "web" = normalizedPlatform;
    addTarget(platform, row?.token as string | undefined, {
      source: "push_tokens",
      storedPlatform: String(row?.platform || ""),
    });
  }
  return { targets };
}

async function disableInvalidPushTarget(
  userID: string,
  target: PushTarget,
): Promise<void> {
  for (const record of target.records) {
    if (record.source === "profile") {
      const { error } = await admin
        .from("profiles")
        .update({ push_token: null })
        .eq("id", userID)
        .eq("push_token", record.storedToken);
      if (error) throw new Error("profile_push_token_cleanup_failed");
      continue;
    }
    if (!record.storedPlatform) {
      throw new Error("push_token_platform_missing");
    }
    const { error } = await admin
      .from("push_tokens")
      .delete()
      .eq("user_id", userID)
      .eq("token", record.storedToken)
      .eq("platform", record.storedPlatform);
    if (error) throw new Error("push_token_cleanup_failed");
  }
}

function cleanAPNsToken(token?: string): string | undefined {
  const trimmed = token?.trim();
  if (!trimmed || trimmed.startsWith("ExponentPushToken")) return undefined;
  const compact = trimmed.replace(/[<>\s]/g, "").toLowerCase();
  if (/^[0-9a-f]+$/.test(compact) && compact.length >= 32) return compact;
  const bytes = trimmed.match(/bytes\s*=\s*0x([0-9a-fA-F\s]+)/i)?.[1];
  const normalized = bytes?.replace(/\s/g, "").toLowerCase();
  return normalized && /^[0-9a-f]+$/.test(normalized) && normalized.length >= 32
    ? normalized
    : undefined;
}

function cleanFCMToken(token?: string): string | undefined {
  const trimmed = token?.trim();
  if (!trimmed || trimmed.startsWith("ExponentPushToken")) return undefined;
  if (trimmed.length < 20 || trimmed.length > 4_096) return undefined;
  return /^[A-Za-z0-9:_-]+$/.test(trimmed) ? trimmed : undefined;
}

async function sendFCM(
  pushToken: string,
  message: FCMMessage,
  collapseID: string,
  platform: "android" | "web",
): Promise<Response> {
  const config = normalizeFCMServiceAccount(
    requiredEnvironment("FCM_SERVICE_ACCOUNT_JSON"),
  );
  const accessToken = await fcmAccessToken(config);
  const request = buildFCMV1Request({
    config,
    accessToken,
    pushToken,
    message,
    collapseID,
    platform,
  });
  return await fetch(request.url, request.init);
}

function webPushLink(data: Record<string, string>): string {
  const configured = requiredEnvironment("WEB_APP_URL");
  let link: URL;
  try {
    link = new URL(configured);
  } catch {
    throw new Error("web_app_url_invalid");
  }
  if (
    link.protocol !== "https:" ||
    link.username ||
    link.password ||
    link.search ||
    link.hash
  ) {
    throw new Error("web_app_url_invalid");
  }
  link.searchParams.set("push", "1");
  for (
    const key of [
      "type",
      "message_id",
      "chat_id",
      "notification_id",
      "task_id",
      "object_type",
      "object_id",
    ]
  ) {
    const value = data[key];
    if (value) link.searchParams.set(key, value);
  }
  return link.toString();
}

async function fcmAccessToken(
  config: ReturnType<typeof normalizeFCMServiceAccount>,
): Promise<string> {
  const now = Date.now();
  if (cachedFCMToken && cachedFCMToken.expiresAt - now > 60_000) {
    return cachedFCMToken.value;
  }

  const privateKey = await importRS256(config.privateKey);
  const assertion = await jwtCreate(
    { alg: "RS256", typ: "JWT" },
    {
      iss: config.clientEmail,
      scope: FCM_SCOPE,
      aud: config.tokenURI,
      iat: getNumericDate(0),
      exp: getNumericDate(3_600),
    },
    privateKey,
  );
  const response = await fetch(config.tokenURI, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
  });
  const payload: unknown = await response.json().catch(() => null);
  const value = String(
    (payload as { access_token?: unknown } | null)?.access_token || "",
  );
  const expiresIn = Number(
    (payload as { expires_in?: unknown } | null)?.expires_in || 0,
  );
  if (
    !response.ok ||
    value.length < 20 ||
    value.length > 4_096 ||
    !Number.isFinite(expiresIn) ||
    expiresIn < 60 ||
    expiresIn > 3_600
  ) {
    throw new Error("fcm_oauth_failed");
  }
  cachedFCMToken = {
    value,
    expiresAt: now + expiresIn * 1_000,
  };
  return value;
}

async function sendAPNs(
  pushToken: string,
  payload: unknown,
  eventID: string,
  collapseID: string,
): Promise<Response> {
  const keyID = requiredEnvironment("APNS_KEY_ID");
  const teamID = requiredEnvironment("APNS_TEAM_ID");
  const bundleID = requiredEnvironment("APNS_BUNDLE_ID");
  const privateKey = requiredEnvironment("APNS_PRIVATE_KEY");
  const cryptoKey = await importPKCS8(privateKey);
  const jwt = await jwtCreate(
    { alg: "ES256", kid: keyID, typ: "JWT" },
    { iss: teamID, iat: getNumericDate(0) },
    cryptoKey,
  );

  const firstHost = preferredAPNsHost();
  let response = await sendAPNsToHost(
    firstHost,
    pushToken,
    payload,
    jwt,
    bundleID,
    eventID,
    collapseID,
  );
  if (response.ok) return response;

  const firstText = await response.text();
  const shouldRetryOppositeHost = response.status === 400 &&
    firstText.includes("BadDeviceToken") &&
    !["production", "sandbox"].includes(Deno.env.get("APNS_ENV") || "");
  if (!shouldRetryOppositeHost) {
    return new Response(firstText, { status: response.status });
  }

  const retryHost = firstHost === APNS_HOST_PROD
    ? APNS_HOST_SANDBOX
    : APNS_HOST_PROD;
  response = await sendAPNsToHost(
    retryHost,
    pushToken,
    payload,
    jwt,
    bundleID,
    eventID,
    collapseID,
  );
  return response;
}

function preferredAPNsHost(): string {
  const explicit = Deno.env.get("APNS_ENV");
  if (explicit === "sandbox") return APNS_HOST_SANDBOX;
  if (explicit === "production") return APNS_HOST_PROD;
  return (Deno.env.get("APNS_USE_SANDBOX") || "0") === "1"
    ? APNS_HOST_SANDBOX
    : APNS_HOST_PROD;
}

async function sendAPNsToHost(
  host: string,
  pushToken: string,
  payload: unknown,
  jwt: string,
  bundleID: string,
  eventID: string,
  collapseID: string,
): Promise<Response> {
  return await fetch(`${host}/3/device/${pushToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": bundleID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-id": eventID,
      "apns-collapse-id": collapseID,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(10_000),
  });
}

async function importPKCS8(pem: string): Promise<CryptoKey> {
  const cleaned = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(
    atob(cleaned),
    (character) => character.charCodeAt(0),
  );
  return await crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

async function importRS256(pem: string): Promise<CryptoKey> {
  const cleaned = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(
    atob(cleaned),
    (character) => character.charCodeAt(0),
  );
  return await crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function displayName(profile: unknown): string {
  const value = profile as { name?: string; nickname?: string } | null;
  return String(value?.name || value?.nickname || "Xfive marketing").trim();
}

function messagePreview(type: string, content: string | null): string {
  if (type === "text") return String(content || "Новое сообщение");
  if (type === "image") return "Фото";
  if (type === "audio") return "Голосовое сообщение";
  if (type === "video") return "Видео";
  if (type === "file") return "Файл";
  return "Новое сообщение";
}

function defaultSocialBody(type: string, actorName: string): string {
  if (type === "portfolio_like") return `${actorName} поставил лайк`;
  if (type === "followed_user_posted") {
    return `${actorName} опубликовал новый пост`;
  }
  return `${actorName}: новое уведомление`;
}

function normalizeUUID(value: unknown): string | undefined {
  const normalized = String(value || "").toLowerCase();
  return UUID_PATTERN.test(normalized) ? normalized : undefined;
}

function requiredEnvironment(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name.toLowerCase()}_missing`);
  return value;
}
