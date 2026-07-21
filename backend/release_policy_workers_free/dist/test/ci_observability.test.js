import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
const root = resolve(process.cwd(), "../..");
const workflowPath = resolve(root, ".github/workflows/release-readiness.yml");
const phaseGuardUrl = pathToFileURL(resolve(root, "backend/release_policy_workers_free/scripts/phase_guard.mjs")).href;
function phaseGuardAssertions() {
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
    ];
    let previous = -1;
    for (const [name, command] of steps) {
        const step = `      - name: ${name}\n        shell: bash\n        run: |\n          set -euo pipefail`;
        const index = backend.indexOf(step);
        assert.ok(index > previous, `${name} is missing or out of order`);
        assert.ok(backend.indexOf(command, index) > index, `${name} command is missing`);
        previous = index;
    }
    assert.ok(backend.indexOf("      - name: Run pinned Play Billing Firestore emulator evidence") > previous);
    assert.doesNotMatch(backend, /Test backend packages|continue-on-error|if:\s*always\(\)|set -x|ACTIONS_STEP_DEBUG|upload-artifact/);
});
test("phase guard accepts only the computed five or six evidence deltas", () => {
    phaseGuardAssertions();
});
