import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { verifyFrozenBaseAndCandidate } from "../scripts/git_anchors.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

test("detached synthetic PR checkout needs origin/main but no local main", () => {
  const root = mkdtempSync(join(tmpdir(), "release-policy-ci-checkout-"));
  try {
    git(root, ["init", "--initial-branch=work"]);
    git(root, ["config", "user.name", "Synthetic Test"]);
    git(root, ["config", "user.email", "synthetic@example.invalid"]);
    writeFileSync(join(root, "fixture.txt"), "base\n");
    git(root, ["add", "fixture.txt"]);
    git(root, ["commit", "-m", "base"]);
    const base = git(root, ["rev-parse", "HEAD"]);
    git(root, ["update-ref", "refs/remotes/origin/main", base]);
    writeFileSync(join(root, "fixture.txt"), "candidate\n");
    git(root, ["commit", "-am", "candidate"]);
    const candidate = git(root, ["rev-parse", "HEAD"]);
    const tree = git(root, ["rev-parse", `${candidate}^{tree}`]);
    const syntheticMerge = git(root, ["commit-tree", tree, "-p", base, "-p", candidate, "-m", "synthetic PR merge"]);
    git(root, ["-c", "advice.detachedHead=false", "switch", "--quiet", "--detach", syntheticMerge]);

    assert.equal(git(root, ["branch", "--list", "main"]), "");
    assert.doesNotThrow(() => verifyFrozenBaseAndCandidate(root, base, candidate));
    git(root, ["update-ref", "refs/remotes/origin/main", candidate]);
    assert.throws(() => verifyFrozenBaseAndCandidate(root, base, candidate), /origin\/main moved/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pull-request workflow passes the true head SHA to candidate gates", () => {
  const workflow = readFileSync(resolve(process.cwd(), "../../.github/workflows/release-readiness.yml"), "utf8");
  assert.match(workflow, /CANDIDATE_SHA:\s*\$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/);
  assert.doesNotMatch(workflow, /--candidate "\$GITHUB_SHA"/);
  assert.match(workflow, /--candidate "\$CANDIDATE_SHA"/);
});
