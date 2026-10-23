const MAX_BATCH_SIZE = 20;
const MAX_PROVIDER_AGE_MILLISECONDS = 24 * 60 * 60 * 1000;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PROVIDER_REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{8,200}$/;
const POLLED_PROVIDER_NAMES = new Set(["google", "openai"]);

export function createVideoReconcileHandler(deps) {
  return async function handleVideoReconciliation(request) {
    if (request.method !== "POST") {
      return jsonResponse({ accepted: false }, 405);
    }
    const reconcileSecret = request.headers.get(
      "X-X5-Reconcile-Secret",
    ) || "";
    if (!constantTimeEqual(reconcileSecret, deps.reconcileSecret)) {
      return jsonResponse({ accepted: false }, 401);
    }

    let claimed;
    try {
      claimed = await deps.claimBatch({
        p_limit: MAX_BATCH_SIZE,
        p_stale_after: "2 minutes",
        p_max_age: "24 hours",
      });
    } catch {
      return jsonResponse({ accepted: false }, 503);
    }
    if (
      claimed?.status !== "claimed" ||
      !Array.isArray(claimed.jobs) ||
      claimed.jobs.length > MAX_BATCH_SIZE
    ) {
      return jsonResponse({ accepted: false }, 503);
    }

    let failedAttempts = 0;
    let terminal = 0;
    let pending = 0;
    const nowMs = deps.nowMs?.() ?? Date.now();
    for (const row of claimed.jobs) {
      if (
        !UUID_PATTERN.test(String(row?.id || "")) ||
        !POLLED_PROVIDER_NAMES.has(row?.provider_name) ||
        !["queued", "rendering"].includes(row?.status)
      ) {
        failedAttempts += 1;
        continue;
      }

      const createdAt = Date.parse(String(row.created_at || ""));
      if (
        !Number.isFinite(createdAt) ||
        nowMs - createdAt >= MAX_PROVIDER_AGE_MILLISECONDS
      ) {
        try {
          const outcome = await deps.failJob({
            p_job_id: row.id,
            p_provider_request_id: row.provider_request_id,
            p_error_code: "provider_timed_out",
          });
          if (
            !["failed", "already_refunded", "already_completed"].includes(
              outcome?.status,
            )
          ) {
            throw new Error("video_timeout_state_unavailable");
          }
          await deps.cleanupInput(row).catch(() => null);
          terminal += 1;
        } catch {
          failedAttempts += 1;
        }
        continue;
      }
      if (
        !PROVIDER_REQUEST_ID_PATTERN.test(
          String(row?.provider_request_id || ""),
        )
      ) {
        failedAttempts += 1;
        continue;
      }

      try {
        const reconciled = await deps.reconcileJob(row, { strict: true });
        if (["completed", "failed"].includes(reconciled?.status)) {
          await deps.cleanupInput(reconciled).catch(() => null);
          terminal += 1;
        } else {
          pending += 1;
        }
      } catch {
        failedAttempts += 1;
      }
    }

    return jsonResponse(
      {
        accepted: failedAttempts === 0,
        processed: claimed.jobs.length,
        terminal,
        pending,
      },
      failedAttempts === 0 ? 200 : 503,
    );
  };
}

function constantTimeEqual(left, right) {
  const leftBytes = new TextEncoder().encode(String(left));
  const rightBytes = new TextEncoder().encode(String(right));
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] || 0) ^ (rightBytes[index] || 0);
  }
  return difference === 0;
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
