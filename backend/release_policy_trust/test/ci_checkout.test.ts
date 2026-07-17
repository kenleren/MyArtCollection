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
    assert.doesNotThrow(() => verifyFrozenBaseAndCandidate(root, base, candidate, {
      expectedMain: base,
      mode: "frozen-bootstrap-pr",
    }));
    git(root, ["update-ref", "refs/remotes/origin/main", candidate]);
    assert.throws(() => verifyFrozenBaseAndCandidate(root, base, candidate, {
      expectedMain: base,
      mode: "frozen-bootstrap-pr",
    }), /origin\/main differs from expected event main/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("post-merge main keeps the frozen base while anchoring origin/main to the candidate", () => {
  const root = mkdtempSync(join(tmpdir(), "release-policy-main-checkout-"));
  try {
    git(root, ["init", "--initial-branch=main"]);
    git(root, ["config", "user.name", "Synthetic Test"]);
    git(root, ["config", "user.email", "synthetic@example.invalid"]);
    writeFileSync(join(root, "fixture.txt"), "base\n");
    git(root, ["add", "fixture.txt"]);
    git(root, ["commit", "-m", "base"]);
    const base = git(root, ["rev-parse", "HEAD"]);
    writeFileSync(join(root, "fixture.txt"), "candidate\n");
    git(root, ["commit", "-am", "candidate"]);
    const candidate = git(root, ["rev-parse", "HEAD"]);
    git(root, ["update-ref", "refs/remotes/origin/main", candidate]);
    git(root, ["-c", "advice.detachedHead=false", "switch", "--quiet", "--detach", candidate]);

    assert.doesNotThrow(() => verifyFrozenBaseAndCandidate(root, base, candidate, {
      expectedMain: candidate,
      mode: "post-merge-main",
    }));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("follow-up pull request anchors to advanced main without changing the frozen base", () => {
  const root = mkdtempSync(join(tmpdir(), "release-policy-follow-up-pr-"));
  try {
    git(root, ["init", "--initial-branch=main"]);
    git(root, ["config", "user.name", "Synthetic Test"]);
    git(root, ["config", "user.email", "synthetic@example.invalid"]);
    writeFileSync(join(root, "fixture.txt"), "base\n");
    git(root, ["add", "fixture.txt"]);
    git(root, ["commit", "-m", "base"]);
    const base = git(root, ["rev-parse", "HEAD"]);
    writeFileSync(join(root, "fixture.txt"), "merged bootstrap\n");
    git(root, ["commit", "-am", "merged bootstrap"]);
    const expectedMain = git(root, ["rev-parse", "HEAD"]);
    git(root, ["update-ref", "refs/remotes/origin/main", expectedMain]);
    writeFileSync(join(root, "fixture.txt"), "follow-up candidate\n");
    git(root, ["commit", "-am", "follow-up candidate"]);
    const candidate = git(root, ["rev-parse", "HEAD"]);

    assert.doesNotThrow(() => verifyFrozenBaseAndCandidate(root, base, candidate, {
      expectedMain,
      mode: "frozen-bootstrap-pr",
    }));
    assert.throws(() => verifyFrozenBaseAndCandidate(root, base, candidate, {
      expectedMain: candidate,
      mode: "post-merge-main",
    }), /origin\/main differs from expected event main/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pull-request workflow passes the true head SHA to candidate gates", () => {
  const workflow = readFileSync(resolve(process.cwd(), "../../.github/workflows/release-readiness.yml"), "utf8");
  assert.match(workflow, /CANDIDATE_SHA:\s*\$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/);
  assert.match(workflow, /EXPECTED_MAIN_SHA:\s*\$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.sha \}\}/);
  assert.match(workflow, /VERIFICATION_MODE:\s*\$\{\{ github\.event_name == 'pull_request' && 'frozen-bootstrap-pr' \|\| 'post-merge-main' \}\}/);
  assert.doesNotMatch(workflow, /--candidate "\$GITHUB_SHA"/);
  assert.match(workflow, /--candidate "\$CANDIDATE_SHA"/);
  assert.match(workflow, /--expected-main "\$EXPECTED_MAIN_SHA"/);
  assert.match(workflow, /--mode "\$VERIFICATION_MODE"/);
});
