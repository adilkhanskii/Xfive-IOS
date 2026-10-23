const TERMINAL_JOB_STATUSES = new Set(["completed", "failed"]);
const PERMANENT_RESULT_ERROR_CODES = new Set([
  "generated_video_invalid",
  "provider_result_invalid",
  "provider_result_too_large",
]);

export async function handleFalTerminalWebhook({
  job,
  requestId,
  payload,
  extractResult,
  finalizeResult,
  failJob,
  cleanupInput,
}) {
  if (TERMINAL_JOB_STATUSES.has(job.status)) {
    await cleanupInput(job);
    return { status: job.status, replayed: true };
  }

  const status = String(payload?.status || "").toUpperCase();
  if (status === "ERROR" || payload?.error) {
    const outcome = await failJob({ job, requestId, payload });
    if (
      !["failed", "already_refunded", "already_completed"].includes(
        outcome?.status,
      )
    ) {
      throw new Error("video_failure_state_unavailable");
    }
    await cleanupInput(job);
    return {
      status: outcome.status === "already_completed" ? "completed" : "failed",
      replayed: false,
    };
  }
  if (status !== "OK") {
    throw new Error("fal_webhook_status_invalid");
  }

  const outcome = await finalizeResult({
    job,
    loadResult: () => extractResult(payload?.payload),
  });
  return { status: outcome.status, replayed: false };
}

export async function finalizeVideoGenerationResult({
  job: row,
  providerName,
  loadResult,
  decodeBase64,
  downloadVideo,
  storeResult,
  completeJob,
  failJob,
  cleanupInput,
}) {
  try {
    const result = await loadResult();
    const bytes = result?.dataBytes instanceof Uint8Array
      ? result.dataBytes
      : result?.dataBase64
      ? decodeBase64(result.dataBase64)
      : await downloadVideo(result?.url || "", { providerName });
    const stored = await storeResult({
      userId: row.user_id,
      jobId: row.id,
      bytes,
    });
    const outcome = await completeJob({
      p_job_id: row.id,
      p_provider_request_id: row.provider_request_id,
      p_result_object_path: stored.path,
      p_result_sha256: stored.sha256,
      p_result_mime_type: stored.mimeType,
    });
    if (!["completed", "already_completed"].includes(outcome?.status)) {
      throw new Error("video_completion_state_unavailable");
    }
    await cleanupInput(row);
    return { status: "completed" };
  } catch (error) {
    const errorCode = resultErrorCode(error);
    if (!PERMANENT_RESULT_ERROR_CODES.has(errorCode)) {
      throw error;
    }
    const outcome = await failJob({
      p_job_id: row.id,
      p_provider_request_id: row.provider_request_id,
      p_error_code: errorCode,
    });
    if (
      !["failed", "already_refunded", "already_completed"].includes(
        outcome?.status,
      )
    ) {
      throw new Error("video_failure_state_unavailable");
    }
    await cleanupInput(row);
    return {
      status: outcome.status === "already_completed" ? "completed" : "failed",
    };
  }
}

function resultErrorCode(error) {
  const code = String(error?.code || error?.message || "");
  return /^[a-z0-9_:-]{1,80}$/.test(code) ? code : "provider_result_invalid";
}
