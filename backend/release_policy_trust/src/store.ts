import { canonicalHash, generationId as hashGenerationTuple } from "./canonical.js";
import { FailClosedError, fail } from "./errors.js";
import type { AppCheck, DurableStorePort, DurableTransaction, ExpectedIdentity, PullRequestSnapshot } from "./ports.js";
import type { ImmutableEvaluation } from "./snapshot.js";

interface Versioned { version: number; value: unknown }

function clone<T>(value: T): T { return structuredClone(value); }

class MemoryTransaction implements DurableTransaction {
  constructor(private readonly rows: Map<string, Versioned>) {}
  get(key: string): unknown { const row = this.rows.get(key); return row === undefined ? undefined : clone(row.value); }
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
    if (this.failNextCommit) { this.failNextCommit = false; return fail("store_failure", "synthetic store commit failure"); }
    this.rows = staged;
    if (this.ambiguousNextCommit) { this.ambiguousNextCommit = false; return fail("store_failure", "synthetic ambiguous store commit"); }
    return result;
  }
  async read(key: string): Promise<unknown> { const row = this.rows.get(key); return row === undefined ? undefined : clone(row.value); }
  version(key: string): number | undefined { return this.rows.get(key)?.version; }
  keys(): string[] { return [...this.rows.keys()].sort(); }
}

export type ReceiptTerminalOutcome = "terminal_success" | "terminal_failure";
export type ReceiptState = "received" | "snapshotting" | "enqueued" | ReceiptTerminalOutcome | "conflict";
export interface Receipt {
  completedOutcome?: ReceiptTerminalOutcome;
  deliveryId: string;
  generationId?: string;
  identityDigest: string;
  installationId: number;
  kind: "pull_request" | "push";
  payloadDigest: string;
  state: ReceiptState;
  targetCount?: number;
  targetDigest?: string;
  targetNumbers?: number[];
  version: number;
}

export type GenerationState = "claimed" | "evaluating" | "decision_ready" | "completing" | "terminal_success" | "terminal_failure" | "obsolete" | "blocked_ambiguous";
export interface Generation {
  decision?: ImmutableEvaluation["decision"];
  draftDecision: ImmutableEvaluation["decision"];
  fileCount: number;
  filesDigest: string;
  generationId: string;
  immutableDigest: string;
  mainSha: string;
  policy: ImmutableEvaluation["policy"];
  pullRequestNumber: number;
  repositoryId: number;
  snapshot: PullRequestSnapshot;
  state: GenerationState;
  tuple: ImmutableEvaluation["tuple"];
  version: number;
}

export interface EffectLease { fence: number; generationId: string; operation: "create_check" | "update_check"; owner: string; mode: "send" | "reconcile" | "retry" }
export interface CurrentGeneration { effectLease: Omit<EffectLease, "generationId" | "mode"> | null; generationId: string; nextFence: number; version: number }
export type IntentOperation = "evaluate_generation" | "create_check" | "update_check";
export type IntentState = "pending" | "leased" | "send_leased" | "reconcile_leased" | "possible_send" | "delivered" | "blocked";
export interface Outbox { fence: number | null; generationId: string; leaseOwner: string | null; operation: IntentOperation; state: IntentState; version: number }
export interface PushChild { generationId?: string; leaseOwner: string | null; pullRequestNumber: number; state: "pending" | "leased" | "enqueued" | "terminal_success" | "terminal_failure"; version: number }
export type BindingState = "create_pending" | "create_possible" | "bound" | "update_pending" | "update_possible" | "terminal" | "blocked";
export interface Binding {
  appId: number;
  checkId?: number;
  checkName: string;
  decisionDigest: string;
  externalId: string;
  generationId: string;
  headSha: string;
  policyDigest: string;
  repositoryId: number;
  state: BindingState;
  version: number;
}

export const receiptKey = (installationId: number, deliveryId: string): string => `receipt/${installationId}/${deliveryId}`;
export const currentKey = (repositoryId: number, pr: number): string => `current/${repositoryId}/${pr}`;
export const generationKey = (generationId: string): string => `generation/${generationId}`;
export const outboxKey = (generationId: string, operation: IntentOperation): string => `outbox/${generationId}/${operation}`;
export const pushChildKey = (installationId: number, deliveryId: string, pr: number): string => `push-child/${installationId}/${deliveryId}/${pr}`;
export const bindingKey = (generationId: string): string => `binding/${generationId}`;

function bindingIdentity(value: Binding): unknown {
  return {
    app_id: value.appId,
    check_name: value.checkName,
    decision_digest: value.decisionDigest,
    external_id: value.externalId,
    generation_id: value.generationId,
    head_sha: value.headSha,
    policy_digest: value.policyDigest,
    repository_id: value.repositoryId,
  };
}

function terminal(state: ReceiptState | GenerationState | PushChild["state"]): boolean { return state.startsWith("terminal") || state === "conflict" || state === "obsolete"; }
function positive(value: number, label: string): void { if (!Number.isSafeInteger(value) || value <= 0) fail("invalid_input", `${label} must be a positive safe integer`); }
function digest(value: string, label: string): void { if (!/^[0-9a-f]{64}$/.test(value)) fail("invalid_input", `${label} must be SHA-256`); }

