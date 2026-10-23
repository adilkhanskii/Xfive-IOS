// Scoped live read-only probe. Credentials/tokens/rows never reach stdout.
// No service-role key, payments, generations, database changes or messages.
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const read = (p) => readFile(new URL(p, root), "utf8");
const config = await read("X5/Services/X5Config.swift");
const base = config.match(/https:\/\/[a-z]+\.supabase\.co/)?.[0];
const anon = config.match(/"(eyJ[^"\s]+)"/)?.[1];
if (!base || !anon) throw new Error("Public application configuration missing");
const credentials = {
  email: process.env.X5_APP_REVIEW_EMAIL?.trim(),
  password: process.env.X5_APP_REVIEW_PASSWORD?.trim(),
};
if (!credentials.email || !credentials.password) throw new Error("Protected review credentials required; no file/history fallback");
const results = [];
const request = async (path, token, options = {}) => {
  const response = await fetch(base + path, {
    ...options,
    headers: { apikey: anon, Authorization: `Bearer ${token || anon}`, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(25000),
  });
  return { status: response.status, data: await response.json().catch(() => null) };
};
const login = await request("/auth/v1/token?grant_type=password", null, {
  method: "POST", body: JSON.stringify(credentials),
});
results.push({ id: "A02-auth", status: login.status, passed: Boolean(login.data?.access_token) });
if (!login.data?.access_token) { console.log(JSON.stringify(results)); process.exit(1); }
let token = login.data.access_token;
const uid = login.data.user.id;
const own = await request(`/rest/v1/profiles?id=eq.${uid}&select=id,credits,is_verified,verified_until,plan`, token);
results.push({ id: "A02-own-profile", status: own.status, passed: own.data?.length === 1 && own.data[0].id === uid });
const refreshed = await request("/auth/v1/token?grant_type=refresh_token", null, {
  method: "POST", body: JSON.stringify({ refresh_token: login.data.refresh_token }),
});
results.push({ id: "A02-token-refresh", status: refreshed.status, passed: refreshed.data?.user?.id === uid && Boolean(refreshed.data?.access_token) });
if (refreshed.data?.access_token) token = refreshed.data.access_token;
for (const table of ["app_store_consumable_transactions", "app_store_transactions", "app_store_entitlement_owners"]) {
  const result = await request(`/rest/v1/${table}?select=*&limit=1`, token);
  results.push({ id: `S01-private-${table}`, status: result.status,
    passed: [401,403].includes(result.status) || (result.status === 200 && Array.isArray(result.data) && result.data.length === 0),
    rowsExposed: Array.isArray(result.data) ? result.data.length : null });
}
const caps = await request("/functions/v1/ai-capabilities", token);
results.push({ id: "AI01-capabilities-not-generation", status: caps.status,
  passed: caps.status === 200 && Boolean(caps.data?.tools), tools: caps.data?.tools, models: caps.data?.models });
const anonymousCaps = await request("/functions/v1/ai-capabilities", null);
results.push({ id: "S01-capabilities-auth", status: anonymousCaps.status, passed: anonymousCaps.status === 401 });
const courses = await request("/rest/v1/courses?select=id&limit=10", token);
results.push({ id: "C01-catalog-not-playback", status: courses.status, passed: courses.status === 200 && Array.isArray(courses.data), count: Array.isArray(courses.data) ? courses.data.length : null });
const portfolio = await request(`/rest/v1/portfolio_items?user_id=eq.${uid}&select=id&limit=10`, token);
results.push({ id: "F01-own-portfolio-read", status: portfolio.status, passed: portfolio.status === 200 && Array.isArray(portfolio.data), count: Array.isArray(portfolio.data) ? portfolio.data.length : null });
console.log(JSON.stringify({ timestamp: new Date().toISOString(), account: "dedicated-app-review", mutations: ["auth-login", "own-session-refresh"], results }, null, 2));
process.exitCode = results.every((r) => r.passed) ? 0 : 1;
