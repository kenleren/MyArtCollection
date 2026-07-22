var __defProp = Object.defineProperty;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __esm = (fn, res) => function __init() {
  return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
};
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};

// node_modules/@archivale/release-policy-trust/dist/src/errors.js
function fail(code, message) {
  throw new FailClosedError(code, message);
}
var FailClosedError;
var init_errors = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/errors.js"() {
    FailClosedError = class extends Error {
      code;
      constructor(code, message) {
        super(message);
        this.code = code;
        this.name = "FailClosedError";
      }
    };
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/canonical.js
import { createHash } from "node:crypto";
function normalize(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string")
    return value;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value))
      fail("invalid_input", "canonical numbers must be safe integers");
    return value;
  }
  if (Array.isArray(value))
    return value.map(normalize);
  if (typeof value === "object") {
    const input = value;
    const output = {};
    for (const key of Object.keys(input).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
      const child = input[key];
      if (child === void 0)
        fail("invalid_input", "undefined is not canonical");
      output[key] = normalize(child);
    }
    return output;
  }
  return fail("invalid_input", "unsupported canonical value");
}
function canonicalJson(value) {
  return JSON.stringify(normalize(value));
}
function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
function canonicalHash(value) {
  return sha256(Buffer.from(canonicalJson(value), "utf8"));
}
function generationId(tuple) {
  return canonicalHash(tuple);
}
var init_canonical = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/canonical.js"() {
    init_errors();
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/pagination.js
async function collect(fetch2, maxPages, maxRows) {
  const rows = [];
  for (let page = 1; page <= maxPages; page += 1) {
    const result = await fetch2(page);
    if (!Number.isInteger(result.nextPage) && result.nextPage !== null)
      fail("invalid_input", "invalid pagination cursor");
    if (result.nextPage !== null && result.nextPage !== page + 1)
      fail("invalid_input", "pagination cursor must be exact next page");
    if (result.nextPage !== null && result.items.length !== 100)
      fail("invalid_input", "nonfinal page must contain 100 rows");
    if (result.items.length > 100)
      fail("overflow", "page exceeds 100 rows");
    rows.push(...result.items);
    if (rows.length > maxRows)
      fail("overflow", "pagination row ceiling exceeded");
    if (result.nextPage === null)
      return rows;
    if (page === maxPages)
      fail("overflow", "pagination page ceiling exceeded");
  }
  return fail("overflow", "pagination did not terminate");
}
async function collectPullRequestFiles(port, repositoryId, number, expectedCount, limits = { filePages: 30, fileRows: 3e3, pageSize: 100 }) {
  if (limits.pageSize !== 100 || !Number.isInteger(expectedCount) || expectedCount < 0 || expectedCount > limits.fileRows)
    fail("overflow", "invalid changed-file count");
  const rows = await collect((page) => port.listPullRequestFiles(repositoryId, number, page, 100), limits.filePages, limits.fileRows);
  if (rows.length !== expectedCount)
    fail("snapshot_race", "changed-file count raced pagination");
  return rows;
}
function validateOpenPr(row, identity) {
  for (const value of [row.number, row.repositoryId, row.installationId, row.appId, row.headRepositoryId]) {
    if (!Number.isSafeInteger(value) || value <= 0)
      fail("identity", "invalid numeric PR identity");
  }
  if (row.repositoryId !== identity.repositoryId || row.installationId !== identity.installationId || row.appId !== identity.appId || row.repositoryName !== identity.repositoryName || row.baseRef !== "main" || row.state !== "open")
    fail("identity", "open PR identity mismatch");
  if (!/^[0-9a-f]{40}$/.test(row.baseSha) || !/^[0-9a-f]{40}$/.test(row.headSha) || row.headRepositoryId !== identity.repositoryId)
    fail("identity", "fork or inaccessible PR head");
}
async function enumerateOpenMainPullRequests(port, identity, limits = { openPrPages: 10, openPrRows: 1e3, openPrPasses: 2, pageSize: 100 }) {
  if (limits.pageSize !== 100 || limits.openPrPasses !== 2)
    fail("invalid_input", "open PR pagination policy mismatch");
  const pass = async () => {
    const rows = await collect((page) => port.listOpenMainPullRequests(identity.repositoryId, page, 100), limits.openPrPages, limits.openPrRows);
    const seen = /* @__PURE__ */ new Set();
    let priorCreated = -1;
    for (const row of rows) {
      validateOpenPr(row, identity);
      if (seen.has(row.number))
        fail("invalid_input", "duplicate open PR number");
      seen.add(row.number);
      const created = Date.parse(row.createdAt);
      if (!Number.isFinite(created) || created < priorCreated)
        fail("invalid_input", "open PR page is not created-ascending");
      priorCreated = created;
    }
    return rows.sort((a, b) => a.number - b.number);
  };
  const first = await pass();
  const second = await pass();
  const firstDigest = canonicalHash(first);
  if (firstDigest !== canonicalHash(second))
    fail("snapshot_race", "open PR enumeration changed between passes");
  return { count: first.length, digest: firstDigest, rows: first };
}
async function enumerateMatchingChecks(port, identity, headSha, name, externalId, limits = { checkPages: 30, checkRows: 3e3, pageSize: 100 }) {
  if (limits.pageSize !== 100)
    fail("invalid_input", "check pagination policy mismatch");
  const rows = await collect((page) => port.listAppChecks(identity.repositoryId, headSha, page, 100), limits.checkPages, limits.checkRows);
  const ids = /* @__PURE__ */ new Set();
  return rows.filter((row) => {
    if (!Number.isSafeInteger(row.checkId) || row.checkId <= 0 || ids.has(row.checkId))
      fail("invalid_input", "invalid or duplicate check id");
    ids.add(row.checkId);
    return row.appId === identity.appId && row.repositoryId === identity.repositoryId && row.headSha === headSha && row.name === name && row.externalId === externalId;
  });
}
var init_pagination = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/pagination.js"() {
    init_canonical();
    init_errors();
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/store.js
function clone(value) {
  return structuredClone(value);
}
function bindingIdentity(value) {
  return {
    app_id: value.appId,
    check_name: value.checkName,
    decision_digest: value.decisionDigest,
    external_id: value.externalId,
    generation_id: value.generationId,
    head_sha: value.headSha,
    policy_digest: value.policyDigest,
    repository_id: value.repositoryId
  };
}
function terminal(state) {
  return state.startsWith("terminal") || state === "conflict" || state === "obsolete";
}
function positive(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0)
    fail("invalid_input", `${label} must be a positive safe integer`);
}
function digest(value, label) {
  if (!/^[0-9a-f]{64}$/.test(value))
    fail("invalid_input", `${label} must be SHA-256`);
}
function immutableGenerationValue(generation) {
  return {
    draft_decision: generation.draftDecision,
    file_count: generation.fileCount,
    files_digest: generation.filesDigest,
    generation_id: generation.generationId,
    main_sha: generation.mainSha,
    policy: generation.policy,
    pull_request_number: generation.pullRequestNumber,
    repository_id: generation.repositoryId,
    snapshot: generation.snapshot,
    tuple: generation.tuple
  };
}
function generationFromEvaluation(evaluation) {
  const base = {
    draftDecision: clone(evaluation.decision),
    fileCount: evaluation.fileCount,
    filesDigest: evaluation.filesDigest,
    generationId: evaluation.generationId,
    mainSha: evaluation.mainSha,
    policy: clone(evaluation.policy),
    pullRequestNumber: evaluation.tuple.pull_request_number,
    repositoryId: evaluation.tuple.repository_id,
    snapshot: clone(evaluation.snapshot),
    tuple: clone(evaluation.tuple)
  };
  return { ...base, immutableDigest: canonicalHash(immutableGenerationValue(base)), state: "claimed", version: 1 };
}
function validateGeneration(generation) {
  positive(generation.repositoryId, "repository id");
  positive(generation.pullRequestNumber, "pull request number");
  digest(generation.filesDigest, "files digest");
  digest(generation.policy.digest, "policy digest");
  digest(generation.draftDecision.digest, "decision digest");
  digest(generation.immutableDigest, "immutable generation digest");
  if (generation.generationId !== generationId(generation.tuple) || generation.tuple.repository_id !== generation.repositoryId || generation.tuple.pull_request_number !== generation.pullRequestNumber || generation.tuple.policy_sha256 !== generation.policy.digest)
    fail("identity", "generation tuple mismatch");
  if (generation.snapshot.repositoryId !== generation.repositoryId || generation.snapshot.number !== generation.pullRequestNumber || generation.snapshot.headSha !== generation.tuple.head_sha || generation.snapshot.baseSha !== generation.tuple.base_sha || generation.mainSha !== generation.tuple.base_sha)
    fail("identity", "generation snapshot mismatch");
  const { immutableDigest, state: _state, version: _version, decision: _decision, ...base } = generation;
  if (immutableDigest !== canonicalHash(immutableGenerationValue(base)))
    fail("conflict", "immutable generation content mismatch");
}
function sameImmutableGeneration(left, right) {
  return left.generationId === right.generationId && left.immutableDigest === right.immutableDigest;
}
async function recoverCommit(store, work, verify) {
  try {
    await store.transact(work);
  } catch (error) {
    if (!(error instanceof FailClosedError) || error.code !== "store_failure" || !await verify())
      throw error;
  }
}
function receiptMatches(existing, input) {
  return existing.payloadDigest === input.payloadDigest && existing.identityDigest === input.identityDigest && existing.kind === input.kind;
}
function receiptTerminalOutcome(receipt) {
  if (receipt.completedOutcome !== void 0)
    return receipt.completedOutcome;
  return receipt.state === "terminal_success" || receipt.state === "terminal_failure" ? receipt.state : void 0;
}
async function persistReceiptConflict(store, key) {
  for (; ; ) {
    const current = await store.read(key);
    if (current === void 0)
      return fail("cas_lost", "receipt disappeared before conflict persistence");
    if (current.state === "conflict")
      return current;
    const completedOutcome = receiptTerminalOutcome(current);
    const next = completedOutcome === void 0 ? { ...current, state: "conflict", version: current.version + 1 } : { ...current, completedOutcome, state: "conflict", version: current.version + 1 };
    try {
      await store.transact((transaction) => transaction.compareAndSwap(key, current.version, next));
      return next;
    } catch (error) {
      const durable = await store.read(key);
      if (durable?.state === "conflict")
        return durable;
      if (error instanceof FailClosedError && error.code === "cas_lost")
        continue;
      throw error;
    }
  }
}
async function receive(store, input) {
  positive(input.installationId, "installation id");
  digest(input.payloadDigest, "payload digest");
  digest(input.identityDigest, "identity digest");
  if (input.deliveryId.length === 0 || !["pull_request", "push"].includes(input.kind))
    fail("invalid_input", "receipt identity is malformed");
  const key = receiptKey(input.installationId, input.deliveryId);
  const existing = await store.read(key);
  if (existing !== void 0) {
    if (!receiptMatches(existing, input))
      return persistReceiptConflict(store, key);
    return existing;
  }
  const receipt = { ...input, state: "received", version: 1 };
  try {
    await store.transact((transaction) => transaction.putIfAbsent(key, receipt));
  } catch (error) {
    const durable = await store.read(key);
    if (durable !== void 0 && receiptMatches(durable, input))
      return durable;
    if (durable !== void 0)
      return persistReceiptConflict(store, key);
    throw error;
  }
  return receipt;
}
async function beginReceiptSnapshot(store, receipt) {
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  const durable = await store.read(key);
  if (durable === void 0 || !receiptMatches(durable, receipt))
    return fail("conflict", "receipt disappeared or changed");
  if (durable.state === "snapshotting" || durable.state === "enqueued" || terminal(durable.state))
    return durable;
  if (durable.state !== "received")
    return fail("cas_lost", "receipt cannot start snapshotting");
  const next = { ...durable, state: "snapshotting", version: durable.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, durable.version, next), async () => (await store.read(key))?.state === "snapshotting");
  return next;
}
function insertOrVerifyGeneration(transaction, generation) {
  validateGeneration(generation);
  const key = generationKey(generation.generationId);
  const existing = transaction.get(key);
  if (existing === void 0)
    transaction.putIfAbsent(key, generation);
  else if (!sameImmutableGeneration(existing, generation))
    fail("conflict", "generation id reused with different immutable content");
}
function insertOrVerifyIntent(transaction, generationId2, operation) {
  const key = outboxKey(generationId2, operation);
  const existing = transaction.get(key);
  if (existing === void 0)
    transaction.putIfAbsent(key, { fence: null, generationId: generationId2, leaseOwner: null, operation, state: "pending", version: 1 });
  else if (existing.generationId !== generationId2 || existing.operation !== operation)
    fail("conflict", "outbox identity mismatch");
}
function moveCurrent(transaction, generation) {
  const key = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const current = transaction.get(key);
  if (current?.effectLease !== null && current !== void 0)
    fail("cas_lost", "current generation has a fenced external-effect lease");
  if (current?.generationId === generation.generationId)
    return;
  if (current !== void 0) {
    const previousKey = generationKey(current.generationId);
    const previous = transaction.get(previousKey);
    if (previous !== void 0 && !terminal(previous.state))
      transaction.compareAndSwap(previousKey, previous.version, { ...previous, state: "obsolete", version: previous.version + 1 });
    transaction.compareAndSwap(key, current.version, { effectLease: null, generationId: generation.generationId, nextFence: current.nextFence, version: current.version + 1 });
  } else
    transaction.putIfAbsent(key, { effectLease: null, generationId: generation.generationId, nextFence: 1, version: 1 });
}
async function atomicEnqueuePull(store, receipt, generation) {
  validateGeneration(generation);
  const rKey = receiptKey(receipt.installationId, receipt.deliveryId);
  const verify = async () => {
    const [durableReceipt, durableGeneration, durableIntent, current] = await Promise.all([
      store.read(rKey),
      store.read(generationKey(generation.generationId)),
      store.read(outboxKey(generation.generationId, "evaluate_generation")),
      store.read(currentKey(generation.repositoryId, generation.pullRequestNumber))
    ]);
    return durableReceipt?.state === "enqueued" && durableReceipt.generationId === generation.generationId && durableGeneration !== void 0 && sameImmutableGeneration(durableGeneration, generation) && durableIntent?.operation === "evaluate_generation" && current?.generationId === generation.generationId;
  };
  if (await verify())
    return;
  await recoverCommit(store, (transaction) => {
    const durableReceipt = transaction.get(rKey);
    if (durableReceipt === void 0 || !receiptMatches(durableReceipt, receipt) || !["received", "snapshotting"].includes(durableReceipt.state))
      fail("cas_lost", "receipt changed before pull enqueue");
    insertOrVerifyGeneration(transaction, generation);
    insertOrVerifyIntent(transaction, generation.generationId, "evaluate_generation");
    moveCurrent(transaction, generation);
    transaction.compareAndSwap(rKey, durableReceipt.version, { ...durableReceipt, generationId: generation.generationId, state: "enqueued", version: durableReceipt.version + 1 });
  }, verify);
}
async function atomicEnqueuePush(store, receipt, targetDigest, pullRequestNumbers) {
  digest(targetDigest, "push target digest");
  const targets = [...pullRequestNumbers];
  if (new Set(targets).size !== targets.length || targets.some((value) => !Number.isSafeInteger(value) || value <= 0) || targets.some((value, index) => index > 0 && value <= targets[index - 1]))
    fail("invalid_input", "push target list must be unique positive ascending numbers");
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  const finalState = targets.length === 0 ? "terminal_success" : "enqueued";
  const verify = async () => {
    const durable = await store.read(key);
    if (durable?.state !== finalState || targets.length === 0 && durable.completedOutcome !== "terminal_success" || durable.targetDigest !== targetDigest || canonicalHash(durable.targetNumbers) !== canonicalHash(targets))
      return false;
    for (const pr of targets)
      if ((await store.read(pushChildKey(receipt.installationId, receipt.deliveryId, pr)))?.pullRequestNumber !== pr)
        return false;
    return true;
  };
  if (await verify())
    return;
  await recoverCommit(store, (transaction) => {
    const durable = transaction.get(key);
    if (durable === void 0 || !receiptMatches(durable, receipt) || !["received", "snapshotting"].includes(durable.state))
      fail("cas_lost", "push receipt changed before fanout");
    for (const pr of targets)
      transaction.putIfAbsent(pushChildKey(receipt.installationId, receipt.deliveryId, pr), { leaseOwner: null, pullRequestNumber: pr, state: "pending", version: 1 });
    const next = targets.length === 0 ? { ...durable, completedOutcome: "terminal_success", state: finalState, targetCount: 0, targetDigest, targetNumbers: targets, version: durable.version + 1 } : { ...durable, state: finalState, targetCount: targets.length, targetDigest, targetNumbers: targets, version: durable.version + 1 };
    transaction.compareAndSwap(key, durable.version, next);
  }, verify);
}
async function leasePushChild(store, receipt, pr, worker) {
  const key = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const child = await store.read(key);
  if (child === void 0 || child.state !== "pending" || child.leaseOwner !== null || worker.length === 0)
    return fail("cas_lost", "push child unavailable for lease");
  const next = { ...child, leaseOwner: worker, state: "leased", version: child.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, child.version, next), async () => {
    const durable = await store.read(key);
    return durable?.state === "leased" && durable.leaseOwner === worker;
  });
  return next;
}
async function recoverPushChildLease(store, receipt, pr, abandonedWorker) {
  const key = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const child = await store.read(key);
  if (child?.state !== "leased" || child.leaseOwner !== abandonedWorker)
    fail("cas_lost", "push child lease is not recoverable");
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, child.version, { ...child, leaseOwner: null, state: "pending", version: child.version + 1 }), async () => (await store.read(key))?.state === "pending");
}
async function atomicEnqueuePushChild(store, receipt, generation, worker) {
  validateGeneration(generation);
  const childKey = pushChildKey(receipt.installationId, receipt.deliveryId, generation.pullRequestNumber);
  const verify = async () => {
    const child = await store.read(childKey);
    const intent = await store.read(outboxKey(generation.generationId, "evaluate_generation"));
    return child?.state === "enqueued" && child.generationId === generation.generationId && intent?.generationId === generation.generationId;
  };
  if (await verify())
    return;
  await recoverCommit(store, (transaction) => {
    const child = transaction.get(childKey);
    if (child === void 0 || child.state !== "leased" || child.leaseOwner !== worker)
      fail("cas_lost", "push child lease changed");
    insertOrVerifyGeneration(transaction, generation);
    insertOrVerifyIntent(transaction, generation.generationId, "evaluate_generation");
    moveCurrent(transaction, generation);
    transaction.compareAndSwap(childKey, child.version, { ...child, generationId: generation.generationId, leaseOwner: null, state: "enqueued", version: child.version + 1 });
  }, verify);
}
async function leaseOutbox(store, generationId2, worker) {
  const key = outboxKey(generationId2, "evaluate_generation");
  const row = await store.read(key);
  const generation = await store.read(generationKey(generationId2));
  if (row === void 0 || row.state !== "pending" || row.leaseOwner !== null || generation === void 0 || generation.state !== "claimed")
    return fail("cas_lost", "evaluation outbox unavailable");
  const next = { ...row, leaseOwner: worker, state: "leased", version: row.version + 1 };
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(generationId2));
    if (durableGeneration === void 0 || durableGeneration.state !== "claimed")
      fail("cas_lost", "generation is not claimable");
    transaction.compareAndSwap(key, row.version, next);
    transaction.compareAndSwap(generationKey(generationId2), durableGeneration.version, { ...durableGeneration, state: "evaluating", version: durableGeneration.version + 1 });
  }, async () => (await store.read(key))?.state === "leased" && (await store.read(generationKey(generationId2)))?.state === "evaluating");
  return next;
}
async function commitDecision(store, generationId2, worker) {
  const key = generationKey(generationId2);
  const intentKey = outboxKey(generationId2, "evaluate_generation");
  const generation = await store.read(key);
  const intent = await store.read(intentKey);
  if (generation === void 0 || generation.state !== "evaluating" || intent?.state !== "leased" || intent.leaseOwner !== worker)
    return fail("cas_lost", "evaluation lease changed");
  const nextGeneration = { ...generation, decision: clone(generation.draftDecision), state: "decision_ready", version: generation.version + 1 };
  const nextIntent = { ...intent, leaseOwner: null, state: "delivered", version: intent.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(key, generation.version, nextGeneration);
    transaction.compareAndSwap(intentKey, intent.version, nextIntent);
  }, async () => (await store.read(key))?.state === "decision_ready" && (await store.read(intentKey))?.state === "delivered");
  return nextGeneration;
}
async function recoverEvaluationLease(store, generationId2, abandonedWorker) {
  const gKey = generationKey(generationId2);
  const iKey = outboxKey(generationId2, "evaluate_generation");
  const generation = await store.read(gKey);
  const intent = await store.read(iKey);
  if (generation?.state !== "evaluating" || intent?.state !== "leased" || intent.leaseOwner !== abandonedWorker)
    fail("cas_lost", "evaluation lease is not recoverable");
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(gKey, generation.version, { ...generation, state: "claimed", version: generation.version + 1 });
    transaction.compareAndSwap(iKey, intent.version, { ...intent, leaseOwner: null, state: "pending", version: intent.version + 1 });
  }, async () => (await store.read(gKey))?.state === "claimed" && (await store.read(iKey))?.state === "pending");
}
async function assertCurrentGeneration(store, generation) {
  const current = await store.read(currentKey(generation.repositoryId, generation.pullRequestNumber));
  if (current?.generationId !== generation.generationId)
    fail("cas_lost", "worker generation is stale");
}
async function prepareCheckBinding(store, generationId2, identity) {
  const generation = await store.read(generationKey(generationId2));
  if (generation === void 0 || generation.state !== "decision_ready" || generation.decision === void 0)
    return fail("cas_lost", "completion requires durable decision_ready generation");
  if (identity.appId !== generation.tuple.app_id || identity.installationId !== generation.tuple.installation_id || identity.repositoryId !== generation.repositoryId || identity.repositoryName !== generation.policy.repository.name || identity.baseRef !== generation.policy.repository.baseRef)
    fail("identity", "completion identity differs from immutable generation");
  await assertCurrentGeneration(store, generation);
  const binding = {
    appId: identity.appId,
    checkName: generation.policy.checkName,
    decisionDigest: generation.decision.digest,
    externalId: generation.generationId,
    generationId: generation.generationId,
    headSha: generation.tuple.head_sha,
    policyDigest: generation.policy.digest,
    repositoryId: generation.repositoryId,
    state: "create_pending",
    version: 1
  };
  const key = bindingKey(generationId2);
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(generationId2));
    const current = transaction.get(currentKey(generation.repositoryId, generation.pullRequestNumber));
    if (durableGeneration?.state !== "decision_ready" || current?.generationId !== generationId2 || current.effectLease !== null)
      fail("cas_lost", "generation changed before binding preparation");
    const existing = transaction.get(key);
    if (existing === void 0)
      transaction.putIfAbsent(key, binding);
    else if (canonicalHash(bindingIdentity(existing)) !== canonicalHash(bindingIdentity(binding)))
      fail("conflict", "binding identity changed");
    insertOrVerifyIntent(transaction, generationId2, "create_check");
  }, async () => (await store.read(key))?.externalId === generationId2 && (await store.read(outboxKey(generationId2, "create_check")))?.operation === "create_check");
  return await store.read(key);
}
async function leaseEffect(store, generationId2, operation, owner) {
  if (owner.length === 0)
    fail("invalid_input", "effect lease owner is empty");
  const generation = await store.read(generationKey(generationId2));
  const intent = await store.read(outboxKey(generationId2, operation));
  if (generation === void 0 || intent === void 0 || !["pending", "possible_send"].includes(intent.state))
    return fail("cas_lost", "effect intent unavailable");
  if (operation === "create_check" && generation.state !== "decision_ready")
    fail("cas_lost", "create requires decision_ready");
  if (operation === "update_check" && generation.state !== "completing")
    fail("cas_lost", "update requires completing generation");
  const currentKeyValue = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const current = await store.read(currentKeyValue);
  if (current?.generationId !== generationId2 || current.effectLease !== null)
    return fail("cas_lost", "current generation effect lease unavailable");
  const mode = intent.state === "pending" ? "send" : operation === "create_check" ? "reconcile" : "retry";
  const fence = current.nextFence;
  const lease = { fence, generationId: generationId2, mode, operation, owner };
  const nextCurrent = { ...current, effectLease: { fence, operation, owner }, nextFence: fence + 1, version: current.version + 1 };
  const nextIntent = { ...intent, fence, leaseOwner: owner, state: mode === "reconcile" ? "reconcile_leased" : "send_leased", version: intent.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(currentKeyValue, current.version, nextCurrent);
    transaction.compareAndSwap(outboxKey(generationId2, operation), intent.version, nextIntent);
  }, async () => {
    const durableCurrent = await store.read(currentKeyValue);
    const durableIntent = await store.read(outboxKey(generationId2, operation));
    return durableCurrent?.effectLease?.fence === fence && durableCurrent.effectLease.owner === owner && durableIntent?.fence === fence && durableIntent.leaseOwner === owner;
  });
  return lease;
}
function assertLeaseRows(current, intent, lease) {
  if (current?.generationId !== lease.generationId || current.effectLease?.owner !== lease.owner || current.effectLease.fence !== lease.fence || current.effectLease.operation !== lease.operation || intent?.leaseOwner !== lease.owner || intent.fence !== lease.fence)
    fail("cas_lost", "effect fence changed");
}
async function markEffectPossibleSend(store, lease) {
  if (lease.mode === "reconcile")
    fail("invalid_input", "reconciliation cannot send a create");
  const generation = await store.read(generationKey(lease.generationId));
  if (generation === void 0)
    fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const iKey = outboxKey(lease.generationId, lease.operation);
  const current = await store.read(cKey);
  const intent = await store.read(iKey);
  assertLeaseRows(current, intent, lease);
  if (intent?.state !== "send_leased")
    fail("cas_lost", "effect is not send-leased");
  const next = { ...intent, state: "possible_send", version: intent.version + 1 };
  const binding = await store.read(bindingKey(lease.generationId));
  if (binding === void 0)
    fail("cas_lost", "binding disappeared before possible-send");
  const wanted = lease.operation === "create_check" ? "create_possible" : "update_possible";
  const allowed = lease.operation === "create_check" ? "create_pending" : "update_pending";
  if (binding.state !== allowed && !(lease.mode === "retry" && binding.state === wanted))
    fail("cas_lost", "binding is not sendable");
  const nextBinding = binding.state === wanted ? binding : { ...binding, state: wanted, version: binding.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(iKey, intent.version, next);
    if (nextBinding !== binding)
      transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, nextBinding);
  }, async () => (await store.read(iKey))?.state === "possible_send" && (await store.read(bindingKey(lease.generationId)))?.state === wanted);
}
async function releaseEffect(store, lease, outcome) {
  const generation = await store.read(generationKey(lease.generationId));
  if (generation === void 0)
    fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const iKey = outboxKey(lease.generationId, lease.operation);
  const current = await store.read(cKey);
  const intent = await store.read(iKey);
  assertLeaseRows(current, intent, lease);
  const nextState = outcome === "definite_not_sent" ? "pending" : outcome === "ambiguous" ? "possible_send" : "blocked";
  const nextIntent = { ...intent, fence: null, leaseOwner: null, state: nextState, version: intent.version + 1 };
  const nextCurrent = { ...current, effectLease: null, version: current.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(iKey, intent.version, nextIntent);
    transaction.compareAndSwap(cKey, current.version, nextCurrent);
    const binding = transaction.get(bindingKey(lease.generationId));
    if (outcome === "definite_not_sent" && binding !== void 0) {
      const possible = lease.operation === "create_check" ? "create_possible" : "update_possible";
      const pending = lease.operation === "create_check" ? "create_pending" : "update_pending";
      if (binding.state === possible)
        transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: pending, version: binding.version + 1 });
    }
    if (outcome === "blocked") {
      const durableGeneration = transaction.get(generationKey(lease.generationId));
      transaction.compareAndSwap(generationKey(lease.generationId), durableGeneration.version, { ...durableGeneration, state: "blocked_ambiguous", version: durableGeneration.version + 1 });
      if (binding !== void 0)
        transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: "blocked", version: binding.version + 1 });
    }
  }, async () => (await store.read(cKey))?.effectLease === null && (await store.read(iKey))?.state === nextState);
}
async function recoverAbandonedEffect(store, generationId2, operation, abandonedOwner, fence) {
  const generation = await store.read(generationKey(generationId2));
  if (generation === void 0)
    fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const iKey = outboxKey(generationId2, operation);
  const current = await store.read(cKey);
  const intent = await store.read(iKey);
  const lease = { fence, generationId: generationId2, mode: intent?.state === "reconcile_leased" ? "reconcile" : "send", operation, owner: abandonedOwner };
  assertLeaseRows(current, intent, lease);
  if (intent?.state === "send_leased")
    return releaseEffect(store, lease, "definite_not_sent");
  if (intent?.state === "possible_send" || intent?.state === "reconcile_leased")
    return releaseEffect(store, lease, "ambiguous");
  fail("cas_lost", "effect lease state is not recoverable");
}
async function bindCreatedCheck(store, lease, check) {
  if (lease.operation !== "create_check")
    fail("invalid_input", "wrong effect operation for binding");
  const generation = await store.read(generationKey(lease.generationId));
  const binding = await store.read(bindingKey(lease.generationId));
  if (generation === void 0 || binding === void 0 || !Number.isSafeInteger(check.checkId) || check.checkId <= 0 || check.appId !== binding.appId || check.repositoryId !== binding.repositoryId || check.headSha !== binding.headSha || check.name !== binding.checkName || check.externalId !== binding.externalId)
    fail("identity", "created/adopted check identity mismatch");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const iKey = outboxKey(lease.generationId, "create_check");
  const current = await store.read(cKey);
  const intent = await store.read(iKey);
  assertLeaseRows(current, intent, lease);
  if (lease.mode === "reconcile" ? intent?.state !== "reconcile_leased" : intent?.state !== "possible_send")
    fail("cas_lost", "create binding is not in an adoptable state");
  const nextBinding = { ...binding, checkId: check.checkId, state: "update_pending", version: binding.version + 1 };
  const nextIntent = { ...intent, fence: null, leaseOwner: null, state: "delivered", version: intent.version + 1 };
  const nextCurrent = { ...current, effectLease: null, version: current.version + 1 };
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(lease.generationId));
    if (durableGeneration.state !== "decision_ready" || durableGeneration.decision?.digest !== binding.decisionDigest)
      fail("cas_lost", "decision changed before Check binding");
    transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, nextBinding);
    transaction.compareAndSwap(iKey, intent.version, nextIntent);
    transaction.compareAndSwap(cKey, current.version, nextCurrent);
    transaction.compareAndSwap(generationKey(lease.generationId), durableGeneration.version, { ...durableGeneration, state: "completing", version: durableGeneration.version + 1 });
    insertOrVerifyIntent(transaction, lease.generationId, "update_check");
  }, async () => (await store.read(bindingKey(lease.generationId)))?.checkId === check.checkId && (await store.read(generationKey(lease.generationId)))?.state === "completing");
  return nextBinding;
}
async function completeCheckUpdate(store, lease) {
  if (lease.operation !== "update_check")
    fail("invalid_input", "wrong effect operation for update completion");
  const generation = await store.read(generationKey(lease.generationId));
  const binding = await store.read(bindingKey(lease.generationId));
  if (generation === void 0 || generation.state !== "completing" || generation.decision === void 0 || binding === void 0 || binding.state !== "update_possible" || binding.checkId === void 0 || binding.decisionDigest !== generation.decision.digest)
    fail("cas_lost", "durable update decision or binding changed");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const iKey = outboxKey(lease.generationId, "update_check");
  const current = await store.read(cKey);
  const intent = await store.read(iKey);
  assertLeaseRows(current, intent, lease);
  if (intent?.state !== "possible_send")
    fail("cas_lost", "update is not possible-sent");
  const terminalState = generation.decision.conclusion === "success" ? "terminal_success" : "terminal_failure";
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: "terminal", version: binding.version + 1 });
    transaction.compareAndSwap(iKey, intent.version, { ...intent, fence: null, leaseOwner: null, state: "delivered", version: intent.version + 1 });
    transaction.compareAndSwap(cKey, current.version, { ...current, effectLease: null, version: current.version + 1 });
    transaction.compareAndSwap(generationKey(lease.generationId), generation.version, { ...generation, state: terminalState, version: generation.version + 1 });
  }, async () => (await store.read(generationKey(lease.generationId)))?.state === terminalState && (await store.read(bindingKey(lease.generationId)))?.state === "terminal");
}
async function settlePullReceipt(store, receipt) {
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  const durable = await store.read(key);
  if (durable === void 0 || durable.kind !== "pull_request" || durable.generationId === void 0)
    fail("cas_lost", "pull receipt has no generation");
  const generation = await store.read(generationKey(durable.generationId));
  if (generation === void 0 || !["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state))
    fail("cas_lost", "pull generation is not terminal");
  const outcome = generation.state === "terminal_success" ? "terminal_success" : "terminal_failure";
  const priorOutcome = receiptTerminalOutcome(durable);
  if (priorOutcome !== void 0 && priorOutcome !== outcome)
    fail("conflict", "receipt completion outcome changed");
  if (durable.completedOutcome === outcome && (durable.state === outcome || durable.state === "conflict"))
    return durable;
  const next = { ...durable, completedOutcome: outcome, state: durable.state === "conflict" ? "conflict" : outcome, version: durable.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, durable.version, next), async () => {
    const current = await store.read(key);
    return current?.completedOutcome === outcome && (current.state === outcome || current.state === "conflict");
  });
  return await store.read(key);
}
async function settlePushChild(store, receipt, pr) {
  const rKey = receiptKey(receipt.installationId, receipt.deliveryId);
  const cKey = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const durableReceipt = await store.read(rKey);
  const child = await store.read(cKey);
  if (durableReceipt === void 0 || durableReceipt.kind !== "push" || child === void 0 || child.generationId === void 0 || !durableReceipt.targetNumbers?.includes(pr))
    fail("cas_lost", "push child identity mismatch");
  const generation = await store.read(generationKey(child.generationId));
  if (generation === void 0 || !["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state))
    fail("cas_lost", "push child generation is not terminal");
  const childState = generation.state === "terminal_success" ? "terminal_success" : "terminal_failure";
  await recoverCommit(store, (transaction) => {
    const durableChild = transaction.get(cKey);
    const currentReceipt = transaction.get(rKey);
    if (durableChild === void 0 || currentReceipt === void 0 || durableChild.generationId !== child.generationId)
      fail("cas_lost", "push child changed during aggregation");
    if (!terminal(durableChild.state))
      transaction.compareAndSwap(cKey, durableChild.version, { ...durableChild, leaseOwner: null, state: childState, version: durableChild.version + 1 });
    const states = currentReceipt.targetNumbers.map((number) => number === pr ? childState : transaction.get(pushChildKey(receipt.installationId, receipt.deliveryId, number))?.state);
    if (states.every((state) => state === "terminal_success" || state === "terminal_failure")) {
      const outcome = states.every((state) => state === "terminal_success") ? "terminal_success" : "terminal_failure";
      const priorOutcome = receiptTerminalOutcome(currentReceipt);
      if (priorOutcome !== void 0 && priorOutcome !== outcome)
        fail("conflict", "push receipt completion outcome changed");
      if (currentReceipt.completedOutcome !== outcome || currentReceipt.state !== outcome && currentReceipt.state !== "conflict") {
        transaction.compareAndSwap(rKey, currentReceipt.version, { ...currentReceipt, completedOutcome: outcome, state: currentReceipt.state === "conflict" ? "conflict" : outcome, version: currentReceipt.version + 1 });
      }
    }
  }, async () => terminal((await store.read(cKey))?.state ?? "pending"));
  return await store.read(rKey);
}
async function readGeneration(store, generationId2) {
  const value = await store.read(generationKey(generationId2));
  if (value === void 0)
    return fail("cas_lost", "generation missing");
  return value;
}
async function readBinding(store, generationId2) {
  const value = await store.read(bindingKey(generationId2));
  if (value === void 0)
    return fail("cas_lost", "binding missing");
  return value;
}
var MemoryTransaction, InMemoryDurableStore, receiptKey, currentKey, generationKey, outboxKey, pushChildKey, bindingKey;
var init_store = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/store.js"() {
    init_canonical();
    init_errors();
    MemoryTransaction = class {
      rows;
      constructor(rows) {
        this.rows = rows;
      }
      get(key) {
        const row = this.rows.get(key);
        return row === void 0 ? void 0 : clone(row.value);
      }
      putIfAbsent(key, value) {
        if (this.rows.has(key))
          fail("cas_lost", `unique key already exists: ${key}`);
        this.rows.set(key, { value: clone(value), version: 1 });
      }
      compareAndSwap(key, expectedVersion, value) {
        const row = this.rows.get(key);
        if (row === void 0 || row.version !== expectedVersion)
          fail("cas_lost", `CAS lost: ${key}`);
        this.rows.set(key, { value: clone(value), version: expectedVersion + 1 });
      }
    };
    InMemoryDurableStore = class {
      rows = /* @__PURE__ */ new Map();
      failNextCommit = false;
      ambiguousNextCommit = false;
      async transact(work) {
        const staged = clone(this.rows);
        const result = work(new MemoryTransaction(staged));
        if (this.failNextCommit) {
          this.failNextCommit = false;
          return fail("store_failure", "synthetic store commit failure");
        }
        this.rows = staged;
        if (this.ambiguousNextCommit) {
          this.ambiguousNextCommit = false;
          return fail("store_failure", "synthetic ambiguous store commit");
        }
        return result;
      }
      async read(key) {
        const row = this.rows.get(key);
        return row === void 0 ? void 0 : clone(row.value);
      }
      version(key) {
        return this.rows.get(key)?.version;
      }
      keys() {
        return [...this.rows.keys()].sort();
      }
    };
    receiptKey = (installationId, deliveryId) => `receipt/${installationId}/${deliveryId}`;
    currentKey = (repositoryId, pr) => `current/${repositoryId}/${pr}`;
    generationKey = (generationId2) => `generation/${generationId2}`;
    outboxKey = (generationId2, operation) => `outbox/${generationId2}/${operation}`;
    pushChildKey = (installationId, deliveryId, pr) => `push-child/${installationId}/${deliveryId}/${pr}`;
    bindingKey = (generationId2) => `binding/${generationId2}`;
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/checks.js
function expectedIdentity(generation) {
  return {
    appId: generation.tuple.app_id,
    baseRef: generation.policy.repository.baseRef,
    installationId: generation.tuple.installation_id,
    repositoryId: generation.repositoryId,
    repositoryName: generation.policy.repository.name
  };
}
function exactCheck(check, binding) {
  return Number.isSafeInteger(check.checkId) && check.checkId > 0 && check.appId === binding.appId && check.repositoryId === binding.repositoryId && check.headSha === binding.headSha && check.name === binding.checkName && check.externalId === binding.externalId;
}
async function reconcileCreateCheckOnce(input) {
  const generation = await readGeneration(input.store, input.generationId);
  const binding = await readBinding(input.store, input.generationId);
  if (generation.state !== "decision_ready" || generation.decision?.digest !== binding.decisionDigest || binding.policyDigest !== generation.policy.digest)
    fail("cas_lost", "create cannot reconcile without immutable durable decision");
  const lease = await leaseEffect(input.store, input.generationId, "create_check", input.worker);
  if (lease.mode !== "reconcile")
    fail("cas_lost", "create reconciliation is not durable");
  const matches = await enumerateMatchingChecks(input.port, expectedIdentity(generation), binding.headSha, binding.checkName, binding.externalId, generation.policy.limits);
  if (matches.length === 1) {
    await bindCreatedCheck(input.store, lease, matches[0]);
    return matches[0];
  }
  if (matches.length > 1 || input.finalAttempt) {
    await releaseEffect(input.store, lease, "blocked");
    return fail("ambiguous_api", matches.length > 1 ? "multiple App-owned checks match immutable generation" : "ambiguous create remained invisible; recreation forbidden");
  }
  await releaseEffect(input.store, lease, "ambiguous");
  return "not_visible";
}
async function runCreateCheck(input) {
  const generation = await readGeneration(input.store, input.generationId);
  const binding = await readBinding(input.store, input.generationId);
  if (generation.state !== "decision_ready" || generation.decision?.digest !== binding.decisionDigest || binding.policyDigest !== generation.policy.digest)
    fail("cas_lost", "create cannot run without the immutable durable decision");
  const identity = expectedIdentity(generation);
  const lease = await leaseEffect(input.store, input.generationId, "create_check", input.worker);
  if (lease.mode === "reconcile") {
    const matches = await enumerateMatchingChecks(input.port, identity, binding.headSha, binding.checkName, binding.externalId, generation.policy.limits);
    if (matches.length === 1) {
      await bindCreatedCheck(input.store, lease, matches[0]);
      return matches[0];
    }
    await releaseEffect(input.store, lease, "blocked");
    return fail("ambiguous_api", matches.length > 1 ? "multiple App-owned checks match immutable generation" : "ambiguous create remained invisible; recreation forbidden");
  }
  await markEffectPossibleSend(input.store, lease);
  let created;
  try {
    created = await input.port.createCheck({ externalId: binding.externalId, headSha: binding.headSha, name: binding.checkName, repositoryId: binding.repositoryId });
  } catch (error) {
    if (error instanceof DefinitiveNotSentError) {
      await releaseEffect(input.store, lease, "definite_not_sent");
      throw error;
    }
    await releaseEffect(input.store, lease, "ambiguous");
    if (error instanceof AmbiguousCreateError)
      throw error;
    return fail("ambiguous_api", "check creation outcome is not definite");
  }
  if (!exactCheck(created, binding)) {
    await releaseEffect(input.store, lease, "blocked");
    return fail("identity", "created check identity mismatch");
  }
  await bindCreatedCheck(input.store, lease, created);
  return created;
}
async function runUpdateCheck(input) {
  const generation = await readGeneration(input.store, input.generationId);
  const binding = await readBinding(input.store, input.generationId);
  if (generation.state !== "completing" || generation.decision === void 0 || generation.decision.digest !== binding.decisionDigest || binding.checkId === void 0 || !["update_pending", "update_possible"].includes(binding.state))
    fail("cas_lost", "update cannot run without one bound immutable decision");
  const lease = await leaseEffect(input.store, input.generationId, "update_check", input.worker);
  const livePullRequest = await input.port.getPullRequest(generation.repositoryId, generation.pullRequestNumber);
  const liveMain = await input.port.getMainRef(generation.repositoryId);
  if (canonicalHash(livePullRequest) !== canonicalHash(generation.snapshot) || liveMain.sha !== generation.mainSha || liveMain.repositoryId !== generation.repositoryId || liveMain.ref !== "refs/heads/main") {
    await releaseEffect(input.store, lease, "definite_not_sent");
    return fail("snapshot_race", "live snapshot changed before Check Run update");
  }
  const matches = await enumerateMatchingChecks(input.port, expectedIdentity(generation), binding.headSha, binding.checkName, binding.externalId, generation.policy.limits);
  if (matches.length !== 1 || matches[0].checkId !== binding.checkId || !exactCheck(matches[0], binding)) {
    await releaseEffect(input.store, lease, "blocked");
    return fail("identity", "bound Check identity cannot be revalidated");
  }
  await markEffectPossibleSend(input.store, lease);
  try {
    await input.port.updateCheck({
      checkId: binding.checkId,
      conclusion: generation.decision.conclusion,
      repositoryId: binding.repositoryId,
      summary: generation.decision.conclusion === "success" ? "No protected release controls changed." : "Protected release controls changed; owner review is required."
    });
  } catch (error) {
    await releaseEffect(input.store, lease, "ambiguous");
    if (error instanceof AmbiguousUpdateError)
      throw error;
    return fail("ambiguous_api", "bound Check update outcome is not definite");
  }
  await completeCheckUpdate(input.store, lease);
}
var AmbiguousCreateError, DefinitiveNotSentError, AmbiguousUpdateError;
var init_checks = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/checks.js"() {
    init_canonical();
    init_errors();
    init_pagination();
    init_store();
    AmbiguousCreateError = class extends Error {
    };
    DefinitiveNotSentError = class extends Error {
    };
    AmbiguousUpdateError = class extends Error {
    };
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/delivery.js
function record(value, label) {
  if (value === null || Array.isArray(value) || typeof value !== "object")
    fail("identity", `${label} identity missing`);
  return value;
}
function positive2(value, label) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
    fail("identity", `${label} must be a positive safe integer`);
  return value;
}
function oid(value, label) {
  if (typeof value !== "string" || !/^[0-9a-f]{40}$/.test(value))
    fail("identity", `${label} is inaccessible or malformed`);
  return value;
}
function validateDeliveryIdentity(webhook, expected) {
  for (const [label, value] of [["App", expected.appId], ["installation", expected.installationId], ["repository", expected.repositoryId]])
    positive2(value, label);
  if (expected.repositoryName !== "kenleren/MyArtCollection" || expected.baseRef !== "main")
    fail("identity", "expected repository identity is outside policy");
  const repository = record(webhook.payload.repository, "repository");
  const installation = record(webhook.payload.installation, "installation");
  if (positive2(repository.id, "repository id") !== expected.repositoryId || repository.full_name !== expected.repositoryName || positive2(installation.id, "installation id") !== expected.installationId)
    fail("identity", "webhook repository or installation mismatch");
  if (webhook.event === "push")
    return { after: oid(webhook.payload.after, "push after"), kind: "push" };
  const pull = record(webhook.payload.pull_request, "pull request");
  const base = record(pull.base, "pull request base");
  const baseRepository = record(base.repo, "pull request base repository");
  const head = record(pull.head, "pull request head");
  const headRepository = record(head.repo, "pull request head repository");
  if (base.ref !== "main" || positive2(baseRepository.id, "base repository id") !== expected.repositoryId || positive2(headRepository.id, "head repository id") !== expected.repositoryId)
    fail("identity", "wrong base or fork pull request");
  return { kind: "pull_request", pullRequestNumber: positive2(webhook.payload.number, "pull request number") };
}
var init_delivery = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/delivery.js"() {
    init_errors();
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/external.js
function runtimeObservationContractDigest(row) {
  return canonicalHash({ consumer: row.consumer, id: row.id, kind: row.kind, locator: row.locator, producer: row.producer });
}
function validIntegrityDigest(algorithm, digest2) {
  if (algorithm === "git-commit-sha1")
    return /^[0-9a-f]{40}$/.test(digest2);
  if (algorithm === "sha256" || algorithm === "lock-sha256")
    return /^[0-9a-f]{64}$/.test(digest2);
  if (algorithm === "sri")
    return /^sha256-[A-Za-z0-9+/]{43}=$/.test(digest2);
  return false;
}
function exactKeys(value, keys2) {
  return Object.keys(value).sort().join("\0") === [...keys2].sort().join("\0");
}
function validateExternalInputs(rows) {
  const ids = /* @__PURE__ */ new Set();
  return rows.map((unknownRow) => {
    if (unknownRow === null || Array.isArray(unknownRow) || typeof unknownRow !== "object" || !exactKeys(unknownRow, KEYS))
      fail("invalid_input", "external row keys mismatch");
    const row = unknownRow;
    if (typeof row.integrity !== "object" || row.integrity === null || !exactKeys(row.integrity, INTEGRITY_KEYS))
      fail("invalid_input", "integrity keys mismatch");
    for (const field of [row.consumer, row.id, row.locator, row.producer, row.integrity.digest])
      if (typeof field !== "string" || field.length === 0)
        fail("invalid_input", "external row contains empty string");
    if (ids.has(row.id))
      fail("invalid_input", "duplicate external input id");
    ids.add(row.id);
    if (!ALGORITHMS.has(row.integrity.algorithm) || !KINDS.has(row.kind) || !["ephemeral", "review-artifact"].includes(row.retention) || row.secret_policy !== "forbidden" || !["trusted", "evidence-only"].includes(row.trust))
      fail("invalid_input", "external row enum mismatch");
    if (!validIntegrityDigest(row.integrity.algorithm, row.integrity.digest))
      fail("invalid_input", "external integrity digest does not match its algorithm");
    if (row.trust === "trusted" && !["policy", "lock"].includes(row.integrity.source))
      fail("invalid_input", "trusted input needs policy or lock integrity");
    if (row.trust === "evidence-only" && row.integrity.source !== "runtime-observation")
      fail("invalid_input", "evidence-only input needs runtime observation");
    if (row.trust === "evidence-only" && row.kind === "action")
      fail("invalid_input", "evidence cannot promote an action to trust");
    if (row.trust === "evidence-only" && row.integrity.algorithm !== "sha256")
      fail("invalid_input", "runtime evidence contracts use SHA-256");
    if (row.trust === "evidence-only" && row.integrity.digest !== runtimeObservationContractDigest(row))
      fail("invalid_input", "runtime evidence contract digest is not canonical");
    if (row.locator.startsWith("/") || /(?:secret|token|credential|keystore|\.env)/i.test(row.locator))
      fail("invalid_input", "external locator crosses secret or absolute-path boundary");
    return row;
  });
}
function verifyAptClosure(simulated, downloaded, installedBeforeVerification) {
  if (installedBeforeVerification)
    fail("invalid_input", "apt install occurred before evidence verification");
  const expected = [...simulated].sort();
  const actual = downloaded.map((row) => row.coordinate).sort();
  if (new Set(expected).size !== expected.length || new Set(actual).size !== actual.length || expected.join("\0") !== actual.join("\0"))
    fail("invalid_input", "downloaded apt closure differs from simulation");
  if (downloaded.some((row) => !/^[0-9a-f]{64}$/.test(row.sha256)))
    fail("invalid_input", "apt archive hash missing or malformed");
}
function verifyAcquiredDigest(expectedSha256, bytes) {
  if (!/^[0-9a-f]{64}$/.test(expectedSha256) || sha256(bytes) !== expectedSha256)
    fail("invalid_input", "acquired input digest mismatch");
}
var KEYS, INTEGRITY_KEYS, ALGORITHMS, KINDS;
var init_external = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/external.js"() {
    init_errors();
    init_canonical();
    KEYS = ["consumer", "id", "integrity", "kind", "locator", "producer", "retention", "secret_policy", "trust"];
    INTEGRITY_KEYS = ["algorithm", "digest", "source"];
    ALGORITHMS = /* @__PURE__ */ new Set(["git-commit-sha1", "sha256", "lock-sha256", "sri"]);
    KINDS = /* @__PURE__ */ new Set(["action", "toolchain", "lock-resolution", "cache", "temporary", "build-output", "live-response", "evidence"]);
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/paths.js
function fullUnicodeCaseFold(value) {
  let output = "";
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code === 305)
      output += character;
    else if (code === 7838)
      output += "ss";
    else if (code >= 5024 && code <= 5109)
      output += character;
    else if (code >= 5112 && code <= 5117)
      output += String.fromCodePoint(code - 8);
    else if (code >= 43888 && code <= 43967)
      output += String.fromCodePoint(code - 38864);
    else
      output += character.toUpperCase().toLowerCase();
  }
  return output.normalize("NFC");
}
function validateRepositoryPath(path) {
  if (path.length === 0 || path.startsWith("/") || path.includes("\\") || /[\u0000-\u001f\u007f]/.test(path)) {
    return fail("invalid_input", "malformed repository path");
  }
  if (path.normalize("NFC") !== path)
    fail("invalid_input", "repository path must be NFC");
  const segments = path.split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === ".."))
    fail("invalid_input", "repository path has invalid segment");
  return path;
}
function isProtected(path, policy) {
  return policy.exact.includes(path) || policy.prefixes.some((prefix) => path.startsWith(prefix));
}
function evaluateChangedFiles(files, policy) {
  const exact = /* @__PURE__ */ new Set();
  const folded = /* @__PURE__ */ new Map();
  const protectedPaths = /* @__PURE__ */ new Set();
  for (const file of files) {
    if (!["added", "modified", "removed", "renamed", "copied"].includes(file.status))
      fail("invalid_input", "unsupported file status");
    if ((file.status === "renamed" || file.status === "copied") !== (file.previousPath !== void 0))
      fail("invalid_input", "prior path contract mismatch");
    const paths = file.previousPath === void 0 ? [file.path] : [file.previousPath, file.path];
    if (file.previousPath === file.path)
      fail("invalid_input", "prior and current paths must differ");
    for (const candidate of paths) {
      const path = validateRepositoryPath(candidate);
      if (exact.has(path))
        fail("invalid_input", "duplicate repository path");
      exact.add(path);
      const collisionKey = fullUnicodeCaseFold(path);
      const prior = folded.get(collisionKey);
      if (prior !== void 0 && prior !== path)
        fail("invalid_input", "case or Unicode path collision");
      folded.set(collisionKey, path);
      if (isProtected(path, policy))
        protectedPaths.add(path);
    }
  }
  return { protectedPaths: [...protectedPaths].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))) };
}
var init_paths = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/paths.js"() {
    init_errors();
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/strict_json.js
function parseStrictJson(bytes, limits) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return fail("invalid_input", "body is not valid UTF-8");
  }
  return new Parser(text, limits).parse();
}
var Parser;
var init_strict_json = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/strict_json.js"() {
    init_errors();
    Parser = class {
      text;
      limits;
      index = 0;
      nodes = 0;
      constructor(text, limits) {
        this.text = text;
        this.limits = limits;
      }
      parse() {
        const value = this.value(0);
        this.space();
        if (this.index !== this.text.length)
          fail("invalid_input", "trailing JSON data");
        return value;
      }
      node(depth) {
        if (depth > this.limits.maxDepth)
          fail("overflow", "JSON depth exceeded");
        this.nodes += 1;
        if (this.nodes > this.limits.maxNodes)
          fail("overflow", "JSON node count exceeded");
      }
      value(depth) {
        this.space();
        this.node(depth);
        const char = this.text[this.index];
        if (char === "{")
          return this.object(depth + 1);
        if (char === "[")
          return this.array(depth + 1);
        if (char === '"')
          return this.string();
        if (char === "t")
          return this.literal("true", true);
        if (char === "f")
          return this.literal("false", false);
        if (char === "n")
          return this.literal("null", null);
        return this.number();
      }
      object(depth) {
        this.index += 1;
        const output = {};
        const keys2 = /* @__PURE__ */ new Set();
        this.space();
        if (this.text[this.index] === "}") {
          this.index += 1;
          return output;
        }
        for (; ; ) {
          this.space();
          if (this.text[this.index] !== '"')
            fail("invalid_input", "object key must be a string");
          const key = this.string();
          if (keys2.has(key))
            fail("invalid_input", "duplicate JSON key");
          keys2.add(key);
          this.space();
          if (this.text[this.index] !== ":")
            fail("invalid_input", "missing JSON colon");
          this.index += 1;
          output[key] = this.value(depth);
          this.space();
          const separator = this.text[this.index++];
          if (separator === "}")
            return output;
          if (separator !== ",")
            fail("invalid_input", "invalid JSON object separator");
        }
      }
      array(depth) {
        this.index += 1;
        const output = [];
        this.space();
        if (this.text[this.index] === "]") {
          this.index += 1;
          return output;
        }
        for (; ; ) {
          output.push(this.value(depth));
          this.space();
          const separator = this.text[this.index++];
          if (separator === "]")
            return output;
          if (separator !== ",")
            fail("invalid_input", "invalid JSON array separator");
        }
      }
      string() {
        const start = this.index;
        this.index += 1;
        let escaped = false;
        while (this.index < this.text.length) {
          const code = this.text.charCodeAt(this.index);
          if (!escaped && code === 34) {
            this.index += 1;
            try {
              return JSON.parse(this.text.slice(start, this.index));
            } catch {
              return fail("invalid_input", "invalid JSON string");
            }
          }
          if (!escaped && code < 32)
            fail("invalid_input", "control byte in JSON string");
          if (!escaped && code === 92)
            escaped = true;
          else
            escaped = false;
          this.index += 1;
        }
        return fail("invalid_input", "unterminated JSON string");
      }
      number() {
        const tail = this.text.slice(this.index);
        const match = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(tail);
        if (!match)
          return fail("invalid_input", "invalid JSON value");
        this.index += match[0].length;
        const value = Number(match[0]);
        if (!Number.isFinite(value))
          return fail("invalid_input", "non-finite JSON number");
        return value;
      }
      literal(token, value) {
        if (!this.text.startsWith(token, this.index))
          fail("invalid_input", "invalid JSON literal");
        this.index += token.length;
        return value;
      }
      space() {
        while ([" ", "	", "\r", "\n"].includes(this.text[this.index] ?? ""))
          this.index += 1;
      }
    };
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/policy.js
function record2(value, label) {
  if (value === null || Array.isArray(value) || typeof value !== "object")
    fail("invalid_input", `${label} must be an object`);
  return value;
}
function exactKeys2(value, expected, label) {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index]))
    fail("invalid_input", `${label} keys mismatch`);
}
function positiveInteger(value, label) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
    fail("invalid_input", `${label} must be a positive safe integer`);
  return value;
}
function strings(value, label, prefix) {
  if (!Array.isArray(value))
    fail("invalid_input", `${label} must be an array`);
  const output = value.map((item) => {
    if (typeof item !== "string")
      return fail("invalid_input", `${label} must contain strings`);
    const path = prefix ? validateRepositoryPath(`${item}sentinel`).slice(0, -8) : validateRepositoryPath(item);
    if (prefix && !path.endsWith("/"))
      fail("invalid_input", `${label} prefixes must end with slash`);
    return path;
  });
  const exact = new Set(output);
  const folded = new Set(output.map(fullUnicodeCaseFold));
  if (exact.size !== output.length || folded.size !== output.length)
    fail("invalid_input", `${label} contains duplicate or case-fold-colliding entries`);
  return Object.freeze([...output]);
}
function assertCanonicalPolicy(value) {
  if (value === null || typeof value !== "object" || !CANONICAL_POLICIES.has(value))
    fail("invalid_input", "policy must come from canonical policy bytes");
}
function loadCanonicalPolicy(bytes) {
  const parsed = record2(parseStrictJson(bytes, { maxDepth: 16, maxNodes: 1e4 }), "policy");
  exactKeys2(parsed, ROOT_KEYS, "policy");
  if (parsed.schema_version !== 1)
    fail("invalid_input", "unsupported policy schema");
  if (typeof parsed.base_commit !== "string" || !/^[0-9a-f]{40}$/.test(parsed.base_commit))
    fail("invalid_input", "policy base commit is malformed");
  if (typeof parsed.check_name !== "string" || parsed.check_name.length === 0 || Buffer.byteLength(parsed.check_name) > 128)
    fail("invalid_input", "policy check name is malformed");
  const repository = record2(parsed.repository, "policy repository");
  exactKeys2(repository, REPOSITORY_KEYS, "policy repository");
  if (repository.base_ref !== "main" || repository.name !== "kenleren/MyArtCollection")
    fail("identity", "policy repository identity mismatch");
  const limits = record2(parsed.limits, "policy limits");
  exactKeys2(limits, LIMIT_KEYS, "policy limits");
  if (!Array.isArray(limits.reconcile_delays_seconds) || limits.reconcile_delays_seconds.length === 0)
    fail("invalid_input", "policy reconcile delays are malformed");
  const delays = limits.reconcile_delays_seconds.map((value, index) => positiveInteger(value, `reconcile delay ${index}`));
  if (delays.some((value, index) => index > 0 && value <= delays[index - 1]))
    fail("invalid_input", "policy reconcile delays must strictly increase");
  const runtimeLimits = {
    actionBytes: positiveInteger(limits.action_bytes, "action bytes"),
    checkPages: positiveInteger(limits.check_pages, "check pages"),
    checkRows: positiveInteger(limits.check_rows, "check rows"),
    deliveryIdBytes: positiveInteger(limits.delivery_id_bytes, "delivery id bytes"),
    eventBytes: positiveInteger(limits.event_bytes, "event bytes"),
    filePages: positiveInteger(limits.file_pages, "file pages"),
    fileRows: positiveInteger(limits.file_rows, "file rows"),
    headerCount: positiveInteger(limits.header_count, "header count"),
    headerNameBytes: positiveInteger(limits.header_name_bytes, "header name bytes"),
    headerValueBytes: positiveInteger(limits.header_value_bytes, "header value bytes"),
    jsonDepth: positiveInteger(limits.json_depth, "JSON depth"),
    jsonNodes: positiveInteger(limits.json_nodes, "JSON nodes"),
    openPrPages: positiveInteger(limits.open_pr_pages, "open PR pages"),
    openPrPasses: positiveInteger(limits.open_pr_passes, "open PR passes"),
    openPrRows: positiveInteger(limits.open_pr_rows, "open PR rows"),
    pageSize: positiveInteger(limits.page_size, "page size"),
    reconcileDelaysSeconds: delays,
    webhookBodyBytes: positiveInteger(limits.webhook_body_bytes, "webhook body bytes")
  };
  if (runtimeLimits.pageSize !== 100 || runtimeLimits.fileRows !== runtimeLimits.filePages * runtimeLimits.pageSize || runtimeLimits.checkRows !== runtimeLimits.checkPages * runtimeLimits.pageSize || runtimeLimits.openPrRows !== runtimeLimits.openPrPages * runtimeLimits.pageSize || runtimeLimits.openPrPasses !== 2)
    fail("invalid_input", "policy pagination limits are internally inconsistent");
  const selectors = record2(parsed.selectors, "policy selectors");
  exactKeys2(selectors, SELECTOR_KEYS, "policy selectors");
  const exact = [...strings(selectors.baseline_exact, "baseline exact", false), ...strings(selectors.final_exact_additions, "final exact", false)];
  const prefixes = [...strings(selectors.baseline_prefixes, "baseline prefixes", true), ...strings(selectors.final_prefix_additions, "final prefixes", true)];
  if (new Set(exact).size !== exact.length || new Set(prefixes).size !== prefixes.length)
    fail("invalid_input", "policy selector groups overlap");
  return new CanonicalReleasePolicyValue(POLICY_FACTORY_TOKEN, {
    baseCommit: parsed.base_commit,
    checkName: parsed.check_name,
    digest: sha256(bytes),
    limits: runtimeLimits,
    pathPolicy: { exact, prefixes }
  });
}
var ROOT_KEYS, REPOSITORY_KEYS, SELECTOR_KEYS, LIMIT_KEYS, POLICY_FACTORY_TOKEN, CANONICAL_POLICIES, CanonicalReleasePolicyValue;
var init_policy = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/policy.js"() {
    init_canonical();
    init_errors();
    init_paths();
    init_strict_json();
    ROOT_KEYS = ["base_commit", "check_name", "limits", "repository", "schema_version", "selectors"];
    REPOSITORY_KEYS = ["base_ref", "name"];
    SELECTOR_KEYS = ["baseline_exact", "baseline_prefixes", "final_exact_additions", "final_prefix_additions"];
    LIMIT_KEYS = [
      "action_bytes",
      "check_pages",
      "check_rows",
      "delivery_id_bytes",
      "event_bytes",
      "file_pages",
      "file_rows",
      "header_count",
      "header_name_bytes",
      "header_value_bytes",
      "json_depth",
      "json_nodes",
      "open_pr_pages",
      "open_pr_passes",
      "open_pr_rows",
      "page_size",
      "reconcile_delays_seconds",
      "webhook_body_bytes"
    ];
    POLICY_FACTORY_TOKEN = Object.freeze({});
    CANONICAL_POLICIES = /* @__PURE__ */ new WeakSet();
    CanonicalReleasePolicyValue = class {
      baseCommit;
      checkName;
      digest;
      limits;
      pathPolicy;
      repository;
      constructor(token, input) {
        if (token !== POLICY_FACTORY_TOKEN)
          fail("invalid_input", "canonical policy construction is private");
        this.baseCommit = input.baseCommit;
        this.checkName = input.checkName;
        this.digest = input.digest;
        this.limits = Object.freeze({ ...input.limits, reconcileDelaysSeconds: Object.freeze([...input.limits.reconcileDelaysSeconds]) });
        this.pathPolicy = Object.freeze({ exact: Object.freeze([...input.pathPolicy.exact]), prefixes: Object.freeze([...input.pathPolicy.prefixes]) });
        this.repository = Object.freeze({ baseRef: "main", name: "kenleren/MyArtCollection" });
        CANONICAL_POLICIES.add(this);
        Object.freeze(this);
      }
    };
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/ports.js
var init_ports = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/ports.js"() {
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/snapshot.js
function positive3(value) {
  return Number.isSafeInteger(value) && value > 0;
}
function samePr(left, right) {
  return canonicalHash(left) === canonicalHash(right);
}
function validatePr(pr, expected, number) {
  if (![pr.appId, pr.installationId, pr.repositoryId, pr.headRepositoryId, pr.number].every(positive3))
    fail("identity", "invalid numeric PR identity");
  if (pr.appId !== expected.appId || pr.installationId !== expected.installationId || pr.repositoryId !== expected.repositoryId || pr.repositoryName !== expected.repositoryName || pr.number !== number || pr.baseRef !== expected.baseRef || pr.state !== "open")
    fail("identity", "PR identity mismatch");
  if (pr.headRepositoryId !== expected.repositoryId)
    fail("identity", "fork pull requests are not accepted");
  if (!/^[0-9a-f]{40}$/.test(pr.baseSha) || !/^[0-9a-f]{40}$/.test(pr.headSha))
    fail("identity", "invalid or inaccessible PR ref");
}
async function snapshotPullRequest(port, expected, number, policy) {
  assertCanonicalPolicy(policy);
  if (expected.repositoryName !== policy.repository.name || expected.baseRef !== policy.repository.baseRef)
    fail("identity", "runtime identity differs from canonical policy");
  const first = await port.getPullRequest(expected.repositoryId, number);
  validatePr(first, expected, number);
  const main = await port.getMainRef(expected.repositoryId);
  if (main.repositoryId !== expected.repositoryId || main.ref !== "refs/heads/main" || main.sha !== first.baseSha)
    fail("snapshot_race", "base is not current main");
  const files = await collectPullRequestFiles(port, expected.repositoryId, number, first.changedFiles, policy.limits);
  const evaluation = evaluateChangedFiles(files, policy.pathPolicy);
  const second = await port.getPullRequest(expected.repositoryId, number);
  const secondMain = await port.getMainRef(expected.repositoryId);
  if (!samePr(first, second) || canonicalHash(main) !== canonicalHash(secondMain))
    fail("snapshot_race", "PR or main moved while snapshotting");
  const tuple = {
    app_id: expected.appId,
    base_ref: first.baseRef,
    base_sha: first.baseSha,
    head_sha: first.headSha,
    installation_id: expected.installationId,
    policy_sha256: policy.digest,
    pull_request_number: number,
    repository_id: expected.repositoryId
  };
  const decision = {
    conclusion: evaluation.protectedPaths.length === 0 ? "success" : "failure",
    digest: canonicalHash({ files_digest: canonicalHash(files), policy_sha256: policy.digest, protected_paths: evaluation.protectedPaths }),
    protectedPaths: evaluation.protectedPaths
  };
  return {
    decision,
    fileCount: files.length,
    filesDigest: canonicalHash(files),
    generationId: generationId(tuple),
    mainSha: main.sha,
    policy: {
      checkName: policy.checkName,
      digest: policy.digest,
      limits: structuredClone(policy.limits),
      pathPolicy: structuredClone(policy.pathPolicy),
      repository: { ...policy.repository }
    },
    snapshot: first,
    tuple
  };
}
async function snapshotPushTargets(port, expected, after, policy) {
  assertCanonicalPolicy(policy);
  if (expected.repositoryName !== policy.repository.name || expected.baseRef !== policy.repository.baseRef)
    fail("identity", "runtime identity differs from canonical policy");
  const before = await port.getMainRef(expected.repositoryId);
  if (before.repositoryId !== expected.repositoryId || before.ref !== "refs/heads/main" || before.sha !== after)
    fail("snapshot_race", "push after does not equal live main");
  const targets = await enumerateOpenMainPullRequests(port, expected, policy.limits);
  const afterRead = await port.getMainRef(expected.repositoryId);
  if (canonicalHash(before) !== canonicalHash(afterRead))
    fail("snapshot_race", "main moved during push fanout");
  return { count: targets.count, digest: targets.digest, numbers: targets.rows.map((row) => row.number) };
}
var init_snapshot = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/snapshot.js"() {
    init_canonical();
    init_errors();
    init_pagination();
    init_paths();
    init_policy();
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/webhook.js
import { createHmac, timingSafeEqual } from "node:crypto";
function ascii(value, max, label) {
  if (Buffer.byteLength(value, "utf8") > max || !/^[\x20-\x7e]+$/.test(value))
    fail("invalid_input", `${label} is malformed`);
}
function verifyWebhook(rawBody, headers, secret, policy) {
  assertCanonicalPolicy(policy);
  const limits = {
    actionBytes: policy.limits.actionBytes,
    bodyBytes: policy.limits.webhookBodyBytes,
    deliveryIdBytes: policy.limits.deliveryIdBytes,
    eventBytes: policy.limits.eventBytes,
    headerCount: policy.limits.headerCount,
    headerNameBytes: policy.limits.headerNameBytes,
    headerValueBytes: policy.limits.headerValueBytes,
    jsonDepth: policy.limits.jsonDepth,
    jsonNodes: policy.limits.jsonNodes
  };
  if (rawBody.byteLength > limits.bodyBytes)
    fail("overflow", "webhook body too large");
  if (headers.length > limits.headerCount)
    fail("overflow", "too many webhook headers");
  const values = /* @__PURE__ */ new Map();
  for (const header of headers) {
    ascii(header.name, limits.headerNameBytes, "header name");
    ascii(header.value, limits.headerValueBytes, "header value");
    const name = header.name.toLowerCase();
    const list = values.get(name) ?? [];
    list.push(header.value);
    values.set(name, list);
  }
  const singleton = (name) => {
    const list = values.get(name);
    if (list?.length !== 1)
      return fail("invalid_input", `${name} must occur exactly once`);
    return list[0];
  };
  const contentType = singleton("content-type").toLowerCase();
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/.test(contentType))
    fail("invalid_input", "unsupported content type");
  const signature = singleton("x-hub-signature-256");
  if (!/^sha256=[0-9a-f]{64}$/.test(signature))
    fail("invalid_input", "malformed webhook signature");
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const supplied = Buffer.from(signature.slice(7), "hex");
  if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected))
    fail("invalid_input", "webhook signature mismatch");
  const event = singleton("x-github-event");
  const deliveryId = singleton("x-github-delivery");
  ascii(event, limits.eventBytes, "event");
  ascii(deliveryId, limits.deliveryIdBytes, "delivery id");
  if (event !== "pull_request" && event !== "push")
    fail("invalid_input", "unsupported webhook event");
  const parsed = parseStrictJson(rawBody, { maxDepth: limits.jsonDepth, maxNodes: limits.jsonNodes });
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object")
    fail("invalid_input", "webhook body must be an object");
  const payload = parsed;
  let action = "";
  if (event === "pull_request") {
    if (typeof payload.action !== "string")
      fail("invalid_input", "pull request action missing");
    ascii(payload.action, limits.actionBytes, "action");
    if (!PULL_ACTIONS.has(payload.action))
      fail("invalid_input", "unsupported pull request action");
    action = payload.action;
  } else {
    if (payload.ref !== "refs/heads/main")
      fail("invalid_input", "push is not for main");
  }
  return { action, deliveryId, event, payload, payloadSha256: sha256(rawBody) };
}
var PULL_ACTIONS;
var init_webhook = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/webhook.js"() {
    init_canonical();
    init_errors();
    init_strict_json();
    init_policy();
    PULL_ACTIONS = /* @__PURE__ */ new Set(["opened", "reopened", "synchronize", "edited", "ready_for_review"]);
  }
});

