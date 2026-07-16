import { canonicalHash, generationId, type GenerationTuple } from "./canonical.js";
import { fail } from "./errors.js";
import { collectPullRequestFiles, enumerateOpenMainPullRequests } from "./pagination.js";
import { evaluateChangedFiles, type PathPolicy } from "./paths.js";
import type { ExpectedIdentity, GitHubCheckRunsPort, PullRequestSnapshot } from "./ports.js";
import { assertCanonicalPolicy, type CanonicalReleasePolicy, type PolicyLimits } from "./policy.js";

function positive(value: number): boolean { return Number.isSafeInteger(value) && value > 0; }
function samePr(left: PullRequestSnapshot, right: PullRequestSnapshot): boolean { return canonicalHash(left) === canonicalHash(right); }

function validatePr(pr: PullRequestSnapshot, expected: ExpectedIdentity, number: number): void {
  if (![pr.appId, pr.installationId, pr.repositoryId, pr.headRepositoryId, pr.number].every(positive)) fail("identity", "invalid numeric PR identity");
  if (pr.appId !== expected.appId || pr.installationId !== expected.installationId || pr.repositoryId !== expected.repositoryId || pr.repositoryName !== expected.repositoryName || pr.number !== number || pr.baseRef !== expected.baseRef || pr.state !== "open") fail("identity", "PR identity mismatch");
  if (pr.headRepositoryId !== expected.repositoryId) fail("identity", "fork pull requests are not accepted");
  if (!/^[0-9a-f]{40}$/.test(pr.baseSha) || !/^[0-9a-f]{40}$/.test(pr.headSha)) fail("identity", "invalid or inaccessible PR ref");
}

export interface ImmutableEvaluation {
  decision: { conclusion: "success" | "failure"; digest: string; protectedPaths: string[] };
  fileCount: number;
  filesDigest: string;
  generationId: string;
  mainSha: string;
  policy: {
    checkName: string;
    digest: string;
    limits: PolicyLimits;
    pathPolicy: PathPolicy;
    repository: { baseRef: "main"; name: "kenleren/MyArtCollection" };
  };
  snapshot: PullRequestSnapshot;
  tuple: GenerationTuple;
}

export async function snapshotPullRequest(port: GitHubCheckRunsPort, expected: ExpectedIdentity, number: number, policy: CanonicalReleasePolicy): Promise<ImmutableEvaluation> {
  assertCanonicalPolicy(policy);
  if (expected.repositoryName !== policy.repository.name || expected.baseRef !== policy.repository.baseRef) fail("identity", "runtime identity differs from canonical policy");
  const first = await port.getPullRequest(expected.repositoryId, number);
  validatePr(first, expected, number);
  const main = await port.getMainRef(expected.repositoryId);
  if (main.repositoryId !== expected.repositoryId || main.ref !== "refs/heads/main" || main.sha !== first.baseSha) fail("snapshot_race", "base is not current main");
  const files = await collectPullRequestFiles(port, expected.repositoryId, number, first.changedFiles, policy.limits);
  const evaluation = evaluateChangedFiles(files, policy.pathPolicy);
  const second = await port.getPullRequest(expected.repositoryId, number);
  const secondMain = await port.getMainRef(expected.repositoryId);
  if (!samePr(first, second) || canonicalHash(main) !== canonicalHash(secondMain)) fail("snapshot_race", "PR or main moved while snapshotting");
  const tuple: GenerationTuple = {
    app_id: expected.appId,
    base_ref: first.baseRef,
    base_sha: first.baseSha,
    head_sha: first.headSha,
    installation_id: expected.installationId,
    policy_sha256: policy.digest,
    pull_request_number: number,
    repository_id: expected.repositoryId,
  };
  const decision = {
    conclusion: evaluation.protectedPaths.length === 0 ? "success" as const : "failure" as const,
    digest: canonicalHash({ files_digest: canonicalHash(files), policy_sha256: policy.digest, protected_paths: evaluation.protectedPaths }),
    protectedPaths: evaluation.protectedPaths,
  };
  return {
    decision,
    fileCount: files.length,
    filesDigest: canonicalHash(files),
    generationId: generationId(tuple),
    mainSha: main.sha,
    policy: {
      checkName: policy.checkName,
      digest: policy.digest,
      limits: structuredClone(policy.limits) as PolicyLimits,
      pathPolicy: structuredClone(policy.pathPolicy) as PathPolicy,
      repository: { ...policy.repository },
    },
    snapshot: first,
    tuple,
  };
}

export async function snapshotPushTargets(port: GitHubCheckRunsPort, expected: ExpectedIdentity, after: string, policy: CanonicalReleasePolicy): Promise<{ count: number; digest: string; numbers: number[] }> {
  assertCanonicalPolicy(policy);
  if (expected.repositoryName !== policy.repository.name || expected.baseRef !== policy.repository.baseRef) fail("identity", "runtime identity differs from canonical policy");
  const before = await port.getMainRef(expected.repositoryId);
  if (before.repositoryId !== expected.repositoryId || before.ref !== "refs/heads/main" || before.sha !== after) fail("snapshot_race", "push after does not equal live main");
  const targets = await enumerateOpenMainPullRequests(port, expected, policy.limits);
  const afterRead = await port.getMainRef(expected.repositoryId);
  if (canonicalHash(before) !== canonicalHash(afterRead)) fail("snapshot_race", "main moved during push fanout");
  return { count: targets.count, digest: targets.digest, numbers: targets.rows.map((row) => row.number) };
}
