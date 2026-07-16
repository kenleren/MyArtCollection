import assert from "node:assert/strict";
import test from "node:test";
import { AmbiguousCreateError, AmbiguousUpdateError, DefinitiveNotSentError, runCreateCheck, runUpdateCheck } from "../src/checks.js";
import { snapshotPullRequest, snapshotPushTargets } from "../src/snapshot.js";
import {
  atomicEnqueuePull,
  atomicEnqueuePush,
  atomicEnqueuePushChild,
  beginReceiptSnapshot,
  bindingKey,
  commitDecision,
  currentKey,
  generationFromEvaluation,
  InMemoryDurableStore,
  leaseOutbox,
  leasePushChild,
  markEffectPossibleSend,
  outboxKey,
  prepareCheckBinding,
  recoverAbandonedEffect,
  readBinding,
  readGeneration,
  receiptKey,
  receive,
  settlePullReceipt,
  settlePushChild,
} from "../src/store.js";
import { FakePort, identity, pages, SHA_A, SHA_B, changed, openPr, policy } from "./helpers.js";

let delivery = 0;
async function ready(store: InMemoryDurableStore, port = new FakePort()) {
  const row = generationFromEvaluation(await snapshotPullRequest(port, identity, port.pull.number, policy()));
  const receipt = await receive(store, { deliveryId: `pull-${++delivery}`, identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request", payloadDigest: String(delivery % 10).repeat(64) });
  await atomicEnqueuePull(store, receipt, row);
  await leaseOutbox(store, row.generationId, `eval-${delivery}`);
  await commitDecision(store, row.generationId, `eval-${delivery}`);
  await prepareCheckBinding(store, row.generationId, identity);
  return { generation: await readGeneration(store, row.generationId), receipt };
}

async function bind(store: InMemoryDurableStore, port: FakePort, generationId: string, worker = "create") {
  const check = await runCreateCheck({ clock: { delay: async () => undefined }, generationId, port, store, worker });
  port.checkPages = pages([check]);
  return check;
}

test("canonical policy bytes alone drive selectors, digest, limits, and immutable decision", async () => {
  const port = new FakePort(); port.pull.changedFiles = 1; port.filePages = pages([changed(1)]);
  const safe = await snapshotPullRequest(port, identity, 7, policy());
  assert.equal(safe.decision.conclusion, "success"); assert.deepEqual(safe.decision.protectedPaths, []);
  port.filePages = pages([{ path: ".github/workflows/x.yml", status: "modified" }]);
  const blocked = await snapshotPullRequest(port, identity, 7, policy());
  assert.equal(blocked.decision.conclusion, "failure"); assert.deepEqual(blocked.decision.protectedPaths, [".github/workflows/x.yml"]);
  assert.notEqual(blocked.policy.digest, "c".repeat(64));
  await assert.rejects(snapshotPullRequest(port, identity, 7, { digest: "c".repeat(64), pathPolicy: { exact: [], prefixes: [] } } as never), /canonical policy bytes/);
});

test("head, base, fork, and main races fail closed", async () => {
  const fork = new FakePort(); fork.pull.headRepositoryId = 99;
  await assert.rejects(snapshotPullRequest(fork, identity, 7, policy()), /fork/);
  const base = new FakePort(); base.main.sha = "f".repeat(40);
  await assert.rejects(snapshotPullRequest(base, identity, 7, policy()), /current main/);
  const race = new FakePort(); let reads = 0; race.getPullRequest = async () => ({ ...race.pull, headSha: reads++ === 0 ? SHA_B : "d".repeat(40) });
  await assert.rejects(snapshotPullRequest(race, identity, 7, policy()), /moved/);
});

test("main push requires stable main and identical bounded target passes from canonical limits", async () => {
  const port = new FakePort(); port.openPages = pages([openPr(1), openPr(2)]);
  assert.deepEqual((await snapshotPushTargets(port, identity, SHA_A, policy())).numbers, [1, 2]);
  await assert.rejects(snapshotPushTargets(port, identity, "f".repeat(40), policy()), /does not equal/);
  const moving = new FakePort(); let reads = 0;
  moving.getMainRef = async () => ({ ...moving.main, sha: reads++ === 0 ? SHA_A : "f".repeat(40) });
  await assert.rejects(snapshotPushTargets(moving, identity, SHA_A, policy()), /moved/);
});

test("create possible-send is durable before the API call and success binds full identity once", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port);
  port.onCreate = async () => {
    assert.equal((await store.read(outboxKey(generation.generationId, "create_check")) as { state: string }).state, "possible_send");
    assert.equal((await store.read(bindingKey(generation.generationId)) as { state: string }).state, "create_possible");
    assert.ok((await store.read(currentKey(33, 7)) as { effectLease: unknown }).effectLease);
  };
  const check = await bind(store, port, generation.generationId);
  assert.equal(check.checkId, 44); assert.equal(port.created.length, 1);
  const binding = await readBinding(store, generation.generationId);
  assert.equal(binding.checkId, 44); assert.equal(binding.appId, 11); assert.equal(binding.headSha, SHA_B); assert.equal(binding.externalId, generation.generationId);
});

