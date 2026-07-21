import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

const root = resolve(process.cwd(), "../..");
const workflowPath = resolve(root, ".github/workflows/release-readiness.yml");
const phaseGuardUrl = pathToFileURL(resolve(root, "backend/release_policy_workers_free/scripts/phase_guard.mjs")).href;

function phaseGuardAssertions(): void {
  const source = [
    `import { assertBDelta, expectedBDelta, mandatoryBDelta } from ${JSON.stringify(phaseGuardUrl)};`,
    "const five = expectedBDelta(false); const six = expectedBDelta(true);",
    "if (five.length !== 5 || six.length !== 6 || six[2] !== 'M\\tbackend/release_policy_trust/evidence/review/reproducibility.v1.json') process.exit(2);",
    "assertBDelta(five, false); assertBDelta(six, true);",
    "for (const [delta, differs] of [[five.slice(1), false], [[...five, 'M\\textra'], false], [[...five.slice(0, 2), 'A\\tbackend/release_policy_trust/evidence/review/reproducibility.v1.json', ...five.slice(2)], true], [five, true]]) { let rejected = false; try { assertBDelta(delta, differs); } catch { rejected = true; } if (!rejected) process.exit(3); }",
    "if (JSON.stringify(mandatoryBDelta) !== JSON.stringify(five)) process.exit(4);",
  ].join("\n");
  execFileSync("node", ["--input-type=module", "--eval", source], { cwd: resolve(root, "backend/release_policy_workers_free"), stdio: "inherit" });
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
}

function resolveCandidate(cwd: string, eventName: string, eventSha: string, pullRequestHeadSha: string, checkedOut: string): { candidateHead: string; artifactAnchor: string } {
  const candidateHead = eventName === "pull_request" ? pullRequestHeadSha : (eventName === "push" || eventName === "workflow_dispatch" ? eventSha : "");
  if (!/^[0-9a-f]{40}$/.test(candidateHead) || /^0{40}$/.test(candidateHead)) throw new Error("candidate rejected");
  if (git(cwd, ["rev-parse", "--verify", `${candidateHead}^{commit}`]) !== candidateHead) throw new Error("candidate object rejected");
  if (checkedOut !== candidateHead) throw new Error("checkout rejected");
  const parents = git(cwd, ["rev-list", "--parents", "-n", "1", candidateHead]).split(" ");
  if (parents.length !== 2) throw new Error("parent topology rejected");
  const artifactAnchor = parents[1]!;
  if (!/^[0-9a-f]{40}$/.test(artifactAnchor) || /^0{40}$/.test(artifactAnchor) || git(cwd, ["rev-parse", "--verify", `${artifactAnchor}^{commit}`]) !== artifactAnchor) throw new Error("anchor rejected");
  return { candidateHead, artifactAnchor };
}

