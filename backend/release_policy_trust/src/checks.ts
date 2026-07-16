import { canonicalHash } from "./canonical.js";
import { fail } from "./errors.js";
import { enumerateMatchingChecks } from "./pagination.js";
import type { AppCheck, DurableStorePort, ExpectedIdentity, GitHubCheckRunsPort } from "./ports.js";
import {
  bindCreatedCheck,
  completeCheckUpdate,
  leaseEffect,
  markEffectPossibleSend,
  readBinding,
  readGeneration,
  releaseEffect,
} from "./store.js";

export class AmbiguousCreateError extends Error {}
export class DefinitiveNotSentError extends Error {}
export class AmbiguousUpdateError extends Error {}
export interface Clock { delay(seconds: number): Promise<void> }

function expectedIdentity(generation: Awaited<ReturnType<typeof readGeneration>>): ExpectedIdentity {
  return {
    appId: generation.tuple.app_id,
    baseRef: generation.policy.repository.baseRef,
    installationId: generation.tuple.installation_id,
    repositoryId: generation.repositoryId,
    repositoryName: generation.policy.repository.name,
  };
}

function exactCheck(check: AppCheck, binding: Awaited<ReturnType<typeof readBinding>>): boolean {
  return Number.isSafeInteger(check.checkId) && check.checkId > 0 && check.appId === binding.appId && check.repositoryId === binding.repositoryId && check.headSha === binding.headSha && check.name === binding.checkName && check.externalId === binding.externalId;
}

export async function runCreateCheck(input: {
  clock: Clock;
  generationId: string;
  port: GitHubCheckRunsPort;
  store: DurableStorePort;
  worker: string;
}): Promise<AppCheck> {
  const generation = await readGeneration(input.store, input.generationId);
  const binding = await readBinding(input.store, input.generationId);
  if (generation.state !== "decision_ready" || generation.decision?.digest !== binding.decisionDigest || binding.policyDigest !== generation.policy.digest) fail("cas_lost", "create cannot run without the immutable durable decision");
  const identity = expectedIdentity(generation);
  const lease = await leaseEffect(input.store, input.generationId, "create_check", input.worker);

  if (lease.mode === "reconcile") {
    for (const delay of generation.policy.limits.reconcileDelaysSeconds) {
      await input.clock.delay(delay);
      const matches = await enumerateMatchingChecks(input.port, identity, binding.headSha, binding.checkName, binding.externalId, generation.policy.limits);
      if (matches.length === 1) { await bindCreatedCheck(input.store, lease, matches[0]!); return matches[0]!; }
      if (matches.length > 1) {
        await releaseEffect(input.store, lease, "blocked");
        return fail("ambiguous_api", "multiple App-owned checks match immutable generation");
      }
    }
    await releaseEffect(input.store, lease, "blocked");
    return fail("ambiguous_api", "ambiguous create remained invisible; recreation forbidden");
  }

  await markEffectPossibleSend(input.store, lease);
  let created: AppCheck;
  try {
    created = await input.port.createCheck({ externalId: binding.externalId, headSha: binding.headSha, name: binding.checkName, repositoryId: binding.repositoryId });
  } catch (error) {
    if (error instanceof DefinitiveNotSentError) { await releaseEffect(input.store, lease, "definite_not_sent"); throw error; }
    await releaseEffect(input.store, lease, "ambiguous");
    if (error instanceof AmbiguousCreateError) throw error;
    return fail("ambiguous_api", "check creation outcome is not definite");
  }
  if (!exactCheck(created, binding)) {
    await releaseEffect(input.store, lease, "blocked");
    return fail("identity", "created check identity mismatch");
  }
  await bindCreatedCheck(input.store, lease, created);
  return created;
}

export async function runUpdateCheck(input: {
  generationId: string;
  port: GitHubCheckRunsPort;
  store: DurableStorePort;
  worker: string;
}): Promise<void> {
  const generation = await readGeneration(input.store, input.generationId);
  const binding = await readBinding(input.store, input.generationId);
  if (generation.state !== "completing" || generation.decision === undefined || generation.decision.digest !== binding.decisionDigest || binding.checkId === undefined || !["update_pending", "update_possible"].includes(binding.state)) fail("cas_lost", "update cannot run without one bound immutable decision");
  const lease = await leaseEffect(input.store, input.generationId, "update_check", input.worker);

  const livePullRequest = await input.port.getPullRequest(generation.repositoryId, generation.pullRequestNumber);
  const liveMain = await input.port.getMainRef(generation.repositoryId);
  if (canonicalHash(livePullRequest) !== canonicalHash(generation.snapshot) || liveMain.sha !== generation.mainSha || liveMain.repositoryId !== generation.repositoryId || liveMain.ref !== "refs/heads/main") {
    await releaseEffect(input.store, lease, "definite_not_sent");
    return fail("snapshot_race", "live snapshot changed before Check Run update");
  }
  const matches = await enumerateMatchingChecks(input.port, expectedIdentity(generation), binding.headSha, binding.checkName, binding.externalId, generation.policy.limits);
  if (matches.length !== 1 || matches[0]!.checkId !== binding.checkId || !exactCheck(matches[0]!, binding)) {
    await releaseEffect(input.store, lease, "blocked");
    return fail("identity", "bound Check identity cannot be revalidated");
  }

  await markEffectPossibleSend(input.store, lease);
  try {
    await input.port.updateCheck({
      checkId: binding.checkId,
      conclusion: generation.decision.conclusion,
      repositoryId: binding.repositoryId,
      summary: generation.decision.conclusion === "success" ? "No protected release controls changed." : "Protected release controls changed; owner review is required.",
    });
  } catch (error) {
    await releaseEffect(input.store, lease, "ambiguous");
    if (error instanceof AmbiguousUpdateError) throw error;
    return fail("ambiguous_api", "bound Check update outcome is not definite");
  }
  await completeCheckUpdate(input.store, lease);
}