// node_modules/@archivale/release-policy-trust/dist/src/index.js
var src_exports = {};
__export(src_exports, {
  AmbiguousCreateError: () => AmbiguousCreateError,
  AmbiguousUpdateError: () => AmbiguousUpdateError,
  DefinitiveNotSentError: () => DefinitiveNotSentError,
  FailClosedError: () => FailClosedError,
  InMemoryDurableStore: () => InMemoryDurableStore,
  assertCanonicalPolicy: () => assertCanonicalPolicy,
  assertCurrentGeneration: () => assertCurrentGeneration,
  atomicEnqueuePull: () => atomicEnqueuePull,
  atomicEnqueuePush: () => atomicEnqueuePush,
  atomicEnqueuePushChild: () => atomicEnqueuePushChild,
  beginReceiptSnapshot: () => beginReceiptSnapshot,
  bindCreatedCheck: () => bindCreatedCheck,
  bindingKey: () => bindingKey,
  canonicalHash: () => canonicalHash,
  canonicalJson: () => canonicalJson,
  collectPullRequestFiles: () => collectPullRequestFiles,
  commitDecision: () => commitDecision,
  completeCheckUpdate: () => completeCheckUpdate,
  currentKey: () => currentKey,
  enumerateMatchingChecks: () => enumerateMatchingChecks,
  enumerateOpenMainPullRequests: () => enumerateOpenMainPullRequests,
  evaluateChangedFiles: () => evaluateChangedFiles,
  fail: () => fail,
  fullUnicodeCaseFold: () => fullUnicodeCaseFold,
  generationFromEvaluation: () => generationFromEvaluation,
  generationId: () => generationId,
  generationKey: () => generationKey,
  isProtected: () => isProtected,
  leaseEffect: () => leaseEffect,
  leaseOutbox: () => leaseOutbox,
  leasePushChild: () => leasePushChild,
  loadCanonicalPolicy: () => loadCanonicalPolicy,
  markEffectPossibleSend: () => markEffectPossibleSend,
  outboxKey: () => outboxKey,
  parseStrictJson: () => parseStrictJson,
  prepareCheckBinding: () => prepareCheckBinding,
  pushChildKey: () => pushChildKey,
  readBinding: () => readBinding,
  readGeneration: () => readGeneration,
  receiptKey: () => receiptKey,
  receive: () => receive,
  reconcileCreateCheckOnce: () => reconcileCreateCheckOnce,
  recoverAbandonedEffect: () => recoverAbandonedEffect,
  recoverEvaluationLease: () => recoverEvaluationLease,
  recoverPushChildLease: () => recoverPushChildLease,
  releaseEffect: () => releaseEffect,
  runCreateCheck: () => runCreateCheck,
  runUpdateCheck: () => runUpdateCheck,
  runtimeObservationContractDigest: () => runtimeObservationContractDigest,
  settlePullReceipt: () => settlePullReceipt,
  settlePushChild: () => settlePushChild,
  sha256: () => sha256,
  snapshotPullRequest: () => snapshotPullRequest,
  snapshotPushTargets: () => snapshotPushTargets,
  validateDeliveryIdentity: () => validateDeliveryIdentity,
  validateExternalInputs: () => validateExternalInputs,
  validateRepositoryPath: () => validateRepositoryPath,
  verifyAcquiredDigest: () => verifyAcquiredDigest,
  verifyAptClosure: () => verifyAptClosure,
  verifyWebhook: () => verifyWebhook
});
var init_src = __esm({
  "node_modules/@archivale/release-policy-trust/dist/src/index.js"() {
    init_canonical();
    init_checks();
    init_delivery();
    init_errors();
    init_external();
    init_pagination();
    init_paths();
    init_policy();
    init_ports();
    init_snapshot();
    init_store();
    init_strict_json();
    init_webhook();
  }
});