function immutableGenerationValue(generation: Omit<Generation, "immutableDigest" | "state" | "version" | "decision">): unknown {
  return {
    draft_decision: generation.draftDecision,
    file_count: generation.fileCount,
    files_digest: generation.filesDigest,
    generation_id: generation.generationId,
    main_sha: generation.mainSha,
    policy: generation.policy,
    pull_request_number: generation.pullRequestNumber,
    repository_id: generation.repositoryId,
    snapshot: generation.snapshot,
    tuple: generation.tuple,
  };
}

export function generationFromEvaluation(evaluation: ImmutableEvaluation): Generation {
  const base = {
    draftDecision: clone(evaluation.decision),
    fileCount: evaluation.fileCount,
    filesDigest: evaluation.filesDigest,
    generationId: evaluation.generationId,
    mainSha: evaluation.mainSha,
    policy: clone(evaluation.policy),
    pullRequestNumber: evaluation.tuple.pull_request_number,
    repositoryId: evaluation.tuple.repository_id,
    snapshot: clone(evaluation.snapshot),
    tuple: clone(evaluation.tuple),
  };
  return { ...base, immutableDigest: canonicalHash(immutableGenerationValue(base)), state: "claimed", version: 1 };
}

function validateGeneration(generation: Generation): void {
  positive(generation.repositoryId, "repository id"); positive(generation.pullRequestNumber, "pull request number");
  digest(generation.filesDigest, "files digest"); digest(generation.policy.digest, "policy digest"); digest(generation.draftDecision.digest, "decision digest"); digest(generation.immutableDigest, "immutable generation digest");
  if (generation.generationId !== hashGenerationTuple(generation.tuple) || generation.tuple.repository_id !== generation.repositoryId || generation.tuple.pull_request_number !== generation.pullRequestNumber || generation.tuple.policy_sha256 !== generation.policy.digest) fail("identity", "generation tuple mismatch");
  if (generation.snapshot.repositoryId !== generation.repositoryId || generation.snapshot.number !== generation.pullRequestNumber || generation.snapshot.headSha !== generation.tuple.head_sha || generation.snapshot.baseSha !== generation.tuple.base_sha || generation.mainSha !== generation.tuple.base_sha) fail("identity", "generation snapshot mismatch");
  const { immutableDigest, state: _state, version: _version, decision: _decision, ...base } = generation;
  if (immutableDigest !== canonicalHash(immutableGenerationValue(base))) fail("conflict", "immutable generation content mismatch");
}

function sameImmutableGeneration(left: Generation, right: Generation): boolean { return left.generationId === right.generationId && left.immutableDigest === right.immutableDigest; }

async function recoverCommit(store: DurableStorePort, work: (transaction: DurableTransaction) => void, verify: () => Promise<boolean>): Promise<void> {
  try { await store.transact(work); }
  catch (error) {
    if (!(error instanceof FailClosedError) || error.code !== "store_failure" || !(await verify())) throw error;
  }
}

function receiptMatches(existing: Receipt, input: Pick<Receipt, "identityDigest" | "payloadDigest" | "kind">): boolean {
  return existing.payloadDigest === input.payloadDigest && existing.identityDigest === input.identityDigest && existing.kind === input.kind;
}

function receiptTerminalOutcome(receipt: Receipt): ReceiptTerminalOutcome | undefined {
  if (receipt.completedOutcome !== undefined) return receipt.completedOutcome;
  return receipt.state === "terminal_success" || receipt.state === "terminal_failure" ? receipt.state : undefined;
}

async function persistReceiptConflict(store: DurableStorePort, key: string): Promise<Receipt> {
  for (;;) {
    const current = await store.read(key) as Receipt | undefined;
    if (current === undefined) return fail("cas_lost", "receipt disappeared before conflict persistence");
    if (current.state === "conflict") return current;
    const completedOutcome = receiptTerminalOutcome(current);
    const next: Receipt = completedOutcome === undefined
      ? { ...current, state: "conflict", version: current.version + 1 }
      : { ...current, completedOutcome, state: "conflict", version: current.version + 1 };
    try {
      await store.transact((transaction) => transaction.compareAndSwap(key, current.version, next));
      return next;
    } catch (error) {
      const durable = await store.read(key) as Receipt | undefined;
      if (durable?.state === "conflict") return durable;
      if (error instanceof FailClosedError && error.code === "cas_lost") continue;
      throw error;
    }
  }
}

type ReceiptInput = Omit<Receipt, "completedOutcome" | "state" | "version" | "generationId" | "targetCount" | "targetDigest" | "targetNumbers">;

