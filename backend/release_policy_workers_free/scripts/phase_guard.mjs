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
// A rebind is deliberately a generic, evidence-only child.  These are the
// only review artifacts that may differ from its source anchor; no issue- or
// history-specific overlay is part of this contract.
export const evidenceOnlyPaths = [
  "backend/release_policy_trust/evidence/review/candidate-tree.v1.jsonl",
  reproductionPath,
  "backend/release_policy_trust/evidence/review/final-candidate.v1.json",
  "backend/release_policy_workers_free/evidence/sbom.spdx.json",
  "backend/release_policy_workers_free/evidence/artifact-manifest.v2.json",
];
export function assertEvidenceOnlyDelta(delta) {
  const expected = evidenceOnlyPaths.map((path) => `M\t${path}`);
  if (JSON.stringify(delta) !== JSON.stringify(expected)) fail("evidence-only path set rejected");
}
export function assertEvidenceOnlyTopology(anchor, candidate) {
  if (!/^[0-9a-f]{40}$/.test(anchor) || !/^[0-9a-f]{40}$/.test(candidate) || /^0+$/.test(anchor) || /^0+$/.test(candidate)) fail("evidence-only oid rejected");
  const parents = git("rev-list", "--parents", "-n", "1", candidate).trim().split(/\s+/);
  if (parents.length !== 2 || parents[0] !== candidate || parents[1] !== anchor) fail("evidence-only parent rejected");
  assertEvidenceOnlyDelta(git("diff", "--name-status", "--no-renames", anchor, candidate).trim().split("\n").filter(Boolean));
  for (const path of evidenceOnlyPaths) if (treeMode(candidate, path) !== "100644") fail("evidence-only mode rejected");
}
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

