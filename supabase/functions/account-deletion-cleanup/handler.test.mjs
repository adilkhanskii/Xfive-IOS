// deno-lint-ignore-file require-await
import assert from "node:assert/strict";
import test from "node:test";

import {
  createAccountDeletionCleanupHandler,
  deleteRefundedVoiceOrphans,
  deleteVoiceObjectBatch,
} from "./handler.mjs";

const userID = "11111111-1111-4111-8111-111111111111";
const secret = "s".repeat(64);

function request(value = secret, query = "") {
  return new Request(`https://example.test/account-deletion-cleanup${query}`, {
    method: "POST",
    headers: { "X-Account-Deletion-Secret": value },
  });
}

test("pre-cleanup deletes exact owner paths before auth finalization", async () => {
  const calls = [];
  const deps = {
    cronSecret: secret,
    claimJob: async () => ({
      status: "claimed",
      user_id: userID,
      phase: "pre_cleanup",
    }),
    listPaths: async ({ p_after_name }) => ({
      status: "ok",
      paths: p_after_name ? [] : [`${userID}/explicit/a/1/audio.mp3`],
    }),
    deletePaths: async (paths) => calls.push(["delete", paths]),
    finalizeAccount: async (parameters) => {
      calls.push(["finalize", parameters]);
      return { status: "post_cleanup_scheduled" };
    },
    recordCleanupPass: async () => assert.fail("unexpected post pass"),
    releaseJob: async () => assert.fail("unexpected release"),
  };
  const response = await createAccountDeletionCleanupHandler(deps)(request());
  assert.equal(response.status, 200);
  assert.deepEqual(calls.map(([name]) => name), ["delete", "finalize"]);
});

test("post-cleanup needs recorded empty passes before durable completion", async () => {
  const calls = [];
  const deps = {
    cronSecret: secret,
    claimJob: async () => ({
      status: "claimed",
      user_id: userID,
      phase: "post_cleanup",
    }),
    listPaths: async () => ({ status: "ok", paths: [] }),
    deletePaths: async () => assert.fail("no objects should be deleted"),
    finalizeAccount: async () => assert.fail("already finalized"),
    recordCleanupPass: async (parameters) => {
      calls.push(parameters);
      return { status: "scheduled", empty_passes: 1 };
    },
    releaseJob: async () => assert.fail("unexpected release"),
  };
  const response = await createAccountDeletionCleanupHandler(deps)(request());
  assert.equal(response.status, 200);
  assert.equal(calls[0].p_deleted_count, 0);
});

test("cleanup helper can paginate beyond one thousand exact object names", async () => {
  const names = Array.from(
    { length: 1_205 },
    (_, index) =>
      `${userID}/explicit/${String(index).padStart(4, "0")}/1/audio.mp3`,
  );
  const deleted = [];
  const result = await deleteVoiceObjectBatch({
    userID,
    maximumPages: 100,
    deps: {
      listPaths: async ({ p_after_name, p_limit }) => {
        const start = p_after_name ? names.indexOf(p_after_name) + 1 : 0;
        return {
          status: "ok",
          paths: names.slice(start, start + p_limit),
        };
      },
      deletePaths: async (paths) => deleted.push(...paths),
    },
  });
  assert.deepEqual(result, { deletedCount: 1_205, complete: true });
  assert.deepEqual(deleted, names);
});

test("foreign-prefix path fails closed without Storage deletion", async () => {
  let deleteCalls = 0;
  await assert.rejects(
    deleteVoiceObjectBatch({
      userID,
      deps: {
        listPaths: async () => ({
          status: "ok",
          paths: [
            "11111111-1111-4111-8111-111111111112/explicit/a/1/audio.mp3",
          ],
        }),
        deletePaths: async () => {
          deleteCalls += 1;
        },
      },
    }),
    /path_invalid/,
  );
  assert.equal(deleteCalls, 0);
});

test("worker bounds each cleanup invocation and safely continues later", async () => {
  const names = Array.from(
    { length: 205 },
    (_, index) =>
      `${userID}/explicit/${String(index).padStart(4, "0")}/1/audio.mp3`,
  );
  const calls = [];
  const remaining = new Set(names);
  const deps = {
    cronSecret: secret,
    claimJob: async () => ({
      status: "claimed",
      user_id: userID,
      phase: "pre_cleanup",
    }),
    listPaths: async ({ p_after_name, p_limit }) => ({
      status: "ok",
      paths: [...remaining]
        .filter((name) => !p_after_name || name > p_after_name)
        .sort()
        .slice(0, p_limit),
    }),
    deletePaths: async (paths) => {
      calls.push(["delete", paths]);
      paths.forEach((path) => remaining.delete(path));
    },
    finalizeAccount: async () => assert.fail("must not finalize early"),
    recordCleanupPass: async () => assert.fail("unexpected post pass"),
    releaseJob: async (parameters) => {
      calls.push(["release", parameters]);
      return { status: "released" };
    },
  };

  const response = await createAccountDeletionCleanupHandler(deps)(request());
  assert.equal(response.status, 202);
  assert.equal(remaining.size, 5);
  assert.deepEqual(calls.map(([name]) => name), [
    "delete",
    "delete",
    "release",
  ]);
  assert.equal(calls[2][1].p_error_code, "cleanup_continuing");
});

test("unauthorized worker request never claims a deletion job", async () => {
  let claimCalls = 0;
  const response = await createAccountDeletionCleanupHandler({
    cronSecret: secret,
    claimJob: async () => {
      claimCalls += 1;
    },
  })(request("wrong"));
  assert.equal(response.status, 401);
  assert.equal(claimCalls, 0);
});

test("authenticated health check works before database migration", async () => {
  let claimCalls = 0;
  const response = await createAccountDeletionCleanupHandler({
    cronSecret: secret,
    claimJob: async () => {
      claimCalls += 1;
    },
  })(request(secret, "?health=1"));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).healthy, true);
  assert.equal(claimCalls, 0);
});

test("idle account worker removes exact refunded voice orphans", async () => {
  const path = `${userID}/explicit/${"a".repeat(64)}/1/audio.mp3`;
  const deleted = [];
  const response = await createAccountDeletionCleanupHandler({
    cronSecret: secret,
    claimJob: async () => ({ status: "empty" }),
    listRefundedVoicePaths: async () => ({ status: "ok", paths: [path] }),
    deletePaths: async (paths) => deleted.push(...paths),
  })(request());

  assert.equal(response.status, 200);
  assert.deepEqual(deleted, [path]);
  assert.equal((await response.json()).phase, "refunded_voice_cleanup");
});

test("refunded orphan cleanup rejects any non-ledger object path", async () => {
  let deleteCalls = 0;
  await assert.rejects(
    deleteRefundedVoiceOrphans({
      deps: {
        listRefundedVoicePaths: async () => ({
          status: "ok",
          paths: [`${userID}/portfolio/private.mp3`],
        }),
        deletePaths: async () => {
          deleteCalls += 1;
        },
      },
    }),
    /path_invalid/,
  );
  assert.equal(deleteCalls, 0);
});