test("ambiguous create becomes reconcile-only; exactly one delayed App match adopts without recreation", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port); port.createBehavior = "ambiguous";
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: generation.generationId, port, store, worker: "first" }), AmbiguousCreateError);
  assert.equal((await store.read(outboxKey(generation.generationId, "create_check")) as { state: string }).state, "possible_send");
  port.checkPages = pages([{ appId: 11, checkId: 88, externalId: generation.generationId, headSha: SHA_B, name: policy().checkName, repositoryId: 33 }]);
  const delays: number[] = [];
  const adopted = await runCreateCheck({ clock: { delay: async (seconds) => { delays.push(seconds); } }, generationId: generation.generationId, port, store, worker: "reconcile" });
  assert.equal(adopted.checkId, 88); assert.equal(port.created.length, 1); assert.deepEqual(delays, [1]);
});

test("invisible or duplicate ambiguous create blocks without recreation", async () => {
  const invisibleStore = new InMemoryDurableStore(); const invisible = new FakePort(); const { generation } = await ready(invisibleStore, invisible); invisible.createBehavior = "ambiguous";
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: generation.generationId, port: invisible, store: invisibleStore, worker: "send" }), AmbiguousCreateError);
  const delays: number[] = [];
  await assert.rejects(runCreateCheck({ clock: { delay: async (seconds) => { delays.push(seconds); } }, generationId: generation.generationId, port: invisible, store: invisibleStore, worker: "reconcile" }), /recreation forbidden/);
  assert.equal(invisible.created.length, 1); assert.deepEqual(delays, policy().limits.reconcileDelaysSeconds);

  const duplicateStore = new InMemoryDurableStore(); const duplicate = new FakePort(); const second = await ready(duplicateStore, duplicate); duplicate.createBehavior = "ambiguous";
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: second.generation.generationId, port: duplicate, store: duplicateStore, worker: "send" }), AmbiguousCreateError);
  duplicate.checkPages = pages([
    { appId: 11, checkId: 1, externalId: second.generation.generationId, headSha: SHA_B, name: policy().checkName, repositoryId: 33 },
    { appId: 11, checkId: 2, externalId: second.generation.generationId, headSha: SHA_B, name: policy().checkName, repositoryId: 33 },
  ]);
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: second.generation.generationId, port: duplicate, store: duplicateStore, worker: "reconcile" }), /multiple/);
  assert.equal(duplicate.created.length, 1);
});

test("definite-not-sent releases the same unique create intent for re-lease", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port); port.createBehavior = "definite";
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: generation.generationId, port, store, worker: "first" }), DefinitiveNotSentError);
  assert.equal((await store.read(outboxKey(generation.generationId, "create_check")) as { state: string }).state, "pending");
  port.createBehavior = "success";
  await bind(store, port, generation.generationId, "second");
  assert.equal(port.created.length, 2); assert.equal(store.keys().filter((key) => key === outboxKey(generation.generationId, "create_check")).length, 1);
});

