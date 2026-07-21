import {
  AmbiguousCreateError, AmbiguousUpdateError, beginReceiptSnapshot, commitDecision,
  prepareCheckBinding, receive, runCreateCheck, runUpdateCheck, settlePullReceipt,
  snapshotPullRequest, snapshotPushTargets, atomicEnqueuePull, atomicEnqueuePush, atomicEnqueuePushChild, leasePushChild, settlePushChild, recoverEvaluationLease, recoverAbandonedEffect,
  type CanonicalReleasePolicy, type ExpectedIdentity, type GitHubCheckRunsPort,
  type Receipt,
} from "@archivale/release-policy-trust";
import type { DurableStorage } from "./platform.js";
import type { SqliteStore } from "./sqlite_store.js";

export type DeliveryTarget = { kind: "pull_request"; pullRequestNumber: number } | { kind: "push"; after: string };
export interface EffectRuntime {
  clock: { delay(seconds: number): Promise<void> };
  identity: ExpectedIdentity;
  policy: CanonicalReleasePolicy;
  port: GitHubCheckRunsPort;
}

const RETRY_SECONDS = [1, 5, 30, 120, 600] as const;
const targetMetaKey = (installationId: number, deliveryId: string) => `target/${installationId}/${deliveryId}`;

/** The alarm is the sole drainer. Ingress only persists and requests it. */
export class AlarmDispatcher {
  constructor(private readonly storage: DurableStorage, private readonly store: SqliteStore, private readonly runtime: EffectRuntime) {}
  async requestDrain(at = Date.now()): Promise<void> { if (await this.storage.getAlarm() === null) await this.storage.setAlarm(at); }
  async watchdog(): Promise<void> { await this.requestDrain(); }
  rememberTarget(receipt: Pick<Receipt, "installationId" | "deliveryId">, target: DeliveryTarget): void { this.store.writeMeta(targetMetaKey(receipt.installationId, receipt.deliveryId), target); }
  async alarm(): Promise<void> {
    let retryAt: number | undefined;
    for (const row of this.store.entries("receipt/")) {
      const receipt = row.value as Receipt;
      try { await this.advanceReceipt(receipt); }
      catch (error) { retryAt = Math.min(retryAt ?? Infinity, this.recordRetry(receipt, error)); }
    }
    // A future alarm is required whenever durable non-terminal work remains.
    if (this.hasPendingWork()) await this.storage.setAlarm(retryAt ?? Date.now());
  }
  private async advanceReceipt(receipt: Receipt): Promise<void> {
    if (["terminal_success", "terminal_failure", "conflict"].includes(receipt.state)) return;
    const target = this.store.readMeta<DeliveryTarget>(targetMetaKey(receipt.installationId, receipt.deliveryId));
    if (!target) throw new Error("delivery target missing");
    if (receipt.state === "received") {
      const snapshotting = await beginReceiptSnapshot(this.store, receipt);
      if (snapshotting.state !== "snapshotting") return;
      if (target.kind === "pull_request") {
        const evaluation = await snapshotPullRequest(this.runtime.port, this.runtime.identity, target.pullRequestNumber, this.runtime.policy);
        await atomicEnqueuePull(this.store, snapshotting, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation));
      } else {
        const targets = await snapshotPushTargets(this.runtime.port, this.runtime.identity, target.after, this.runtime.policy);
        await atomicEnqueuePush(this.store, snapshotting, targets.digest, targets.numbers);
      }
    }
    const current = await this.store.read(`receipt/${receipt.installationId}/${receipt.deliveryId}`) as Receipt | undefined;
    if (current?.kind === "push" && current.targetNumbers) return this.advancePush(current);
    if (!current?.generationId) return;
    await this.advanceGeneration(current.generationId);
    await settlePullReceipt(this.store, current);
  }
  private async advancePush(receipt: Receipt): Promise<void> {
    for (const pr of receipt.targetNumbers ?? []) {
      const child = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`) as { state: string; generationId?: string } | undefined;
      if (!child || ["terminal_success", "terminal_failure"].includes(child.state)) continue;
      if (child.state === "pending") {
        const worker = `alarm:push:${receipt.deliveryId.slice(0, 16)}:${pr}`;
        await leasePushChild(this.store, receipt, pr, worker);
        const evaluation = await snapshotPullRequest(this.runtime.port, this.runtime.identity, pr, this.runtime.policy);
        await atomicEnqueuePushChild(this.store, receipt, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation), worker);
      }
      const durable = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`) as { generationId?: string } | undefined;
      if (durable?.generationId) { await this.advanceGeneration(durable.generationId); await settlePushChild(this.store, receipt, pr); }
    }
  }
  private async advanceGeneration(generationId: string): Promise<void> {
    const generation = await this.store.read(`generation/${generationId}`) as { state?: string } | undefined;
    if (!generation || ["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state ?? "")) return;
    const worker = `alarm:${generationId.slice(0, 16)}`;
    // A prior alarm may have died after durable leasing. Reclaim only the
    // recorded owner/fence; possible-send is deliberately reconciled by core.
    const evaluation = await this.store.read(`outbox/${generationId}/evaluate_generation`) as { state?: string; leaseOwner?: string } | undefined;
    if (evaluation?.state === "leased" && evaluation.leaseOwner) await recoverEvaluationLease(this.store, generationId, evaluation.leaseOwner);
    for (const operation of ["create_check", "update_check"] as const) {
      const effect = await this.store.read(`outbox/${generationId}/${operation}`) as { state?: string; leaseOwner?: string; fence?: number } | undefined;
      if (["send_leased", "reconcile_leased"].includes(effect?.state ?? "") && effect?.leaseOwner && typeof effect.fence === "number") await recoverAbandonedEffect(this.store, generationId, operation, effect.leaseOwner, effect.fence);
    }
    if (generation.state === "claimed") {
      const { leaseOutbox } = await import("@archivale/release-policy-trust");
      await leaseOutbox(this.store, generationId, worker); await commitDecision(this.store, generationId, worker);
    }
    const afterEvaluation = await this.store.read(`generation/${generationId}`) as { state?: string } | undefined;
    if (afterEvaluation?.state === "decision_ready") await prepareCheckBinding(this.store, generationId, this.runtime.identity);
    const afterBinding = await this.store.read(`generation/${generationId}`) as { state?: string } | undefined;
    if (afterBinding?.state === "decision_ready") await runCreateCheck({ ...this.runtime, generationId, store: this.store, worker });
    const completing = await this.store.read(`generation/${generationId}`) as { state?: string } | undefined;
    if (completing?.state === "completing") await runUpdateCheck({ generationId, port: this.runtime.port, store: this.store, worker });
  }
  private hasPendingWork(): boolean { return this.store.entries("receipt/").some(({ value }) => !["terminal_success", "terminal_failure", "conflict"].includes((value as Receipt).state)); }
  private recordRetry(receipt: Receipt, error: unknown): number {
    // Error text is deliberately not persisted: it may contain provider material.
    const key = `retry/${receipt.installationId}/${receipt.deliveryId}`;
    const previous = this.store.readMeta<{ attempts: number }>(key)?.attempts ?? 0;
    const attempts = Math.min(previous + 1, RETRY_SECONDS.length);
    const retryAt = Date.now() + RETRY_SECONDS[attempts - 1]! * 1000;
    const errorClass = error instanceof AmbiguousCreateError || error instanceof AmbiguousUpdateError ? "ambiguous" : "transient";
    this.store.writeMeta(key, { attempts, error_class: errorClass, retry_at: retryAt });
    return retryAt;
  }
}
