import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const option = (name) => { const index = process.argv.indexOf(`--${name}`); return index < 0 ? undefined : process.argv[index + 1]; };
const phase = option("phase");
const start = option("start");
const artifactPath = "backend/release_policy_workers_free/evidence/sbom.spdx.json";
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const git = (...args) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" });
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fail = (message) => { throw new Error(`phase guard: ${message}`); };
const regular = (path) => existsSync(path) && lstatSync(path).isFile() && !lstatSync(path).isSymbolicLink();
const required = (value, name) => { if (!value) fail(`${name} required`); return value; };
const cleanIndex = () => { try { git("diff", "--cached", "--quiet", "--exit-code"); } catch { fail("index must be empty"); } };
const pathFromRoot = (path) => { const result = relative(root, resolve(path)); if (!result || result.startsWith("..") || isAbsolute(result)) fail("path outside repository"); return result; };
const startBytes = (oid, path) => Buffer.from(git("show", `${oid}:${path}`));
const hashAt = (oid, path) => hash(startBytes(oid, path));
const writeCanonical = (path, value) => writeFileSync(path, `${JSON.stringify(value)}\n`, { flag: "wx" });
const reproductionPath = "backend/release_policy_trust/evidence/review/reproducibility.v1.json";
export const mandatoryBDelta = [
  "M\tbackend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl",
  "M\tbackend/release_policy_trust/evidence/review/final-candidate.v1.json",
  "D\tbackend/release_policy_workers_free/evidence/artifact-manifest.v1.json",
  "M\tbackend/release_policy_workers_free/evidence/artifact-manifest.v2.json",
  "M\tbackend/release_policy_workers_free/evidence/sbom.spdx.json",
];
const reproductionDelta = `M\t${reproductionPath}`;

export function expectedBDelta(reproductionDiffers) {
  return reproductionDiffers
    ? [mandatoryBDelta[0], mandatoryBDelta[1], reproductionDelta, ...mandatoryBDelta.slice(2)]
    : mandatoryBDelta;
}

export function assertBDelta(delta, reproductionDiffers) {
  if (JSON.stringify(delta) !== JSON.stringify(expectedBDelta(reproductionDiffers))) fail("B path set rejected");
}