export async function receive(store: DurableStorePort, input: ReceiptInput): Promise<Receipt> {
  positive(input.installationId, "installation id"); digest(input.payloadDigest, "payload digest"); digest(input.identityDigest, "identity digest");
  if (input.deliveryId.length === 0 || !["pull_request", "push"].includes(input.kind)) fail("invalid_input", "receipt identity is malformed");
  const key = receiptKey(input.installationId, input.deliveryId);
  const existing = await store.read(key) as Receipt | undefined;
  if (existing !== undefined) {
    if (!receiptMatches(existing, input)) return persistReceiptConflict(store, key);
    return existing;
  }
  const receipt: Receipt = { ...input, state: "received", version: 1 };
  try { await store.transact((transaction) => transaction.putIfAbsent(key, receipt)); }
  catch (error) {
    const durable = await store.read(key) as Receipt | undefined;
    if (durable !== undefined && receiptMatches(durable, input)) return durable;
    if (durable !== undefined) return persistReceiptConflict(store, key);
    throw error;
  }
  return receipt;
}

export async function beginReceiptSnapshot(store: DurableStorePort, receipt: Receipt): Promise<Receipt> {
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  const durable = await store.read(key) as Receipt | undefined;
  if (durable === undefined || !receiptMatches(durable, receipt)) return fail("conflict", "receipt disappeared or changed");
  if (durable.state === "snapshotting" || durable.state === "enqueued" || terminal(durable.state)) return durable;
  if (durable.state !== "received") return fail("cas_lost", "receipt cannot start snapshotting");
  const next = { ...durable, state: "snapshotting" as const, version: durable.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, durable.version, next), async () => (await store.read(key) as Receipt | undefined)?.state === "snapshotting");
  return next;
}

function insertOrVerifyGeneration(transaction: DurableTransaction, generation: Generation): void {
  validateGeneration(generation);
  const key = generationKey(generation.generationId);
  const existing = transaction.get(key) as Generation | undefined;
  if (existing === undefined) transaction.putIfAbsent(key, generation);
  else if (!sameImmutableGeneration(existing, generation)) fail("conflict", "generation id reused with different immutable content");
}

function insertOrVerifyIntent(transaction: DurableTransaction, generationId: string, operation: IntentOperation): void {
  const key = outboxKey(generationId, operation);
  const existing = transaction.get(key) as Outbox | undefined;
  if (existing === undefined) transaction.putIfAbsent(key, { fence: null, generationId, leaseOwner: null, operation, state: "pending", version: 1 } satisfies Outbox);
  else if (existing.generationId !== generationId || existing.operation !== operation) fail("conflict", "outbox identity mismatch");
}

function moveCurrent(transaction: DurableTransaction, generation: Generation): void {
  const key = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const current = transaction.get(key) as CurrentGeneration | undefined;
  if (current?.effectLease !== null && current !== undefined) fail("cas_lost", "current generation has a fenced external-effect lease");
  if (current?.generationId === generation.generationId) return;
  if (current !== undefined) {
    const previousKey = generationKey(current.generationId);
    const previous = transaction.get(previousKey) as Generation | undefined;
    if (previous !== undefined && !terminal(previous.state)) transaction.compareAndSwap(previousKey, previous.version, { ...previous, state: "obsolete", version: previous.version + 1 });
    transaction.compareAndSwap(key, current.version, { effectLease: null, generationId: generation.generationId, nextFence: current.nextFence, version: current.version + 1 } satisfies CurrentGeneration);
  } else transaction.putIfAbsent(key, { effectLease: null, generationId: generation.generationId, nextFence: 1, version: 1 } satisfies CurrentGeneration);
}

export async function atomicEnqueuePull(store: DurableStorePort, receipt: Receipt, generation: Generation): Promise<void> {
  validateGeneration(generation);
  const rKey = receiptKey(receipt.installationId, receipt.deliveryId);
  const verify = async (): Promise<boolean> => {
    const [durableReceipt, durableGeneration, durableIntent, current] = await Promise.all([
      store.read(rKey), store.read(generationKey(generation.generationId)), store.read(outboxKey(generation.generationId, "evaluate_generation")), store.read(currentKey(generation.repositoryId, generation.pullRequestNumber)),
    ]) as [Receipt | undefined, Generation | undefined, Outbox | undefined, CurrentGeneration | undefined];
    return durableReceipt?.state === "enqueued" && durableReceipt.generationId === generation.generationId && durableGeneration !== undefined && sameImmutableGeneration(durableGeneration, generation) && durableIntent?.operation === "evaluate_generation" && current?.generationId === generation.generationId;
  };
  if (await verify()) return;
  await recoverCommit(store, (transaction) => {
    const durableReceipt = transaction.get(rKey) as Receipt | undefined;
    if (durableReceipt === undefined || !receiptMatches(durableReceipt, receipt) || !["received", "snapshotting"].includes(durableReceipt.state)) fail("cas_lost", "receipt changed before pull enqueue");
    insertOrVerifyGeneration(transaction, generation);
    insertOrVerifyIntent(transaction, generation.generationId, "evaluate_generation");
    moveCurrent(transaction, generation);
    transaction.compareAndSwap(rKey, durableReceipt.version, { ...durableReceipt, generationId: generation.generationId, state: "enqueued", version: durableReceipt.version + 1 });
  }, verify);
}

