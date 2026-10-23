const PROJECT_ID_PATTERN = /^[a-z][a-z0-9-]{4,61}[a-z0-9]$/;
const CLIENT_EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.gserviceaccount\.com$/;
const TOKEN_URI = "https://oauth2.googleapis.com/token";

export function normalizeFCMServiceAccount(raw) {
  let value;
  try {
    value = JSON.parse(String(raw || ""));
  } catch {
    throw new Error("fcm_credentials_invalid");
  }
  const projectID = String(value?.project_id || "").trim();
  const clientEmail = String(value?.client_email || "").trim();
  const privateKey = String(value?.private_key || "").trim();
  const tokenURI = String(value?.token_uri || TOKEN_URI).trim();
  if (
    !PROJECT_ID_PATTERN.test(projectID) ||
    !CLIENT_EMAIL_PATTERN.test(clientEmail) ||
    !privateKey.includes("-----BEGIN PRIVATE KEY-----") ||
    !privateKey.includes("-----END PRIVATE KEY-----") ||
    tokenURI !== TOKEN_URI
  ) {
    throw new Error("fcm_credentials_invalid");
  }
  return { projectID, clientEmail, privateKey, tokenURI };
}

export function buildFCMV1Request({
  config,
  accessToken,
  pushToken,
  message,
  collapseID,
  platform = "android",
}) {
  const token = String(pushToken || "").trim();
  const bearer = String(accessToken || "").trim();
  const collapseKey = String(collapseID || "").trim();
  if (
    !config ||
    !PROJECT_ID_PATTERN.test(String(config.projectID || "")) ||
    !bearer ||
    token.length < 20 ||
    token.length > 4_096 ||
    !/^[A-Za-z0-9:_-]+$/.test(token) ||
    !/^[0-9a-f-]{36}$/i.test(collapseKey) ||
    !["android", "web"].includes(platform)
  ) {
    throw new Error("fcm_request_invalid");
  }
  const data = Object.fromEntries(
    Object.entries(message?.data || {}).filter(
      ([, value]) => typeof value === "string" && value.length > 0,
    ),
  );
  const platformConfig = platform === "web"
    ? {
      webpush: {
        headers: { Urgency: "high" },
        notification: {
          title: String(message?.title || "").slice(0, 80),
          body: String(message?.body || "").slice(0, 180),
        },
        fcm_options: { link: validWebLink(message?.link) },
      },
    }
    : {
      android: {
        collapse_key: collapseKey,
        priority: "HIGH",
      },
    };
  return {
    url:
      `https://fcm.googleapis.com/v1/projects/${config.projectID}/messages:send`,
    init: {
      method: "POST",
      headers: {
        "authorization": `Bearer ${bearer}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: {
            title: String(message?.title || "").slice(0, 80),
            body: String(message?.body || "").slice(0, 180),
          },
          data,
          ...platformConfig,
        },
      }),
      signal: AbortSignal.timeout(10_000),
    },
  };
}

function validWebLink(raw) {
  let value;
  try {
    value = new URL(String(raw || ""));
  } catch {
    throw new Error("fcm_web_link_invalid");
  }
  if (
    value.protocol !== "https:" ||
    value.username ||
    value.password ||
    value.hash
  ) {
    throw new Error("fcm_web_link_invalid");
  }
  return value.toString();
}

export const FCM_TOKEN_URI = TOKEN_URI;
