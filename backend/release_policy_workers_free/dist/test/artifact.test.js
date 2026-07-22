import test from "node:test";
import assert from "node:assert/strict";
import { artifactDrift, sha256 } from "../src/artifact.js";
test("artifact verification rejects an ancestor whose asserted bytes differ", () => {
    const recorded = { "worker.mjs": sha256("ancestor bytes") };
    const current = { "worker.mjs": sha256("current bytes") };
    assert.deepEqual(artifactDrift(recorded, current, recorded), ["worker.mjs"]);
});
test("artifact verification binds recorded, working, and exact anchor-tree bytes", () => {
    const digest = sha256("same bytes");
    const hashes = { "worker.mjs": digest };
    assert.deepEqual(artifactDrift(hashes, hashes, hashes), []);
});