export async function atomicEnqueuePush(store: DurableStorePort, receipt: Receipt, targetDigest: string, pullRequestNumbers: readonly number[]): Promise<void> {
  digest(targetDigest, "push target digest");
  const targets = [...pullRequestNumbers];
  if (new Set(targets).size !== targets.length || targets.some((value) => !Number.isSafeInteger(value) || value <= 0) || targets.some((value, index) => index > 0 && value <= targets[index - 1]!)) fail("invalid_input", "push target list must be unique positive ascending numbers");
  const key = receiptKey(receipt.installationId, receipt.deliveryId);
  const finalState: ReceiptState = targets.length === 0 ? "terminal_success" : "enqueued";
  const verify = async (): Promise<boolean> => {
    const durable = await store.read(key) as Receipt | undefined;
    if (durable?.state !== finalState || (targets.length === 0 && durable.completedOutcome !== "terminal_success") || durable.targetDigest !== targetDigest || canonicalHash(durable.targetNumbers) !== canonicalHash(targets)) return false;
    for (const pr of targets) if ((await store.read(pushChildKey(receipt.installationId, receipt.deliveryId, pr)) as PushChild | undefined)?.pullRequestNumber !== pr) return false;
    return true;
  };
  if (await verify()) return;
  await recoverCommit(store, (transaction) => {
    const durable = transaction.get(key) as Receipt | undefined;
    if (durable === undefined || !receiptMatches(durable, receipt) || !["received", "snapshotting"].includes(durable.state)) fail("cas_lost", "push receipt changed before fanout");
    for (const pr of targets) transaction.putIfAbsent(pushChildKey(receipt.installationId, receipt.deliveryId, pr), { leaseOwner: null, pullRequestNumber: pr, state: "pending", version: 1 } satisfies PushChild);
    const next: Receipt = targets.length === 0
      ? { ...durable, completedOutcome: "terminal_success", state: finalState, targetCount: 0, targetDigest, targetNumbers: targets, version: durable.version + 1 }
      : { ...durable, state: finalState, targetCount: targets.length, targetDigest, targetNumbers: targets, version: durable.version + 1 };
    transaction.compareAndSwap(key, durable.version, next);
  }, verify);
}

export async function leasePushChild(store: DurableStorePort, receipt: Receipt, pr: number, worker: string): Promise<PushChild> {
  const key = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const child = await store.read(key) as PushChild | undefined;
  if (child === undefined || child.state !== "pending" || child.leaseOwner !== null || worker.length === 0) return fail("cas_lost", "push child unavailable for lease");
  const next = { ...child, leaseOwner: worker, state: "leased" as const, version: child.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, child.version, next), async () => {
    const durable = await store.read(key) as PushChild | undefined; return durable?.state === "leased" && durable.leaseOwner === worker;
  });
  return next;
}

export async function recoverPushChildLease(store: DurableStorePort, receipt: Receipt, pr: number, abandonedWorker: string): Promise<void> {
  const key = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const child = await store.read(key) as PushChild | undefined;
  if (child?.state !== "leased" || child.leaseOwner !== abandonedWorker) fail("cas_lost", "push child lease is not recoverable");
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, child.version, { ...child, leaseOwner: null, state: "pending", version: child.version + 1 }), async () => (await store.read(key) as PushChild | undefined)?.state === "pending");
}

export async function atomicEnqueuePushChild(store: DurableStorePort, receipt: Receipt, generation: Generation, worker: string): Promise<void> {
  validateGeneration(generation);
  const childKey = pushChildKey(receipt.installationId, receipt.deliveryId, generation.pullRequestNumber);
  const verify = async (): Promise<boolean> => {
    const child = await store.read(childKey) as PushChild | undefined;
    const intent = await store.read(outboxKey(generation.generationId, "evaluate_generation")) as Outbox | undefined;
    return child?.state === "enqueued" && child.generationId === generation.generationId && intent?.generationId === generation.generationId;
  };
  if (await verify()) return;
  await recoverCommit(store, (transaction) => {
    const child = transaction.get(childKey) as PushChild | undefined;
    if (child === undefined || child.state !== "leased" || child.leaseOwner !== worker) fail("cas_lost", "push child lease changed");
    insertOrVerifyGeneration(transaction, generation);
    insertOrVerifyIntent(transaction, generation.generationId, "evaluate_generation");
    moveCurrent(transaction, generation);
    transaction.compareAndSwap(childKey, child.version, { ...child, generationId: generation.generationId, leaseOwner: null, state: "enqueued", version: child.version + 1 });
  }, verify);
}

export async function leaseOutbox(store: DurableStorePort, generationId: string, worker: string): Promise<Outbox> {
  const key = outboxKey(generationId, "evaluate_generation");
  const row = await store.read(key) as Outbox | undefined;
  const generation = await store.read(generationKey(generationId)) as Generation | undefined;
  if (row === undefined || row.state !== "pending" || row.leaseOwner !== null || generation === undefined || generation.state !== "claimed") return fail("cas_lost", "evaluation outbox unavailable");
  const next = { ...row, leaseOwner: worker, state: "leased" as const, version: row.version + 1 };
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(generationId)) as Generation | undefined;
    if (durableGeneration === undefined || durableGeneration.state !== "claimed") fail("cas_lost", "generation is not claimable");
    transaction.compareAndSwap(key, row.version, next);
    transaction.compareAndSwap(generationKey(generationId), durableGeneration.version, { ...durableGeneration, state: "evaluating", version: durableGeneration.version + 1 });
  }, async () => (await store.read(key) as Outbox | undefined)?.state === "leased" && (await store.read(generationKey(generationId)) as Generation | undefined)?.state === "evaluating");
  return next;
}