test("crash before possible-send re-leases create; crash after possible-send forces reconcile-only", async () => {
  const beforeStore = new InMemoryDurableStore(); const beforePort = new FakePort(); const before = await ready(beforeStore, beforePort);
  const { leaseEffect } = await import("../src/store.js");
  const unsent = await leaseEffect(beforeStore, before.generation.generationId, "create_check", "dead-before");
  await recoverAbandonedEffect(beforeStore, unsent.generationId, unsent.operation, unsent.owner, unsent.fence);
  await bind(beforeStore, beforePort, before.generation.generationId, "replacement");
  assert.equal(beforePort.created.length, 1);

  const afterStore = new InMemoryDurableStore(); const afterPort = new FakePort(); const after = await ready(afterStore, afterPort);
  const possible = await leaseEffect(afterStore, after.generation.generationId, "create_check", "dead-after");
  await markEffectPossibleSend(afterStore, possible);
  await recoverAbandonedEffect(afterStore, possible.generationId, possible.operation, possible.owner, possible.fence);
  afterPort.checkPages = pages([{ appId: 11, checkId: 77, externalId: after.generation.generationId, headSha: SHA_B, name: policy().checkName, repositoryId: 33 }]);
  const adopted = await runCreateCheck({ clock: { delay: async () => undefined }, generationId: after.generation.generationId, port: afterPort, store: afterStore, worker: "replacement" });
  assert.equal(adopted.checkId, 77); assert.equal(afterPort.created.length, 0);
});

test("ambiguous durable commits after create/update responses reconcile by reread without duplicate side effects", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port);
  port.onCreate = () => { store.ambiguousNextCommit = true; };
  const check = await bind(store, port, generation.generationId);
  assert.equal(port.created.length, 1); assert.equal((await readBinding(store, generation.generationId)).checkId, check.checkId);
  delete port.onCreate; port.onUpdate = () => { store.ambiguousNextCommit = true; };
  await runUpdateCheck({ generationId: generation.generationId, port, store, worker: "update" });
  assert.equal(port.updates.length, 1); assert.equal((await readGeneration(store, generation.generationId)).state, "terminal_success");
});

test("update possible-send is fenced, validates the bound identity, and ambiguity retries only that numeric ID", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation, receipt } = await ready(store, port); const check = await bind(store, port, generation.generationId);
  port.updateBehavior = "ambiguous";
  await assert.rejects(runUpdateCheck({ generationId: generation.generationId, port, store, worker: "update-a" }), AmbiguousUpdateError);
  assert.equal((await store.read(outboxKey(generation.generationId, "update_check")) as { state: string }).state, "possible_send");
  port.updateBehavior = "success";
  await runUpdateCheck({ generationId: generation.generationId, port, store, worker: "update-b" });
  assert.deepEqual(port.updates.map((row) => row.checkId), [check.checkId, check.checkId]);
  assert.equal((await readGeneration(store, generation.generationId)).state, "terminal_success");
  assert.equal((await settlePullReceipt(store, receipt)).state, "terminal_success");
});

test("mismatched bound ID or same-name non-App check cannot be updated", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port); const check = await bind(store, port, generation.generationId);
  port.checkPages = pages([{ ...check, checkId: 999, appId: 999 }]);
  await assert.rejects(runUpdateCheck({ generationId: generation.generationId, port, store, worker: "bad-update" }), /identity/);
  assert.equal(port.updates.length, 0);
});

