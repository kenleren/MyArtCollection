import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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
  "A\tbackend/release_policy_workers_free/evidence/artifact-manifest.v2.json",
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

const sbomNamespace = /^https:\/\/archivale\.app\/spdx\/release-policy-workers-free\/([0-9a-f]{40})\/([0-9a-f]{64})$/;
const within = (parent, child) => child === parent || child.startsWith(`${parent}/`);
const regularInput = (path, label) => { if (!regular(path)) fail(`${label} must be a regular nonsymlink file`); return readFileSync(path); };
function assertPreservationTree(directory, state) {
  const expected = new Set(["KEEP_UNTIL_FINAL_B", "current.spdx.json", "record.v1.json", "repro/evidence/sbom.spdx.json", "repro/package-lock.json", "start.spdx.json", ...(state === "generated-b" || state === "final-clean" ? ["final-reproduced.spdx.json"] : [])]);
  const seen = [];
  const visit = (relativePath = "") => {
    for (const entry of readdirSync(resolve(directory, relativePath), { withFileTypes: true })) {
      const child = relativePath ? `${relativePath}/${entry.name}` : entry.name; const stat = lstatSync(resolve(directory, child));
      if (stat.isSymbolicLink()) fail("preservation symlink rejected");
      if (stat.isDirectory()) visit(child); else if (stat.isFile()) seen.push(child); else fail("preservation type rejected");
    }
  };
  visit();
  if (JSON.stringify(seen.sort()) !== JSON.stringify([...expected].sort())) fail("preservation file allowlist rejected");
  for (const path of expected) regularInput(resolve(directory, path), "preservation input");
}
function parseSpdx(bytes, lockBytes) {
  let doc; try { doc = JSON.parse(bytes.toString("utf8")); } catch { fail("SBOM document rejected"); }
  const match = typeof doc?.documentNamespace === "string" ? doc.documentNamespace.match(sbomNamespace) : null;
  if (!match || hash(lockBytes) !== match[2]) fail("SBOM namespace rejected");
  const anchor = match[1]; try { git("cat-file", "-e", `${anchor}^{commit}`); } catch { fail("SBOM anchor rejected"); }
  const epoch = Number(git("show", "-s", "--format=%ct", anchor).trim());
  if (!Number.isSafeInteger(epoch) || doc.spdxVersion !== "SPDX-2.3" || doc.SPDXID !== "SPDXRef-DOCUMENT" || doc.dataLicense !== "CC0-1.0" || doc.creationInfo?.created !== new Date(epoch * 1000).toISOString().replace(".000", "") || !Array.isArray(doc.packages) || doc.packages.length === 0 || !Array.isArray(doc.relationships)) fail("SBOM document rejected");
  const ids = new Set(); for (const pkg of doc.packages) { if (!pkg || typeof pkg !== "object" || typeof pkg.SPDXID !== "string" || ids.has(pkg.SPDXID) || typeof pkg.name !== "string" || typeof pkg.versionInfo !== "string" || pkg.downloadLocation !== "NOASSERTION" || pkg.filesAnalyzed !== false || pkg.licenseConcluded !== "NOASSERTION" || pkg.licenseDeclared !== "NOASSERTION" || pkg.copyrightText !== "NOASSERTION") fail("SBOM package rejected"); ids.add(pkg.SPDXID); }
  if (!doc.relationships.some((row) => row && typeof row === "object" && row.spdxElementId === "SPDXRef-DOCUMENT" && row.relationshipType === "DESCRIBES" && ids.has(row.relatedSpdxElement))) fail("SBOM relationship rejected");
  for (const row of doc.relationships) if (!row || typeof row !== "object" || (!ids.has(row.spdxElementId) && row.spdxElementId !== "SPDXRef-DOCUMENT") || !ids.has(row.relatedSpdxElement)) fail("SBOM relationship rejected");
  return { anchor, namespace: doc.documentNamespace, created: doc.creationInfo.created, package_count: doc.packages.length, relationship_count: doc.relationships.length };
}
function runGenerator(anchor, output, lock) {
  execFileSync(process.execPath, [resolve(root, "backend/release_policy_workers_free/dist/scripts/sbom.js"), "--anchor", anchor, "--output", output, "--lock", lock], { cwd: resolve(root, "backend/release_policy_workers_free"), env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C" }, stdio: "inherit" });
}
function canonicalRecord(start, startBytes, currentBytes, lockBytes, reproducedBytes, document) {
  return { schema_version: 1, repository_path: artifactPath, mode: "100644", start_oid: start, start_epoch: Number(git("show", "-s", "--format=%ct", start).trim()), start_sha256: hash(startBytes), start_bytes: startBytes.length, current_sha256: hash(currentBytes), current_bytes: currentBytes.length, lock_sha256: hash(lockBytes), lock_bytes: lockBytes.length, source_generator_sha256: hash(readFileSync(resolve(root, "backend/release_policy_workers_free/scripts/sbom.ts"))), compiled_generator_sha256: hash(readFileSync(resolve(root, "backend/release_policy_workers_free/dist/scripts/sbom.js"))), reproduced_sha256: hash(reproducedBytes), reproduced_bytes: reproducedBytes.length, namespace: document.namespace, created: document.created, package_count: document.package_count, relationship_count: document.relationship_count, byte_reproduced: currentBytes.equals(reproducedBytes) };
}

function preserve() {
  const oid = required(start, "start"); const path = required(option("path"), "path"); const directory = preservationDirectory();
  if (path !== artifactPath || git("rev-parse", "HEAD").trim() !== oid || !/^[0-9a-f]{40}$/.test(oid)) fail("preservation start rejected");
  cleanIndex();
  const worktree = resolve(root, path); if (!regular(worktree)) fail("SBOM worktree input rejected");
  const parent = realpathSync(dirname(directory)); if (within(root, parent)) fail("preservation directory must be external");
  const startSnapshot = startBytes(oid, path); const current = regularInput(worktree, "SBOM worktree input"); const lock = resolve(root, "backend/release_policy_workers_free/package-lock.json"); const lockBytes = regularInput(lock, "lock input");
  const tree = git("ls-tree", "-r", oid, "--", path).trim().split(/\s+/); if (tree[0] !== "100644") fail("SBOM mode rejected");
  if (existsSync(directory)) fail("preservation directory must not exist");
  mkdirSync(resolve(directory, "repro", "evidence"), { recursive: true, mode: 0o700 });
  const canonicalDirectory = realpathSync(directory); if (within(root, canonicalDirectory)) fail("preservation directory redirection rejected");
  writeFileSync(resolve(directory, "current.spdx.json"), current, { flag: "wx" }); writeFileSync(resolve(directory, "start.spdx.json"), startSnapshot, { flag: "wx" }); writeFileSync(resolve(directory, "repro/package-lock.json"), lockBytes, { flag: "wx" });
  const document = parseSpdx(current, lockBytes); const reproducedPath = resolve(directory, "repro/evidence/sbom.spdx.json"); runGenerator(document.anchor, reproducedPath, resolve(directory, "repro/package-lock.json"));
  const reproduced = regularInput(reproducedPath, "reproduced SBOM"); if (!current.equals(reproduced)) fail("preserved SBOM did not byte reproduce");
  if (!regularInput(worktree, "SBOM worktree input").equals(current)) fail("preservation capture drift");
  const record = canonicalRecord(oid, startSnapshot, current, lockBytes, reproduced, document);
  writeCanonical(resolve(directory, "record.v1.json"), record);
  writeFileSync(resolve(directory, "KEEP_UNTIL_FINAL_B"), `${hash(readFileSync(resolve(directory, "record.v1.json")))}\n`, { flag: "wx" });
  assertPreservationTree(directory, "dirty");
}

function verifyPreservation() {
  const oid = required(start, "start"); const path = required(option("path"), "path"); const directory = preservationDirectory(); const state = required(option("expected-state"), "expected state");
  if (path !== artifactPath || !/^[0-9a-f]{40}$/.test(oid) || !["dirty", "restored", "anchored-a", "generated-b", "final-clean"].includes(state)) fail("preservation verification rejected");
  const parent = realpathSync(dirname(directory)); if (within(root, parent) || !lstatSync(directory).isDirectory() || lstatSync(directory).isSymbolicLink()) fail("preservation directory rejected");
  assertPreservationTree(directory, state);
  const recordBytes = regularInput(resolve(directory, "record.v1.json"), "record"); let record; try { record = JSON.parse(recordBytes.toString("utf8")); } catch { fail("preservation record rejected"); }
  const current = regularInput(resolve(directory, "current.spdx.json"), "current snapshot"); const copiedStart = regularInput(resolve(directory, "start.spdx.json"), "start snapshot"); const lock = regularInput(resolve(directory, "repro/package-lock.json"), "lock snapshot"); const repro = regularInput(resolve(directory, "repro/evidence/sbom.spdx.json"), "reproduction"); if (!lock.equals(regularInput(resolve(root, "backend/release_policy_workers_free/package-lock.json"), "lock input"))) fail("preservation lock drift"); const document = parseSpdx(current, lock);
  const expected = canonicalRecord(oid, copiedStart, current, lock, repro, document);
  if (!expectedRecord(record) || JSON.stringify(record) !== JSON.stringify(expected) || hash(recordBytes) !== regularInput(resolve(directory, "KEEP_UNTIL_FINAL_B"), "marker").toString("utf8").trim() || !copiedStart.equals(startBytes(oid, path)) || !current.equals(repro)) fail("preservation byte drift");
  const worktree = regularInput(resolve(root, path), "SBOM worktree input");
  if (state === "dirty" && !worktree.equals(current)) fail("dirty SBOM unexpectedly changed");
  if (["restored", "anchored-a"].includes(state) && !worktree.equals(copiedStart)) fail("START SBOM not retained");
  if (state === "anchored-a") { const anchor = required(option("anchor"), "anchor"); if (!startBytes(anchor, path).equals(copiedStart)) fail("A SBOM not START placeholder"); }
  if (["generated-b", "final-clean"].includes(state)) { const anchor = required(option("anchor"), "anchor"); const final = worktree; const reproducedFinal = regularInput(resolve(directory, "final-reproduced.spdx.json"), "final reproduction"); const finalDocument = parseSpdx(final, lock); if (finalDocument.anchor !== anchor || !final.equals(reproducedFinal) || final.equals(current)) fail("final SBOM preservation semantics rejected"); }
  if (state === "final-clean") cleanIndex();
}

const overlayPaths = [
  "backend/release_policy_workers_free/evidence/sbom.spdx.json",
  "backend/release_policy_workers_free/evidence/artifact-manifest.v1.json",
  "backend/release_policy_workers_free/evidence/artifact-manifest.v2.json",
];
const overlayDelta = [
  `M\t${overlayPaths[0]}`,
  `D\t${overlayPaths[1]}`,
  `A\t${overlayPaths[2]}`,
];
const candidatePath = "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl";
const summaryPath = "backend/release_policy_trust/evidence/review/final-candidate.v1.json";
function stagedMode(path) {
  const row = git("ls-files", "--stage", "--", path).trim().split(/\s+/);
  return row.length >= 3 ? row[0] : "";
}
function assertOverlayIndex(anchor, allowEvidenceWorktree = false) {
  const delta = git("diff", "--cached", "--name-status", anchor).trim().split("\n").filter(Boolean);
  if (JSON.stringify([...delta].sort()) !== JSON.stringify([...overlayDelta].sort())) fail("overlay index rejected");
  if (stagedMode(overlayPaths[0]) !== "100644" || stagedMode(overlayPaths[2]) !== "100644" || stagedMode(overlayPaths[1]) !== "") fail("overlay index modes rejected");
  if (!regular(resolve(root, overlayPaths[0])) || !regular(resolve(root, overlayPaths[2])) || existsSync(resolve(root, overlayPaths[1]))) fail("overlay worktree topology rejected");
  const overlay = JSON.parse(readFileSync(resolve(root, "backend/release_policy_workers_free/config/phase-b-overlay.v1.json"), "utf8"));
  if (JSON.stringify(overlay.map((row) => [row.operation, row.path])) !== JSON.stringify([["replace", overlayPaths[0]], ["delete", overlayPaths[1]], ["add", overlayPaths[2]]])) fail("overlay manifest rejected");
  for (const path of overlayPaths) {
    if (path === overlayPaths[1]) continue;
    const staged = Buffer.from(git("show", `:${path}`)); if (!staged.equals(readFileSync(resolve(root, path)))) fail("overlay staged bytes rejected");
  }
  const evidence = [candidatePath, summaryPath, reproductionPath];
  if (evidence.some((path) => !git("diff", "--cached", "--quiet", "--", path) === false)) fail("evidence index rejected");
  const worktreeDelta = git("diff", "--name-only").trim().split("\n").filter(Boolean);
  const allowed = allowEvidenceWorktree ? [candidatePath, summaryPath] : [];
  if (worktreeDelta.some((path) => !allowed.includes(path))) fail("overlay worktree rejected");
}
function regenerateOverlayEvidence(anchor, expectedCandidate, expectedSummary) {
  const temporary = mkdtempSync(join(tmpdir(), "release-policy-overlay-"));
  try {
    const candidate = resolve(temporary, "candidate-tree.v1.jsonl"); const summary = resolve(temporary, "final-candidate.v1.json");
    execFileSync("npm", ["--prefix", "backend/release_policy_trust", "run", "candidate:generate", "--", "--candidate-base", anchor, "--overlay-manifest", "backend/release_policy_workers_free/config/phase-b-overlay.v1.json", "--output", candidate], { cwd: root, env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C" }, stdio: "inherit" });
    execFileSync("npm", ["--prefix", "backend/release_policy_trust", "run", "candidate:summary", "--", "--candidate-inventory", candidate, "--reproducibility", reproductionPath, "--output", summary], { cwd: root, env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C" }, stdio: "inherit" });
    const inventory = regularInput(candidate, "candidate output"); const final = regularInput(summary, "summary output");
    if (!inventory.equals(regularInput(resolve(root, expectedCandidate), "candidate evidence")) || !final.equals(regularInput(resolve(root, expectedSummary), "summary evidence"))) fail("overlay evidence regeneration rejected");
    const rows = inventory.toString("utf8").trim().split("\n").map((row) => JSON.parse(row)); const protectedRows = rows.filter((row) => row.class === "protected-control");
    const doc = JSON.parse(final.toString("utf8"));
    if (protectedRows.length !== 179 || rows.some((row) => row.path === overlayPaths[1]) || rows.filter((row) => row.path === overlayPaths[2]).length !== 1 || doc.protected_file_count !== 182 || doc.package_file_count !== 59 || doc.test_case_count !== 66) fail("overlay evidence counts rejected");
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}

function main() {
if (phase === "preserve-sbom") preserve();
else if (phase === "verify-sbom-preservation") verifyPreservation();
else if (["prepared", "a-worktree", "a-index", "a10-index", "b-worktree", "overlay-index", "evidence-ready", "b-index", "final"].includes(phase)) {
  if (git("rev-parse", "--abbrev-ref", "HEAD").trim() !== "codex/issue-245-workers-free-adapter") fail("branch rejected");
  if (option("base") && git("merge-base", option("base"), "HEAD").trim() !== option("base")) fail("base rejected");
  const bPaths = [artifactPath, "backend/release_policy_workers_free/evidence/artifact-manifest.v1.json", "backend/release_policy_workers_free/evidence/artifact-manifest.v2.json", "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl", "backend/release_policy_trust/evidence/review/reproducibility.v1.json", "backend/release_policy_trust/evidence/review/final-candidate.v1.json"];
  if (phase === "prepared") { cleanIndex(); const oid = required(start, "start"); for (const path of bPaths) { const working = resolve(root, path); const inStart = (() => { try { startBytes(oid, path); return true; } catch { return false; } })(); if (existsSync(working) !== inStart || (inStart && !readFileSync(working).equals(startBytes(oid, path)))) fail(`pre-A B path drift: ${path}`); } }
  if (phase === "a-worktree") cleanIndex();
  if (phase === "a-index") { const staged = git("diff", "--cached", "--name-only").trim().split("\n").filter(Boolean); if (staged.some((path) => bPaths.includes(path))) fail("B path staged in A"); }
  if (phase === "a10-index") {
    const parent = required(start, "start"); const delta = git("diff", "--cached", "--name-status", parent).trim().split("\n").filter(Boolean);
    const expected = [`A\t${overlayPaths[1]}`, `D\t${overlayPaths[2]}`, "M\tbackend/release_policy_workers_free/scripts/phase_guard.mjs"];
    if (git("rev-parse", "HEAD").trim() !== parent || JSON.stringify(delta) !== JSON.stringify(expected) || stagedMode(overlayPaths[1]) !== "100644" || stagedMode(overlayPaths[2]) !== "") fail("A10 index rejected");
    if (hash(Buffer.from(git("show", `:${overlayPaths[1]}`))) !== "53055b0aceb861392fbf97daa35819c1a30a5916e9fb5ee1680a8c8aad608fe8" || existsSync(resolve(root, overlayPaths[2])) || !readFileSync(resolve(root, overlayPaths[0])).equals(startBytes(parent, overlayPaths[0]))) fail("A10 placeholder topology rejected");
  }
  if (phase === "b-worktree") cleanIndex();
  if (phase === "overlay-index") { const anchor = required(option("anchor"), "anchor"); assertOverlayIndex(anchor); }
  if (phase === "evidence-ready") { const anchor = required(option("anchor"), "anchor"); assertOverlayIndex(anchor, true); const before = git("diff", "--cached", "--name-status", anchor); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); if (git("diff", "--cached", "--name-status", anchor) !== before) fail("overlay index drifted"); }
  if (phase === "b-index") { const anchor = required(option("anchor"), "anchor"); const staged = git("diff", "--cached", "--name-status", anchor).trim().split("\n").filter(Boolean); assertBDelta(staged, reproductionDiffersFromAnchor(anchor)); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); }
  if (phase === "final") { const anchor = required(option("anchor"), "anchor"); const candidate = required(option("candidate"), "candidate"); if (git("rev-parse", `${candidate}^`).trim() !== anchor) fail("B parent rejected"); const delta = git("diff", "--name-status", anchor, candidate).trim().split("\n").filter(Boolean); assertBDelta(delta, reproductionDiffersFromAnchor(anchor)); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); cleanIndex(); }
} else fail("phase rejected");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
