import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  isAllowedKaspiProviderIp,
  readForwardedClientIp,
  readKaspiProviderQuery,
} from "./protocol.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ||
  "https://afwznqjpshybmqhlewmy.supabase.co";

Deno.serve(async (request) => {
  if (request.method !== "GET") {
    return response({ result: 5, comment: "Method not allowed" }, 405);
  }

  const clientIp = readForwardedClientIp(request.headers);
  if (!isAllowedKaspiProviderIp(clientIp, Deno.env.get("KASPI_ALLOWED_IPS"))) {
    console.warn("[kaspi-pay-provider] rejected source IP", clientIp || "missing");
    return response({ result: 5, comment: "Forbidden" }, 403);
  }

  let query;
  try {
    query = readKaspiProviderQuery(request.url);
  } catch (error) {
    const comment = error instanceof Error ? error.message : "invalid_request";
    return response({ result: 5, comment }, 200);
  }

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) {
    return response(
      { txn_id: query.txnId, result: 5, comment: "Unavailable" },
      503,
    );
  }

  const admin = createClient(SUPABASE_URL, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.rpc("apply_kaspi_provider_command", {
    p_command: query.command,
    p_txn_id: query.txnId,
    p_txn_date: query.txnDate,
    p_account: query.account,
    p_amount: query.amount,
  });

  if (error || !data) {
    console.error(
      "[kaspi-pay-provider] command failed",
      error?.message || "empty_response",
    );
    return response(
      { txn_id: query.txnId, result: 5, comment: "Temporary error" },
      503,
    );
  }
  return response(data, 200);
});

function response(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