export async function commitDecision(store: DurableStorePort, generationId: string, worker: string): Promise<Generation> {
  const key = generationKey(generationId); const intentKey = outboxKey(generationId, "evaluate_generation");
  const generation = await store.read(key) as Generation | undefined; const intent = await store.read(intentKey) as Outbox | undefined;
  if (generation === undefined || generation.state !== "evaluating" || intent?.state !== "leased" || intent.leaseOwner !== worker) return fail("cas_lost", "evaluation lease changed");
  const nextGeneration = { ...generation, decision: clone(generation.draftDecision), state: "decision_ready" as const, version: generation.version + 1 };
  const nextIntent = { ...intent, leaseOwner: null, state: "delivered" as const, version: intent.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(key, generation.version, nextGeneration);
    transaction.compareAndSwap(intentKey, intent.version, nextIntent);
  }, async () => (await store.read(key) as Generation | undefined)?.state === "decision_ready" && (await store.read(intentKey) as Outbox | undefined)?.state === "delivered");
  return nextGeneration;
}

export async function recoverEvaluationLease(store: DurableStorePort, generationId: string, abandonedWorker: string): Promise<void> {
  const gKey = generationKey(generationId); const iKey = outboxKey(generationId, "evaluate_generation");
  const generation = await store.read(gKey) as Generation | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  if (generation?.state !== "evaluating" || intent?.state !== "leased" || intent.leaseOwner !== abandonedWorker) fail("cas_lost", "evaluation lease is not recoverable");
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(gKey, generation.version, { ...generation, state: "claimed", version: generation.version + 1 });
    transaction.compareAndSwap(iKey, intent.version, { ...intent, leaseOwner: null, state: "pending", version: intent.version + 1 });
  }, async () => (await store.read(gKey) as Generation | undefined)?.state === "claimed" && (await store.read(iKey) as Outbox | undefined)?.state === "pending");
}

export async function assertCurrentGeneration(store: DurableStorePort, generation: Pick<Generation, "generationId" | "repositoryId" | "pullRequestNumber">): Promise<void> {
  const current = await store.read(currentKey(generation.repositoryId, generation.pullRequestNumber)) as CurrentGeneration | undefined;
  if (current?.generationId !== generation.generationId) fail("cas_lost", "worker generation is stale");
}

export async function prepareCheckBinding(store: DurableStorePort, generationId: string, identity: ExpectedIdentity): Promise<Binding> {
  const generation = await store.read(generationKey(generationId)) as Generation | undefined;
  if (generation === undefined || generation.state !== "decision_ready" || generation.decision === undefined) return fail("cas_lost", "completion requires durable decision_ready generation");
  if (identity.appId !== generation.tuple.app_id || identity.installationId !== generation.tuple.installation_id || identity.repositoryId !== generation.repositoryId || identity.repositoryName !== generation.policy.repository.name || identity.baseRef !== generation.policy.repository.baseRef) fail("identity", "completion identity differs from immutable generation");
  await assertCurrentGeneration(store, generation);
  const binding: Binding = {
    appId: identity.appId,
    checkName: generation.policy.checkName,
    decisionDigest: generation.decision.digest,
    externalId: generation.generationId,
    generationId: generation.generationId,
    headSha: generation.tuple.head_sha,
    policyDigest: generation.policy.digest,
    repositoryId: generation.repositoryId,
    state: "create_pending",
    version: 1,
  };
  const key = bindingKey(generationId);
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(generationId)) as Generation | undefined;
    const current = transaction.get(currentKey(generation.repositoryId, generation.pullRequestNumber)) as CurrentGeneration | undefined;
    if (durableGeneration?.state !== "decision_ready" || current?.generationId !== generationId || current.effectLease !== null) fail("cas_lost", "generation changed before binding preparation");
    const existing = transaction.get(key) as Binding | undefined;
    if (existing === undefined) transaction.putIfAbsent(key, binding);
    else if (canonicalHash(bindingIdentity(existing)) !== canonicalHash(bindingIdentity(binding))) fail("conflict", "binding identity changed");
    insertOrVerifyIntent(transaction, generationId, "create_check");
  }, async () => (await store.read(key) as Binding | undefined)?.externalId === generationId && (await store.read(outboxKey(generationId, "create_check")) as Outbox | undefined)?.operation === "create_check");
  return (await store.read(key)) as Binding;
}

