import {
  AmbiguousCreateError, AmbiguousUpdateError, beginReceiptSnapshot, commitDecision,
  prepareCheckBinding, receive, runCreateCheck, runUpdateCheck, settlePullReceipt,
  snapshotPullRequest, snapshotPushTargets, atomicEnqueuePull, atomicEnqueuePush, atomicEnqueuePushChild, leasePushChild, settlePushChild, recoverEvaluationLease, recoverAbandonedEffect,
  type CanonicalReleasePolicy, type ExpectedIdentity, type GitHubCheckRunsPort,
  type Receipt,
} from "@archivale/release-policy-trust";
import type { DurableStorage } from "./platform.js";
import type { SqliteStore } from "./sqlite_store.js";
import { sanitizeTelemetry } from "./telemetry.js";

export type DeliveryTarget = { kind: "pull_request"; pullRequestNumber: number } | { kind: "push"; after: string };
export interface EffectRuntime {
  clock: { delay(seconds: number): Promise<void> };
  identity: ExpectedIdentity;
  policy: CanonicalReleasePolicy;
  port?: GitHubCheckRunsPort;
  portFactory?: () => GitHubCheckRunsPort;
}

const RETRY_SECONDS = [1, 5, 30, 120, 600] as const;
const targetMetaKey = (installationId: number, deliveryId: string) => `target/${installationId}/${deliveryId}`;