test("immutable candidate fixture rejects synthetic merges and invalid event topology", () => {
  const fixture = mkdtempSync(join(tmpdir(), "workers-candidate-fixture-"));
  try {
    git(fixture, ["init", "--initial-branch=main"]);
    git(fixture, ["config", "user.name", "Fixture"]); git(fixture, ["config", "user.email", "fixture@example.invalid"]);
    writeFileSync(join(fixture, "fixture.txt"), "A\n"); git(fixture, ["add", "."]); git(fixture, ["commit", "-m", "A"]);
    const anchor = git(fixture, ["rev-parse", "HEAD"]);
    writeFileSync(join(fixture, "fixture.txt"), "B\n"); git(fixture, ["commit", "-am", "B"]);
    const candidate = git(fixture, ["rev-parse", "HEAD"]);
    const merge = git(fixture, ["commit-tree", git(fixture, ["rev-parse", `${candidate}^{tree}`]), "-p", anchor, "-p", candidate, "-m", "synthetic merge"]);
    assert.deepEqual(resolveCandidate(fixture, "pull_request", merge, candidate, candidate), { candidateHead: candidate, artifactAnchor: anchor });
    assert.deepEqual(resolveCandidate(fixture, "push", candidate, "", candidate), { candidateHead: candidate, artifactAnchor: anchor });
    assert.deepEqual(resolveCandidate(fixture, "workflow_dispatch", candidate, "", candidate), { candidateHead: candidate, artifactAnchor: anchor });
    const rejectedCases: Array<[string, string, string, string]> = [["pull_request", merge, candidate, merge], ["unsupported", candidate, "", candidate], ["pull_request", merge, "", candidate], ["push", "A".repeat(40), "", candidate], ["push", "0".repeat(40), "", candidate], ["push", "f".repeat(40), "", candidate], ["push", candidate, "", merge], ["push", merge, "", merge], ["push", anchor, "", anchor], ["push", "refs/heads/main", "", candidate]];
    for (const [event, eventSha, prHead, checkout] of rejectedCases) {
      assert.throws(() => resolveCandidate(fixture, event, eventSha, prHead, checkout));
    }
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("Release Readiness partitions backend commands into strict, ordered observability steps", () => {
  const workflow = readFileSync(workflowPath, "utf8");
  const backend = workflow.slice(workflow.indexOf("  backend-and-audit:"), workflow.indexOf("  static-site:"));
  const steps = [
    ["Install broker dependencies", "npm --prefix backend/broker ci"],
    ["Test broker package", "npm --prefix backend/broker test"],
    ["Install forms dependencies", "npm --prefix backend/forms ci"],
    ["Test forms package", "npm --prefix backend/forms test"],
    ["Install Play Billing dependencies", "npm --prefix backend/play_billing ci"],
    ["Test Play Billing package", "npm --prefix backend/play_billing test"],
    ["Install Workers Free dependencies", "npm --prefix backend/release_policy_workers_free ci --ignore-scripts"],
    ["Audit Workers Free production dependencies", "npm --prefix backend/release_policy_workers_free audit --package-lock-only --omit=dev --audit-level=moderate"],
    ["Audit Workers Free complete lockfile", "npm --prefix backend/release_policy_workers_free audit --package-lock-only --audit-level=high"],
    ["Test Workers Free package", "npm --prefix backend/release_policy_workers_free test"],
    ["Test Workers Free runtime contract", "npm --prefix backend/release_policy_workers_free run test:runtime-contract"],
    ["Test Workers Free SQLite conformance", "npm --prefix backend/release_policy_workers_free run test:sqlite-conformance"],
    ["Generate Workers Free SPDX evidence", "npm --prefix backend/release_policy_workers_free run sbom:generate -- --anchor \"$A\" --output \"$RUNNER_TEMP/sbom.spdx.json\""],
    ["Verify Workers Free SPDX evidence", "npm --prefix backend/release_policy_workers_free run sbom:verify -- --anchor \"$A\" --input \"$RUNNER_TEMP/sbom.spdx.json\""],
    ["Verify Workers Free artifact manifest", "npm --prefix backend/release_policy_workers_free run artifact:verify -- --anchor \"$A\" --sbom \"$RUNNER_TEMP/sbom.spdx.json\" --output backend/release_policy_workers_free/evidence/artifact-manifest.v2.json"],
    ["Rehearse Workers Free restore", "npm --prefix backend/release_policy_workers_free run restore:rehearsal"],
  ] as const;
  let previous = -1;
  for (const [name, command] of steps) {
    const step = `      - name: ${name}\n        shell: bash\n        run: |\n          set -euo pipefail`;
    const index = backend.indexOf(step);
    assert.ok(index > previous, `${name} is missing or out of order`);
    assert.ok(backend.indexOf(command, index) > index, `${name} command is missing`);
    previous = index;
  }
  assert.ok(backend.indexOf("      - name: Run pinned Play Billing Firestore emulator evidence") > previous);
  const resolver = `      - name: Resolve immutable Workers candidate\n        id: immutable-workers-candidate\n        shell: bash\n        run: |\n          set -euo pipefail`;
  assert.ok(backend.indexOf("ref: ${{ github.event.pull_request.head.sha || github.sha }}") < backend.indexOf(resolver));
  assert.ok(backend.indexOf(resolver) < backend.indexOf("      - name: Install broker dependencies"));
  assert.match(backend, /EVENT_NAME: \$\{\{ github\.event_name \}\}/);
  assert.match(backend, /EVENT_SHA: \$\{\{ github\.sha \}\}/);
  assert.match(backend, /PULL_REQUEST_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \|\| '' \}\}/);
  assert.match(backend, /pull_request\)\s+candidate_head="\$PULL_REQUEST_HEAD_SHA"/);
  assert.match(backend, /push\|workflow_dispatch\)\s+candidate_head="\$EVENT_SHA"/);
  assert.match(backend, /git rev-parse --verify "\$\{candidate_head\}\^\{commit\}"/);
  assert.match(backend, /git rev-parse --verify HEAD\^\{commit\}/);
  assert.match(backend, /git rev-list --parents -n 1 "\$candidate_head"/);
  assert.match(backend, /candidate_head=%s\\nartifact_anchor=%s\\n/);
  assert.doesNotMatch(backend.slice(backend.indexOf("Generate Workers Free SPDX evidence"), backend.indexOf("Rehearse Workers Free restore")), /git rev-parse HEAD\^|GITHUB_SHA\^/);
  assert.equal((backend.match(/\$\{\{ steps\.immutable-workers-candidate\.outputs\.artifact_anchor \}\}/g) ?? []).length, 3);
  assert.doesNotMatch(backend, /Test backend packages|continue-on-error|if:\s*always\(\)|set -x|ACTIONS_STEP_DEBUG|upload-artifact/);
});

test("phase guard accepts only the computed five or six evidence deltas", () => {
  phaseGuardAssertions();
});