export async function leaseEffect(store: DurableStorePort, generationId: string, operation: EffectLease["operation"], owner: string): Promise<EffectLease> {
  if (owner.length === 0) fail("invalid_input", "effect lease owner is empty");
  const generation = await store.read(generationKey(generationId)) as Generation | undefined;
  const intent = await store.read(outboxKey(generationId, operation)) as Outbox | undefined;
  if (generation === undefined || intent === undefined || !["pending", "possible_send"].includes(intent.state)) return fail("cas_lost", "effect intent unavailable");
  if (operation === "create_check" && generation.state !== "decision_ready") fail("cas_lost", "create requires decision_ready");
  if (operation === "update_check" && generation.state !== "completing") fail("cas_lost", "update requires completing generation");
  const currentKeyValue = currentKey(generation.repositoryId, generation.pullRequestNumber);
  const current = await store.read(currentKeyValue) as CurrentGeneration | undefined;
  if (current?.generationId !== generationId || current.effectLease !== null) return fail("cas_lost", "current generation effect lease unavailable");
  const mode: EffectLease["mode"] = intent.state === "pending" ? "send" : operation === "create_check" ? "reconcile" : "retry";
  const fence = current.nextFence;
  const lease: EffectLease = { fence, generationId, mode, operation, owner };
  const nextCurrent: CurrentGeneration = { ...current, effectLease: { fence, operation, owner }, nextFence: fence + 1, version: current.version + 1 };
  const nextIntent: Outbox = { ...intent, fence, leaseOwner: owner, state: mode === "reconcile" ? "reconcile_leased" : "send_leased", version: intent.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(currentKeyValue, current.version, nextCurrent);
    transaction.compareAndSwap(outboxKey(generationId, operation), intent.version, nextIntent);
  }, async () => {
    const durableCurrent = await store.read(currentKeyValue) as CurrentGeneration | undefined;
    const durableIntent = await store.read(outboxKey(generationId, operation)) as Outbox | undefined;
    return durableCurrent?.effectLease?.fence === fence && durableCurrent.effectLease.owner === owner && durableIntent?.fence === fence && durableIntent.leaseOwner === owner;
  });
  return lease;
}

function assertLeaseRows(current: CurrentGeneration | undefined, intent: Outbox | undefined, lease: EffectLease): asserts current is CurrentGeneration {
  if (current?.generationId !== lease.generationId || current.effectLease?.owner !== lease.owner || current.effectLease.fence !== lease.fence || current.effectLease.operation !== lease.operation || intent?.leaseOwner !== lease.owner || intent.fence !== lease.fence) fail("cas_lost", "effect fence changed");
}

export async function markEffectPossibleSend(store: DurableStorePort, lease: EffectLease): Promise<void> {
  if (lease.mode === "reconcile") fail("invalid_input", "reconciliation cannot send a create");
  const generation = await store.read(generationKey(lease.generationId)) as Generation | undefined;
  if (generation === undefined) fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber); const iKey = outboxKey(lease.generationId, lease.operation);
  const current = await store.read(cKey) as CurrentGeneration | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  assertLeaseRows(current, intent, lease);
  if (intent?.state !== "send_leased") fail("cas_lost", "effect is not send-leased");
  const next = { ...intent, state: "possible_send" as const, version: intent.version + 1 };
  const binding = await store.read(bindingKey(lease.generationId)) as Binding | undefined;
  if (binding === undefined) fail("cas_lost", "binding disappeared before possible-send");
  const wanted: BindingState = lease.operation === "create_check" ? "create_possible" : "update_possible";
  const allowed: BindingState = lease.operation === "create_check" ? "create_pending" : "update_pending";
  if (binding.state !== allowed && !(lease.mode === "retry" && binding.state === wanted)) fail("cas_lost", "binding is not sendable");
  const nextBinding = binding.state === wanted ? binding : { ...binding, state: wanted, version: binding.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(iKey, intent.version, next);
    if (nextBinding !== binding) transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, nextBinding);
  }, async () => (await store.read(iKey) as Outbox | undefined)?.state === "possible_send" && (await store.read(bindingKey(lease.generationId)) as Binding | undefined)?.state === wanted);
}

export async function releaseEffect(store: DurableStorePort, lease: EffectLease, outcome: "definite_not_sent" | "ambiguous" | "blocked"): Promise<void> {
  const generation = await store.read(generationKey(lease.generationId)) as Generation | undefined;
  if (generation === undefined) fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber); const iKey = outboxKey(lease.generationId, lease.operation);
  const current = await store.read(cKey) as CurrentGeneration | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  assertLeaseRows(current, intent, lease);
  const nextState: IntentState = outcome === "definite_not_sent" ? "pending" : outcome === "ambiguous" ? "possible_send" : "blocked";
  const nextIntent = { ...intent!, fence: null, leaseOwner: null, state: nextState, version: intent!.version + 1 };
  const nextCurrent = { ...current, effectLease: null, version: current.version + 1 };
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(iKey, intent!.version, nextIntent);
    transaction.compareAndSwap(cKey, current.version, nextCurrent);
    const binding = transaction.get(bindingKey(lease.generationId)) as Binding | undefined;
    if (outcome === "definite_not_sent" && binding !== undefined) {
      const possible: BindingState = lease.operation === "create_check" ? "create_possible" : "update_possible";
      const pending: BindingState = lease.operation === "create_check" ? "create_pending" : "update_pending";
      if (binding.state === possible) transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: pending, version: binding.version + 1 });
    }
    if (outcome === "blocked") {
      const durableGeneration = transaction.get(generationKey(lease.generationId)) as Generation;
      transaction.compareAndSwap(generationKey(lease.generationId), durableGeneration.version, { ...durableGeneration, state: "blocked_ambiguous", version: durableGeneration.version + 1 });
      if (binding !== undefined) transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: "blocked", version: binding.version + 1 });
    }
  }, async () => (await store.read(cKey) as CurrentGeneration | undefined)?.effectLease === null && (await store.read(iKey) as Outbox | undefined)?.state === nextState);
}