// src/worker.ts
init_src();

// src/config.ts
init_src();
var REPOSITORY_ID = 1288597824;
var REPOSITORY_NAME = "kenleren/MyArtCollection";
var MAX_WEBHOOK_BYTES = 26214400;
var githubApiOrigin = "https://api.github.com";
var GITHUB_API_VERSION = "2022-11-28";
var POLICY_SHA256 = "a443af2eb86fa310ea8705826e70d1b178a4d8d231060440ed522d3069b9a80d";
var EGRESS_MANIFEST_SHA256 = "0e1666e746a12f05885ddc7c13919fd8b03e6fed6af873b47c78050e358148f3";
var SQLITE_COMPATIBILITY_SHA256 = "1d5246c2a0f056208b2652129023c8f99ce33a17a5156ce27d63c982681b9ff2";
var FIXED_PERMISSIONS = Object.freeze({ checks: "write", contents: "read", metadata: "read", pull_requests: "read" });
var FIXED_QUOTA = Object.freeze({ window_seconds: 86400, warning_units: 1e3, hard_units: 1e4 });
var keys = ["app_id", "contract_version", "egress_manifest_sha256", "github_api_origin", "github_api_version", "installation_id", "permissions", "policy_sha256", "quota", "repository_id", "repository_name"];
var positive4 = (value) => typeof value === "number" && Number.isSafeInteger(value) && value > 0;
var exactRecord = (value, expected) => value !== null && typeof value === "object" && !Array.isArray(value) && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(Object.keys(expected).sort()) && Object.entries(expected).every(([key, wanted]) => value[key] === wanted);
function canonicalActivation(input) {
  const normalized = { contract_version: input.contractVersion, repository_id: input.repositoryId, repository_name: input.repositoryName, app_id: input.appId, installation_id: input.installationId, github_api_origin: input.githubApiOrigin, github_api_version: input.githubApiVersion, policy_sha256: input.policySha256, egress_manifest_sha256: input.egressManifestSha256, permissions: input.permissions, quota: input.quota };
  return `sha256:${sha256(JSON.stringify({ config: normalized, sqlite_compatibility_sha256: SQLITE_COMPATIBILITY_SHA256 }))}`;
}
function parseRuntimeConfig(value) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error("runtime configuration is invalid");
  }
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object" || JSON.stringify(Object.keys(parsed).sort()) !== JSON.stringify(keys)) throw new Error("runtime configuration keys mismatch");
  const input = parsed;
  if (input.contract_version !== 1 || input.repository_id !== REPOSITORY_ID || input.repository_name !== REPOSITORY_NAME || input.github_api_origin !== githubApiOrigin || input.github_api_version !== GITHUB_API_VERSION || input.policy_sha256 !== POLICY_SHA256 || input.egress_manifest_sha256 !== EGRESS_MANIFEST_SHA256 || !positive4(input.app_id) || !positive4(input.installation_id) || !exactRecord(input.permissions, FIXED_PERMISSIONS) || !exactRecord(input.quota, FIXED_QUOTA)) throw new Error("runtime identity is invalid");
  const base = { contractVersion: 1, repositoryId: REPOSITORY_ID, repositoryName: REPOSITORY_NAME, appId: input.app_id, installationId: input.installation_id, githubApiOrigin, githubApiVersion: GITHUB_API_VERSION, policySha256: POLICY_SHA256, egressManifestSha256: EGRESS_MANIFEST_SHA256, permissions: FIXED_PERMISSIONS, quota: FIXED_QUOTA };
  return Object.freeze({ ...base, activationDigest: canonicalActivation(base) });
}
function repositoryObjectName(repositoryId) {
  if (repositoryId !== REPOSITORY_ID) throw new Error("repository outside frozen policy");
  return `repository:${repositoryId}`;
}

