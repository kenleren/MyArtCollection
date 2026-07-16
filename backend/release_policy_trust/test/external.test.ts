import assert from "node:assert/strict";
import test from "node:test";
import { sha256 } from "../src/canonical.js";
import { runtimeObservationContractDigest, validateExternalInputs, verifyAcquiredDigest, verifyAptClosure } from "../src/external.js";

const valid = { consumer: "ci", id: "one", integrity: { algorithm: "sha256", digest: "a".repeat(64), source: "policy" }, kind: "toolchain", locator: "https:example.invalid/tool", producer: "verified download", retention: "ephemeral", secret_policy: "forbidden", trust: "trusted" };

test("external manifest schema separates trusted and evidence-only input", () => {
  assert.equal(validateExternalInputs([valid]).length, 1);
  const evidence = { ...valid, id: "evidence", kind: "evidence", trust: "evidence-only" } as const;
  assert.equal(validateExternalInputs([{ ...evidence, integrity: { algorithm: "sha256", digest: runtimeObservationContractDigest(evidence), source: "runtime-observation" } }]).length, 1);
});

test("observed, missing digest, promotion, unknown keys, and secret locators fail", () => {
  assert.throws(() => validateExternalInputs([{ ...valid, integrity: { algorithm: "observed", digest: "x", source: "policy" } }]));
  assert.throws(() => validateExternalInputs([{ ...valid, integrity: { ...valid.integrity, digest: "" } }]));
  assert.throws(() => validateExternalInputs([{ ...valid, integrity: { algorithm: "git-commit-sha1", digest: "a".repeat(64), source: "policy" } }]));
  assert.throws(() => validateExternalInputs([{ ...valid, integrity: { algorithm: "sha256", digest: "runtime-sha256", source: "policy" } }]));
  assert.throws(() => validateExternalInputs([{ ...valid, integrity: { ...valid.integrity, source: "runtime-observation" } }]));
  assert.throws(() => validateExternalInputs([{ ...valid, extra: true }]));
  assert.throws(() => validateExternalInputs([{ ...valid, locator: "workspace/.env.local" }]));
});

test("apt closure is complete, hashed, and verified before installation", () => {
  const downloaded = [{ coordinate: "lib:1:amd64", sha256: "a".repeat(64) }, { coordinate: "poppler-utils:2:amd64", sha256: "b".repeat(64) }];
  assert.doesNotThrow(() => verifyAptClosure(["poppler-utils:2:amd64", "lib:1:amd64"], downloaded, false));
  assert.throws(() => verifyAptClosure(["poppler-utils:2:amd64"], downloaded, false), /differs/);
  assert.throws(() => verifyAptClosure(["lib:1:amd64", "poppler-utils:2:amd64"], downloaded, true), /before/);
  assert.throws(() => verifyAptClosure(["lib:1:amd64"], [{ coordinate: "lib:1:amd64", sha256: "changed" }], false), /hash/);
});

test("post-download mutation invalidates predeclared integrity", () => {
  const acquired = Buffer.from("synthetic archive");
  assert.doesNotThrow(() => verifyAcquiredDigest(sha256(acquired), acquired));
  assert.throws(() => verifyAcquiredDigest(sha256(acquired), Buffer.from("synthetic archive changed")), /digest mismatch/);
});