export async function recoverAbandonedEffect(store: DurableStorePort, generationId: string, operation: EffectLease["operation"], abandonedOwner: string, fence: number): Promise<void> {
  const generation = await store.read(generationKey(generationId)) as Generation | undefined;
  if (generation === undefined) fail("cas_lost", "generation disappeared");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber); const iKey = outboxKey(generationId, operation);
  const current = await store.read(cKey) as CurrentGeneration | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  const lease: EffectLease = { fence, generationId, mode: intent?.state === "reconcile_leased" ? "reconcile" : "send", operation, owner: abandonedOwner };
  assertLeaseRows(current, intent, lease);
  if (intent?.state === "send_leased") return releaseEffect(store, lease, "definite_not_sent");
  if (intent?.state === "possible_send" || intent?.state === "reconcile_leased") return releaseEffect(store, lease, "ambiguous");
  fail("cas_lost", "effect lease state is not recoverable");
}

export async function bindCreatedCheck(store: DurableStorePort, lease: EffectLease, check: AppCheck): Promise<Binding> {
  if (lease.operation !== "create_check") fail("invalid_input", "wrong effect operation for binding");
  const generation = await store.read(generationKey(lease.generationId)) as Generation | undefined;
  const binding = await store.read(bindingKey(lease.generationId)) as Binding | undefined;
  if (generation === undefined || binding === undefined || !Number.isSafeInteger(check.checkId) || check.checkId <= 0 || check.appId !== binding.appId || check.repositoryId !== binding.repositoryId || check.headSha !== binding.headSha || check.name !== binding.checkName || check.externalId !== binding.externalId) fail("identity", "created/adopted check identity mismatch");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber); const iKey = outboxKey(lease.generationId, "create_check");
  const current = await store.read(cKey) as CurrentGeneration | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  assertLeaseRows(current, intent, lease);
  if (lease.mode === "reconcile" ? intent?.state !== "reconcile_leased" : intent?.state !== "possible_send") fail("cas_lost", "create binding is not in an adoptable state");
  const nextBinding: Binding = { ...binding, checkId: check.checkId, state: "update_pending", version: binding.version + 1 };
  const nextIntent: Outbox = { ...intent!, fence: null, leaseOwner: null, state: "delivered", version: intent!.version + 1 };
  const nextCurrent: CurrentGeneration = { ...current, effectLease: null, version: current.version + 1 };
  await recoverCommit(store, (transaction) => {
    const durableGeneration = transaction.get(generationKey(lease.generationId)) as Generation;
    if (durableGeneration.state !== "decision_ready" || durableGeneration.decision?.digest !== binding.decisionDigest) fail("cas_lost", "decision changed before Check binding");
    transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, nextBinding);
    transaction.compareAndSwap(iKey, intent!.version, nextIntent);
    transaction.compareAndSwap(cKey, current.version, nextCurrent);
    transaction.compareAndSwap(generationKey(lease.generationId), durableGeneration.version, { ...durableGeneration, state: "completing", version: durableGeneration.version + 1 });
    insertOrVerifyIntent(transaction, lease.generationId, "update_check");
  }, async () => (await store.read(bindingKey(lease.generationId)) as Binding | undefined)?.checkId === check.checkId && (await store.read(generationKey(lease.generationId)) as Generation | undefined)?.state === "completing");
  return nextBinding;
}

export async function completeCheckUpdate(store: DurableStorePort, lease: EffectLease): Promise<void> {
  if (lease.operation !== "update_check") fail("invalid_input", "wrong effect operation for update completion");
  const generation = await store.read(generationKey(lease.generationId)) as Generation | undefined;
  const binding = await store.read(bindingKey(lease.generationId)) as Binding | undefined;
  if (generation === undefined || generation.state !== "completing" || generation.decision === undefined || binding === undefined || binding.state !== "update_possible" || binding.checkId === undefined || binding.decisionDigest !== generation.decision.digest) fail("cas_lost", "durable update decision or binding changed");
  const cKey = currentKey(generation.repositoryId, generation.pullRequestNumber); const iKey = outboxKey(lease.generationId, "update_check");
  const current = await store.read(cKey) as CurrentGeneration | undefined; const intent = await store.read(iKey) as Outbox | undefined;
  assertLeaseRows(current, intent, lease);
  if (intent?.state !== "possible_send") fail("cas_lost", "update is not possible-sent");
  const terminalState: GenerationState = generation.decision.conclusion === "success" ? "terminal_success" : "terminal_failure";
  await recoverCommit(store, (transaction) => {
    transaction.compareAndSwap(bindingKey(lease.generationId), binding.version, { ...binding, state: "terminal", version: binding.version + 1 });
    transaction.compareAndSwap(iKey, intent.version, { ...intent, fence: null, leaseOwner: null, state: "delivered", version: intent.version + 1 });
    transaction.compareAndSwap(cKey, current.version, { ...current, effectLease: null, version: current.version + 1 });
    transaction.compareAndSwap(generationKey(lease.generationId), generation.version, { ...generation, state: terminalState, version: generation.version + 1 });
  }, async () => (await store.read(generationKey(lease.generationId)) as Generation | undefined)?.state === terminalState && (await store.read(bindingKey(lease.generationId)) as Binding | undefined)?.state === "terminal");
}

