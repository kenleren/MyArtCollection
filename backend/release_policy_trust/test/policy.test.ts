import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { sha256 } from "../src/canonical.js";
import { assertCanonicalPolicy, loadCanonicalPolicy } from "../src/policy.js";
import { isProtected } from "../src/paths.js";
import * as policyRuntime from "../src/policy.js";

const bytes = readFileSync(resolve(process.cwd(), "policy/release-policy.v1.json"));

test("canonical policy computes its own raw-byte digest and owns every runtime input", () => {
  const policy = loadCanonicalPolicy(bytes);
  assert.equal(policy.digest, sha256(bytes));
  assert.equal(policy.repository.name, "kenleren/MyArtCollection");
  assert.equal(policy.checkName, "Archivale release policy trust");
  assert.equal(policy.limits.fileRows, policy.limits.filePages * policy.limits.pageSize);
  assert.ok(policy.pathPolicy.prefixes.includes(".github/"));
  assert.equal(policy.pathPolicy.exact.filter((path) => path === ".gitleaksignore").length, 1);
  assert.equal(isProtected(".gitleaksignore", policy.pathPolicy), true);
  assert.doesNotThrow(() => assertCanonicalPolicy(policy));
  assert.throws(() => assertCanonicalPolicy({ ...policy }), /canonical policy bytes/);
});

test("emitted JavaScript exposes no policy constructor and rejects prototype and symbol forgery", () => {
  assert.equal(Object.hasOwn(policyRuntime, "CanonicalReleasePolicy"), false);
  const policy = loadCanonicalPolicy(bytes);
  const runtimeConstructor = Object.getPrototypeOf(policy).constructor as new (...input: unknown[]) => object;
  assert.throws(() => Reflect.construct(runtimeConstructor, [{}, {
    baseCommit: policy.baseCommit,
    checkName: policy.checkName,
    digest: policy.digest,
    limits: policy.limits,
    pathPolicy: { exact: [], prefixes: [] },
  }]), /construction is private/);

  const forged = Object.create(Object.getPrototypeOf(policy)) as object;
  Object.defineProperties(forged, Object.getOwnPropertyDescriptors(policy));
  for (const symbol of Object.getOwnPropertySymbols(policy)) Object.defineProperty(forged, symbol, Object.getOwnPropertyDescriptor(policy, symbol)!);
  assert.throws(() => assertCanonicalPolicy(forged), /canonical policy bytes/);
});

test("policy rejects unknown keys, binds selector substitution to a new digest, and rejects inconsistent limits/repository drift", () => {
  const source = JSON.parse(bytes.toString("utf8")) as Record<string, unknown>;
  const encode = (value: unknown) => Buffer.from(`${JSON.stringify(value)}\n`);
  assert.throws(() => loadCanonicalPolicy(encode({ ...source, extra: true })), /keys mismatch/);
  const selectors = source.selectors as Record<string, unknown>;
  const substituted = loadCanonicalPolicy(encode({ ...source, selectors: { ...selectors, baseline_exact: [], baseline_prefixes: [], final_exact_additions: [], final_prefix_additions: [] } }));
  assert.notEqual(substituted.digest, sha256(bytes)); assert.deepEqual(substituted.pathPolicy, { exact: [], prefixes: [] });
  const limits = source.limits as Record<string, unknown>;
  assert.throws(() => loadCanonicalPolicy(encode({ ...source, limits: { ...limits, file_rows: 2999 } })), /inconsistent/);
  assert.throws(() => loadCanonicalPolicy(encode({ ...source, repository: { base_ref: "main", name: "attacker/repository" } })), /identity mismatch/);
});
