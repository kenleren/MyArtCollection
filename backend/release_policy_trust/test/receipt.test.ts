import assert from "node:assert/strict";
import test from "node:test";
import { snapshotPullRequest } from "../src/snapshot.js";
import {
  atomicEnqueuePull,
  atomicEnqueuePush,
  atomicEnqueuePushChild,
  beginReceiptSnapshot,
  commitDecision,
  currentKey,
  generationFromEvaluation,
  generationKey,
  InMemoryDurableStore,
  leaseOutbox,
  leasePushChild,
  outboxKey,
  pushChildKey,
  receiptKey,
  receive,
  recoverEvaluationLease,
  recoverPushChildLease,
} from "../src/store.js";
import { FakePort, identity, policy } from "./helpers.js";

const pullInput = { deliveryId: "delivery", identityDigest: "1".repeat(64), installationId: 22, kind: "pull_request" as const, payloadDigest: "2".repeat(64) };
const pushInput = { ...pullInput, deliveryId: "push", kind: "push" as const, payloadDigest: "3".repeat(64) };

async function generation(port = new FakePort()) {
  return generationFromEvaluation(await snapshotPullRequest(port, identity, port.pull.number, policy()));
}

test("same-body replay resumes nonterminal receipt; different body or kind conflicts terminally", async () => {
  const store = new InMemoryDurableStore();
  const first = await receive(store, pullInput);
  assert.equal((await beginReceiptSnapshot(store, first)).state, "snapshotting");
  assert.equal((await receive(store, pullInput)).state, "snapshotting");
  const conflict = await receive(store, { ...pullInput, payloadDigest: "f".repeat(64) });
  assert.equal(conflict.state, "conflict");
  assert.equal((await receive(store, pullInput)).state, "conflict");
});

test("receipt, immutable generation, current pointer, and evaluate intent commit atomically", async () => {
  const store = new InMemoryDurableStore(); const receipt = await beginReceiptSnapshot(store, await receive(store, pullInput)); const row = await generation();
  await atomicEnqueuePull(store, receipt, row);
  const durable = await store.read(receiptKey(22, "delivery")) as { generationId: string; state: string };
  assert.equal(durable.state, "enqueued"); assert.equal(durable.generationId, row.generationId);
  assert.equal((await store.read(currentKey(33, 7)) as { generationId: string }).generationId, row.generationId);
  assert.equal((await store.read(generationKey(row.generationId)) as { immutableDigest: string }).immutableDigest, row.immutableDigest);
  assert.equal((await store.read(outboxKey(row.generationId, "evaluate_generation")) as { state: string }).state, "pending");
});

test("failed commit leaves no generation/outbox half-state and receipt resumes", async () => {
  const store = new InMemoryDurableStore(); const receipt = await beginReceiptSnapshot(store, await receive(store, pullInput)); const row = await generation(); store.failNextCommit = true;
  await assert.rejects(atomicEnqueuePull(store, receipt, row), /commit failure/);
  assert.equal(await store.read(generationKey(row.generationId)), undefined);
  assert.equal(await store.read(outboxKey(row.generationId, "evaluate_generation")), undefined);
  assert.equal((await store.read(receiptKey(22, "delivery")) as { state: string }).state, "snapshotting");
  await atomicEnqueuePull(store, await receive(store, pullInput), row);
  assert.equal((await store.read(receiptKey(22, "delivery")) as { state: string }).state, "enqueued");
});

test("ambiguous commits resolve by durable reread without duplicate generation or intent", async () => {
  const store = new InMemoryDurableStore(); const receipt = await beginReceiptSnapshot(store, await receive(store, pullInput)); const row = await generation(); store.ambiguousNextCommit = true;
  await atomicEnqueuePull(store, receipt, row);
  await atomicEnqueuePull(store, await receive(store, pullInput), row);
  assert.deepEqual(store.keys().filter((key) => key.includes(row.generationId)).sort(), [generationKey(row.generationId), outboxKey(row.generationId, "evaluate_generation")].sort());
});

