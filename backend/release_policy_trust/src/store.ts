import { fail } from "./errors.js";
import type { DurableStorePort, DurableTransaction } from "./ports.js";

interface Versioned { version: number; value: unknown }

function clone<T>(value: T): T {
  return structuredClone(value);
}

class MemoryTransaction implements DurableTransaction {
  constructor(private readonly rows: Map<string, Versioned>) {}

  get(key: string): unknown {
    const row = this.rows.get(key);
    return row === undefined ? undefined : clone(row.value);
  }

  putIfAbsent(key: string, value: unknown): void {
    if (this.rows.has(key)) fail("cas_lost", `unique key already exists: ${key}`);
    this.rows.set(key, { value: clone(value), version: 1 });
  }

  compareAndSwap(key: string, expectedVersion: number, value: unknown): void {
    const row = this.rows.get(key);
    if (row === undefined || row.version !== expectedVersion) fail("cas_lost", `CAS lost: ${key}`);
    this.rows.set(key, { value: clone(value), version: expectedVersion + 1 });
  }
}

export class InMemoryDurableStore implements DurableStorePort {
  private rows = new Map<string, Versioned>();
  failNextCommit = false;
  ambiguousNextCommit = false;

  async transact<T>(work: (transaction: DurableTransaction) => T): Promise<T> {
    const staged = clone(this.rows);
    const result = work(new MemoryTransaction(staged));
    if (this.failNextCommit) {
      this.failNextCommit = false;
      return fail("store_failure", "synthetic store commit failure");
    }
    this.rows = staged;
    if (this.ambiguousNextCommit) {
      this.ambiguousNextCommit = false;
      return fail("store_failure", "synthetic ambiguous store commit");
    }
    return result;
  }

  async read(key: string): Promise<unknown> {
    const row = this.rows.get(key);
    return row === undefined ? undefined : clone(row.value);
  }

  version(key: string): number | undefined { return this.rows.get(key)?.version; }
  keys(): string[] { return [...this.rows.keys()].sort(); }
}

export type ReceiptState = "received" | "snapshotting" | "enqueued" | "processing" | "terminal_success" | "terminal_failure" | "conflict";
export interface Receipt {
  deliveryId: string;
  identityDigest: string;
  installationId: number;
  payloadDigest: string;
  state: ReceiptState;
  targetCount?: number;
  targetDigest?: string;
  version: number;
}
export type GenerationState = "claimed" | "evaluating" | "decision_ready" | "completing" | "terminal_success" | "terminal_failure" | "obsolete" | "blocked_ambiguous";
export interface Generation { generationId: string; pullRequestNumber: number; repositoryId: number; state: GenerationState; version: number }
export interface Outbox { generationId: string; leaseOwner: string | null; operation: "evaluate_generation" | "reevaluate_pr"; version: number }
export interface PushChild { generationId?: string; pullRequestNumber: number; state: "pending" | "enqueued" | "terminal_success" | "terminal_failure"; version: number }
export type BindingState = "none" | "create_pending" | "create_sent" | "bound" | "update_pending" | "terminal";
export interface Binding { checkId?: number; generationId: string; state: BindingState; version: number }

export const receiptKey = (installationId: number, deliveryId: string): string => `receipt/${installationId}/${deliveryId}`;
export const currentKey = (repositoryId: number, pr: number): string => `current/${repositoryId}/${pr}`;
export const generationKey = (generationId: string): string => `generation/${generationId}`;
export const outboxKey = (generationId: string, operation: Outbox["operation"]): string => `outbox/${generationId}/${operation}`;
export const pushChildKey = (installationId: number, deliveryId: string, pr: number): string => `push-child/${installationId}/${deliveryId}/${pr}`;
export const bindingKey = (generationId: string): string => `binding/${generationId}`;

export async function receive(store: DurableStorePort, input: Omit<Receipt, "state" | "version">): Promise<Receipt> {
  const key = receiptKey(input.installationId, input.deliveryId);
  const existing = await store.read(key) as Receipt | undefined;
  if (existing !== undefined) {
    if (existing.payloadDigest !== input.payloadDigest || existing.identityDigest !== input.identityDigest) {
      if (!existing.state.startsWith("terminal") && existing.state !== "conflict") {
        await store.transact((transaction) => transaction.compareAndSwap(key, existing.version, { ...existing, state: "conflict", version: existing.version + 1 }));
      }
      return { ...existing, state: "conflict" };
    }
    return existing;
  }
  const receipt: Receipt = { ...input, state: "received", version: 1 };
  await store.transact((transaction) => transaction.putIfAbsent(key, receipt));
  return receipt;
}

