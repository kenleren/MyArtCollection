import { canonicalHash, generationId, type GenerationTuple } from "./canonical.js";
import { fail } from "./errors.js";
import { collectPullRequestFiles, enumerateOpenMainPullRequests } from "./pagination.js";
import { evaluateChangedFiles, type PathPolicy } from "./paths.js";
import type { ExpectedIdentity, GitHubCheckRunsPort, PullRequestSnapshot } from "./ports.js";

function positive(value: number): boolean { return Number.isSafeInteger(value) && value > 0; }
function samePr(left: PullRequestSnapshot, right: PullRequestSnapshot): boolean { return canonicalHash(left) === canonicalHash(right); }

function validatePr(pr: PullRequestSnapshot, expected: ExpectedIdentity, number: number): void {
  if (![pr.appId, pr.installationId, pr.repositoryId, pr.headRepositoryId, pr.number].every(positive)) fail("identity", "invalid numeric PR identity");
  if (pr.appId !== expected.appId || pr.installationId !== expected.installationId || pr.repositoryId !== expected.repositoryId || pr.repositoryName !== expected.repositoryName || pr.number !== number || pr.baseRef !== expected.baseRef || pr.state !== "open") fail("identity", "PR identity mismatch");
  if (pr.headRepositoryId !== expected.repositoryId) fail("identity", "fork pull requests are not accepted");
  if (!/^[0-9a-f]{40}$/.test(pr.baseSha) || !/^[0-9a-f]{40}$/.test(pr.headSha)) fail("identity", "invalid or inaccessible PR ref");
}

export interface ImmutableEvaluation {
  filesDigest: string;
  generationId: string;
  protectedPaths: string[];
  snapshot: PullRequestSnapshot;
  tuple: GenerationTuple;
}

export async function snapshotPullRequest(port: GitHubCheckRunsPort, expected: ExpectedIdentity, number: number, policySha256: string, pathPolicy: PathPolicy): Promise<ImmutableEvaluation> {
  const first = await port.getPullRequest(expected.repositoryId, number);
  validatePr(first, expected, number);
  const main = await port.getMainRef(expected.repositoryId);
  if (main.repositoryId !== expected.repositoryId || main.ref !== "refs/heads/main" || main.sha !== first.baseSha) fail("snapshot_race", "base is not current main");
  const files = await collectPullRequestFiles(port, expected.repositoryId, number, first.changedFiles);
  const evaluation = evaluateChangedFiles(files, pathPolicy);
  const second = await port.getPullRequest(expected.repositoryId, number);
  const secondMain = await port.getMainRef(expected.repositoryId);
  if (!samePr(first, second) || canonicalHash(main) !== canonicalHash(secondMain)) fail("snapshot_race", "PR or main moved while snapshotting");
  const tuple: GenerationTuple = {
    app_id: expected.appId,
    base_ref: first.baseRef,
    base_sha: first.baseSha,
    head_sha: first.headSha,
    installation_id: expected.installationId,
    policy_sha256: policySha256,
    pull_request_number: number,
    repository_id: expected.repositoryId,
  };
  return { filesDigest: canonicalHash(files), generationId: generationId(tuple), protectedPaths: evaluation.protectedPaths, snapshot: first, tuple };
}

export async function snapshotPushTargets(port: GitHubCheckRunsPort, expected: ExpectedIdentity, after: string): Promise<{ count: number; digest: string; numbers: number[] }> {
  const before = await port.getMainRef(expected.repositoryId);
  if (before.repositoryId !== expected.repositoryId || before.ref !== "refs/heads/main" || before.sha !== after) fail("snapshot_race", "push after does not equal live main");
  const targets = await enumerateOpenMainPullRequests(port, expected);
  const afterRead = await port.getMainRef(expected.repositoryId);
  if (canonicalHash(before) !== canonicalHash(afterRead)) fail("snapshot_race", "main moved during push fanout");
  return { count: targets.count, digest: targets.digest, numbers: targets.rows.map((row) => row.number) };
}
