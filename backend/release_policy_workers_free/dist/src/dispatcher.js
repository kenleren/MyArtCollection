import { AmbiguousCreateError, AmbiguousUpdateError, DefinitiveNotSentError, beginReceiptSnapshot, commitDecision, prepareCheckBinding, runCreateCheck, reconcileCreateCheckOnce, runUpdateCheck, settlePullReceipt, snapshotPullRequest, snapshotPushTargets, atomicEnqueuePull, atomicEnqueuePush, atomicEnqueuePushChild, leasePushChild, settlePushChild, recoverEvaluationLease, recoverAbandonedEffect, } from "@archivale/release-policy-trust";
import { boundedBucket, sanitizeTelemetry } from "./telemetry.js";
const RETRY_SECONDS = [1, 5, 30, 120, 600];
const targetMetaKey = (installationId, deliveryId) => `target/${installationId}/${deliveryId}`;
/** The alarm is the sole drainer. Ingress only persists and requests it. */
export class AlarmDispatcher {
    storage;
    store;
    runtime;
    constructor(storage, store, runtime) {
        this.storage = storage;
        this.store = store;
        this.runtime = runtime;
    }
    async requestDrain(at = Date.now(), reassert = false) { const current = await this.storage.getAlarm(); if (current === null || reassert) {
        await this.storage.setAlarm(Math.max(at, current ?? at) + 100);
        return true;
    } return false; }
    async watchdog() {
        const pendingReceipts = this.store.entries("receipt/").filter(({ value }) => !["terminal_success", "terminal_failure", "conflict"].includes(value.state));
        const pending = pendingReceipts.length;
        const alarm = await this.storage.getAlarm();
        // Persist only bounded, non-sensitive operational buckets; never payloads,
        // headers, credentials, provider errors, or raw quota values.
        const alarmRuntime = this.store.readMeta("alarm_runtime/v1");
        const alarmIsActive = alarmRuntime?.running === true && Number.isFinite(alarmRuntime.started_at) && Date.now() - alarmRuntime.started_at < 60_000;
        const alarmReasserted = pending > 0 && !alarmIsActive ? await this.requestDrain(Date.now(), true) : false;
        const oldestReceivedAt = pendingReceipts.map(({ value }) => value).map((receipt) => this.store.readMeta(targetMetaKey(receipt.installationId, receipt.deliveryId))?.received_at).filter((value) => typeof value === "number" && Number.isFinite(value)).sort((a, b) => a - b)[0];
        const oldestWorkBucket = oldestReceivedAt === undefined ? 0 : Date.now() - oldestReceivedAt < 60_000 ? 1 : 2;
        const bindings = this.store.entries("binding/").map(({ value }) => value);
        const seen = new Set();
        let duplicates = 0;
        for (const binding of bindings) {
            if (binding.checkId === undefined || binding.externalId === undefined)
                continue;
            const identity = `${binding.checkId}:${binding.externalId}`;
            if (seen.has(identity))
                duplicates += 1;
            else
                seen.add(identity);
        }
        const rows = this.store.rowCount();
        const bytes = this.store.databaseBytes();
        const metric = (name) => this.store.readMeta(`${name}/v1`) ?? 0;
        const doInvocations = metric("do_request_count") + metric("alarm_count");
        this.store.writeMeta("watchdog/v1", sanitizeTelemetry({
            alarm_present: alarm !== null, alarm_reasserted: alarmReasserted,
            do_headroom_bucket: boundedBucket(doInvocations, 1_000, 10_000),
            duplicate_binding_bucket: boundedBucket(duplicates, 1, 3), duplicate_check_bucket: boundedBucket(metric("egress/duplicate_check"), 1, 3),
            exceeded_resource_bucket: boundedBucket(metric("egress/exceeded_resource"), 1, 3), forbidden_egress_bucket: boundedBucket(metric("egress/forbidden_egress"), 1, 3),
            oldest_work_bucket: oldestWorkBucket, pending_bucket: boundedBucket(pending, 10, 100),
            provider_error_bucket: boundedBucket(metric("egress/provider_error"), 1, 3), request_headroom_bucket: boundedBucket(metric("egress/request_high_water"), 40, 51),
            row_headroom_bucket: boundedBucket(rows, 50, 100), status_egress_bucket: boundedBucket(metric("egress/status_egress"), 1, 3),
            storage_headroom_bucket: boundedBucket(bytes, 524_288, 1_048_576), worker_error_bucket: boundedBucket(metric("worker_error_count"), 1, 3),
        }));
    }
    rememberTarget(receipt, target) { const key = targetMetaKey(receipt.installationId, receipt.deliveryId); if (this.store.readMeta(key) === undefined)
        this.store.writeMeta(key, { ...target, received_at: Date.now() }); }
    async alarm() {
        const quota = typeof this.store.reserveQuota === "function" ? this.store.reserveQuota(Date.now(), { alarms: 1 }) : { admitted: true, rolloverAt: Date.now() + 25 };
        if (!quota.admitted) {
            await this.storage.setAlarm(quota.rolloverAt);
            return;
        }
        const port = this.runtime.portFactory?.() ?? this.runtime.port;
        if (!port)
            throw new Error("alarm GitHub port unavailable");
        const priorAlarmCount = this.store.readMeta("alarm_count/v1") ?? 0;
        this.store.writeMeta("alarm_count/v1", Math.min(priorAlarmCount + 1, 10_001));
        this.store.writeMeta("alarm_runtime/v1", { running: true, started_at: Date.now() });
        const pullSnapshots = new Map();
        try {
            let retryAt;
            for (const row of this.store.entries("receipt/")) {
                const receipt = row.value;
                const retry = this.store.readMeta(`retry/${receipt.installationId}/${receipt.deliveryId}`);
                if (retry?.state === "quarantined")
                    continue;
                if (typeof retry?.retry_at === "number" && retry.retry_at > Date.now()) {
                    retryAt = Math.min(retryAt ?? Infinity, retry.retry_at);
                    continue;
                }
                try {
                    await this.advanceReceipt(receipt, port, pullSnapshots);
                }
                catch (error) {
                    this.store.incrementMeta("worker_error_count/v1");
                    if (error instanceof DefinitiveNotSentError)
                        this.store.incrementMeta("egress/exceeded_resource/v1");
                    retryAt = Math.min(retryAt ?? Infinity, this.recordRetry(receipt, error));
                }
            }
            // A future alarm is required whenever durable non-terminal work remains.
            if (this.hasPendingWork())
                await this.storage.setAlarm(retryAt ?? Date.now() + 25);
        }
        finally {
            this.store.writeMeta("alarm_runtime/v1", { running: false, started_at: 0 });
        }
    }
    async advanceReceipt(receipt, port, pullSnapshots) {
        if (["terminal_success", "terminal_failure", "conflict"].includes(receipt.state))
            return;
        const target = this.store.readMeta(targetMetaKey(receipt.installationId, receipt.deliveryId));
        if (!target)
            throw new Error("delivery target missing");
        if (receipt.state === "received" || receipt.state === "snapshotting") {
            const snapshotting = await beginReceiptSnapshot(this.store, receipt);
            if (snapshotting.state !== "snapshotting")
                return;
            if (target.kind === "pull_request") {
                const evaluation = await this.pullSnapshot(port, target.pullRequestNumber, pullSnapshots);
                await atomicEnqueuePull(this.store, snapshotting, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation));
            }
            else {
                const targets = await snapshotPushTargets(port, this.runtime.identity, target.after, this.runtime.policy);
                await atomicEnqueuePush(this.store, snapshotting, targets.digest, targets.numbers);
            }
        }
        const current = await this.store.read(`receipt/${receipt.installationId}/${receipt.deliveryId}`);
        if (current?.kind === "push" && current.targetNumbers)
            return this.advancePush(current, port, pullSnapshots);
        if (!current?.generationId)
            return;
        await this.advanceGeneration(current.generationId, port);
        await settlePullReceipt(this.store, current);
    }
    async advancePush(receipt, port, pullSnapshots) {
        for (const pr of receipt.targetNumbers ?? []) {
            const child = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`);
            if (!child || ["terminal_success", "terminal_failure"].includes(child.state))
                continue;
            if (child.state === "pending") {
                const worker = `alarm:push:${receipt.deliveryId.slice(0, 16)}:${pr}`;
                await leasePushChild(this.store, receipt, pr, worker);
                const evaluation = await this.pullSnapshot(port, pr, pullSnapshots);
                await atomicEnqueuePushChild(this.store, receipt, (await import("@archivale/release-policy-trust")).generationFromEvaluation(evaluation), worker);
            }
            const durable = await this.store.read(`push-child/${receipt.installationId}/${receipt.deliveryId}/${pr}`);
            if (durable?.generationId) {
                await this.advanceGeneration(durable.generationId, port);
                await settlePushChild(this.store, receipt, pr);
            }
        }
    }
    pullSnapshot(port, pullRequestNumber, cache) {
        const prior = cache.get(pullRequestNumber);
        if (prior)
            return prior;
        const pending = snapshotPullRequest(port, this.runtime.identity, pullRequestNumber, this.runtime.policy);
        cache.set(pullRequestNumber, pending);
        return pending;
    }
    async advanceGeneration(generationId, port) {
        const generation = await this.store.read(`generation/${generationId}`);
        if (!generation || ["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state ?? ""))
            return;
        const worker = `alarm:${generationId.slice(0, 16)}`;
        // A prior alarm may have died after durable leasing. Reclaim only the
        // recorded owner/fence; possible-send is deliberately reconciled by core.
        const evaluation = await this.store.read(`outbox/${generationId}/evaluate_generation`);
        if (evaluation?.state === "leased" && evaluation.leaseOwner)
            await recoverEvaluationLease(this.store, generationId, evaluation.leaseOwner);
        for (const operation of ["create_check", "update_check"]) {
            const effect = await this.store.read(`outbox/${generationId}/${operation}`);
            if (["send_leased", "reconcile_leased"].includes(effect?.state ?? "") && effect?.leaseOwner && typeof effect.fence === "number")
                await recoverAbandonedEffect(this.store, generationId, operation, effect.leaseOwner, effect.fence);
        }
        if (generation.state === "claimed") {
            const { leaseOutbox } = await import("@archivale/release-policy-trust");
            await leaseOutbox(this.store, generationId, worker);
            await commitDecision(this.store, generationId, worker);
        }
        const afterEvaluation = await this.store.read(`generation/${generationId}`);
        if (afterEvaluation?.state === "decision_ready")
            await prepareCheckBinding(this.store, generationId, this.runtime.identity);
        const afterBinding = await this.store.read(`generation/${generationId}`);
        if (afterBinding?.state === "decision_ready") {
            const reconcileKey = `reconcile/${generationId}/v1`;
            const reconciliation = this.store.readMeta(reconcileKey);
            if (reconciliation && !reconciliation.cleared) {
                if (reconciliation.due_at > Date.now())
                    return;
                const result = await reconcileCreateCheckOnce({ generationId, port, store: this.store, worker, finalAttempt: reconciliation.attempt >= 5 });
                if (result === "not_visible") {
                    const delay = [1, 2, 4, 8, 16, 32][reconciliation.attempt + 1] ?? 32;
                    this.store.writeMeta(reconcileKey, { attempt: reconciliation.attempt + 1, due_at: Date.now() + delay * 1000 });
                }
                else
                    this.store.writeMeta(reconcileKey, { attempt: reconciliation.attempt, due_at: 0, cleared: true });
            }
            else {
                try {
                    await runCreateCheck({ clock: this.runtime.clock, generationId, port, store: this.store, worker });
                }
                catch (error) {
                    if (error instanceof AmbiguousCreateError) {
                        this.store.writeMeta(reconcileKey, { attempt: 0, due_at: Date.now() + 1000 });
                        return;
                    }
                    throw error;
                }
            }
        }
        const completing = await this.store.read(`generation/${generationId}`);
        if (completing?.state === "completing")
            await runUpdateCheck({ generationId, port, store: this.store, worker });
    }
    hasPendingWork() { return this.store.entries("receipt/").some(({ value }) => { const receipt = value; const retry = this.store.readMeta(`retry/${receipt.installationId}/${receipt.deliveryId}`); return !["terminal_success", "terminal_failure", "conflict"].includes(receipt.state) && retry?.state !== "quarantined"; }); }
    recordRetry(receipt, error) {
        // Error text is deliberately not persisted: it may contain provider material.
        const key = `retry/${receipt.installationId}/${receipt.deliveryId}`;
        const previous = this.store.readMeta(key)?.attempts ?? 0;
        const attempts = Math.min(previous + 1, RETRY_SECONDS.length);
        const retryAt = Date.now() + RETRY_SECONDS[attempts - 1] * 1000;
        const errorClass = error instanceof AmbiguousCreateError || error instanceof AmbiguousUpdateError ? "ambiguous" : "transient";
        this.store.writeMeta(key, attempts >= RETRY_SECONDS.length ? { attempts, error_class: errorClass, state: "quarantined" } : { attempts, error_class: errorClass, retry_at: retryAt });
        return retryAt;
    }
}