// src/generated/canonical_policy_bytes.ts
var CANONICAL_POLICY_BYTES = new Uint8Array([123, 10, 32, 32, 34, 98, 97, 115, 101, 95, 99, 111, 109, 109, 105, 116, 34, 58, 32, 34, 102, 52, 50, 53, 56, 50, 99, 56, 101, 98, 48, 100, 49, 52, 48, 53, 99, 100, 53, 101, 50, 49, 52, 102, 54, 98, 57, 99, 56, 48, 57, 56, 48, 50, 50, 53, 98, 53, 102, 49, 34, 44, 10, 32, 32, 34, 99, 104, 101, 99, 107, 95, 110, 97, 109, 101, 34, 58, 32, 34, 65, 114, 99, 104, 105, 118, 97, 108, 101, 32, 114, 101, 108, 101, 97, 115, 101, 32, 112, 111, 108, 105, 99, 121, 32, 116, 114, 117, 115, 116, 34, 44, 10, 32, 32, 34, 108, 105, 109, 105, 116, 115, 34, 58, 32, 123, 10, 32, 32, 32, 32, 34, 97, 99, 116, 105, 111, 110, 95, 98, 121, 116, 101, 115, 34, 58, 32, 54, 52, 44, 10, 32, 32, 32, 32, 34, 99, 104, 101, 99, 107, 95, 112, 97, 103, 101, 115, 34, 58, 32, 51, 48, 44, 10, 32, 32, 32, 32, 34, 99, 104, 101, 99, 107, 95, 114, 111, 119, 115, 34, 58, 32, 51, 48, 48, 48, 44, 10, 32, 32, 32, 32, 34, 100, 101, 108, 105, 118, 101, 114, 121, 95, 105, 100, 95, 98, 121, 116, 101, 115, 34, 58, 32, 49, 50, 56, 44, 10, 32, 32, 32, 32, 34, 101, 118, 101, 110, 116, 95, 98, 121, 116, 101, 115, 34, 58, 32, 51, 50, 44, 10, 32, 32, 32, 32, 34, 102, 105, 108, 101, 95, 112, 97, 103, 101, 115, 34, 58, 32, 51, 48, 44, 10, 32, 32, 32, 32, 34, 102, 105, 108, 101, 95, 114, 111, 119, 115, 34, 58, 32, 51, 48, 48, 48, 44, 10, 32, 32, 32, 32, 34, 104, 101, 97, 100, 101, 114, 95, 99, 111, 117, 110, 116, 34, 58, 32, 54, 52, 44, 10, 32, 32, 32, 32, 34, 104, 101, 97, 100, 101, 114, 95, 110, 97, 109, 101, 95, 98, 121, 116, 101, 115, 34, 58, 32, 54, 52, 44, 10, 32, 32, 32, 32, 34, 104, 101, 97, 100, 101, 114, 95, 118, 97, 108, 117, 101, 95, 98, 121, 116, 101, 115, 34, 58, 32, 49, 48, 50, 52, 44, 10, 32, 32, 32, 32, 34, 106, 115, 111, 110, 95, 100, 101, 112, 116, 104, 34, 58, 32, 54, 52, 44, 10, 32, 32, 32, 32, 34, 106, 115, 111, 110, 95, 110, 111, 100, 101, 115, 34, 58, 32, 50, 48, 48, 48, 48, 48, 44, 10, 32, 32, 32, 32, 34, 111, 112, 101, 110, 95, 112, 114, 95, 112, 97, 103, 101, 115, 34, 58, 32, 49, 48, 44, 10, 32, 32, 32, 32, 34, 111, 112, 101, 110, 95, 112, 114, 95, 112, 97, 115, 115, 101, 115, 34, 58, 32, 50, 44, 10, 32, 32, 32, 32, 34, 111, 112, 101, 110, 95, 112, 114, 95, 114, 111, 119, 115, 34, 58, 32, 49, 48, 48, 48, 44, 10, 32, 32, 32, 32, 34, 112, 97, 103, 101, 95, 115, 105, 122, 101, 34, 58, 32, 49, 48, 48, 44, 10, 32, 32, 32, 32, 34, 114, 101, 99, 111, 110, 99, 105, 108, 101, 95, 100, 101, 108, 97, 121, 115, 95, 115, 101, 99, 111, 110, 100, 115, 34, 58, 32, 91, 49, 44, 32, 50, 44, 32, 52, 44, 32, 56, 44, 32, 49, 54, 44, 32, 51, 50, 93, 44, 10, 32, 32, 32, 32, 34, 119, 101, 98, 104, 111, 111, 107, 95, 98, 111, 100, 121, 95, 98, 121, 116, 101, 115, 34, 58, 32, 50, 54, 50, 49, 52, 52, 48, 48, 10, 32, 32, 125, 44, 10, 32, 32, 34, 114, 101, 112, 111, 115, 105, 116, 111, 114, 121, 34, 58, 32, 123, 10, 32, 32, 32, 32, 34, 98, 97, 115, 101, 95, 114, 101, 102, 34, 58, 32, 34, 109, 97, 105, 110, 34, 44, 10, 32, 32, 32, 32, 34, 110, 97, 109, 101, 34, 58, 32, 34, 107, 101, 110, 108, 101, 114, 101, 110, 47, 77, 121, 65, 114, 116, 67, 111, 108, 108, 101, 99, 116, 105, 111, 110, 34, 10, 32, 32, 125, 44, 10, 32, 32, 34, 115, 99, 104, 101, 109, 97, 95, 118, 101, 114, 115, 105, 111, 110, 34, 58, 32, 49, 44, 10, 32, 32, 34, 115, 101, 108, 101, 99, 116, 111, 114, 115, 34, 58, 32, 123, 10, 32, 32, 32, 32, 34, 98, 97, 115, 101, 108, 105, 110, 101, 95, 101, 120, 97, 99, 116, 34, 58, 32, 91, 10, 32, 32, 32, 32, 32, 32, 34, 46, 103, 105, 116, 108, 101, 97, 107, 115, 105, 103, 110, 111, 114, 101, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 46, 103, 105, 116, 108, 101, 97, 107, 115, 46, 116, 111, 109, 108, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 97, 108, 121, 115, 105, 115, 95, 111, 112, 116, 105, 111, 110, 115, 46, 121, 97, 109, 108, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 46, 103, 105, 116, 105, 103, 110, 111, 114, 101, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 98, 117, 105, 108, 100, 46, 103, 114, 97, 100, 108, 101, 46, 107, 116, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 97, 110, 100, 114, 111, 105, 100, 84, 101, 115, 116, 47, 107, 111, 116, 108, 105, 110, 47, 97, 112, 112, 47, 97, 114, 99, 104, 105, 118, 97, 108, 101, 47, 65, 116, 116, 97, 99, 104, 109, 101, 110, 116, 67, 117, 115, 116, 111, 100, 121, 73, 110, 115, 116, 114, 117, 109, 101, 110, 116, 97, 116, 105, 111, 110, 84, 101, 115, 116, 46, 107, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 109, 97, 105, 110, 47, 99, 112, 112, 47, 67, 77, 97, 107, 101, 76, 105, 115, 116, 115, 46, 116, 120, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 116, 101, 115, 116, 47, 99, 112, 112, 47, 65, 116, 116, 97, 99, 104, 109, 101, 110, 116, 67, 117, 115, 116, 111, 100, 121, 72, 97, 114, 110, 101, 115, 115, 46, 99, 112, 112, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 116, 101, 115, 116, 47, 99, 112, 112, 47, 65, 116, 116, 97, 99, 104, 109, 101, 110, 116, 67, 117, 115, 116, 111, 100, 121, 84, 101, 115, 116, 83, 117, 105, 116, 101, 46, 104, 112, 112, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 116, 101, 115, 116, 47, 107, 111, 116, 108, 105, 110, 47, 97, 112, 112, 47, 97, 114, 99, 104, 105, 118, 97, 108, 101, 47, 65, 116, 116, 97, 99, 104, 109, 101, 110, 116, 67, 117, 115, 116, 111, 100, 121, 78, 97, 116, 105, 118, 101, 65, 99, 99, 101, 115, 115, 84, 101, 115, 116, 46, 107, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 116, 101, 115, 116, 47, 107, 111, 116, 108, 105, 110, 47, 97, 112, 112, 47, 97, 114, 99, 104, 105, 118, 97, 108, 101, 47, 65, 116, 116, 97, 99, 104, 109, 101, 110, 116, 86, 105, 101, 119, 101, 114, 80, 111, 108, 105, 99, 121, 84, 101, 115, 116, 46, 107, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 97, 112, 112, 47, 115, 114, 99, 47, 116, 101, 115, 116, 47, 107, 111, 116, 108, 105, 110, 47, 97, 112, 112, 47, 97, 114, 99, 104, 105, 118, 97, 108, 101, 47, 69, 120, 112, 111, 114, 116, 83, 97, 118, 101, 67, 111, 112, 121, 80, 111, 108, 105, 99, 121, 84, 101, 115, 116, 46, 107, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 98, 117, 105, 108, 100, 46, 103, 114, 97, 100, 108, 101, 46, 107, 116, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 103, 114, 97, 100, 108, 101, 46, 112, 114, 111, 112, 101, 114, 116, 105, 101, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 115, 101, 116, 116, 105, 110, 103, 115, 46, 103, 114, 97, 100, 108, 101, 46, 107, 116, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 98, 114, 111, 107, 101, 114, 47, 112, 97, 99, 107, 97, 103, 101, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 98, 114, 111, 107, 101, 114, 47, 116, 115, 99, 111, 110, 102, 105, 103, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 102, 111, 114, 109, 115, 47, 112, 97, 99, 107, 97, 103, 101, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 102, 111, 114, 109, 115, 47, 116, 115, 99, 111, 110, 102, 105, 103, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 112, 108, 97, 121, 95, 98, 105, 108, 108, 105, 110, 103, 47, 112, 97, 99, 107, 97, 103, 101, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 112, 108, 97, 121, 95, 98, 105, 108, 108, 105, 110, 103, 47, 116, 115, 99, 111, 110, 102, 105, 103, 46, 106, 115, 111, 110, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 100, 111, 99, 115, 47, 82, 69, 76, 69, 65, 83, 69, 95, 82, 69, 65, 68, 73, 78, 69, 83, 83, 95, 67, 73, 46, 109, 100, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 100, 111, 99, 115, 47, 83, 69, 67, 82, 69, 84, 95, 72, 89, 71, 73, 69, 78, 69, 46, 109, 100, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 99, 104, 101, 99, 107, 95, 97, 110, 100, 114, 111, 105, 100, 95, 99, 105, 95, 105, 110, 112, 117, 116, 115, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 99, 104, 101, 99, 107, 95, 98, 114, 111, 107, 101, 114, 95, 97, 117, 100, 105, 116, 46, 109, 106, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 103, 101, 110, 101, 114, 97, 116, 101, 95, 115, 105, 116, 101, 109, 97, 112, 46, 112, 121, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 109, 111, 98, 105, 108, 101, 95, 98, 114, 111, 107, 101, 114, 95, 98, 121, 112, 97, 115, 115, 95, 103, 117, 97, 114, 100, 46, 109, 106, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 115, 101, 99, 114, 101, 116, 95, 115, 99, 97, 110, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 118, 97, 108, 105, 100, 97, 116, 101, 95, 115, 116, 97, 116, 105, 99, 95, 115, 105, 116, 101, 46, 112, 121, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 115, 99, 114, 105, 112, 116, 115, 47, 118, 101, 114, 105, 102, 121, 95, 103, 114, 97, 100, 108, 101, 95, 119, 114, 97, 112, 112, 101, 114, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 110, 100, 114, 111, 105, 100, 95, 99, 105, 95, 105, 110, 112, 117, 116, 95, 103, 117, 97, 114, 100, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 116, 116, 97, 99, 104, 109, 101, 110, 116, 95, 99, 117, 115, 116, 111, 100, 121, 95, 105, 110, 115, 116, 114, 117, 109, 101, 110, 116, 97, 116, 105, 111, 110, 95, 99, 111, 110, 116, 114, 97, 99, 116, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 116, 116, 97, 99, 104, 109, 101, 110, 116, 95, 99, 117, 115, 116, 111, 100, 121, 95, 110, 97, 116, 105, 118, 101, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 116, 116, 97, 99, 104, 109, 101, 110, 116, 95, 99, 117, 115, 116, 111, 100, 121, 95, 114, 101, 108, 101, 97, 115, 101, 95, 115, 121, 109, 98, 111, 108, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 116, 116, 97, 99, 104, 109, 101, 110, 116, 95, 110, 97, 116, 105, 118, 101, 95, 118, 105, 101, 119, 101, 114, 95, 112, 111, 108, 105, 99, 121, 95, 103, 117, 97, 114, 100, 46, 112, 121, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 97, 116, 116, 97, 99, 104, 109, 101, 110, 116, 95, 110, 97, 116, 105, 118, 101, 95, 118, 105, 101, 119, 101, 114, 95, 112, 111, 108, 105, 99, 121, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 98, 114, 111, 107, 101, 114, 95, 97, 117, 100, 105, 116, 95, 112, 111, 108, 105, 99, 121, 95, 116, 101, 115, 116, 46, 109, 106, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 103, 114, 97, 100, 108, 101, 95, 119, 114, 97, 112, 112, 101, 114, 95, 118, 97, 108, 105, 100, 97, 116, 105, 111, 110, 95, 116, 101, 115, 116, 46, 115, 104, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 109, 111, 98, 105, 108, 101, 95, 98, 114, 111, 107, 101, 114, 95, 98, 121, 112, 97, 115, 115, 95, 103, 117, 97, 114, 100, 95, 102, 105, 120, 116, 117, 114, 101, 95, 116, 101, 115, 116, 46, 109, 106, 115, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 109, 111, 98, 105, 108, 101, 95, 98, 114, 111, 107, 101, 114, 95, 98, 121, 112, 97, 115, 115, 95, 103, 117, 97, 114, 100, 95, 116, 101, 115, 116, 46, 100, 97, 114, 116, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 118, 97, 108, 105, 100, 97, 116, 101, 95, 115, 116, 97, 116, 105, 99, 95, 115, 105, 116, 101, 95, 116, 101, 115, 116, 46, 112, 121, 34, 10, 32, 32, 32, 32, 93, 44, 10, 32, 32, 32, 32, 34, 98, 97, 115, 101, 108, 105, 110, 101, 95, 112, 114, 101, 102, 105, 120, 101, 115, 34, 58, 32, 91, 10, 32, 32, 32, 32, 32, 32, 34, 46, 103, 105, 116, 104, 117, 98, 47, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 97, 110, 100, 114, 111, 105, 100, 47, 103, 114, 97, 100, 108, 101, 47, 119, 114, 97, 112, 112, 101, 114, 47, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 116, 101, 115, 116, 47, 102, 105, 120, 116, 117, 114, 101, 115, 47, 98, 114, 111, 107, 101, 114, 45, 97, 117, 100, 105, 116, 47, 34, 10, 32, 32, 32, 32, 93, 44, 10, 32, 32, 32, 32, 34, 102, 105, 110, 97, 108, 95, 101, 120, 97, 99, 116, 95, 97, 100, 100, 105, 116, 105, 111, 110, 115, 34, 58, 32, 91, 10, 32, 32, 32, 32, 32, 32, 34, 100, 111, 99, 115, 47, 82, 69, 76, 69, 65, 83, 69, 95, 80, 79, 76, 73, 67, 89, 95, 84, 82, 85, 83, 84, 46, 109, 100, 34, 10, 32, 32, 32, 32, 93, 44, 10, 32, 32, 32, 32, 34, 102, 105, 110, 97, 108, 95, 112, 114, 101, 102, 105, 120, 95, 97, 100, 100, 105, 116, 105, 111, 110, 115, 34, 58, 32, 91, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 114, 101, 108, 101, 97, 115, 101, 95, 112, 111, 108, 105, 99, 121, 95, 116, 114, 117, 115, 116, 47, 34, 44, 10, 32, 32, 32, 32, 32, 32, 34, 98, 97, 99, 107, 101, 110, 100, 47, 114, 101, 108, 101, 97, 115, 101, 95, 112, 111, 108, 105, 99, 121, 95, 119, 111, 114, 107, 101, 114, 115, 95, 102, 114, 101, 101, 47, 34, 10, 32, 32, 32, 32, 93, 10, 32, 32, 125, 10, 125, 10]);