test("fenced effect lease excludes superseding generation and stale workers make no API call", async () => {
  const store = new InMemoryDurableStore(); const oldPort = new FakePort(); const { generation: old } = await ready(store, oldPort);
  const lease = await import("../src/store.js").then(({ leaseEffect }) => leaseEffect(store, old.generationId, "create_check", "old-worker"));
  await markEffectPossibleSend(store, lease);
  const moved = new FakePort(); moved.pull.headSha = "d".repeat(40); const newer = generationFromEvaluation(await snapshotPullRequest(moved, identity, 7, policy()));
  const newerReceipt = await receive(store, { deliveryId: "newer", identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request", payloadDigest: "9".repeat(64) });
  await assert.rejects(atomicEnqueuePull(store, newerReceipt, newer), /fenced/);
  assert.equal(oldPort.created.length, 0);
});

test("superseded worker cannot acquire create lease or call the API", async () => {
  const store = new InMemoryDurableStore(); const oldPort = new FakePort(); const { generation: old } = await ready(store, oldPort);
  const moved = new FakePort(); moved.pull.headSha = "e".repeat(40); const newer = generationFromEvaluation(await snapshotPullRequest(moved, identity, 7, policy()));
  await atomicEnqueuePull(store, await receive(store, { deliveryId: "supersede", identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request", payloadDigest: "e".repeat(64) }), newer);
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: old.generationId, port: oldPort, store, worker: "stale" }), /durable decision|unavailable/);
  assert.equal(oldPort.created.length, 0); assert.equal((await readGeneration(store, old.generationId)).state, "obsolete");
});

test("new generation cannot be admitted while a bound update side effect holds the PR fence", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port); await bind(store, port, generation.generationId);
  const moved = new FakePort(); moved.pull.headSha = "f".repeat(40); const newer = generationFromEvaluation(await snapshotPullRequest(moved, identity, 7, policy()));
  const newerReceipt = await receive(store, { deliveryId: "during-update", identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request", payloadDigest: "f".repeat(64) });
  port.onUpdate = async () => { await assert.rejects(atomicEnqueuePull(store, newerReceipt, newer), /fenced/); };
  await runUpdateCheck({ generationId: generation.generationId, port, store, worker: "bound-update" });
  assert.equal(port.updates.length, 1);
  await atomicEnqueuePull(store, newerReceipt, newer);
  assert.equal((await store.read(currentKey(33, 7)) as { generationId: string }).generationId, newer.generationId);
});

test("live snapshot movement prevents update before possible-send and emits no side effect", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort(); const { generation } = await ready(store, port); await bind(store, port, generation.generationId);
  port.pull.headSha = "d".repeat(40);
  await assert.rejects(runUpdateCheck({ generationId: generation.generationId, port, store, worker: "race" }), /live snapshot changed/);
  assert.equal(port.updates.length, 0);
  assert.equal((await store.read(currentKey(33, 7)) as { effectLease: unknown }).effectLease, null);
});

test("push children resume independently and receipt aggregates only after every child terminal", async () => {
  const store = new InMemoryDurableStore();
  const receipt = await beginReceiptSnapshot(store, await receive(store, { deliveryId: "push-aggregate", identityDigest: "1".repeat(64), installationId: 22, kind: "push", payloadDigest: "8".repeat(64) }));
  await atomicEnqueuePush(store, receipt, "a".repeat(64), [7, 8]);
  const ports = [new FakePort(), new FakePort()]; ports[1]!.pull = { ...ports[1]!.pull, number: 8 };
  for (const [index, port] of ports.entries()) {
    const row = generationFromEvaluation(await snapshotPullRequest(port, identity, port.pull.number, policy()));
    await leasePushChild(store, receipt, port.pull.number, `fanout-${index}`);
    await atomicEnqueuePushChild(store, receipt, row, `fanout-${index}`);
    await leaseOutbox(store, row.generationId, `eval-push-${index}`); await commitDecision(store, row.generationId, `eval-push-${index}`); await prepareCheckBinding(store, row.generationId, identity);
    const check = await bind(store, port, row.generationId, `create-push-${index}`); port.checkPages = pages([check]); await runUpdateCheck({ generationId: row.generationId, port, store, worker: `update-push-${index}` });
  }
  assert.equal((await settlePushChild(store, receipt, 7)).state, "enqueued");
  assert.equal((await settlePushChild(store, receipt, 8)).state, "terminal_success");
  assert.equal((await store.read(receiptKey(22, "push-aggregate")) as { state: string }).state, "terminal_success");
});

test("binding/outbox commit failure cannot leave a callable create half-state", async () => {
  const store = new InMemoryDurableStore(); const port = new FakePort();
  const row = generationFromEvaluation(await snapshotPullRequest(port, identity, 7, policy())); const receipt = await receive(store, { deliveryId: "prepare-fail", identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request", payloadDigest: "b".repeat(64) });
  await atomicEnqueuePull(store, receipt, row); await leaseOutbox(store, row.generationId, "eval"); await commitDecision(store, row.generationId, "eval");
  store.failNextCommit = true;
  await assert.rejects(prepareCheckBinding(store, row.generationId, identity), /commit failure/);
  assert.equal(await store.read(bindingKey(row.generationId)), undefined);
  assert.equal(await store.read(outboxKey(row.generationId, "create_check")), undefined);
  await assert.rejects(runCreateCheck({ clock: { delay: async () => undefined }, generationId: row.generationId, port, store, worker: "illegal" }), /binding missing/);
  assert.equal(port.created.length, 0);
});