function reproductionDiffersFromAnchor(anchor) {
  const temporary = mkdtempSync(join(tmpdir(), "release-policy-phase-guard-"));
  try {
    const output = resolve(temporary, "reproducibility.v1.json");
    execFileSync("npm", ["--prefix", "backend/release_policy_trust", "run", "reproduce", "--", "--source-commit", anchor, "--output", output], {
      cwd: root,
      env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C" },
      stdio: "inherit",
    });
    const regenerated = readFileSync(output);
    const differs = !regenerated.equals(startBytes(anchor, reproductionPath));
    if (differs) {
      const worktreeRecord = resolve(root, reproductionPath);
      if (!regular(worktreeRecord) || !readFileSync(worktreeRecord).equals(regenerated)) fail("regenerated reproduction record is not staged truth");
    }
    return differs;
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function preservationDirectory() {
  const directory = required(option("preservation-dir"), "preservation directory");
  if (!isAbsolute(directory) || resolve(directory).startsWith(`${root}/`)) fail("preservation directory must be absolute and external");
  return resolve(directory);
}

function expectedRecord(record) {
  const keys = ["schema_version", "repository_path", "mode", "start_oid", "start_epoch", "start_sha256", "start_bytes", "current_sha256", "current_bytes", "lock_sha256", "lock_bytes", "source_generator_sha256", "compiled_generator_sha256", "reproduced_sha256", "reproduced_bytes", "namespace", "created", "package_count", "relationship_count", "byte_reproduced"];
  return record && typeof record === "object" && !Array.isArray(record) && JSON.stringify(Object.keys(record)) === JSON.stringify(keys) && record.schema_version === 1 && record.repository_path === artifactPath && record.mode === "100644" && record.byte_reproduced === true;
}

function preserve() {
  const oid = required(start, "start"); const path = required(option("path"), "path"); const directory = preservationDirectory();
  if (path !== artifactPath || git("rev-parse", "HEAD").trim() !== oid || !/^[0-9a-f]{40}$/.test(oid)) fail("preservation start rejected");
  cleanIndex();
  const worktree = resolve(root, path); const startSnapshot = startBytes(oid, path); const current = readFileSync(worktree);
  if (hash(startSnapshot) !== "a75297dec1cb0a698f395e0c4560b104f6bfd500d0094423261fc8a60cd4a6a4" || hash(current) !== "a5876a8213e890b65ae23bb8564b222341ae42fa2f9c3302f8e5610579c099fb") fail("preservation bytes drifted");
  if (existsSync(directory)) fail("preservation directory must not exist");
  mkdirSync(resolve(directory, "repro", "evidence"), { recursive: true, mode: 0o700 });
  copyFileSync(worktree, resolve(directory, "current.spdx.json"));
  writeFileSync(resolve(directory, "start.spdx.json"), startSnapshot, { flag: "wx" });
  const packageRoot = resolve(root, "backend/release_policy_workers_free");
  const lock = resolve(packageRoot, "package-lock.json"); const source = resolve(packageRoot, "scripts/sbom.ts"); const compiled = resolve(packageRoot, "dist/scripts/sbom.js");
  copyFileSync(lock, resolve(directory, "repro/package-lock.json"));
  // The preserved compiled generator is executed with its root set to the external
  // repro directory. GIT_DIR/WORK_TREE retain only immutable START identity.
  execFileSync(process.execPath, [compiled], { cwd: resolve(directory, "repro"), env: { ...process.env, GIT_DIR: resolve(root, ".git"), GIT_WORK_TREE: root, TZ: "UTC", LC_ALL: "C", LANG: "C" }, stdio: "inherit" });
  const reproduced = readFileSync(resolve(directory, "repro/evidence/sbom.spdx.json"));
  if (!current.equals(reproduced)) fail("preserved SBOM did not byte reproduce");
  const doc = JSON.parse(current.toString("utf8"));
  if (!doc || !Array.isArray(doc.packages) || !Array.isArray(doc.relationships) || typeof doc.documentNamespace !== "string" || typeof doc.creationInfo?.created !== "string") fail("preserved SBOM structure rejected");
  const epoch = Number(git("show", "-s", "--format=%ct", oid).trim());
  const record = { schema_version: 1, repository_path: path, mode: "100644", start_oid: oid, start_epoch: epoch, start_sha256: hash(startSnapshot), start_bytes: startSnapshot.length, current_sha256: hash(current), current_bytes: current.length, lock_sha256: hash(readFileSync(lock)), lock_bytes: readFileSync(lock).length, source_generator_sha256: hash(readFileSync(source)), compiled_generator_sha256: hash(readFileSync(compiled)), reproduced_sha256: hash(reproduced), reproduced_bytes: reproduced.length, namespace: doc.documentNamespace, created: doc.creationInfo.created, package_count: doc.packages.length, relationship_count: doc.relationships.length, byte_reproduced: true };
  writeCanonical(resolve(directory, "record.v1.json"), record);
  writeFileSync(resolve(directory, "KEEP_UNTIL_FINAL_B"), `${hash(readFileSync(resolve(directory, "record.v1.json")))}\n`, { flag: "wx" });
}

function verifyPreservation() {
  const oid = required(start, "start"); const path = required(option("path"), "path"); const directory = preservationDirectory(); const state = required(option("expected-state"), "expected state");
  if (path !== artifactPath || !regular(resolve(directory, "KEEP_UNTIL_FINAL_B")) || !regular(resolve(directory, "record.v1.json")) || !regular(resolve(directory, "current.spdx.json")) || !regular(resolve(directory, "start.spdx.json")) || !regular(resolve(directory, "repro/package-lock.json")) || !regular(resolve(directory, "repro/evidence/sbom.spdx.json"))) fail("preservation files missing");
  const recordBytes = readFileSync(resolve(directory, "record.v1.json")); const record = JSON.parse(recordBytes.toString("utf8"));
  if (!expectedRecord(record) || record.start_oid !== oid || hash(recordBytes) !== readFileSync(resolve(directory, "KEEP_UNTIL_FINAL_B"), "utf8").trim()) fail("preservation record rejected");
  const current = readFileSync(resolve(directory, "current.spdx.json")); const copiedStart = readFileSync(resolve(directory, "start.spdx.json")); const repro = readFileSync(resolve(directory, "repro/evidence/sbom.spdx.json"));
  if (hash(current) !== record.current_sha256 || !current.equals(repro) || hash(copiedStart) !== record.start_sha256 || !copiedStart.equals(startBytes(oid, path))) fail("preservation byte drift");
  const worktree = readFileSync(resolve(root, path));
  if (state === "dirty" && !worktree.equals(current)) fail("dirty SBOM unexpectedly changed");
  if (["restored", "anchored-a"].includes(state) && !worktree.equals(copiedStart)) fail("START SBOM not retained");
  if (state === "anchored-a") { const anchor = required(option("anchor"), "anchor"); if (!startBytes(anchor, path).equals(copiedStart)) fail("A SBOM not START placeholder"); }
  if (["generated-b", "final-clean"].includes(state)) { const anchor = required(option("anchor"), "anchor"); const final = worktree; const reproducedFinal = resolve(directory, "final-reproduced.spdx.json"); if (!regular(reproducedFinal) || !final.equals(readFileSync(reproducedFinal)) || final.equals(current)) fail("final SBOM preservation semantics rejected"); const doc = JSON.parse(final.toString("utf8")); const epoch = Number(git("show", "-s", "--format=%ct", anchor).trim()); if (!doc.documentNamespace.includes(anchor) || doc.creationInfo?.created !== new Date(epoch * 1000).toISOString().replace(".000", "")) fail("final SBOM anchor rejected"); }
  if (state === "final-clean") cleanIndex();
}

function main() {
if (phase === "preserve-sbom") preserve();
else if (phase === "verify-sbom-preservation") verifyPreservation();
else if (["prepared", "a-worktree", "a-index", "b-worktree", "b-index", "final"].includes(phase)) {
  if (git("rev-parse", "--abbrev-ref", "HEAD").trim() !== "codex/issue-245-workers-free-adapter") fail("branch rejected");
  if (option("base") && git("merge-base", option("base"), "HEAD").trim() !== option("base")) fail("base rejected");
  const bPaths = [artifactPath, "backend/release_policy_workers_free/evidence/artifact-manifest.v1.json", "backend/release_policy_workers_free/evidence/artifact-manifest.v2.json", "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl", "backend/release_policy_trust/evidence/review/reproducibility.v1.json", "backend/release_policy_trust/evidence/review/final-candidate.v1.json"];
  if (phase === "prepared") { cleanIndex(); const oid = required(start, "start"); for (const path of bPaths) { const working = resolve(root, path); const inStart = (() => { try { startBytes(oid, path); return true; } catch { return false; } })(); if (existsSync(working) !== inStart || (inStart && !readFileSync(working).equals(startBytes(oid, path)))) fail(`pre-A B path drift: ${path}`); } }
  if (phase === "a-worktree") cleanIndex();
  if (phase === "a-index") { const staged = git("diff", "--cached", "--name-only").trim().split("\n").filter(Boolean); if (staged.some((path) => bPaths.includes(path))) fail("B path staged in A"); }
  if (phase === "b-worktree") cleanIndex();
  if (phase === "b-index") { const anchor = required(option("anchor"), "anchor"); const staged = git("diff", "--cached", "--name-status", anchor).trim().split("\n").filter(Boolean); assertBDelta(staged, reproductionDiffersFromAnchor(anchor)); }
  if (phase === "final") { const anchor = required(option("anchor"), "anchor"); const candidate = required(option("candidate"), "candidate"); if (git("rev-parse", `${candidate}^`).trim() !== anchor) fail("B parent rejected"); const delta = git("diff", "--name-status", anchor, candidate).trim().split("\n").filter(Boolean); assertBDelta(delta, reproductionDiffersFromAnchor(anchor)); cleanIndex(); }
} else fail("phase rejected");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
