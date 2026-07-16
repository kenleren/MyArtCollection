import assert from "node:assert/strict";
import test from "node:test";
import { canonicalHash, canonicalJson, generationId } from "../src/canonical.js";

test("canonical JSON byte-sorts keys and rejects unstable numbers", () => {
  assert.equal(canonicalJson({ z: 1, a: { y: true, b: "x" } }), '{"a":{"b":"x","y":true},"z":1}');
  assert.equal(canonicalHash({ b: 2, a: 1 }), "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777");
  assert.throws(() => canonicalJson({ bad: 1.2 }), /safe integers/);
});

test("generation ID is stable across tuple insertion order", () => {
  const tuple = { app_id: 1, base_ref: "main", base_sha: "a".repeat(40), head_sha: "b".repeat(40), installation_id: 2, policy_sha256: "c".repeat(64), pull_request_number: 3, repository_id: 4 };
  assert.equal(generationId(tuple), generationId({ ...tuple }));
  assert.equal(generationId(tuple).length, 64);
});