// src/dispatcher.ts
init_src();

// src/telemetry.ts
var forbidden = /(?:authorization|cookie|secret|token|private.?key|x-hub-signature|body|headers?|stack)/i;
function sanitizeTelemetry(input) {
  for (const [key, value] of Object.entries(input)) {
    if (forbidden.test(key) || typeof value === "string" && forbidden.test(value)) throw new Error("telemetry field is forbidden");
  }
  return Object.freeze({ ...input });
}
function boundedBucket(value, warning, limit) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || !Number.isSafeInteger(value) || !Number.isSafeInteger(warning) || !Number.isSafeInteger(limit) || warning < 0 || limit <= warning) return 2;
  return value < warning ? 0 : value < limit ? 1 : 2;
}

// src/dispatcher.ts
var RETRY_SECONDS = [1, 5, 30, 120, 600];
var targetMetaKey = (installationId, deliveryId) => `target/${installationId}/${deliveryId}`;
var AlarmDispatcher = class {
  constructor(storage, store, runtime) {
    this.storage = storage;
    this.store = store;
    this.runtime = runtime;
  }
  async requestDrain(at = Date.now(), reassert = false) {
    const current = await this.storage.getAlarm();
    if (current === null || reassert) {
      await this.storage.setAlarm(Math.max(at, current ?? at) + 100);
      return true;
    }
    return false;
  }
  async watchdog() {
    const pendingReceipts = this.store.entries("receipt/").filter(({ value }) => !["terminal_success", "terminal_failure", "conflict"].includes(value.state));
    const pending = pendingReceipts.length;
    const alarm = await this.storage.getAlarm();
    const alarmRuntime = this.store.readMeta("alarm_runtime/v1");
    const alarmIsActive = alarmRuntime?.running === true && Number.isFinite(alarmRuntime.started_at) && Date.now() - alarmRuntime.started_at < 6e4;
    const alarmReasserted = pending > 0 && !alarmIsActive ? await this.requestDrain(Date.now(), true) : false;
    const oldestReceivedAt = pendingReceipts.map(({ value }) => value).map((receipt) => this.store.readMeta(targetMetaKey(receipt.installationId, receipt.deliveryId))?.received_at).filter((value) => typeof value === "number" && Number.isFinite(value)).sort((a, b) => a - b)[0];
    const oldestWorkBucket = oldestReceivedAt === void 0 ? 0 : Date.now() - oldestReceivedAt < 6e4 ? 1 : 2;
    const bindings = this.store.entries("binding/").map(({ value }) => value);
    const seen = /* @__PURE__ */ new Set();
    let duplicates = 0;
    for (const binding of bindings) {
      if (binding.checkId === void 0 || binding.externalId === void 0) continue;
      const identity = `${binding.checkId}:${binding.externalId}`;
      if (seen.has(identity)) duplicates += 1;
      else seen.add(identity);
    }
    const rows = this.store.rowCount();
    const bytes = this.store.databaseBytes();
    const metric = (name) => this.store.readMeta(`${name}/v1`) ?? 0;
    const doInvocations = metric("do_request_count") + metric("alarm_count");
    this.store.writeMeta("watchdog/v1", sanitizeTelemetry({
      alarm_present: alarm !== null,
      alarm_reasserted: alarmReasserted,
      do_headroom_bucket: boundedBucket(doInvocations, 1e3, 1e4),
      duplicate_binding_bucket: boundedBucket(duplicates, 1, 3),
      duplicate_check_bucket: boundedBucket(metric("egress/duplicate_check"), 1, 3),
      exceeded_resource_bucket: boundedBucket(metric("egress/exceeded_resource"), 1, 3),
      forbidden_egress_bucket: boundedBucket(metric("egress/forbidden_egress"), 1, 3),
      oldest_work_bucket: oldestWorkBucket,
      pending_bucket: boundedBucket(pending, 10, 100),
      provider_error_bucket: boundedBucket(metric("egress/provider_error"), 1, 3),
      request_headroom_bucket: boundedBucket(metric("egress/request_high_water"), 40, 51),
      row_headroom_bucket: boundedBucket(rows, 50, 100),
      status_egress_bucket: boundedBucket(metric("egress/status_egress"), 1, 3),
      storage_headroom_bucket: boundedBucket(bytes, 524288, 1048576),
      worker_error_bucket: boundedBucket(metric("worker_error_count"), 1, 3)
    }));
  }
  rememberTarget(receipt, target) {
    const key = targetMetaKey(receipt.installationId, receipt.deliveryId);
    if (this.store.readMeta(key) === void 0) this.store.writeMeta(key, { ...target, received_at: Date.now() });
  }
  async alarm() {
    const quota = typeof this.store.reserveQuota === "function" ? this.store.reserveQuota(Date.now(), { alarms: 1 }) : { admitted: true, rolloverAt: Date.now() + 25 };
    if (!quota.admitted) {
      await this.storage.setAlarm(quota.rolloverAt);
      return;
    }
    const port = this.runtime.portFactory?.() ?? this.runtime.port;
    if (!port) throw new Error("alarm GitHub port unavailable");
    const priorAlarmCount = this.store.readMeta("alarm_count/v1") ?? 0;
    this.store.writeMeta("alarm_count/v1", Math.min(priorAlarmCount + 1, 10001));
    this.store.writeMeta("alarm_runtime/v1", { running: true, started_at: Date.now() });
    const pullSnapshots = /* @__PURE__ */ new Map();
    try {
      let retryAt;
      for (const row of this.store.entries("receipt/")) {
        const receipt = row.value;
        const retry = this.store.readMeta(`retry/${receipt.installationId}/${receipt.deliveryId}`);
        if (retry?.state === "quarantined") continue;
        if (typeof retry?.retry_at === "number" && retry.retry_at > Date.now()) {
          retryAt = Math.min(retryAt ?? Infinity, retry.retry_at);
          continue;
        }
        try {
          await this.advanceReceipt(receipt, port, pullSnapshots);
        } catch (error) {
          this.store.incrementMeta("worker_error_count/v1");
          if (error instanceof DefinitiveNotSentError) this.store.incrementMeta("egress/exceeded_resource/v1");
          retryAt = Math.min(retryAt ?? Infinity, this.recordRetry(receipt, error));
        }
      }
      if (this.hasPendingWork()) await this.storage.setAlarm(retryAt ?? Date.now() + 25);
    } finally {
      this.store.writeMeta("alarm_runtime/v1", { running: false, started_at: 0 });
    }
  }
  async advanceReceipt(receipt, port, pullSnapshots) {
    if (["terminal_success", "terminal_failure", "conflict"].includes(receipt.state)) return;
    const target = this.store.readMeta(targetMetaKey(receipt.installationId, receipt.deliveryId));
    if (!target) throw new Error("delivery target missing");
    if (receipt.state === "received" || receipt.state === "snapshotting") {
      const snapshotting = await beginReceiptSnapshot(this.store, receipt);
      if (snapshotting.state !== "snapshotting") return;
      if (target.kind === "pull_request") {
        const evaluation = await this.pullSnapshot(port, target.pullRequestNumber, pullSnapshots);
        await atomicEnqueuePull(this.store, snapshotting, (await Promise.resolve().then(() => (init_src(), src_exports))).generationFromEvaluation(evaluation));
      } else {
        const targets = await snapshotPushTargets(port, this.runtime.identity, target.after, this.runtime.policy);
        await atomicEnqueuePush(this.store, snapshotting, targets.digest, targets.numbers);
      }
    }
    const current = await this.store.read(`receipt/${receipt.installationId}/${receipt.deliveryId}`);
    if (current?.kind === "push" && current.targetNumbers) return this.advancePush(current, port, pullSnapshots);
    if (!current?.generationId) return;
    await this.advanceGeneration(current.generationId, port);
    await settlePullReceipt(this.store, current);
  }
  async advancePush(receipt, port, pullSnapshots) {
    for (const pr of receipt.targetNumbers ?? []) {
      const child = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`);
      if (!child || ["terminal_success", "terminal_failure"].includes(child.state)) continue;
      if (child.state === "pending") {
        const worker = `alarm:push:${receipt.deliveryId.slice(0, 16)}:${pr}`;
        await leasePushChild(this.store, receipt, pr, worker);
        const evaluation = await this.pullSnapshot(port, pr, pullSnapshots);
        await atomicEnqueuePushChild(this.store, receipt, (await Promise.resolve().then(() => (init_src(), src_exports))).generationFromEvaluation(evaluation), worker);
      }
      const durable = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`);
      if (durable?.generationId) {
        await this.advanceGeneration(durable.generationId, port);
        await settlePushChild(this.store, receipt, pr);
      }
    }
  }
  pullSnapshot(port, pullRequestNumber, cache) {
    const prior = cache.get(pullRequestNumber);
    if (prior) return prior;
    const pending = snapshotPullRequest(port, this.runtime.identity, pullRequestNumber, this.runtime.policy);
    cache.set(pullRequestNumber, pending);
    return pending;
  }
  async advanceGeneration(generationId2, port) {
    const generation = await this.store.read(`generation/${generationId2}`);
    if (!generation || ["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state ?? "")) return;
    const worker = `alarm:${generationId2.slice(0, 16)}`;
    const evaluation = await this.store.read(`outbox/${generationId2}/evaluate_generation`);
    if (evaluation?.state === "leased" && evaluation.leaseOwner) await recoverEvaluationLease(this.store, generationId2, evaluation.leaseOwner);
    for (const operation of ["create_check", "update_check"]) {
      const effect = await this.store.read(`outbox/${generationId2}/${operation}`);
      if (["send_leased", "reconcile_leased"].includes(effect?.state ?? "") && effect?.leaseOwner && typeof effect.fence === "number") await recoverAbandonedEffect(this.store, generationId2, operation, effect.leaseOwner, effect.fence);
    }
    if (generation.state === "claimed") {
      const { leaseOutbox: leaseOutbox2 } = await Promise.resolve().then(() => (init_src(), src_exports));
      await leaseOutbox2(this.store, generationId2, worker);
      await commitDecision(this.store, generationId2, worker);
    }
    const afterEvaluation = await this.store.read(`generation/${generationId2}`);
    if (afterEvaluation?.state === "decision_ready") await prepareCheckBinding(this.store, generationId2, this.runtime.identity);
    const afterBinding = await this.store.read(`generation/${generationId2}`);
    if (afterBinding?.state === "decision_ready") {
      const reconcileKey = `reconcile/${generationId2}/v1`;
      const reconciliation = this.store.readMeta(reconcileKey);
      if (reconciliation && !reconciliation.cleared) {
        if (reconciliation.due_at > Date.now()) return;
        const result = await reconcileCreateCheckOnce({ generationId: generationId2, port, store: this.store, worker, finalAttempt: reconciliation.attempt >= 5 });
        if (result === "not_visible") {
          const delay = [1, 2, 4, 8, 16, 32][reconciliation.attempt + 1] ?? 32;
          this.store.writeMeta(reconcileKey, { attempt: reconciliation.attempt + 1, due_at: Date.now() + delay * 1e3 });
        } else this.store.writeMeta(reconcileKey, { attempt: reconciliation.attempt, due_at: 0, cleared: true });
      } else {
        try {
          await runCreateCheck({ clock: this.runtime.clock, generationId: generationId2, port, store: this.store, worker });
        } catch (error) {
          if (error instanceof AmbiguousCreateError) {
            this.store.writeMeta(reconcileKey, { attempt: 0, due_at: Date.now() + 1e3 });
            return;
          }
          throw error;
        }
      }
    }
    const completing = await this.store.read(`generation/${generationId2}`);
    if (completing?.state === "completing") await runUpdateCheck({ generationId: generationId2, port, store: this.store, worker });
  }
  hasPendingWork() {
    return this.store.entries("receipt/").some(({ value }) => {
      const receipt = value;
      const retry = this.store.readMeta(`retry/${receipt.installationId}/${receipt.deliveryId}`);
      return !["terminal_success", "terminal_failure", "conflict"].includes(receipt.state) && retry?.state !== "quarantined";
    });
  }
  recordRetry(receipt, error) {
    const key = `retry/${receipt.installationId}/${receipt.deliveryId}`;
    const previous = this.store.readMeta(key)?.attempts ?? 0;
    const attempts = Math.min(previous + 1, RETRY_SECONDS.length);
    const retryAt = Date.now() + RETRY_SECONDS[attempts - 1] * 1e3;
    const errorClass = error instanceof AmbiguousCreateError || error instanceof AmbiguousUpdateError ? "ambiguous" : "transient";
    this.store.writeMeta(key, attempts >= RETRY_SECONDS.length ? { attempts, error_class: errorClass, state: "quarantined" } : { attempts, error_class: errorClass, retry_at: retryAt });
    return retryAt;
  }
};

// src/repository_durable_object.ts
init_src();

// src/sqlite_store.ts
init_src();

// src/quota.ts
var QUOTA_HARD = 1e4;
var QUOTA_SENTINEL = 10001;
var day = 864e5;
var names = ["worker_events", "do_fetches", "alarms", "outbound_attempts"];
var empty = (start) => ({ window_start_utc_ms: start, worker_events: 0, do_fetches: 0, alarms: 0, outbound_attempts: 0, total_units: 0, stopped: false });
var valid = (value, start) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value;
  if (JSON.stringify(Object.keys(row)) !== JSON.stringify(["window_start_utc_ms", ...names, "total_units", "stopped"]) || row.window_start_utc_ms !== start || typeof row.stopped !== "boolean") return false;
  if (names.some((key) => !Number.isSafeInteger(row[key]) || row[key] < 0 || row[key] > QUOTA_SENTINEL) || !Number.isSafeInteger(row.total_units) || row.total_units < 0 || row.total_units > QUOTA_SENTINEL) return false;
  const sum = names.reduce((total, key) => total + row[key], 0);
  return row.total_units === (sum > QUOTA_HARD ? QUOTA_SENTINEL : sum) && row.stopped === row.total_units >= QUOTA_HARD;
};
function reserveQuota(storage, now, vector) {
  if (!Number.isSafeInteger(now) || now < 0 || names.some((name) => vector[name] !== void 0 && (!Number.isSafeInteger(vector[name]) || vector[name] < 0))) return { admitted: false, rolloverAt: now + day, record: { ...empty(0), stopped: true } };
  const start = Math.floor(now / day) * day;
  const rollout = start + day + 100;
  return storage.transactionSync(() => {
    const raw = storage.sql.exec("SELECT value_json FROM meta WHERE key='quota/v1'").toArray()[0];
    let record3;
    try {
      record3 = raw === void 0 ? empty(start) : JSON.parse(raw.value_json);
    } catch {
      return { admitted: false, rolloverAt: rollout, record: { ...empty(start), stopped: true } };
    }
    if (raw !== void 0 && record3.window_start_utc_ms > start) return { admitted: false, rolloverAt: rollout, record: { ...record3, stopped: true } };
    if (record3.window_start_utc_ms < start) record3 = empty(start);
    else if (!valid(record3, start)) return { admitted: false, rolloverAt: rollout, record: { ...empty(start), stopped: true } };
    const increment = names.reduce((total, name) => total + (vector[name] ?? 0), 0);
    const attempted = Math.min(QUOTA_SENTINEL, record3.total_units + increment);
    const next = { ...record3 };
    for (const name of names) next[name] = Math.min(QUOTA_SENTINEL, next[name] + (vector[name] ?? 0));
    next.total_units = attempted > QUOTA_HARD ? QUOTA_SENTINEL : attempted;
    next.stopped = attempted >= QUOTA_HARD;
    storage.sql.exec("INSERT INTO meta(key,value_json) VALUES('quota/v1',?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", JSON.stringify(next));
    return { admitted: attempted < QUOTA_HARD, rolloverAt: rollout, record: next };
  });
}