const finalAPaths = [overlayPaths[1], overlayPaths[2], "backend/release_policy_workers_free/scripts/phase_guard.mjs"];
const finalAV1Sha256 = "53055b0aceb861392fbf97daa35819c1a30a5916e9fb5ee1680a8c8aad608fe8";
function nameStatus(from, to) { return git("diff", "--name-status", from, to).trim().split("\n").filter(Boolean); }
function treeMode(oid, path) { const row = git("ls-tree", oid, "--", path).trim(); return row ? row.split(/\s+/)[0] : ""; }
function requireCleanWorktree() { if (git("status", "--porcelain=v1", "--untracked-files=all").trim()) fail("worktree must be completely clean"); }
function assertAllowedACommit(parent, commit) {
  const delta = nameStatus(parent, commit);
  if (!delta.length) fail("empty A commit rejected");
  for (const row of delta) {
    const [status, path] = row.split("\t");
    if (!finalAPaths.includes(path) || !["A", "D", "M"].includes(status) || (status !== "D" && treeMode(commit, path) !== "100644")) fail("A commit path or mode rejected");
  }
}
function assertCumulativeAHead(startOid, head) {
  const allowed = new Set([`A\t${overlayPaths[1]}`, `D\t${overlayPaths[2]}`, "M\tbackend/release_policy_workers_free/scripts/phase_guard.mjs"]);
  const delta = nameStatus(startOid, head);
  if (delta.some((row) => !allowed.has(row))) fail("intermediate A cumulative path or mode rejected");
  if (treeMode(head, overlayPaths[1]) && treeMode(head, overlayPaths[1]) !== "100644") fail("intermediate A v1 mode rejected");
  if (treeMode(head, finalAPaths[2]) !== "100644") fail("intermediate A guard mode rejected");
}
function assertFinalAChain(startOid, anchor, requireHead = true) {
  if (startOid !== "303125410ee00d21ae17108037e327373f57d10a" || (requireHead && git("rev-parse", "HEAD^{commit}").trim() !== anchor)) fail("final A anchor rejected");
  try { git("merge-base", "--is-ancestor", startOid, anchor); } catch { fail("final A ancestry rejected"); }
  const chain = git("rev-list", "--reverse", "--ancestry-path", `${startOid}..${anchor}`).trim().split("\n").filter(Boolean);
  if (!chain.length) fail("final A chain missing");
  let parent = startOid;
  for (const commit of chain) {
    const parents = git("rev-list", "--parents", "-n", "1", commit).trim().split(/\s+/);
    if (parents.length !== 2 || parents[1] !== parent) fail("final A topology rejected");
    assertAllowedACommit(parent, commit);
    assertCumulativeAHead(startOid, commit);
    parent = commit;
  }
  const expected = [`A\t${overlayPaths[1]}`, `D\t${overlayPaths[2]}`, "M\tbackend/release_policy_workers_free/scripts/phase_guard.mjs"];
  if (JSON.stringify(nameStatus(startOid, anchor)) !== JSON.stringify(expected) || treeMode(anchor, overlayPaths[1]) !== "100644" || treeMode(anchor, overlayPaths[2]) || treeMode(anchor, finalAPaths[2]) !== "100644") fail("final A cumulative path or mode rejected");
  if (hashAt(anchor, overlayPaths[1]) !== finalAV1Sha256 || !startBytes(startOid, artifactPath).equals(startBytes(anchor, artifactPath)) || hashAt(startOid, "backend/release_policy_workers_free/config/phase-b-overlay.v1.json") !== hashAt(anchor, "backend/release_policy_workers_free/config/phase-b-overlay.v1.json")) fail("final A placeholder or overlay drift rejected");
}
function assertProductionEvidenceBinding(anchor, sbomBytes, artifactBytes, lockBytes, guardSha256) {
  let sbom; let artifact; try { sbom = JSON.parse(sbomBytes.toString("utf8")); artifact = JSON.parse(artifactBytes.toString("utf8")); } catch { fail("production evidence JSON rejected"); }
  const namespace = `https://archivale.app/spdx/release-policy-workers-free/${anchor}/${hash(lockBytes)}`;
  if (sbom.spdxVersion !== "SPDX-2.3" || sbom.documentNamespace !== namespace || !Number.isSafeInteger(Date.parse(sbom.creationInfo?.created)) || artifact.schema_version !== 2 || artifact.source_git_sha !== anchor || artifact.derived_files?.["evidence/sbom.spdx.json"] !== hash(sbomBytes) || artifact.source_files?.["scripts/phase_guard.mjs"] !== guardSha256) fail("production final-A evidence binding rejected");
}
function syntheticEvidence(oid, fixtureGit, guardBytes, lockBytes) {
  const epoch = Number(fixtureGit(["show", "-s", "--format=%ct", oid]));
  const namespace = `https://archivale.app/spdx/release-policy-workers-free/${oid}/${hash(lockBytes)}`;
  const sbom = Buffer.from(`${JSON.stringify({ SPDXID: "SPDXRef-DOCUMENT", spdxVersion: "SPDX-2.3", dataLicense: "CC0-1.0", name: "fixture", documentNamespace: namespace, creationInfo: { created: new Date(epoch * 1000).toISOString().replace(".000", ""), creators: ["Tool: Archivale release-policy SBOM generator"] }, packages: [{ SPDXID: "SPDXRef-Package-0", name: "fixture", versionInfo: "1", downloadLocation: "NOASSERTION", filesAnalyzed: false, licenseConcluded: "NOASSERTION", licenseDeclared: "NOASSERTION", copyrightText: "NOASSERTION" }], relationships: [{ spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: "SPDXRef-Package-0" }] })}\n`);
  const artifact = Buffer.from(`${JSON.stringify({ schema_version: 2, source_git_sha: oid, source_files: { "scripts/phase_guard.mjs": hash(guardBytes) }, derived_files: { "evidence/sbom.spdx.json": hash(sbom) } })}\n`);
  return { sbom, artifact, guard_sha256: hash(guardBytes) };
}
function assertSyntheticProvisionalFinalRegression() {
  const directory = mkdtempSync(join(tmpdir(), "release-policy-pf-fixture-"));
  const fixtureGit = (args, env = {}) => execFileSync("git", ["-C", directory, ...args], { encoding: "utf8", env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C", ...env } }).trim();
  const commit = (label, content, date) => {
    writeFileSync(resolve(directory, "scripts/phase_guard.mjs"), content);
    fixtureGit(["add", "scripts/phase_guard.mjs"]); fixtureGit(["commit", "--no-gpg-sign", "-m", label], { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date });
    return fixtureGit(["rev-parse", "HEAD^{commit}"]);
  };
  try {
    mkdirSync(resolve(directory, "scripts")); writeFileSync(resolve(directory, "package-lock.json"), "fixture-lock\n");
    fixtureGit(["init", "--quiet"]); fixtureGit(["config", "user.name", "fixture"]); fixtureGit(["config", "user.email", "fixture@example.invalid"]);
    const base = commit("C", "base\n", "2000-01-01T00:00:00Z");
    const provisional = commit("P", "provisional\n", "2000-01-01T00:00:01Z"); fixtureGit(["update-ref", "refs/fixture/provisional", provisional]);
    fixtureGit(["checkout", "--quiet", "--detach", base]);
    const final = commit("F", "final\n", "2000-01-01T00:00:02Z"); fixtureGit(["update-ref", "refs/fixture/final", final]);
    if (fixtureGit(["rev-parse", `${provisional}^`]) !== base || fixtureGit(["rev-parse", `${final}^`]) !== base || fixtureGit(["rev-parse", "refs/fixture/provisional"]) !== provisional || fixtureGit(["rev-parse", "refs/fixture/final"]) !== final) fail("synthetic P/F topology rejected");
    const lock = readFileSync(resolve(directory, "package-lock.json"));
    const pEvidence = syntheticEvidence(provisional, fixtureGit, Buffer.from("provisional\n"), lock);
    const fEvidence = syntheticEvidence(final, fixtureGit, Buffer.from("final\n"), lock);
    try { assertProductionEvidenceBinding(final, pEvidence.sbom, pEvidence.artifact, lock, fEvidence.guard_sha256); fail("synthetic P evidence unexpectedly accepted at F"); } catch (error) { if (!(error instanceof Error) || !error.message.includes("production final-A evidence binding rejected")) throw error; }
    assertProductionEvidenceBinding(final, fEvidence.sbom, fEvidence.artifact, lock, fEvidence.guard_sha256);
    const syntheticB = fixtureGit(["commit-tree", fixtureGit(["write-tree"]), "-p", final], { GIT_AUTHOR_DATE: "2000-01-01T00:00:03Z", GIT_COMMITTER_DATE: "2000-01-01T00:00:03Z" });
    if (fixtureGit(["rev-parse", `${syntheticB}^`]) !== final) fail("synthetic B parent rejected");
    const syntheticMerge = fixtureGit(["commit-tree", fixtureGit(["write-tree"]), "-p", final, "-p", provisional], { GIT_AUTHOR_DATE: "2000-01-01T00:00:04Z", GIT_COMMITTER_DATE: "2000-01-01T00:00:04Z" });
    if (fixtureGit(["rev-list", "--parents", "-n", "1", syntheticMerge]).split(/\s+/).length !== 3) fail("synthetic B merge regression rejected");
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
function assertReachableHistoricalStaleRegression() {
  const b10 = "303125410ee00d21ae17108037e327373f57d10a"; const finalA10 = "1c9919414330aadb5b77e6e8da7e173e0d4520a9";
  const staleArtifact = startBytes(b10, overlayPaths[2]); const staleSbom = startBytes(b10, artifactPath); const lock = startBytes(b10, "backend/release_policy_workers_free/package-lock.json");
  let manifest; let sbom; try { manifest = JSON.parse(staleArtifact.toString("utf8")); sbom = JSON.parse(staleSbom.toString("utf8")); } catch { fail("reachable stale evidence rejected"); }
  if (manifest.source_git_sha !== "5410bf14b25b006664dc8e9a0398d3fb2f2ee2a5" || manifest.source_files?.["scripts/phase_guard.mjs"] !== "9c4d6b891040860d008da6fed082a8687de9ca58d0d8346b10df516090474281" || manifest.derived_files?.["evidence/sbom.spdx.json"] !== "4f4e253d7e472d07747d81e6bb5a13c9a7d0a3c24e7d0966023c168d14966893" || sbom.documentNamespace !== `https://archivale.app/spdx/release-policy-workers-free/${manifest.source_git_sha}/${hash(lock)}`) fail("reachable stale constants rejected");
  const temporary = mkdtempSync(join(tmpdir(), "release-policy-final-a10-sbom-"));
  try {
    const lockPath = resolve(temporary, "package-lock.json"); const finalSbomPath = resolve(temporary, "final.spdx.json"); writeFileSync(lockPath, lock); runGenerator(finalA10, finalSbomPath, lockPath);
    const finalSbom = regularInput(finalSbomPath, "regenerated final A10 SBOM");
    if (hashAt(finalA10, finalAPaths[2]) !== "73f47a6969f170c4f910825f71a6e369d55e919bca25f02f70fd8d9e316fe897" || hash(finalSbom) !== "67ba7e8b2c764ad749fc2fbad61572ccf757a7a501af297a6538e1093590356f" || hash(finalSbom) === manifest.derived_files?.["evidence/sbom.spdx.json"]) fail("reachable final A10 SBOM regeneration rejected");
    parseSpdx(finalSbom, lock);
    try { assertProductionEvidenceBinding(finalA10, finalSbom, staleArtifact, lock, hashAt(finalA10, finalAPaths[2])); fail("stale artifact hash unexpectedly accepted against final A10 SBOM"); } catch (error) { if (!(error instanceof Error) || !error.message.includes("production final-A evidence binding rejected")) throw error; }
    try { assertProductionEvidenceBinding(finalA10, staleSbom, staleArtifact, lock, hashAt(finalA10, finalAPaths[2])); fail("reachable stale evidence unexpectedly accepted"); } catch (error) { if (!(error instanceof Error) || !error.message.includes("production final-A evidence binding rejected")) throw error; }
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}
function assertTransientCumulativeModeRegression() {
  const directory = mkdtempSync(join(tmpdir(), "release-policy-a-chain-fixture-"));
  const fixtureGit = (args, env = {}) => execFileSync("git", ["-C", directory, ...args], { encoding: "utf8", env: { ...process.env, TZ: "UTC", LC_ALL: "C", LANG: "C", ...env } }).trim();
  const commit = (message, date) => { fixtureGit(["add", "."]); fixtureGit(["commit", "--no-gpg-sign", "-m", message], { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date }); return fixtureGit(["rev-parse", "HEAD"]); };
  try {
    fixtureGit(["init", "--quiet"]); fixtureGit(["config", "user.name", "fixture"]); fixtureGit(["config", "user.email", "fixture@example.invalid"]);
    mkdirSync(resolve(directory, "evidence")); mkdirSync(resolve(directory, "scripts")); writeFileSync(resolve(directory, "evidence/v2"), "base\n"); writeFileSync(resolve(directory, "scripts/guard"), "base\n");
    const base = commit("C", "2000-01-01T00:00:00Z"); writeFileSync(resolve(directory, "evidence/v2"), "transient\n"); const provisional = commit("P", "2000-01-01T00:00:01Z"); fixtureGit(["update-ref", "refs/fixture/transient", provisional]);
    fixtureGit(["checkout", "--quiet", "--detach", base]); writeFileSync(resolve(directory, "evidence/v1"), "placeholder\n"); rmSync(resolve(directory, "evidence/v2")); writeFileSync(resolve(directory, "scripts/guard"), "final\n"); const final = commit("F", "2000-01-01T00:00:02Z");
    const allowed = new Set(["A\tevidence/v1", "D\tevidence/v2", "M\tscripts/guard"]); const provisionalDelta = fixtureGit(["diff", "--name-status", base, provisional]).split("\n").filter(Boolean); const finalDelta = fixtureGit(["diff", "--name-status", base, final]).split("\n").filter(Boolean);
    if (!provisionalDelta.includes("M\tevidence/v2") || provisionalDelta.every((row) => allowed.has(row)) || finalDelta.some((row) => !allowed.has(row))) fail("transient A cumulative mode regression rejected");
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
function requireNoUntracked() { if (git("ls-files", "--others", "--exclude-standard").trim()) fail("untracked worktree content rejected"); }
function assertUnstagedOnly(allowed) { const changed = git("diff", "--name-only").trim().split("\n").filter(Boolean); if (changed.some((path) => !allowed.includes(path))) fail("unstaged source or worktree drift rejected"); }
function assertPreCommitBSeal(phaseName) {
  const anchor = required(option("anchor"), "anchor"); const startOid = required(start, "start");
  if (phaseName === "b-worktree") { cleanIndex(); requireCleanWorktree(); } else requireNoUntracked();
  assertFinalAChain(startOid, anchor);
  if (!readFileSync(resolve(root, finalAPaths[2])).equals(startBytes(anchor, finalAPaths[2]))) fail("pre-commit B source drift rejected");
  return anchor;
}
function assertStagedProductionBinding(anchor) {
  const sbom = Buffer.from(git("show", `:${artifactPath}`)); const artifact = Buffer.from(git("show", `:${overlayPaths[2]}`));
  assertProductionEvidenceBinding(anchor, sbom, artifact, startBytes(anchor, "backend/release_policy_workers_free/package-lock.json"), hashAt(anchor, finalAPaths[2]));
}
function assertCommittedBSeal() {
  const candidate = required(option("candidate"), "candidate"); const supplied = required(option("anchor"), "anchor"); const parents = git("rev-list", "--parents", "-n", "1", candidate).trim().split(/\s+/); if (parents.length !== 2) fail("committed B merge topology rejected"); const actual = parents[1];
  if (supplied !== actual || git("rev-parse", "HEAD^{commit}").trim() !== candidate) fail("committed B anchor rejected");
  assertFinalAChain(required(start, "start"), actual, false);
  const sbom = startBytes(candidate, artifactPath); const artifact = startBytes(candidate, overlayPaths[2]);
  assertProductionEvidenceBinding(actual, sbom, artifact, startBytes(actual, "backend/release_policy_workers_free/package-lock.json"), hashAt(actual, finalAPaths[2]));
  return { actual, candidate };
}
function assertFinalASeal() {
  const anchor = required(option("anchor"), "anchor"); const startOid = required(start, "start");
  cleanIndex(); requireCleanWorktree(); assertFinalAChain(startOid, anchor);
  const runningGuard = readFileSync(resolve(root, finalAPaths[2]));
  if (!runningGuard.equals(startBytes(anchor, finalAPaths[2]))) fail("running guard differs from committed final A");
  assertReachableHistoricalStaleRegression(); assertSyntheticProvisionalFinalRegression(); assertTransientCumulativeModeRegression();
}

function main() {
  if (phase === "evidence-only") {
    const anchor = required(option("anchor"), "anchor");
    const candidate = required(option("candidate"), "candidate");
    requireCleanWorktree();
    assertEvidenceOnlyTopology(anchor, candidate);
    return;
  }
if (phase === "preserve-sbom") preserve();
else if (phase === "verify-sbom-preservation") verifyPreservation();
else if (phase === "final-a") assertFinalASeal();
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
  if (phase === "b-worktree") assertPreCommitBSeal("b-worktree");
  if (phase === "overlay-index") { const anchor = assertPreCommitBSeal("overlay-index"); assertOverlayIndex(anchor); assertStagedProductionBinding(anchor); }
  if (phase === "evidence-ready") { const anchor = assertPreCommitBSeal("evidence-ready"); assertOverlayIndex(anchor, true); assertStagedProductionBinding(anchor); const before = git("diff", "--cached", "--name-status", anchor); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); if (git("diff", "--cached", "--name-status", anchor) !== before) fail("overlay index drifted"); }
  if (phase === "b-index") { const anchor = assertPreCommitBSeal("b-index"); assertUnstagedOnly([candidatePath, summaryPath]); const staged = git("diff", "--cached", "--name-status", anchor).trim().split("\n").filter(Boolean); assertBDelta(staged, reproductionDiffersFromAnchor(anchor)); assertStagedProductionBinding(anchor); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); }
  if (phase === "final") { const { actual: anchor, candidate } = assertCommittedBSeal(); const delta = git("diff", "--name-status", anchor, candidate).trim().split("\n").filter(Boolean); assertBDelta(delta, reproductionDiffersFromAnchor(anchor)); regenerateOverlayEvidence(anchor, candidatePath, summaryPath); cleanIndex(); requireCleanWorktree(); }
} else fail("phase rejected");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
