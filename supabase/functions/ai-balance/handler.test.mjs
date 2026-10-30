import { createAIBalanceHandler, sameSecret } from "./handler.mjs";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const SERVICE = "service-role-test";
const ELEVEN = "eleven-test-key";

function handlerWith(fetchImpl, env = { ELEVENLABS_API_KEY: ELEVEN }) {
  return createAIBalanceHandler({
    serviceRoleKey: SERVICE,
    env: (name) => env[name] || "",
    fetchImpl,
  });
}

const okFetch = () =>
  Promise.resolve(
    new Response(
      JSON.stringify({
        tier: "free",
        character_count: 2500,
        character_limit: 10000,
        next_character_count_reset_unix: 1800000000,
      }),
      { status: 200 },
    ),
  );

Deno.test("без service_role — 403 и провайдер не вызывается", async () => {
  let called = false;
  const handler = handlerWith(() => {
    called = true;
    return okFetch();
  });
  const anon = await handler(
    new Request("https://x/ai-balance", {
      headers: { Authorization: "Bearer user-jwt" },
    }),
  );
  const none = await handler(new Request("https://x/ai-balance"));
  assert(anon.status === 403 && none.status === 403, "must be forbidden");
  assert(!called, "provider must not be called");
});

Deno.test("service_role — только числа, ключа в ответе нет", async () => {
  const response = await handlerWith(okFetch)(
    new Request("https://x/ai-balance", {
      headers: { Authorization: `Bearer ${SERVICE}` },
    }),
  );
  const text = await response.text();
  const body = JSON.parse(text);
  assert(response.status === 200, "status 200");
  assert(body.elevenlabs.used === 2500, "used");
  assert(body.elevenlabs.limit === 10000, "limit");
  assert(body.elevenlabs.left_pct === 75, "left_pct");
  assert(!text.includes(ELEVEN) && !text.includes(SERVICE), "no secrets");
});

Deno.test("ключ без права user_read — ok:false, http_401", async () => {
  const response = await handlerWith(() =>
    Promise.resolve(new Response("{}", { status: 401 }))
  )(
    new Request("https://x/ai-balance", {
      headers: { Authorization: `Bearer ${SERVICE}` },
    }),
  );
  const body = await response.json();
  assert(body.elevenlabs.ok === false, "not ok");
  assert(body.elevenlabs.error === "http_401", "http_401");
});

Deno.test("sameSecret", () => {
  assert(sameSecret("abc", "abc"), "equal");
  assert(!sameSecret("abc", "abd"), "differs");
  assert(!sameSecret("abc", "abcd"), "length");
});

const fakeJWT = (role) =>
  `x.${btoa(JSON.stringify({ role })).replace(/=+$/, "")}.y`;

Deno.test("JWT service_role — пускает только после ответа Auth admin 200", async () => {
  const calls = [];
  const fetchImpl = (url) => {
    calls.push(String(url));
    if (String(url).includes("/auth/v1/admin/users")) {
      return Promise.resolve(new Response("{}", { status: 200 }));
    }
    return okFetch();
  };
  const handler = createAIBalanceHandler({
    serviceRoleKey: SERVICE,
    supabaseURL: "https://p.supabase.co",
    env: (name) => (name === "ELEVENLABS_API_KEY" ? ELEVEN : ""),
    fetchImpl,
  });
  const ok = await handler(
    new Request("https://x/ai-balance", {
      headers: { Authorization: `Bearer ${fakeJWT("service_role")}` },
    }),
  );
  assert(ok.status === 200, "service_role jwt allowed");
  calls.length = 0;
  const user = await handler(
    new Request("https://x/ai-balance", {
      headers: { Authorization: `Bearer ${fakeJWT("authenticated")}` },
    }),
  );
  assert(user.status === 403, "user jwt forbidden");
  assert(calls.length === 0, "no calls for user jwt");
});

Deno.test("JWT service_role, но Auth отказал — 403", async () => {
  const handler = createAIBalanceHandler({
    serviceRoleKey: SERVICE,
    supabaseURL: "https://p.supabase.co",
    env: () => "",
    fetchImpl: () => Promise.resolve(new Response("{}", { status: 401 })),
  });
  const response = await handler(
    new Request("https://x/ai-balance", {
      headers: { Authorization: `Bearer ${fakeJWT("service_role")}` },
    }),
  );
  assert(response.status === 403, "forged role forbidden");
});