test("evaluation lease CASes claimed to evaluating and only durable draft decision reaches decision_ready", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, pullInput); const row = await generation(); await atomicEnqueuePull(store, receipt, row);
  await leaseOutbox(store, row.generationId, "worker-a");
  await assert.rejects(leaseOutbox(store, row.generationId, "worker-b"), /unavailable/);
  const decided = await commitDecision(store, row.generationId, "worker-a");
  assert.equal(decided.state, "decision_ready"); assert.deepEqual(decided.decision, row.draftDecision);
  await assert.rejects(commitDecision(store, row.generationId, "worker-a"), /changed/);
});

test("abandoned evaluation lease returns to the same pending intent and resumes", async () => {
  const store = new InMemoryDurableStore(); const row = await generation(); await atomicEnqueuePull(store, await receive(store, { ...pullInput, deliveryId: "recover-eval", payloadDigest: "a".repeat(64) }), row);
  await leaseOutbox(store, row.generationId, "dead-worker");
  await recoverEvaluationLease(store, row.generationId, "dead-worker");
  assert.equal((await store.read(outboxKey(row.generationId, "evaluate_generation")) as { state: string }).state, "pending");
  await leaseOutbox(store, row.generationId, "replacement");
  assert.equal((await commitDecision(store, row.generationId, "replacement")).state, "decision_ready");
});

test("same immutable generation is reused across distinct deliveries without a second evaluate intent", async () => {
  const store = new InMemoryDurableStore(); const row = await generation();
  await atomicEnqueuePull(store, await receive(store, pullInput), row);
  await atomicEnqueuePull(store, await receive(store, { ...pullInput, deliveryId: "delivery-2", payloadDigest: "4".repeat(64) }), row);
  assert.equal(store.keys().filter((key) => key === generationKey(row.generationId)).length, 1);
  assert.equal(store.keys().filter((key) => key === outboxKey(row.generationId, "evaluate_generation")).length, 1);
});

test("push fanout, child lease/enqueue, replay, and ambiguous commit are resumable and unique", async () => {
  const store = new InMemoryDurableStore(); const receipt = await beginReceiptSnapshot(store, await receive(store, pushInput)); store.ambiguousNextCommit = true;
  await atomicEnqueuePush(store, receipt, "5".repeat(64), [7, 8]);
  await atomicEnqueuePush(store, await receive(store, pushInput), "5".repeat(64), [7, 8]);
  assert.equal((await store.read(receiptKey(22, "push")) as { targetCount: number }).targetCount, 2);
  assert.equal((await leasePushChild(store, receipt, 7, "fanout-a")).state, "leased");
  await assert.rejects(leasePushChild(store, receipt, 7, "fanout-b"), /unavailable/);
  const row = await generation();
  await atomicEnqueuePushChild(store, receipt, row, "fanout-a");
  await atomicEnqueuePushChild(store, receipt, row, "fanout-a");
  assert.equal((await store.read(pushChildKey(22, "push", 7)) as { state: string }).state, "enqueued");
});

test("empty push fanout terminates successfully and malformed target ordering fails", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, pushInput);
  await atomicEnqueuePush(store, receipt, "6".repeat(64), []);
  assert.equal((await store.read(receiptKey(22, "push")) as { state: string }).state, "terminal_success");
  const second = await receive(store, { ...pushInput, deliveryId: "push-2", payloadDigest: "7".repeat(64) });
  await assert.rejects(atomicEnqueuePush(store, second, "6".repeat(64), [8, 7]), /ascending/);
});

test("abandoned push child lease returns to pending without creating generation or outbox", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, { ...pushInput, deliveryId: "recover-child", payloadDigest: "c".repeat(64) });
  await atomicEnqueuePush(store, receipt, "d".repeat(64), [7]);
  await leasePushChild(store, receipt, 7, "dead-fanout");
  await recoverPushChildLease(store, receipt, 7, "dead-fanout");
  assert.equal((await store.read(pushChildKey(22, "recover-child", 7)) as { state: string }).state, "pending");
  assert.equal(store.keys().some((key) => key.startsWith("generation/")), false);
  assert.equal(store.keys().some((key) => key.startsWith("outbox/")), false);
});
