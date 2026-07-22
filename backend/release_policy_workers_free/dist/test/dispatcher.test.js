import test from "node:test";
import assert from "node:assert/strict";
import { loadCanonicalPolicy } from "@archivale/release-policy-trust";
import { AlarmDispatcher } from "../src/dispatcher.js";
import { CANONICAL_POLICY_BYTES } from "../src/generated/canonical_policy_bytes.js";
class Store {
    rows = new Map();
    meta = new Map();
    async transact(work) { const rows = structuredClone(this.rows); const tx = { get: (key) => structuredClone(rows.get(key)?.value), putIfAbsent: (key, value) => { if (rows.has(key))
            throw new Error("cas"); rows.set(key, { version: 1, value: structuredClone(value) }); }, compareAndSwap: (key, version, value) => { const row = rows.get(key); if (!row || row.version !== version)
            throw new Error("cas"); rows.set(key, { version: version + 1, value: structuredClone(value) }); } }; const result = work(tx); this.rows = rows; return result; }
    async read(key) { return structuredClone(this.rows.get(key)?.value); }
    entries(prefix) { return [...this.rows].filter(([key]) => key.startsWith(prefix)).map(([key, row]) => ({ key, value: structuredClone(row.value) })); }
    readMeta(key) { return structuredClone(this.meta.get(key)); }
    writeMeta(key, value) { this.meta.set(key, structuredClone(value)); }
}
class Port {
    created = 0;
    updated = 0;
    check;
    pr() { return { appId: 9, baseRef: "main", baseSha: "a".repeat(40), changedFiles: 0, headRepositoryId: 1288597824, headSha: "b".repeat(40), installationId: 11, number: 7, repositoryId: 1288597824, repositoryName: "kenleren/MyArtCollection", state: "open" }; }
    async getPullRequest() { return this.pr(); }
    async getMainRef() { return { repositoryId: 1288597824, ref: "refs/heads/main", sha: "a".repeat(40) }; }
    async listPullRequestFiles() { return { items: [], nextPage: null }; }
    async listOpenMainPullRequests() { return { items: [], nextPage: null }; }
    async listAppChecks() { return { items: this.check ? [this.check] : [], nextPage: null }; }
    async createCheck(input) { this.created++; return this.check = { appId: 9, checkId: 99, ...input }; }
    async updateCheck() { this.updated++; }
}
test("alarm is sole drainer and a replay cannot duplicate a Check Run", async () => {
    const store = new Store();
    const alarms = [];
    const storage = { getAlarm: async () => null, setAlarm: async (at) => { alarms.push(at); } };
    const port = new Port();
    const policy = loadCanonicalPolicy(CANONICAL_POLICY_BYTES);
    const dispatcher = new AlarmDispatcher(storage, store, { clock: { delay: async () => { } }, identity: { appId: 9, installationId: 11, repositoryId: 1288597824, repositoryName: "kenleren/MyArtCollection", baseRef: "main" }, policy, port });
    const { receive } = await import("@archivale/release-policy-trust");
    const receipt = await receive(store, { deliveryId: "synthetic-delivery", identityDigest: "1".repeat(64), payloadDigest: "1".repeat(64), installationId: 11, kind: "pull_request" });
    dispatcher.rememberTarget(receipt, { kind: "pull_request", pullRequestNumber: 7 });
    await dispatcher.requestDrain();
    await dispatcher.alarm();
    await dispatcher.alarm();
    assert.equal(port.created, 1);
    assert.equal(port.updated, 1);
    assert.equal((await store.read("receipt/11/synthetic-delivery")).state, "terminal_success");
    assert.ok(alarms.length >= 1);
});
