import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { isProtected } from "../src/paths.js";
import { verifyFrozenBaseAndCandidate } from "./git_anchors.js";
import { argument, git, hashBytes, loadPolicy, repoRoot, validateOid } from "./shared.js";

const base = validateOid(argument("--base"));
const candidate = validateOid(argument("--candidate"));
const policy = loadPolicy();
if (base !== policy.base_commit) throw new Error("base differs from frozen policy base");
verifyFrozenBaseAndCandidate(repoRoot, base, candidate);

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
for (let index = 0; index < output.length; index += 1) if (output[index] === 0) {
  const chunk = output.subarray(start, index); start = index + 1;
  const tab = chunk.indexOf(0x09);
  const metadata = chunk.subarray(0, tab).toString("ascii").split(" ");
  const path = new TextDecoder("utf-8", { fatal: true }).decode(chunk.subarray(tab + 1));
  if (path.normalize("NFC") !== path || !["100644", "100755"].includes(metadata[0]!) || metadata[1] !== "blob") throw new Error("candidate tree contains unsupported row");
  const protectedPath = isProtected(path, finalPolicy);
  if (protectedPath) protectedCount += 1;
  if (path.startsWith("backend/release_policy_trust/")) packageCount += 1;
  if (!path.startsWith("backend/release_policy_trust/evidence/review/")) candidateRows.push(JSON.stringify({ blob_oid: metadata[2], class: protectedPath ? "protected-control" : "evaluated-input", mode: metadata[0], path }));
}
if (protectedCount !== 52 + packageCount) throw new Error(`final protected count mismatch: ${protectedCount} != 52 + ${packageCount}`);
const summary = JSON.parse(readFileSync(resolve(repoRoot, "backend/release_policy_trust/evidence/review/final-candidate.v1.json"), "utf8")) as Record<string, unknown>;
const inventoryBytes = Buffer.from(`${candidateRows.join("\n")}\n`);
const committedInventory = readFileSync(resolve(repoRoot, "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl"));
if (Buffer.compare(inventoryBytes, committedInventory) !== 0) throw new Error("candidate JSONL diverges from exact candidate");
if (summary.base_commit !== base || summary.package_file_count !== packageCount || summary.protected_file_count !== protectedCount || summary.candidate_inventory_sha256 !== hashBytes(inventoryBytes)) throw new Error("final candidate summary diverges from exact candidate");
