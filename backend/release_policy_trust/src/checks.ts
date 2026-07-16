import { fail } from "./errors.js";
import { enumerateMatchingChecks } from "./pagination.js";
import type { AppCheck, ExpectedIdentity, GitHubCheckRunsPort } from "./ports.js";
import type { PullRequestSnapshot } from "./ports.js";
import { canonicalHash } from "./canonical.js";
import { assertCurrentGeneration, markBindingTerminal, recordBoundCheck, type Generation } from "./store.js";
import type { DurableStorePort } from "./ports.js";

export class AmbiguousCreateError extends Error {}
export class DefinitiveNotSentError extends Error {}
export class AmbiguousUpdateError extends Error {}
export interface Clock { delay(seconds: number): Promise<void> }
export const RECONCILE_DELAYS = [1, 2, 4, 8, 16, 32] as const;

function validCreated(check: AppCheck, identity: ExpectedIdentity, headSha: string, name: string, externalId: string): boolean {
  return Number.isSafeInteger(check.checkId) && check.checkId > 0 && check.appId === identity.appId && check.repositoryId === identity.repositoryId && check.headSha === headSha && check.name === name && check.externalId === externalId;
}

export async function bindOneCheck(
  port: GitHubCheckRunsPort,
  clock: Clock,
  identity: ExpectedIdentity,
  headSha: string,
  name: string,
  generation: string,
): Promise<AppCheck> {
  try {
    const created = await port.createCheck({ externalId: generation, headSha, name, repositoryId: identity.repositoryId });
    if (!validCreated(created, identity, headSha, name, generation)) fail("identity", "created check identity mismatch");
    return created;
  } catch (error) {
    if (error instanceof DefinitiveNotSentError) throw error;
    if (!(error instanceof AmbiguousCreateError)) return fail("ambiguous_api", "check creation failed");
  }
  for (const delay of RECONCILE_DELAYS) {
    await clock.delay(delay);
    const matches = await enumerateMatchingChecks(port, identity, headSha, name, generation);
    if (matches.length === 1) return matches[0]!;
    if (matches.length > 1) fail("ambiguous_api", "multiple App-owned checks match generation");
  }
  return fail("ambiguous_api", "ambiguous create remained invisible; recreation forbidden");
}

export async function finishBoundCheck(port: GitHubCheckRunsPort, input: { checkId: number; repositoryId: number; protectedPaths: readonly string[] }): Promise<void> {
  try {
    await port.updateCheck({
      checkId: input.checkId,
      conclusion: input.protectedPaths.length === 0 ? "success" : "failure",
      repositoryId: input.repositoryId,
      summary: input.protectedPaths.length === 0 ? "No protected release controls changed." : "Protected release controls changed; owner review is required.",
    });
  } catch (error) {
    if (error instanceof AmbiguousUpdateError) throw error;
    return fail("ambiguous_api", "bound check update failed");
  }
}

export async function finishCurrentGeneration(input: {
  check: AppCheck;
  expectedMainSha: string;
  expectedPullRequest: PullRequestSnapshot;
  generation: Generation;
  port: GitHubCheckRunsPort;
  protectedPaths: readonly string[];
  store: DurableStorePort;
}): Promise<void> {
  await assertCurrentGeneration(input.store, input.generation);
  await recordBoundCheck(input.store, input.generation, input.check.checkId);
  const livePullRequest = await input.port.getPullRequest(input.generation.repositoryId, input.generation.pullRequestNumber);
  const liveMain = await input.port.getMainRef(input.generation.repositoryId);
  if (canonicalHash(livePullRequest) !== canonicalHash(input.expectedPullRequest) || liveMain.sha !== input.expectedMainSha) fail("snapshot_race", "live snapshot changed before Check Run update");
  await assertCurrentGeneration(input.store, input.generation);
  await finishBoundCheck(input.port, { checkId: input.check.checkId, protectedPaths: input.protectedPaths, repositoryId: input.generation.repositoryId });
  await markBindingTerminal(input.store, input.generation, input.check.checkId);
}
