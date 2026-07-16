import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import ts from "typescript";

const root = process.cwd();
const hash = (path: string) => createHash("sha256").update(readFileSync(resolve(root, path))).digest("hex");

test("final summary verifies every dependent evidence digest and executable test count", () => {
  const summary = JSON.parse(readFileSync(resolve(root, "evidence/review/final-candidate.v1.json"), "utf8")) as Record<string, unknown>;
  assert.equal(summary.schema_version, 1); assert.match(summary.base_commit as string, /^[0-9a-f]{40}$/);
  assert.equal(summary.candidate_inventory_sha256, hash("evidence/review/candidate-tree.v1.jsonl"));
  assert.equal(summary.claim_matrix_sha256, hash("evidence/claim-matrix.v1.json"));
  assert.equal(summary.external_manifest_sha256, hash("policy/external-inputs.v1.jsonl"));
  assert.equal(summary.package_lock_sha256, hash("package-lock.json"));
  assert.equal(summary.policy_sha256, hash("policy/release-policy.v1.json"));
  assert.equal(summary.reproducibility_sha256, hash("evidence/review/reproducibility.v1.json"));

  let testCases = 0;
  for (const name of readdirSync(resolve(root, "test")).filter((value) => value.endsWith(".test.ts"))) {
    const source = readFileSync(resolve(root, "test", name), "utf8");
    const tree = ts.createSourceFile(name, source, ts.ScriptTarget.ES2022, false, ts.ScriptKind.TS);
    const visit = (node: ts.Node): void => {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "test") testCases += 1;
      ts.forEachChild(node, visit);
    };
    visit(tree);
  }
  assert.equal(summary.test_case_count, testCases);
});

test("review JSONL/JSON artifacts are strict LF/BOM-free and reproduction digests are algorithm-valid", () => {
  for (const path of ["evidence/review/candidate-tree.v1.jsonl", "policy/external-inputs.v1.jsonl"]) {
    const bytes = readFileSync(resolve(root, path));
    assert.equal(bytes.at(-1), 0x0a); assert.equal(bytes.includes(0x0d), false); assert.equal(bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])), false);
    for (const line of bytes.toString("utf8").trimEnd().split("\n")) assert.doesNotThrow(() => JSON.parse(line));
  }
  const reproduction = JSON.parse(readFileSync(resolve(root, "evidence/review/reproducibility.v1.json"), "utf8")) as Record<string, unknown>;
  assert.deepEqual(Object.keys(reproduction).sort(), ["base_commit", "build_sha256", "package_lock_sha256", "package_source_sha256", "pack_sha256", "sbom_sha256", "schema_version"].sort());
  for (const key of ["build_sha256", "package_lock_sha256", "package_source_sha256", "pack_sha256", "sbom_sha256"]) assert.match(reproduction[key] as string, /^[0-9a-f]{64}$/);
  assert.equal(reproduction.package_lock_sha256, hash("package-lock.json"));
});