/** The alarm is the sole drainer. Ingress only persists and requests it. */
export class AlarmDispatcher {
  constructor(private readonly storage: DurableStorage, private readonly store: SqliteStore, private readonly runtime: EffectRuntime) {}
  async requestDrain(at = Date.now(), reassert = false): Promise<boolean> { const current = await this.storage.getAlarm(); if (current === null || reassert) { await this.storage.setAlarm(Math.max(at, current ?? at) + 100); return true; } return false; }
  async watchdog(): Promise<void> {
    const pendingReceipts = this.store.entries("receipt/").filter(({ value }) => !["terminal_success", "terminal_failure", "conflict"].includes((value as Receipt).state));
    const pending = pendingReceipts.length;
    const alarm = await this.storage.getAlarm();
    // Persist only bounded, non-sensitive operational buckets; never payloads,
    // headers, credentials, provider errors, or raw quota values.
    const alarmRuntime = this.store.readMeta<{ running: boolean; started_at: number }>("alarm_runtime/v1");
    const alarmIsActive = alarmRuntime?.running === true && Number.isFinite(alarmRuntime.started_at) && Date.now() - alarmRuntime.started_at < 60_000;
    const alarmReasserted = pending > 0 && !alarmIsActive ? await this.requestDrain(Date.now(), true) : false;
    const oldestReceivedAt = pendingReceipts.map(({ value }) => value as Receipt).map((receipt) => this.store.readMeta<DeliveryTarget & { received_at?: number }>(targetMetaKey(receipt.installationId, receipt.deliveryId))?.received_at).filter((value): value is number => typeof value === "number" && Number.isFinite(value)).sort((a, b) => a - b)[0];
    const oldestWorkBucket = oldestReceivedAt === undefined ? 0 : Date.now() - oldestReceivedAt < 60_000 ? 1 : 2;
    const bindings = this.store.entries("binding/").map(({ value }) => value as { checkId?: number; externalId?: string }); const seen = new Set<string>(); let duplicates = 0;
    for (const binding of bindings) { if (binding.checkId === undefined || binding.externalId === undefined) continue; const identity = `${binding.checkId}:${binding.externalId}`; if (seen.has(identity)) duplicates += 1; else seen.add(identity); }
    const rows = this.store.rowCount();
    this.store.writeMeta("watchdog/v1", sanitizeTelemetry({ alarm_present: alarm !== null, alarm_reasserted: alarmReasserted, duplicate_binding_bucket: duplicates === 0 ? 0 : duplicates < 3 ? 1 : 2, forbidden_egress_count: 0, oldest_work_bucket: oldestWorkBucket, pending_bucket: pending === 0 ? 0 : pending < 10 ? 1 : 2, row_headroom_bucket: rows < 50 ? 0 : rows < 100 ? 1 : 2, status_egress_count: 0 }));
  }
  rememberTarget(receipt: Pick<Receipt, "installationId" | "deliveryId">, target: DeliveryTarget): void { const key = targetMetaKey(receipt.installationId, receipt.deliveryId); if (this.store.readMeta(key) === undefined) this.store.writeMeta(key, { ...target, received_at: Date.now() }); }
  async alarm(): Promise<void> {
    const port = this.runtime.portFactory?.() ?? this.runtime.port;
    if (!port) throw new Error("alarm GitHub port unavailable");
    const priorAlarmCount = this.store.readMeta<number>("alarm_count/v1") ?? 0;
    this.store.writeMeta("alarm_count/v1", Math.min(priorAlarmCount + 1, 9));
    this.store.writeMeta("alarm_runtime/v1", { running: true, started_at: Date.now() });
    const pullSnapshots = new Map<number, Promise<Awaited<ReturnType<typeof snapshotPullRequest>>>>();
    try {
      let retryAt: number | undefined;
      for (const row of this.store.entries("receipt/")) {
        const receipt = row.value as Receipt;
        try { await this.advanceReceipt(receipt, port, pullSnapshots); }
        catch (error) { retryAt = Math.min(retryAt ?? Infinity, this.recordRetry(receipt, error)); }
      }
      // A future alarm is required whenever durable non-terminal work remains.
      if (this.hasPendingWork()) await this.storage.setAlarm(retryAt ?? Date.now() + 25);
    } finally {
      this.store.writeMeta("alarm_runtime/v1", { running: false, started_at: 0 });
    }
  }
  private async advanceReceipt(receipt: Receipt, port: GitHubCheckRunsPort, pullSnapshots: Map<number, Promise<Awaited<ReturnType<typeof snapshotPullRequest>>>>): Promise<void> {
    if (["terminal_success", "terminal_failure", "conflict"].includes(receipt.state)) return;
    const target = this.store.readMeta<DeliveryTarget>(targetMetaKey(receipt.installationId, receipt.deliveryId));
    if (!target) throw new Error("delivery target missing");
    if (receipt.state === "received" || receipt.state === "snapshotting") {
      const snapshotting = await beginReceiptSnapshot(this.store, receipt);
      if (snapshotting.state !== "snapshotting") return;
      if (target.kind === "pull_request") {
        const evaluation = await this.pullSnapshot(port, target.pullRequestNumber, pullSnapshots);
        await atomicEnqueuePull(this.store, snapshotting, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation));
      } else {
        const targets = await snapshotPushTargets(port, this.runtime.identity, target.after, this.runtime.policy);
        await atomicEnqueuePush(this.store, snapshotting, targets.digest, targets.numbers);
      }
    }
    const current = await this.store.read(`receipt/${receipt.installationId}/${receipt.deliveryId}`) as Receipt | undefined;
    if (current?.kind === "push" && current.targetNumbers) return this.advancePush(current, port, pullSnapshots);
    if (!current?.generationId) return;
    await this.advanceGeneration(current.generationId, port);
    await settlePullReceipt(this.store, current);
  }
  private async advancePush(receipt: Receipt, port: GitHubCheckRunsPort, pullSnapshots: Map<number, Promise<Awaited<ReturnType<typeof snapshotPullRequest>>>>): Promise<void> {
    for (const pr of receipt.targetNumbers ?? []) {
      const child = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`) as { state: string; generationId?: string } | undefined;
      if (!child || ["terminal_success", "terminal_failure"].includes(child.state)) continue;
      if (child.state === "pending") {
        const worker = `alarm:push:${receipt.deliveryId.slice(0, 16)}:${pr}`;
        await leasePushChild(this.store, receipt, pr, worker);
        const evaluation = await this.pullSnapshot(port, pr, pullSnapshots);
        await atomicEnqueuePushChild(this.store, receipt, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation), worker);
      }
      const durable = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`) as { generationId?: string } | undefined;
      if (durable?.generationId) { await this.advanceGeneration(durable.generationId, port); await settlePushChild(this.store, receipt, pr); }
    }
  }
  private pullSnapshot(port: GitHubCheckRunsPort, pullRequestNumber: number, cache: Map<number, Promise<Awaited<ReturnType<typeof snapshotPullRequest>>>>): Promise<Awaited<ReturnType<typeof snapshotPullRequest>>> {
    const prior = cache.get(pullRequestNumber); if (prior) return prior;
    const pending = snapshotPullRequest(port, this.runtime.identity, pullRequestNumber, this.runtime.policy);
    cache.set(pullRequestNumber, pending); return pending;
  }
  private async advanceGeneration(generationId: string, port: GitHubCheckRunsPort): Promise<void> {
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
    if (afterBinding?.state === "decision_ready") await runCreateCheck({ clock: this.runtime.clock, generationId, port, store: this.store, worker });
    const completing = await this.store.read(`generation/${generationId}`) as { state?: string } | undefined;
    if (completing?.state === "completing") await runUpdateCheck({ generationId, port, store: this.store, worker });
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
