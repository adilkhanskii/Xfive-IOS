const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PATH_LIMIT = 100;
const MAXIMUM_PAGES_PER_INVOCATION = 2;
const VOICE_OBJECT_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\/explicit\/[0-9a-f]{64}\/[1-9][0-9]*\/audio\.mp3$/i;

export function createAccountDeletionCleanupHandler(deps) {
  return async function handleCleanup(req) {
    if (req.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    if (
      !secureEqual(
        req.headers.get("X-Account-Deletion-Secret") || "",
        deps.cronSecret,
      )
    ) {
      return json({ error: "unauthorized" }, 401);
    }
    if (new URL(req.url).searchParams.get("health") === "1") {
      return json({ ok: true, healthy: true });
    }

    const leaseToken = createLeaseToken();
    let job = null;
    try {
      job = await deps.claimJob({ p_lease_token: leaseToken });
      if (job?.status === "empty") {
        const deletedCount = await deleteRefundedVoiceOrphans({ deps });
        return json({
          ok: true,
          processed: deletedCount > 0,
          phase: "refunded_voice_cleanup",
          deleted_count: deletedCount,
        });
      }
      const userID = String(job?.user_id || "");
      const phase = String(job?.phase || "");
      if (
        job?.status !== "claimed" ||
        !UUID_PATTERN.test(userID) ||
        !["pre_cleanup", "post_cleanup"].includes(phase)
      ) {
        throw new Error("account_deletion_job_invalid");
      }

      const cleanup = await deleteVoiceObjectBatch({
        userID,
        deps,
        maximumPages: MAXIMUM_PAGES_PER_INVOCATION,
      });
      const deletedCount = cleanup.deletedCount;
      if (!cleanup.complete) {
        const released = await deps.releaseJob({
          p_user_id: userID,
          p_lease_token: leaseToken,
          p_error_code: "cleanup_continuing",
        });
        if (released?.status !== "released") {
          throw new Error("account_deletion_continue_failed");
        }
        return json({
          ok: true,
          processed: true,
          phase,
          deleted_count: deletedCount,
          status: "continuing",
        }, 202);
      }
      if (phase === "pre_cleanup") {
        const finalized = await deps.finalizeAccount({
          p_user_id: userID,
          p_lease_token: leaseToken,
        });
        if (finalized?.status !== "post_cleanup_scheduled") {
          throw new Error("account_deletion_finalize_failed");
        }
        return json({
          ok: true,
          processed: true,
          phase,
          deleted_count: deletedCount,
        });
      }

      const recorded = await deps.recordCleanupPass({
        p_user_id: userID,
        p_lease_token: leaseToken,
        p_deleted_count: deletedCount,
      });
      if (!["scheduled", "completed"].includes(recorded?.status)) {
        throw new Error("account_deletion_pass_record_failed");
      }
      return json({
        ok: true,
        processed: true,
        phase,
        deleted_count: deletedCount,
        status: recorded.status,
      });
    } catch (error) {
      const userID = String(job?.user_id || "");
      if (UUID_PATTERN.test(userID)) {
        await deps.releaseJob({
          p_user_id: userID,
          p_lease_token: leaseToken,
          p_error_code: safeErrorCode(error),
        }).catch(() => null);
      }
      return json({ error: "cleanup_temporarily_unavailable" }, 503);
    }
  };
}

export async function deleteRefundedVoiceOrphans({ deps }) {
  const listed = await deps.listRefundedVoicePaths({ p_limit: PATH_LIMIT });
  if (listed?.status !== "ok" || !Array.isArray(listed.paths)) {
    throw new Error("refunded_voice_list_failed");
  }
  const paths = listed.paths.map(String);
  if (
    paths.length > PATH_LIMIT ||
    paths.some((path) => path.length > 1024 || !VOICE_OBJECT_PATTERN.test(path))
  ) {
    throw new Error("refunded_voice_path_invalid");
  }
  if (new Set(paths).size !== paths.length) {
    throw new Error("refunded_voice_path_duplicate");
  }
  if (paths.length > 0) await deps.deletePaths(paths);
  return paths.length;
}

export async function deleteVoiceObjectBatch({
  userID,
  deps,
  maximumPages = MAXIMUM_PAGES_PER_INVOCATION,
}) {
  if (!UUID_PATTERN.test(String(userID || ""))) {
    throw new Error("account_deletion_user_invalid");
  }
  if (
    !Number.isInteger(maximumPages) ||
    maximumPages < 1 ||
    maximumPages > 100
  ) {
    throw new Error("account_deletion_page_limit_invalid");
  }
  const prefix = `${userID.toLowerCase()}/`;
  let afterName = null;
  let deletedCount = 0;
  for (let page = 0; page < maximumPages; page += 1) {
    const listed = await deps.listPaths({
      p_user_id: userID,
      p_after_name: afterName,
      p_limit: PATH_LIMIT,
    });
    if (listed?.status !== "ok" || !Array.isArray(listed.paths)) {
      throw new Error("account_deletion_list_failed");
    }
    const paths = listed.paths.map(String);
    if (paths.length > PATH_LIMIT) {
      throw new Error("account_deletion_list_oversized");
    }
    let previous = afterName || "";
    for (const path of paths) {
      if (
        !path.startsWith(prefix) ||
        path.length > 1024 ||
        path <= previous
      ) {
        throw new Error("account_deletion_path_invalid");
      }
      previous = path;
    }
    if (paths.length === 0) {
      return { deletedCount, complete: true };
    }
    await deps.deletePaths(paths);
    deletedCount += paths.length;
    afterName = paths[paths.length - 1];
    if (paths.length < PATH_LIMIT) {
      return { deletedCount, complete: true };
    }
  }
  return { deletedCount, complete: false };
}

function createLeaseToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function secureEqual(candidate, expected) {
  const left = new TextEncoder().encode(String(candidate || ""));
  const right = new TextEncoder().encode(String(expected || ""));
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] || 0) ^ (right[index] || 0);
  }
  return difference === 0 && right.length >= 32;
}

function safeErrorCode(error) {
  const value = String(error?.message || "worker_failed").toLowerCase();
  return /^[a-z0-9_:-]{1,120}$/.test(value) ? value : "worker_failed";
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