export async function settlePullReceipt(store: DurableStorePort, receipt: Receipt): Promise<Receipt> {
  const key = receiptKey(receipt.installationId, receipt.deliveryId); const durable = await store.read(key) as Receipt | undefined;
  if (durable === undefined || durable.kind !== "pull_request" || durable.generationId === undefined) fail("cas_lost", "pull receipt has no generation");
  const generation = await store.read(generationKey(durable.generationId)) as Generation | undefined;
  if (generation === undefined || !["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state)) fail("cas_lost", "pull generation is not terminal");
  const outcome: ReceiptTerminalOutcome = generation.state === "terminal_success" ? "terminal_success" : "terminal_failure";
  const priorOutcome = receiptTerminalOutcome(durable);
  if (priorOutcome !== undefined && priorOutcome !== outcome) fail("conflict", "receipt completion outcome changed");
  if (durable.completedOutcome === outcome && (durable.state === outcome || durable.state === "conflict")) return durable;
  const next: Receipt = { ...durable, completedOutcome: outcome, state: durable.state === "conflict" ? "conflict" : outcome, version: durable.version + 1 };
  await recoverCommit(store, (transaction) => transaction.compareAndSwap(key, durable.version, next), async () => {
    const current = await store.read(key) as Receipt | undefined;
    return current?.completedOutcome === outcome && (current.state === outcome || current.state === "conflict");
  });
  return (await store.read(key)) as Receipt;
}

export async function settlePushChild(store: DurableStorePort, receipt: Receipt, pr: number): Promise<Receipt> {
  const rKey = receiptKey(receipt.installationId, receipt.deliveryId); const cKey = pushChildKey(receipt.installationId, receipt.deliveryId, pr);
  const durableReceipt = await store.read(rKey) as Receipt | undefined; const child = await store.read(cKey) as PushChild | undefined;
  if (durableReceipt === undefined || durableReceipt.kind !== "push" || child === undefined || child.generationId === undefined || !durableReceipt.targetNumbers?.includes(pr)) fail("cas_lost", "push child identity mismatch");
  const generation = await store.read(generationKey(child.generationId)) as Generation | undefined;
  if (generation === undefined || !["terminal_success", "terminal_failure", "obsolete", "blocked_ambiguous"].includes(generation.state)) fail("cas_lost", "push child generation is not terminal");
  const childState: PushChild["state"] = generation.state === "terminal_success" ? "terminal_success" : "terminal_failure";
  await recoverCommit(store, (transaction) => {
    const durableChild = transaction.get(cKey) as PushChild | undefined;
    const currentReceipt = transaction.get(rKey) as Receipt | undefined;
    if (durableChild === undefined || currentReceipt === undefined || durableChild.generationId !== child.generationId) fail("cas_lost", "push child changed during aggregation");
    if (!terminal(durableChild.state)) transaction.compareAndSwap(cKey, durableChild.version, { ...durableChild, leaseOwner: null, state: childState, version: durableChild.version + 1 });
    const states = currentReceipt.targetNumbers!.map((number) => number === pr ? childState : (transaction.get(pushChildKey(receipt.installationId, receipt.deliveryId, number)) as PushChild | undefined)?.state);
    if (states.every((state) => state === "terminal_success" || state === "terminal_failure")) {
      const outcome: ReceiptTerminalOutcome = states.every((state) => state === "terminal_success") ? "terminal_success" : "terminal_failure";
      const priorOutcome = receiptTerminalOutcome(currentReceipt);
      if (priorOutcome !== undefined && priorOutcome !== outcome) fail("conflict", "push receipt completion outcome changed");
      if (currentReceipt.completedOutcome !== outcome || (currentReceipt.state !== outcome && currentReceipt.state !== "conflict")) {
        transaction.compareAndSwap(rKey, currentReceipt.version, { ...currentReceipt, completedOutcome: outcome, state: currentReceipt.state === "conflict" ? "conflict" : outcome, version: currentReceipt.version + 1 });
      }
    }
  }, async () => terminal((await store.read(cKey) as PushChild | undefined)?.state ?? "pending"));
  return (await store.read(rKey)) as Receipt;
}

export async function readGeneration(store: DurableStorePort, generationId: string): Promise<Generation> {
  const value = await store.read(generationKey(generationId)) as Generation | undefined;
  if (value === undefined) return fail("cas_lost", "generation missing");
  return value;
}

export async function readBinding(store: DurableStorePort, generationId: string): Promise<Binding> {
  const value = await store.read(bindingKey(generationId)) as Binding | undefined;
  if (value === undefined) return fail("cas_lost", "binding missing");
  return value;
}
