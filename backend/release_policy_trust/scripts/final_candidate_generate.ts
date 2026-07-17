import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import ts from "typescript";
import { git, hashFile, packageRoot, policyPath, repoRoot } from "./shared.js";

function hashBytes(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

const trackedPackagePaths = (git(["ls-files", "backend/release_policy_trust"], { encoding: "utf8" }) as string).trim().split("\n").filter(Boolean);
let testCaseCount = 0;
for (const path of trackedPackagePaths.filter((value) => value.startsWith("backend/release_policy_trust/test/"))) {
  if (!path.endsWith(".test.ts")) continue;
  const source = readFileSync(resolve(repoRoot, path), "utf8");
  const tree = ts.createSourceFile(path, source, ts.ScriptTarget.ES2022, false, ts.ScriptKind.TS);
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "test") testCaseCount += 1;
    ts.forEachChild(node, visit);
  };
  visit(tree);
}

const inventoryPath = resolve(packageRoot, "evidence/review/candidate-tree.v1.jsonl");
const reproductionPath = resolve(packageRoot, "evidence/review/reproducibility.v1.json");
const summary = {
  base_commit: "f42582c8eb0d1405cd5e214f6b9c80980225b5f1",
  candidate_inventory_sha256: hashBytes(readFileSync(inventoryPath)),
  claim_matrix_sha256: hashFile(resolve(packageRoot, "evidence/claim-matrix.v1.json")),
  external_manifest_sha256: hashFile(resolve(packageRoot, "policy/external-inputs.v1.jsonl")),
  package_file_count: trackedPackagePaths.length,
  package_lock_sha256: hashFile(resolve(packageRoot, "package-lock.json")),
  policy_sha256: hashFile(policyPath),
  protected_file_count: 52 + trackedPackagePaths.length,
  reproducibility_sha256: hashFile(reproductionPath),
  schema_version: 1,
  test_case_count: testCaseCount,
};
writeFileSync(resolve(packageRoot, "evidence/review/final-candidate.v1.json"), `${JSON.stringify(summary, null, 2)}\n`);