export async function atomicEnqueuePull(store: DurableStorePort, receipt: Receipt, generation: Generation): Promise<void> {
  const rKey = receiptKey(receipt.installationId, receipt.deliveryId);
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  await store.transact((transaction) => {
    const durableReceipt = transaction.get(rKey) as Receipt | undefined;
    if (durableReceipt === undefined || durableReceipt.version !== receipt.version || durableReceipt.state !== "received") fail("cas_lost", "receipt changed before enqueue");
    const current = transaction.get(cKey) as { generationId: string; version: number } | undefined;
    if (current === undefined) transaction.putIfAbsent(cKey, { generationId: generation.generationId, version: 1 });
    else transaction.compareAndSwap(cKey, current.version, { generationId: generation.generationId, version: current.version + 1 });
    transaction.putIfAbsent(generationKey(generation.generationId), generation);
    transaction.putIfAbsent(outboxKey(generation.generationId, "evaluate_generation"), { generationId: generation.generationId, leaseOwner: null, operation: "evaluate_generation", version: 1 } satisfies Outbox);
    transaction.compareAndSwap(rKey, durableReceipt.version, { ...durableReceipt, state: "enqueued", version: durableReceipt.version + 1 });
  });
}

export async function atomicEnqueuePush(store: DurableStorePort, receipt: Receipt, targetDigest: string, pullRequestNumbers: readonly number[]): Promise<void> {
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  if (new Set(pullRequestNumbers).size !== pullRequestNumbers.length || pullRequestNumbers.some((value) => !Number.isSafeInteger(value) || value <= 0)) fail("invalid_input", "invalid push target list");
  await store.transact((transaction) => {
    const durable = transaction.get(key) as Receipt | undefined;
    if (durable === undefined || durable.version !== receipt.version || durable.state !== "received") fail("cas_lost", "push receipt changed before fanout");
    for (const pr of pullRequestNumbers) transaction.putIfAbsent(pushChildKey(receipt.installationId, receipt.deliveryId, pr), { pullRequestNumber: pr, state: "pending", version: 1 } satisfies PushChild);
    transaction.compareAndSwap(key, durable.version, { ...durable, state: "enqueued", targetCount: pullRequestNumbers.length, targetDigest, version: durable.version + 1 });
  });
}

export async function atomicEnqueuePushChild(store: DurableStorePort, receipt: Receipt, generation: Generation): Promise<void> {
  const childKey = pushChildKey(receipt.installationId, receipt.deliveryId, generation.pullRequestNumber);
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber);
  await store.transact((transaction) => {
    const child = transaction.get(childKey) as PushChild | undefined;
    if (child === undefined || child.state !== "pending") fail("cas_lost", "push child unavailable");
    const current = transaction.get(cKey) as { generationId: string; version: number } | undefined;
    if (current === undefined) transaction.putIfAbsent(cKey, { generationId: generation.generationId, version: 1 });
    else transaction.compareAndSwap(cKey, current.version, { generationId: generation.generationId, version: current.version + 1 });
    transaction.putIfAbsent(generationKey(generation.generationId), generation);
    transaction.putIfAbsent(outboxKey(generation.generationId, "evaluate_generation"), { generationId: generation.generationId, leaseOwner: null, operation: "evaluate_generation", version: 1 } satisfies Outbox);
    transaction.compareAndSwap(childKey, child.version, { ...child, generationId: generation.generationId, state: "enqueued", version: child.version + 1 });
  });
}

export async function leaseOutbox(store: DurableStorePort, generationId: string, worker: string): Promise<Outbox> {
  const key = outboxKey(generationId, "evaluate_generation");
  const row = await store.read(key) as Outbox | undefined;
  if (row === undefined || row.leaseOwner !== null) return fail("cas_lost", "outbox unavailable");
  const next = { ...row, leaseOwner: worker, version: row.version + 1 };
  await store.transact((transaction) => transaction.compareAndSwap(key, row.version, next));
  return next;
}

export async function assertCurrentGeneration(store: DurableStorePort, generation: Generation): Promise<void> {
  const current = await store.read(currentKey(generation.repositoryId, generation.pullRequestNumber)) as { generationId: string } | undefined;
  if (current?.generationId !== generation.generationId) fail("cas_lost", "worker generation is stale");
}

export async function recordBoundCheck(store: DurableStorePort, generation: Generation, checkId: number): Promise<void> {
  if (!Number.isSafeInteger(checkId) || checkId <= 0) fail("identity", "invalid bound check id");
  await assertCurrentGeneration(store, generation);
  const key = bindingKey(generation.generationId);
  const existing = await store.read(key) as Binding | undefined;
  if (existing !== undefined) {
    if (existing.checkId === checkId && (existing.state === "bound" || existing.state === "terminal")) return;
    fail("cas_lost", "generation already has a different check binding");
  }
  await store.transact((transaction) => transaction.putIfAbsent(key, { checkId, generationId: generation.generationId, state: "bound", version: 1 } satisfies Binding));
}

export async function markBindingTerminal(store: DurableStorePort, generation: Generation, checkId: number): Promise<void> {
  await assertCurrentGeneration(store, generation);
  const key = bindingKey(generation.generationId);
  const binding = await store.read(key) as Binding | undefined;
  if (binding === undefined || binding.state !== "bound" || binding.checkId !== checkId) fail("cas_lost", "bound check changed");
  await store.transact((transaction) => transaction.compareAndSwap(key, binding.version, { ...binding, state: "terminal", version: binding.version + 1 }));
}
