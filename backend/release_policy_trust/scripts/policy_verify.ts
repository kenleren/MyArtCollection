import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { isProtected } from "../src/paths.js";
import ts from "typescript";
import { verifyFrozenBaseAndCandidate } from "./git_anchors.js";
import { argument, externalPath, git, hashBytes, hashFile, loadPolicy, packageRoot, policyPath, repoRoot, validateOid } from "./shared.js";

const base = validateOid(argument("--base"));
const candidate = validateOid(argument("--candidate"));
const expectedMain = validateOid(argument("--expected-main"));
const mode = argument("--mode");
if (mode !== "frozen-bootstrap-pr" && mode !== "post-merge-main") throw new Error("unsupported anchor verification mode");
const policy = loadPolicy();
if (base !== policy.base_commit) throw new Error("base differs from frozen policy base");
verifyFrozenBaseAndCandidate(repoRoot, base, candidate, { expectedMain, mode });

const allowedExact = new Set([".github/workflows/release-readiness.yml", ".github/CODEOWNERS", "docs/RELEASE_READINESS_CI.md", "docs/RELEASE_POLICY_TRUST.md"]);
const changed = (git(["diff", "--name-only", "-z", base, candidate]) as Buffer).subarray(0).toString("utf8").split("\0").filter(Boolean);
for (const path of changed) if (!path.startsWith("backend/release_policy_trust/") && !allowedExact.has(path)) throw new Error(`out-of-scope path changed: ${path}`);
for (const path of allowedExact) if (!changed.includes(path)) throw new Error(`required shared surface is unchanged: ${path}`);

const output = git(["ls-tree", "-rz", "--full-tree", candidate]) as Buffer;
const finalPolicy = { exact: [...policy.selectors.baseline_exact, ...policy.selectors.final_exact_additions], prefixes: [...policy.selectors.baseline_prefixes, ...policy.selectors.final_prefix_additions] };
let protectedCount = 0;
let packageCount = 0;
let start = 0;
const candidateRows: string[] = [];
const candidateTestPaths: string[] = [];
for (let index = 0; index < output.length; index += 1) if (output[index] === 0) {
  const chunk = output.subarray(start, index); start = index + 1;
  const tab = chunk.indexOf(0x09);
  const metadata = chunk.subarray(0, tab).toString("ascii").split(" ");
  const path = new TextDecoder("utf-8", { fatal: true }).decode(chunk.subarray(tab + 1));
  if (path.normalize("NFC") !== path || !["100644", "100755"].includes(metadata[0]!) || metadata[1] !== "blob") throw new Error("candidate tree contains unsupported row");
  const protectedPath = isProtected(path, finalPolicy);
  if (protectedPath) protectedCount += 1;
  if (path.startsWith("backend/release_policy_trust/")) packageCount += 1;
  if (/^backend\/release_policy_trust\/test\/.*\.test\.ts$/.test(path)) candidateTestPaths.push(path);
  if (!path.startsWith("backend/release_policy_trust/evidence/review/")) candidateRows.push(JSON.stringify({ blob_oid: metadata[2], class: protectedPath ? "protected-control" : "evaluated-input", mode: metadata[0], path }));
}
if (protectedCount !== 52 + packageCount) throw new Error(`final protected count mismatch: ${protectedCount} != 52 + ${packageCount}`);
const summaryPath = resolve(packageRoot, "evidence/review/final-candidate.v1.json");
const summary = JSON.parse(readFileSync(summaryPath, "utf8")) as Record<string, unknown>;
const summaryKeys = ["base_commit", "candidate_inventory_sha256", "claim_matrix_sha256", "external_manifest_sha256", "package_file_count", "package_lock_sha256", "policy_sha256", "protected_file_count", "reproducibility_sha256", "schema_version", "test_case_count"];
if (Object.keys(summary).sort().join("\0") !== summaryKeys.sort().join("\0")) throw new Error("final candidate summary keys mismatch");
const inventoryBytes = Buffer.from(`${candidateRows.join("\n")}\n`);
const committedInventory = readFileSync(resolve(repoRoot, "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl"));
if (Buffer.compare(inventoryBytes, committedInventory) !== 0) throw new Error("candidate JSONL diverges from exact candidate");
let testCaseCount = 0;
for (const path of candidateTestPaths) {
  const source = git(["show", `${candidate}:${path}`], { encoding: "utf8" }) as string;
  const tree = ts.createSourceFile(path, source, ts.ScriptTarget.ES2022, false, ts.ScriptKind.TS);
  const visit = (node: ts.Node): void => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "test") testCaseCount += 1;
    ts.forEachChild(node, visit);
  };
  visit(tree);
}
const claimMatrixPath = resolve(packageRoot, "evidence/claim-matrix.v1.json");
const reproducibilityPath = resolve(packageRoot, "evidence/review/reproducibility.v1.json");
const reproduction = JSON.parse(readFileSync(reproducibilityPath, "utf8")) as Record<string, unknown>;
const reproductionKeys = ["base_commit", "build_sha256", "package_lock_sha256", "package_source_sha256", "pack_sha256", "sbom_sha256", "schema_version"];
if (Object.keys(reproduction).sort().join("\0") !== reproductionKeys.sort().join("\0") || reproduction.schema_version !== 1 || reproduction.base_commit !== base || reproduction.package_lock_sha256 !== hashFile(resolve(packageRoot, "package-lock.json"))) throw new Error("reproducibility summary metadata mismatch");
for (const key of ["build_sha256", "package_lock_sha256", "package_source_sha256", "pack_sha256", "sbom_sha256"]) if (typeof reproduction[key] !== "string" || !/^[0-9a-f]{64}$/.test(reproduction[key] as string)) throw new Error(`reproducibility digest malformed: ${key}`);
if (
  summary.schema_version !== 1 ||
  summary.base_commit !== base ||
  summary.package_file_count !== packageCount ||
  summary.protected_file_count !== protectedCount ||
  summary.test_case_count !== testCaseCount ||
  summary.candidate_inventory_sha256 !== hashBytes(inventoryBytes) ||
  summary.claim_matrix_sha256 !== hashFile(claimMatrixPath) ||
  summary.external_manifest_sha256 !== hashFile(externalPath) ||
  summary.package_lock_sha256 !== hashFile(resolve(packageRoot, "package-lock.json")) ||
  summary.policy_sha256 !== hashFile(policyPath) ||
  summary.reproducibility_sha256 !== hashFile(reproducibilityPath)
) throw new Error("final candidate summary diverges from exact candidate or dependent evidence");
