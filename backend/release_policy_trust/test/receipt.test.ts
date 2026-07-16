import assert from "node:assert/strict";
import test from "node:test";
import { atomicEnqueuePull, atomicEnqueuePush, atomicEnqueuePushChild, currentKey, generationKey, InMemoryDurableStore, outboxKey, pushChildKey, receiptKey, receive, type Generation } from "../src/store.js";

const input = { deliveryId: "delivery", identityDigest: "i".repeat(64), installationId: 22, payloadDigest: "p".repeat(64) };
const generation: Generation = { generationId: "g".repeat(64), pullRequestNumber: 7, repositoryId: 33, state: "claimed", version: 1 };

test("same-body replay resumes nonterminal receipt; different body conflicts", async () => {
  const store = new InMemoryDurableStore();
  const first = await receive(store, input); const replay = await receive(store, input);
  assert.deepEqual(replay, first);
  const conflict = await receive(store, { ...input, payloadDigest: "x".repeat(64) });
  assert.equal(conflict.state, "conflict");
});

test("receipt, generation, current pointer, and outbox commit atomically", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, input);
  await atomicEnqueuePull(store, receipt, generation);
  assert.equal((await store.read(receiptKey(22, "delivery")) as { state: string }).state, "enqueued");
  assert.ok(await store.read(currentKey(33, 7)));
  assert.ok(await store.read(generationKey(generation.generationId)));
  assert.ok(await store.read(outboxKey(generation.generationId, "evaluate_generation")));
});

test("failed commit leaves no generation-without-outbox half state", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, input); store.failNextCommit = true;
  await assert.rejects(atomicEnqueuePull(store, receipt, generation), /commit failure/);
  assert.equal(await store.read(generationKey(generation.generationId)), undefined);
  assert.equal(await store.read(outboxKey(generation.generationId, "evaluate_generation")), undefined);
  assert.equal((await store.read(receiptKey(22, "delivery")) as { state: string }).state, "received");
});

test("ambiguous commit is resolved by durable reread without duplicate intents", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, input); store.ambiguousNextCommit = true;
  await assert.rejects(atomicEnqueuePull(store, receipt, generation), /ambiguous/);
  assert.ok(await store.read(generationKey(generation.generationId)));
  assert.ok(await store.read(outboxKey(generation.generationId, "evaluate_generation")));
  await assert.rejects(atomicEnqueuePull(store, receipt, generation), /receipt changed|CAS/);
});

test("push target fanout and each child enqueue are separately atomic and unique", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, input);
  await atomicEnqueuePush(store, receipt, "t".repeat(64), [7, 8]);
  assert.ok(await store.read(pushChildKey(22, "delivery", 7)));
  assert.ok(await store.read(pushChildKey(22, "delivery", 8)));
  await atomicEnqueuePushChild(store, receipt, generation);
  assert.equal((await store.read(pushChildKey(22, "delivery", 7)) as { state: string }).state, "enqueued");
  await assert.rejects(atomicEnqueuePushChild(store, receipt, generation), /unavailable/);
});

test("CAS loss stops concurrent writers", async () => {
  const store = new InMemoryDurableStore(); const receipt = await receive(store, input);
  await atomicEnqueuePull(store, receipt, generation);
  const stale = { ...receipt };
  await assert.rejects(atomicEnqueuePull(store, stale, { ...generation, generationId: "h".repeat(64) }), /receipt changed|CAS/);
});
