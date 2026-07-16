import assert from "node:assert/strict";
import test from "node:test";
import { AmbiguousUpdateError, bindOneCheck, DefinitiveNotSentError, finishBoundCheck, finishCurrentGeneration, RECONCILE_DELAYS } from "../src/checks.js";
import { snapshotPullRequest, snapshotPushTargets } from "../src/snapshot.js";
import { FakePort, identity, pages, SHA_A, SHA_B, changed, openPr } from "./helpers.js";
import { atomicEnqueuePull, InMemoryDurableStore, receive, type Generation } from "../src/store.js";

test("immutable snapshot succeeds for evaluated paths and rejects protected paths", async () => {
  const port = new FakePort(); port.pull.changedFiles = 1; port.filePages = pages([changed(1)]);
  const safe = await snapshotPullRequest(port, identity, 7, "c".repeat(64), { exact: [], prefixes: [".github/"] });
  assert.deepEqual(safe.protectedPaths, []);
  port.filePages = pages([{ path: ".github/workflows/x.yml", status: "modified" }]);
  const blocked = await snapshotPullRequest(port, identity, 7, "c".repeat(64), { exact: [], prefixes: [".github/"] });
  assert.deepEqual(blocked.protectedPaths, [".github/workflows/x.yml"]);
});

test("head, base, fork, and main races fail closed", async () => {
  const fork = new FakePort(); fork.pull.headRepositoryId = 99;
  await assert.rejects(snapshotPullRequest(fork, identity, 7, "c".repeat(64), { exact: [], prefixes: [] }), /fork/);
  const base = new FakePort(); base.main.sha = "f".repeat(40);
  await assert.rejects(snapshotPullRequest(base, identity, 7, "c".repeat(64), { exact: [], prefixes: [] }), /current main/);
  const race = new FakePort(); let reads = 0; race.getPullRequest = async () => ({ ...race.pull, headSha: reads++ === 0 ? SHA_B : "d".repeat(40) });
  await assert.rejects(snapshotPullRequest(race, identity, 7, "c".repeat(64), { exact: [], prefixes: [] }), /moved/);
});

test("main push requires stable main and identical bounded target passes", async () => {
  const port = new FakePort(); port.openPages = pages([openPr(1), openPr(2)]);
  assert.deepEqual((await snapshotPushTargets(port, identity, SHA_A)).numbers, [1, 2]);
  await assert.rejects(snapshotPushTargets(port, identity, "f".repeat(40)), /does not equal/);
  const moving = new FakePort(); let reads = 0;
  moving.getMainRef = async () => ({ ...moving.main, sha: reads++ === 0 ? SHA_A : "f".repeat(40) });
  await assert.rejects(snapshotPushTargets(moving, identity, SHA_A), /moved/);
});

test("one create per generation and exact App-owned adoption after ambiguity", async () => {
  const port = new FakePort(); port.createBehavior = "ambiguous";
  port.checkPages = pages([{ appId: 11, checkId: 88, externalId: "generation", headSha: SHA_B, name: "trusted", repositoryId: 33 }]);
  const delays: number[] = [];
  const check = await bindOneCheck(port, { delay: async (seconds) => { delays.push(seconds); } }, identity, SHA_B, "trusted", "generation");
  assert.equal(check.checkId, 88); assert.equal(port.created.length, 1); assert.deepEqual(delays, [1]);
});

test("ambiguous invisible or duplicate check never recreates or succeeds", async () => {
  const invisible = new FakePort(); invisible.createBehavior = "ambiguous"; const delays: number[] = [];
  await assert.rejects(bindOneCheck(invisible, { delay: async (seconds) => { delays.push(seconds); } }, identity, SHA_B, "trusted", "generation"), /recreation forbidden/);
  assert.equal(invisible.created.length, 1); assert.deepEqual(delays, RECONCILE_DELAYS);
  const duplicate = new FakePort(); duplicate.createBehavior = "ambiguous"; duplicate.checkPages = pages([
    { appId: 11, checkId: 1, externalId: "generation", headSha: SHA_B, name: "trusted", repositoryId: 33 },
    { appId: 11, checkId: 2, externalId: "generation", headSha: SHA_B, name: "trusted", repositoryId: 33 },
  ]);
  await assert.rejects(bindOneCheck(duplicate, { delay: async () => undefined }, identity, SHA_B, "trusted", "generation"), /multiple/);
});

test("definite not-sent can be re-leased, while update ambiguity retains bound id", async () => {
  const port = new FakePort(); port.createBehavior = "definite";
  await assert.rejects(bindOneCheck(port, { delay: async () => undefined }, identity, SHA_B, "trusted", "g"), DefinitiveNotSentError);
  assert.equal(port.created.length, 1);
  port.updateCheck = async () => { throw new AmbiguousUpdateError(); };
  await assert.rejects(finishBoundCheck(port, { checkId: 44, protectedPaths: [], repositoryId: 33 }), AmbiguousUpdateError);
});

test("terminal decision is success only for no protected paths", async () => {
  const port = new FakePort();
  await finishBoundCheck(port, { checkId: 44, protectedPaths: [], repositoryId: 33 });
  await finishBoundCheck(port, { checkId: 45, protectedPaths: [".github/x"], repositoryId: 33 });
  assert.deepEqual(port.updates.map((row) => row.conclusion), ["success", "failure"]);
});

test("stale worker and live snapshot races cannot update a Check Run", async () => {
  const store = new InMemoryDurableStore();
  const receipt = await receive(store, { deliveryId: "d", identityDigest: "i".repeat(64), installationId: 22, payloadDigest: "p".repeat(64) });
  const oldGeneration: Generation = { generationId: "1".repeat(64), pullRequestNumber: 7, repositoryId: 33, state: "decision_ready", version: 1 };
  await atomicEnqueuePull(store, receipt, oldGeneration);
  const newerReceipt = await receive(store, { deliveryId: "e", identityDigest: "i".repeat(64), installationId: 22, payloadDigest: "q".repeat(64) });
  const newerGeneration: Generation = { ...oldGeneration, generationId: "2".repeat(64) };
  await atomicEnqueuePull(store, newerReceipt, newerGeneration);
  const port = new FakePort();
  const check = { appId: 11, checkId: 44, externalId: oldGeneration.generationId, headSha: SHA_B, name: "trusted", repositoryId: 33 };
  await assert.rejects(finishCurrentGeneration({ check, expectedMainSha: SHA_A, expectedPullRequest: port.pull, generation: oldGeneration, port, protectedPaths: [], store }), /stale/);
  assert.equal(port.updates.length, 0);

  const currentCheck = { ...check, externalId: newerGeneration.generationId };
  port.pull.headSha = "d".repeat(40);
  await assert.rejects(finishCurrentGeneration({ check: currentCheck, expectedMainSha: SHA_A, expectedPullRequest: { ...port.pull, headSha: SHA_B }, generation: newerGeneration, port, protectedPaths: [], store }), /live snapshot changed/);
  assert.equal(port.updates.length, 0);
});