// src/sqlite_store.ts
var CasConflict = class extends Error {
};
var IncompatibleSqliteSchema = class extends Error {
};
var SQLITE_SCHEMA_ID = "archivale-release-policy-workers-free/sqlite-v2";
var KV_DDL = "CREATE TABLE kv(key TEXT NOT NULL PRIMARY KEY,version INTEGER NOT NULL CHECK(version>=1),value_json TEXT NOT NULL CHECK(json_valid(value_json))) STRICT, WITHOUT ROWID";
var META_DDL = "CREATE TABLE meta(key TEXT NOT NULL PRIMARY KEY,value_json TEXT NOT NULL CHECK(json_valid(value_json))) STRICT, WITHOUT ROWID";
var SCHEMA_PREIMAGE = `schema_id=${SQLITE_SCHEMA_ID}
schema_version=2
object.1=table|kv|${KV_DDL}
object.2=table|meta|${META_DDL}
application_indexes=none
application_triggers=none
application_views=none
metadata.1=activation/digest|json-string|sha256:<64-lower-hex>
metadata.2=compatibility/digest|json-string|sha256:<64-lower-hex>
metadata.3=schema/digest|json-string|sha256:<64-lower-hex>
metadata.4=schema/id|json-string|${SQLITE_SCHEMA_ID}
metadata.5=schema/state|json-string|ready
metadata.6=schema/version|json-integer|2
`;
var SQLITE_SCHEMA_DIGEST = `sha256:${sha256(SCHEMA_PREIMAGE)}`;
var expectedMetadata = (activationDigest, compatibilityDigest) => ({ "schema/id": JSON.stringify(SQLITE_SCHEMA_ID), "schema/version": "2", "schema/state": JSON.stringify("ready"), "schema/digest": JSON.stringify(SQLITE_SCHEMA_DIGEST), "compatibility/digest": JSON.stringify(compatibilityDigest), "activation/digest": JSON.stringify(activationDigest) });
var rowArray = (storage, sql, ...values) => storage.sql.exec(sql, ...values).toArray();
var SqliteStore = class {
  constructor(storage) {
    this.storage = storage;
  }
  /** This must run in blockConcurrencyWhile before a dispatcher or port exists. */
  initialize(activationDigest, compatibilityDigest) {
    if (!/^sha256:[0-9a-f]{64}$/.test(activationDigest) || !/^sha256:[0-9a-f]{64}$/.test(compatibilityDigest)) throw new IncompatibleSqliteSchema("activation identity rejected");
    this.storage.transactionSync(() => {
      const objects = rowArray(this.storage, "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE '_cf_%' ORDER BY type,name");
      if (objects.length === 0) {
        this.storage.sql.exec(KV_DDL);
        this.storage.sql.exec(META_DDL);
        for (const [key, value] of Object.entries(expectedMetadata(activationDigest, compatibilityDigest))) this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES(?,?)", key, value);
        this.assertCompatible(activationDigest, compatibilityDigest);
        return;
      }
      this.assertCompatible(activationDigest, compatibilityDigest);
    });
  }
  assertCompatible(activationDigest, compatibilityDigest) {
    const objects = rowArray(this.storage, "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE '_cf_%' ORDER BY type,name");
    const tables = objects.filter((row) => row.type === "table");
    const expected = [{ type: "table", name: "kv", sql: KV_DDL }, { type: "table", name: "meta", sql: META_DDL }];
    if (JSON.stringify(tables) !== JSON.stringify(expected) || objects.some((row) => row.type !== "table")) throw new IncompatibleSqliteSchema("application schema rejected");
    for (const table of ["kv", "meta"]) {
      const columns = rowArray(this.storage, `PRAGMA table_xinfo(${table})`);
      const expectedColumns = table === "kv" ? ["key", "version", "value_json"] : ["key", "value_json"];
      if (columns.length !== expectedColumns.length || columns.some((row, index) => row.name !== expectedColumns[index] || row.hidden !== 0) || rowArray(this.storage, `PRAGMA foreign_key_list(${table})`).length !== 0) throw new IncompatibleSqliteSchema("application columns rejected");
      const indexes = rowArray(this.storage, `PRAGMA index_list(${table})`);
      if (indexes.length !== 1 || indexes[0]?.name !== `sqlite_autoindex_${table}_1` || indexes[0]?.unique !== 1 || indexes[0]?.origin !== "pk" || indexes[0]?.partial !== 0) throw new IncompatibleSqliteSchema("application index rejected");
    }
    const values = Object.fromEntries(rowArray(this.storage, "SELECT key,value_json FROM meta WHERE key IN ('schema/id','schema/version','schema/state','schema/digest','compatibility/digest','activation/digest') ORDER BY key").map((row) => [row.key, row.value_json]));
    const wanted = expectedMetadata(activationDigest, compatibilityDigest);
    const wantedSorted = Object.fromEntries(Object.entries(wanted).sort(([a], [b]) => a.localeCompare(b)));
    if (JSON.stringify(values) !== JSON.stringify(wantedSorted)) throw new IncompatibleSqliteSchema("application metadata rejected");
  }
  async transact(work) {
    return this.storage.transactionSync(() => work(new SqliteTransaction(this.storage)));
  }
  async read(key) {
    const row = rowArray(this.storage, "SELECT value_json FROM kv WHERE key=?", key)[0];
    return row === void 0 ? void 0 : JSON.parse(row.value_json);
  }
  entries(prefix) {
    if (!/^(receipt|generation|outbox|push-child|binding|current)\/$/.test(prefix)) throw new Error("scheduler prefix rejected");
    return rowArray(this.storage, "SELECT key,value_json FROM kv WHERE key LIKE ? ORDER BY key", `${prefix}%`).map((row) => ({ key: row.key, value: JSON.parse(row.value_json) }));
  }
  rowCount() {
    return Number(rowArray(this.storage, "SELECT count(*) AS count FROM kv")[0].count);
  }
  databaseBytes() {
    const bytes = this.storage.sql.databaseSize;
    if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error("SQLite storage measurement unavailable");
    return bytes;
  }
  reserveQuota(now, vector) {
    return reserveQuota(this.storage, now, vector);
  }
  readMeta(key) {
    const row = rowArray(this.storage, "SELECT value_json FROM meta WHERE key=?", key)[0];
    return row === void 0 ? void 0 : JSON.parse(row.value_json);
  }
  writeMeta(key, value) {
    this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", key, JSON.stringify(value));
  }
  incrementMeta(key, amount = 1, ceiling = 1e6) {
    const prior = this.readMeta(key);
    const base = prior === void 0 ? 0 : typeof prior === "number" && Number.isSafeInteger(prior) && prior >= 0 ? prior : ceiling;
    const next = Math.min(base + amount, ceiling);
    this.writeMeta(key, next);
    return next;
  }
};
var SqliteTransaction = class {
  constructor(storage) {
    this.storage = storage;
  }
  get(key) {
    const row = rowArray(this.storage, "SELECT value_json FROM kv WHERE key=?", key)[0];
    return row === void 0 ? void 0 : JSON.parse(row.value_json);
  }
  putIfAbsent(key, value) {
    const row = this.storage.sql.exec("INSERT INTO kv(key,version,value_json) VALUES(?,1,?) ON CONFLICT(key) DO NOTHING RETURNING key", key, JSON.stringify(value)).toArray()[0];
    if (row === void 0) throw new CasConflict("unique key already exists");
  }
  compareAndSwap(key, version, value) {
    const row = this.storage.sql.exec("UPDATE kv SET version=version+1,value_json=? WHERE key=? AND version=? RETURNING key", JSON.stringify(value), key, version).toArray()[0];
    if (row === void 0) throw new CasConflict("CAS lost");
  }
};

// src/github_app_port.ts
init_src();

// src/github_routes.ts
var positive5 = (value) => typeof value === "number" ? Number.isSafeInteger(value) && value > 0 : /^[0-9a-f]{40}$/.test(value);
function requireIdentity(identity, route, args) {
  if (!Number.isSafeInteger(identity.installationId) || identity.installationId <= 0 || identity.repositoryId !== REPOSITORY_ID || args.some((arg) => !positive5(arg))) throw new Error("github route rejected");
  if (route === "installationToken") {
    if (args.length !== 1 || args[0] !== identity.installationId) throw new Error("github route rejected");
    return;
  }
  if (args[0] !== identity.repositoryId) throw new Error("github route rejected");
}
var routes = {
  installationToken: { method: "POST", path: ([id]) => `/app/installations/${id}/access_tokens` },
  pullRequest: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}` },
  mainRef: { method: "GET", path: ([repo]) => `/repositories/${repo}/git/ref/heads/main` },
  pullFiles: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}/files` },
  openMainPulls: { method: "GET", path: ([repo]) => `/repositories/${repo}/pulls` },
  appChecks: { method: "GET", path: ([repo, sha]) => `/repositories/${repo}/commits/${sha}/check-runs` },
  createCheck: { method: "POST", path: ([repo]) => `/repositories/${repo}/check-runs` },
  updateCheck: { method: "PATCH", path: ([repo, id]) => `/repositories/${repo}/check-runs/${id}` }
};
function githubRoute(identity, route, args, query = "") {
  requireIdentity(identity, route, args);
  if (query && !/^[A-Za-z0-9_=&-]+$/.test(query)) throw new Error("github route rejected");
  const spec = routes[route];
  const url = new URL(spec.path(args), githubApiOrigin);
  url.search = query;
  return new Request(url.toString(), { method: spec.method, redirect: "manual", headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": GITHUB_API_VERSION } });
}
function isExactGithubRequest(identity, request) {
  const url = new URL(request.url);
  if (url.origin !== githubApiOrigin || url.username || url.password || url.hash || request.redirect !== "manual" || request.headers.get("accept") !== "application/vnd.github+json" || request.headers.get("x-github-api-version") !== GITHUB_API_VERSION) return false;
  const prefix = `/repositories/${identity.repositoryId}`;
  const patterns = [["POST", new RegExp(`^/app/installations/${identity.installationId}/access_tokens$`)], ["GET", new RegExp(`^${prefix}/pulls/[1-9][0-9]*$`)], ["GET", new RegExp(`^${prefix}/git/ref/heads/main$`)], ["GET", new RegExp(`^${prefix}/pulls/[1-9][0-9]*/files$`)], ["GET", new RegExp(`^${prefix}/pulls$`)], ["GET", new RegExp(`^${prefix}/commits/[0-9a-f]{40}/check-runs$`)], ["POST", new RegExp(`^${prefix}/check-runs$`)], ["PATCH", new RegExp(`^${prefix}/check-runs/[1-9][0-9]*$`)]];
  if (!patterns.some(([method, path]) => request.method === method && path.test(url.pathname))) return false;
  if (url.search && !/^\?(?:page=[1-9][0-9]*&per_page=100|state=open&base=main&sort=created&direction=asc&page=[1-9][0-9]*&per_page=100)$/.test(url.search)) return false;
  return true;
}

// src/github_app_port.ts
var MAX_RESPONSE_BYTES = { installationToken: 16384, pullRequest: 131072, mainRef: 16384, pullFiles: 1048576, openMainPulls: 1048576, appChecks: 1048576, createCheck: 131072, updateCheck: 131072 };
var PAGE_CEILING = { pullFiles: 30, openMainPulls: 10, appChecks: 30 };
var callFetch = (fetcher, request, init) => Reflect.apply(fetcher, globalThis, init === void 0 ? [request] : [request, init]);
function paginationRejected() {
  throw new Error("github pagination rejected");
}
function canonicalPage(value, ceiling) {
  if (!/^[1-9][0-9]*$/.test(value)) return paginationRejected();
  const page = Number(value);
  if (!Number.isSafeInteger(page) || page > ceiling) return paginationRejected();
  return page;
}
function exactQuery(url, request, page, route) {
  if (!url.search || /%/.test(url.search)) return paginationRejected();
  const expected = request.search.slice(1).split("&");
  const actual = url.search.slice(1).split("&");
  if (actual.length !== expected.length || new Set(actual.map((x) => x.split("=")[0])).size !== actual.length) return paginationRejected();
  const values = new Map(actual.map((entry) => {
    const pieces = entry.split("=");
    if (pieces.length !== 2 || !pieces[0] || !pieces[1]) return paginationRejected();
    return [pieces[0], pieces[1]];
  }));
  for (const entry of expected) {
    const [key, value] = entry.split("=");
    if (!key || !value || !values.has(key)) return paginationRejected();
    if (key === "page") {
      if (canonicalPage(values.get(key), PAGE_CEILING[route]) !== page) return paginationRejected();
    } else if (values.get(key) !== value) return paginationRejected();
  }
}
function parsePagination(link, request, route, current) {
  if (link === null) return null;
  const bytes = new TextEncoder().encode(link);
  if (bytes.length === 0 || bytes.length > 8192 || !/^(?:[\x20-\x7e]|\t)+$/.test(link)) return paginationRejected();
  const members = link.split(",");
  if (members.length > 4 || members.some((member) => new TextEncoder().encode(member).length === 0 || new TextEncoder().encode(member).length > 2048)) return paginationRejected();
  const relations = /* @__PURE__ */ new Map();
  for (const member of members) {
    const match = /^[ \t]*<(https:\/\/api\.github\.com\/[^<>"\s]+)>[ \t]*;[ \t]*rel="(next|prev|first|last)"[ \t]*$/.exec(member);
    if (!match) return paginationRejected();
    const [, targetText, relation] = match;
    if (!targetText || !relation || relations.has(relation)) return paginationRejected();
    let target;
    try {
      target = new URL(targetText);
    } catch {
      return paginationRejected();
    }
    if (target.origin !== "https://api.github.com" || target.username || target.password || target.hash || target.pathname !== request.pathname) return paginationRejected();
    const targetPage = canonicalPage(target.searchParams.get("page") ?? "", PAGE_CEILING[route]);
    exactQuery(target, request, targetPage, route);
    relations.set(relation, targetPage);
  }
  const first = relations.get("first");
  const prev = relations.get("prev");
  const next = relations.get("next");
  const last = relations.get("last");
  if (first !== void 0 && first !== 1) return paginationRejected();
  if (prev !== void 0 && (current === 1 || prev !== current - 1)) return paginationRejected();
  if (next !== void 0 && next !== current + 1) return paginationRejected();
  if (last !== void 0 && (last < current || last > PAGE_CEILING[route])) return paginationRejected();
  if (next === void 0 && last !== void 0 && last !== current) return paginationRejected();
  if (next !== void 0 && last !== void 0 && last < next) return paginationRejected();
  return next ?? null;
}
async function boundedJson(response, limit) {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > limit)) throw new Error("github response exceeds bound");
  const reader = response.body?.getReader();
  if (!reader) throw new Error("github response missing body");
  const chunks = [];
  let size = 0;
  try {
    for (; ; ) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new Error("github response exceeds bound");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("github JSON rejected");
  }
}
var GitHubAppPort = class {
  constructor(fetcher, authorization, identity, measure = () => {
  }) {
    this.fetcher = fetcher;
    this.authorization = authorization;
    this.identity = identity;
    this.measure = measure;
  }
  async json(route, args, query = "", body, page) {
    if (route !== "installationToken" && args[0] !== this.identity.repositoryId) throw new DefinitiveNotSentError("github repository rejected");
    const base = githubRoute({ installationId: this.identity.installationId, repositoryId: this.identity.repositoryId }, route, args, query);
    const token = await this.authorization();
    if (!token || /[\r\n]/.test(token)) throw new Error("github authorization unavailable");
    const headers = new Headers(base.headers);
    headers.set("Authorization", `Bearer ${token}`);
    if (body !== void 0) headers.set("Content-Type", "application/json");
    const outbound = new Request(base.url, { method: base.method, redirect: "manual", headers, ...body === void 0 ? {} : { body: JSON.stringify(body) } });
    let response;
    try {
      response = await callFetch(this.fetcher, outbound);
    } catch (error) {
      if (!(error instanceof DefinitiveNotSentError)) this.measure({ metric: "provider_error", value: 1 });
      throw error;
    }
    if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? "")) {
      this.measure({ metric: "provider_error", value: 1 });
      throw new Error("github route rejected");
    }
    const nextPage = page === void 0 ? null : parsePagination(response.headers.get("link"), new URL(base.url), route, page);
    return { value: await boundedJson(response, MAX_RESPONSE_BYTES[route]), nextPage };
  }
  async getPullRequest(repositoryId, number) {
    return this.json("pullRequest", [repositoryId, number]).then(({ value }) => this.pr(value));
  }
  async getMainRef(repositoryId) {
    const { value } = await this.json("mainRef", [repositoryId]);
    const v = value;
    return { repositoryId, ref: "refs/heads/main", sha: this.string(v.object && v.object.sha) };
  }
  async listPullRequestFiles(repositoryId, number, page, perPage) {
    const { value, nextPage } = await this.json("pullFiles", [repositoryId, number], `page=${page}&per_page=${perPage}`, void 0, page);
    return { items: this.array(value).map((x) => ({ path: this.string(x.filename), status: this.string(x.status), ...typeof x.previous_filename === "string" ? { previousPath: x.previous_filename } : {} })), nextPage };
  }
  async listOpenMainPullRequests(repositoryId, page, perPage) {
    const { value, nextPage } = await this.json("openMainPulls", [repositoryId], `state=open&base=main&sort=created&direction=asc&page=${page}&per_page=${perPage}`, void 0, page);
    return { items: this.array(value).map((x) => ({ ...this.pr(x), createdAt: this.string(x.created_at) })), nextPage };
  }
  async listAppChecks(repositoryId, headSha, page, perPage) {
    const { value, nextPage } = await this.json("appChecks", [repositoryId, headSha], `page=${page}&per_page=${perPage}`, void 0, page);
    const v = value;
    const items = this.array(v.check_runs).map((x) => this.check(repositoryId, x));
    const seen = /* @__PURE__ */ new Set();
    let duplicates = 0;
    for (const item of items) {
      const key = `${item.appId}:${item.checkId}:${item.externalId}`;
      if (seen.has(key)) duplicates += 1;
      else seen.add(key);
    }
    if (duplicates > 0) this.measure({ metric: "duplicate_check", value: duplicates });
    return { items, nextPage };
  }
  async createCheck(input) {
    return this.json("createCheck", [input.repositoryId], "", { name: input.name, head_sha: input.headSha, external_id: input.externalId, status: "in_progress" }).then(({ value }) => this.check(input.repositoryId, value));
  }
  async updateCheck(input) {
    await this.json("updateCheck", [input.repositoryId, input.checkId], "", { status: "completed", conclusion: input.conclusion, output: { title: "Release policy", summary: input.summary } });
  }
  array(v) {
    if (!Array.isArray(v)) throw new Error("github schema rejected");
    return v.map((x) => {
      if (!x || typeof x !== "object" || Array.isArray(x)) throw new Error("github schema rejected");
      return x;
    });
  }
  string(v) {
    if (typeof v !== "string" || v.length === 0) throw new Error("github schema rejected");
    return v;
  }
  number(v) {
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v <= 0) throw new Error("github schema rejected");
    return v;
  }
  pr(v) {
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("github schema rejected");
    const x = v;
    const base = x.base;
    const head = x.head;
    const baseRepo = base?.repo;
    const headRepo = head?.repo;
    const repositoryId = this.number(baseRepo?.id);
    const repositoryName = this.string(baseRepo?.full_name);
    const state = this.string(x.state);
    const baseRef = this.string(base?.ref);
    if (repositoryId !== this.identity.repositoryId || repositoryName !== this.identity.repositoryName || baseRef !== this.identity.baseRef || state !== "open") throw new Error("github PR identity rejected");
    return { appId: this.identity.appId, baseRef, baseSha: this.string(base?.sha), changedFiles: this.number(x.changed_files), headRepositoryId: this.number(headRepo?.id), headSha: this.string(head?.sha), installationId: this.identity.installationId, number: this.number(x.number), repositoryId, repositoryName, state };
  }
  check(repositoryId, v) {
    const x = v;
    return { appId: this.number(x.app?.id), checkId: this.number(x.id), externalId: this.string(x.external_id), headSha: this.string(x.head_sha), name: this.string(x.name), repositoryId };
  }
};
function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
function pemBytes(pem) {
  if (!/^-----BEGIN PRIVATE KEY-----\r?\n[\sA-Za-z0-9+/=]+\r?\n-----END PRIVATE KEY-----\s*$/.test(pem)) throw new Error("github private key malformed");
  const binary = atob(pem.replace(/-----[^-]+-----|\s/g, ""));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
function githubInstallationAuthorization(input) {
  return async () => {
    const now = Math.floor((input.now?.() ?? Date.now()) / 1e3);
    const header = base64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
    const claims = base64Url(new TextEncoder().encode(JSON.stringify({ iat: now - 30, exp: now + 540, iss: input.appId })));
    const key = await globalThis.crypto.subtle.importKey("pkcs8", pemBytes(input.privateKeyPem), { hash: "SHA-256", name: "RSASSA-PKCS1-v1_5" }, false, ["sign"]);
    const signature = new Uint8Array(await globalThis.crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
    const identity = { installationId: input.installationId, repositoryId: input.repositoryId };
    const request = githubRoute(identity, "installationToken", [input.installationId]);
    const headers = new Headers(request.headers);
    headers.set("Authorization", `Bearer ${header}.${claims}.${base64Url(signature)}`);
    headers.set("Content-Type", "application/json");
    const bodyText = JSON.stringify({ repository_ids: [input.repositoryId], permissions: { checks: "write", contents: "read", metadata: "read", pull_requests: "read" } });
    const outbound = new Request(request.url, { method: request.method, redirect: "manual", headers, body: bodyText });
    const response = await callFetch(input.fetcher, outbound);
    if (response.redirected || response.status !== 201 || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? "")) throw new Error("github installation token rejected");
    const body = await boundedJson(response, MAX_RESPONSE_BYTES.installationToken);
    if (typeof body.token !== "string" || body.token.length < 1 || body.token.length > 512 || !/^[\x21-\x7e]+$/.test(body.token) || body.repository_selection !== "selected") throw new Error("github installation token malformed");
    const permissions = body.permissions;
    const requiredPermissions = { checks: "write", contents: "read", metadata: "read", pull_requests: "read" };
    if (!permissions || typeof permissions !== "object" || Array.isArray(permissions) || JSON.stringify(Object.entries(permissions).sort(([a], [b]) => a.localeCompare(b))) !== JSON.stringify(Object.entries(requiredPermissions).sort(([a], [b]) => a.localeCompare(b)))) throw new Error("github installation scope rejected");
    const repositories = body.repositories;
    if (!Array.isArray(repositories) || repositories.length !== 1 || !repositories[0] || typeof repositories[0] !== "object") throw new Error("github installation scope rejected");
    const repository = repositories[0];
    if (repository.id !== input.repositoryId || repository.name !== "MyArtCollection" || repository.full_name !== "kenleren/MyArtCollection") throw new Error("github installation scope rejected");
    if (typeof body.expires_at !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(body.expires_at)) throw new Error("github installation expiry rejected");
    const expiry = Date.parse(body.expires_at);
    const nowMs = input.now?.() ?? Date.now();
    if (!Number.isSafeInteger(expiry) || expiry < nowMs + 6e4 || expiry > nowMs + 65 * 6e4) throw new Error("github installation expiry rejected");
    return body.token;
  };
}
function classifyGitHubEgress(identity, request) {
  const url = new URL(request.url);
  if (/^\/repositories\/[1-9][0-9]*\/statuses\/[0-9a-f]{40}$/.test(url.pathname)) return "status";
  return isExactGithubRequest(identity, request) ? "allowed" : "forbidden";
}
function enforceGitHubEgress(identity, request, measure) {
  const classification = classifyGitHubEgress(identity, request);
  if (classification === "allowed") return;
  measure({ metric: classification === "status" ? "status_egress" : "forbidden_egress", value: 1 });
  throw new DefinitiveNotSentError("github egress route rejected");
}
function githubAlarmPort(input) {
  let outboundCalls = 0;
  const budgetedFetch = async (request, init) => {
    const outbound = request instanceof Request ? request : new Request(request, init);
    const identity = { installationId: input.installationId, repositoryId: input.repositoryId };
    enforceGitHubEgress(identity, outbound, input.measure ?? (() => {
    }));
    if (input.reserveOutbound && !input.reserveOutbound()) {
      input.measure?.({ metric: "exceeded_resource", value: 1 });
      throw new DefinitiveNotSentError("github quota exhausted");
    }
    outboundCalls += 1;
    input.measure?.({ metric: "request_high_water", value: outboundCalls });
    if (outboundCalls > 50) {
      input.measure?.({ metric: "exceeded_resource", value: 1 });
      throw new DefinitiveNotSentError("github alarm subrequest budget exhausted");
    }
    return callFetch(input.fetcher, outbound, request instanceof Request ? init : void 0);
  };
  const issueAuthorization = githubInstallationAuthorization({ ...input, fetcher: budgetedFetch });
  let authorization;
  return new GitHubAppPort(budgetedFetch, () => authorization ??= issueAuthorization(), { appId: input.appId, baseRef: "main", installationId: input.installationId, repositoryId: input.repositoryId, repositoryName: input.repositoryName }, input.measure);
}

// src/repository_durable_object.ts
var RepositoryDurableObject = class {
  constructor(state, env) {
    this.state = state;
    this.store = new SqliteStore(state.storage);
    const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
    this.ready = state.blockConcurrencyWhile(async () => {
      this.store.initialize(config.activationDigest, `sha256:${SQLITE_COMPATIBILITY_SHA256}`);
    });
    this.dispatcher = new AlarmDispatcher(state.storage, this.store, {
      clock: { delay: async () => {
      } },
      identity: { appId: config.appId, baseRef: "main", installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection" },
      policy: loadCanonicalPolicy(CANONICAL_POLICY_BYTES),
      portFactory: () => githubAlarmPort({ appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", privateKeyPem: env.GITHUB_APP_PRIVATE_KEY_PEM, fetcher: fetch, measure: (measurement) => this.recordEgress(measurement), reserveOutbound: () => this.store.reserveQuota(Date.now(), { outbound_attempts: 1 }).admitted })
    });
  }
  store;
  dispatcher;
  ready;
  async fetch(request) {
    try {
      await this.ready;
    } catch {
      return new Response("repository state unavailable", { status: 503 });
    }
    this.store.incrementMeta("do_request_count/v1");
    const path = new URL(request.url).pathname;
    if (request.method !== "POST") return new Response("not found", { status: 404 });
    const quota = this.store.reserveQuota(Date.now(), { worker_events: 1, do_fetches: 1 });
    if (!quota.admitted) {
      await this.state.storage.setAlarm(quota.rolloverAt);
      const retryAfter = String(Math.max(1, Math.ceil((quota.rolloverAt - Date.now()) / 1e3)));
      return new Response("repository quota unavailable", { status: 503, headers: { "retry-after": retryAfter } });
    }
    if (path === "/watchdog") {
      await this.watchdog();
      return new Response(null, { status: 202 });
    }
    if (path !== "/verified-delivery") return new Response("not found", { status: 404 });
    const input = await request.json();
    if (!input || !["pull_request", "push"].includes(input.event) || !Number.isSafeInteger(input.installation_id) || !input.target || input.target.kind !== input.event) return new Response("invalid delivery", { status: 400 });
    if (input.target.kind === "pull_request" && (!Number.isSafeInteger(input.target.pullRequestNumber) || input.target.pullRequestNumber <= 0) || input.target.kind === "push" && !/^[0-9a-f]{40}$/.test(input.target.after)) return new Response("invalid delivery", { status: 400 });
    const receipt = await receive(this.store, { deliveryId: input.delivery_id, identityDigest: input.payload_sha256, installationId: input.installation_id, kind: input.event, payloadDigest: input.payload_sha256 });
    this.dispatcher.rememberTarget(receipt, input.target);
    await this.dispatcher.requestDrain();
    return new Response(null, { status: 202 });
  }
  async alarm() {
    await this.ready;
    await this.dispatcher.alarm();
  }
  async watchdog() {
    await this.ready;
    await this.dispatcher.watchdog();
  }
  recordEgress(measurement) {
    const key = `egress/${measurement.metric}/v1`;
    if (!Number.isSafeInteger(measurement.value) || measurement.value < 0) {
      this.store.writeMeta(key, 1e6);
      return;
    }
    if (measurement.metric === "request_high_water") {
      const prior = this.store.readMeta(key) ?? 0;
      this.store.writeMeta(key, Math.min(Math.max(prior, measurement.value), 1e6));
    } else this.store.incrementMeta(key, measurement.value);
  }
};

// src/worker.ts
function rawHeaders(request) {
  return [...request.headers].map(([name, value]) => ({ name, value }));
}
async function boundedBody(request) {
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_WEBHOOK_BYTES)) return null;
  if (request.body === null) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (; ; ) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > MAX_WEBHOOK_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const raw = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return raw;
}
async function watchdog(env) {
  const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID)));
  await stub.fetch(new Request("https://do.invalid/watchdog", { method: "POST" }));
}
var worker_default = { async fetch(request, env) {
  const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
  if (!env.GITHUB_WEBHOOK_SECRET || !env.GITHUB_APP_PRIVATE_KEY_PEM) return new Response("misconfigured", { status: 503 });
  const path = new URL(request.url).pathname;
  if (path === "/scheduled-watchdog") return new Response("not found", { status: 404 });
  if (path !== "/webhook" || request.method !== "POST") return new Response("not found", { status: 404 });
  const raw = await boundedBody(request);
  if (raw === null) return new Response("payload too large", { status: 413 });
  let verified;
  let target;
  try {
    verified = verifyWebhook(raw, rawHeaders(request), new TextEncoder().encode(env.GITHUB_WEBHOOK_SECRET), loadCanonicalPolicy(CANONICAL_POLICY_BYTES));
    target = validateDeliveryIdentity(verified, { appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", baseRef: "main" });
  } catch {
    return new Response("invalid webhook", { status: 401 });
  }
  const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID)));
  return stub.fetch(new Request("https://do.invalid/verified-delivery", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ delivery_id: verified.deliveryId, event: verified.event, payload_sha256: verified.payloadSha256, installation_id: config.installationId, target }) }));
}, async scheduled(_event, env) {
  parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
  if (!env.GITHUB_APP_PRIVATE_KEY_PEM) return;
  await watchdog(env);
} };
export {
  RepositoryDurableObject,
  worker_default as default
};
