import {
  ACK_COOLDOWN_MS,
  ACTIVE_KEY_VERSION,
  ATTEMPT_LEASE_MS,
  BINDING_RETENTION_MS,
  COLLECTIONS,
  CONTRACT_VERSION,
  DISCLOSURE_ASSERTION_VERSION,
  DISCLOSURE_PURPOSE,
  DISCLOSURE_RETENTION_MS,
  DISCLOSURE_VERSION,
  MAX_ACKS_PER_TOKEN_WINDOW,
  MAX_GETS_PER_SUBJECT_WINDOW,
  OPERATION_RETENTION_MS,
  PRODUCT_ALLOWLIST,
  RATE_WINDOW_MS,
  REVOKED_RETENTION_MS,
  TOKEN_GET_COOLDOWN_MS,
  type PlanId,
  type ProductId,
} from './constants.js';
import type { NonceSource, NormalizedPaidState } from './contracts.js';

export type BillingCollection = (typeof COLLECTIONS)[keyof typeof COLLECTIONS];

export interface BillingTransaction {
  get<T>(collection: BillingCollection, id: string): Promise<T | undefined>;
  set<T>(collection: BillingCollection, id: string, value: T): void;
}

export interface BillingDatabase {
  readonly databaseId: string;
  runTransaction<T>(operation: (transaction: BillingTransaction) => Promise<T>): Promise<T>;
}

export interface AttemptOwner {
  requestFingerprint: string;
  attemptGeneration: number;
  attemptNonce: Uint8Array;
}

export interface AttemptHandle {
  tokenFingerprint: string;
  accountSubject: string;
  owner: AttemptOwner;
  usesReplay: boolean;
}

type OperationPhase =
  | 'lookup_in_flight'
  | 'verified_owner'
  | 'delivery_committed'
  | 'ack_in_progress'
  | 'ack_unknown'
  | 'paid'
  | 'free'
  | 'canceled_pending_read_only';

interface BaseRecord {
  contractVersion: typeof CONTRACT_VERSION;
  keyVersion: typeof ACTIVE_KEY_VERSION;
  createdAt: Date;
  updatedAt: Date;
  retentionExpiresAt: Date;
}

interface DisclosureRecord extends BaseRecord {
  assertionVersion: typeof DISCLOSURE_ASSERTION_VERSION;
  accountSubject: string;
  disclosureVersion: typeof DISCLOSURE_VERSION;
  purpose: typeof DISCLOSURE_PURPOSE;
  acceptedAt: Date;
  status: 'accepted' | 'revoked';
  statusChangedAt: Date;
}

interface RequestReplayRecord extends BaseRecord, AttemptOwner {
  tokenFingerprint: string;
  phase: OperationPhase;
  outcomeCode: 'in_flight' | 'ack_unknown' | 'paid' | 'free';
  leaseExpiresAt?: Date;
  cooldownUntil?: Date;
}

interface TokenOperationRecord extends BaseRecord, AttemptOwner {
  tokenFingerprint: string;
  accountSubject?: string;
  phase: OperationPhase;
  outcomeCode: 'in_flight' | 'ack_unknown' | 'paid' | 'free';
  leaseExpiresAt?: Date;
  cooldownUntil?: Date;
  lastGetStartedAt: Date;
  acknowledgementStartedAt: Date[];
}

interface PurchaseBindingRecord extends BaseRecord {
  tokenFingerprint: string;
  accountSubject: string;
  planId: PlanId;
  productId: ProductId;
  basePlanId: 'monthly';
  offerIdAbsent: true;
  normalizedState: NormalizedPaidState;
  playExpiresAt: Date;
  lastVerifiedAt: Date;
  deliveryState: 'committed';
  ackState: 'pending' | 'play_acknowledged' | 'unknown' | 'acknowledged';
  bindingState:
    | 'verified_delivery_committed'
    | 'acknowledged_delivery'
    | 'superseded';
  recoveryReason: 'none' | 'acknowledgement_unknown';
  attemptGeneration: number;
  attemptNonce: Uint8Array;
  attemptRequestFingerprint: string;
  attemptPhase: 'delivery_committed' | 'ack_in_progress' | 'paid';
  stagedPredecessorFingerprint?: string;
  predecessorFingerprint?: string;
  successorFingerprint?: string;
  acknowledgementConfirmedAt?: Date;
  stateChangedAt: Date;
}

interface RateLimitRecord extends BaseRecord {
  accountSubject: string;
  getStartedAt: Date[];
}

export type AcquireResult =
  | { kind: 'acquired'; attempt: AttemptHandle }
  | {
      kind:
        | 'replay_conflict'
        | 'in_flight'
        | 'verification_pending'
        | 'rate_limited'
        | 'unsafe_record';
    };

export interface DeliveryInput {
  planId: PlanId;
  productId: ProductId;
  normalizedState: NormalizedPaidState;
  playExpiresAt: Date;
  verifiedAt: Date;
  playAcknowledged: boolean;
  predecessorFingerprint?: string;
}

export interface PaidCommit {
  planId: PlanId;
  productId: ProductId;
  normalizedState: NormalizedPaidState;
  playExpiresAt: Date;
  verifiedAt: Date;
}

const PROTECTED_PHASES = new Set<OperationPhase>([
  'lookup_in_flight',
  'verified_owner',
  'delivery_committed',
  'ack_in_progress',
]);

export class BillingRepository {
  constructor(
    private readonly database: BillingDatabase,
    private readonly nonces: NonceSource,
  ) {}

  get databaseId(): string {
    return this.database.databaseId;
  }

  async acceptDisclosure(accountSubject: string, now: Date): Promise<void> {
    await this.database.runTransaction(async (tx) => {
      const existing = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject);
      if (existing !== undefined && !validDisclosure(existing, accountSubject)) {
        throw new UnsafeBillingRecordError();
      }
      tx.set<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject, {
        contractVersion: CONTRACT_VERSION,
        keyVersion: ACTIVE_KEY_VERSION,
        assertionVersion: DISCLOSURE_ASSERTION_VERSION,
        accountSubject,
        disclosureVersion: DISCLOSURE_VERSION,
        purpose: DISCLOSURE_PURPOSE,
        acceptedAt: now,
        status: 'accepted',
        statusChangedAt: now,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        retentionExpiresAt: addMs(now, DISCLOSURE_RETENTION_MS),
      });
    });
  }

  async revokeDisclosure(accountSubject: string, now: Date): Promise<void> {
    await this.database.runTransaction(async (tx) => {
      const existing = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject);
      if (existing === undefined) {
        return;
      }
      if (!validDisclosure(existing, accountSubject)) {
        throw new UnsafeBillingRecordError();
      }
      tx.set<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject, {
        ...existing,
        status: 'revoked',
        statusChangedAt: now,
        updatedAt: now,
        retentionExpiresAt: addMs(now, REVOKED_RETENTION_MS),
      });
    });
  }

  async hasCurrentDisclosure(accountSubject: string, now: Date): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const record = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject);
      if (record === undefined) {
        return false;
      }
      if (!validDisclosure(record, accountSubject)) {
        return false;
      }
      return record.status === 'accepted' && record.retentionExpiresAt.getTime() > now.getTime();
    });
  }

  acquireAttempt(
    accountSubject: string,
    requestFingerprint: string,
    tokenFingerprint: string,
    now: Date,
  ): Promise<AcquireResult> {
    return this.acquire(accountSubject, requestFingerprint, tokenFingerprint, now, true);
  }

  acquirePredecessorAttempt(
    accountSubject: string,
    requestFingerprint: string,
    tokenFingerprint: string,
    now: Date,
  ): Promise<AcquireResult> {
    return this.acquire(accountSubject, requestFingerprint, tokenFingerprint, now, false);
  }

  private async acquire(
    accountSubject: string,
    requestFingerprint: string,
    tokenFingerprint: string,
    now: Date,
    usesReplay: boolean,
  ): Promise<AcquireResult> {
    return this.database.runTransaction(async (tx) => {
      const replay = usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, requestFingerprint)
        : undefined;
      const operation = await tx.get<TokenOperationRecord>(COLLECTIONS.operations, tokenFingerprint);
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, tokenFingerprint);

      if (
        (replay !== undefined && !validReplay(replay, requestFingerprint)) ||
        (operation !== undefined && !validOperation(operation, tokenFingerprint)) ||
        (binding !== undefined && !validBinding(binding, tokenFingerprint))
      ) {
        return { kind: 'unsafe_record' };
      }
      if (replay !== undefined && replay.tokenFingerprint !== tokenFingerprint) {
        return { kind: 'replay_conflict' };
      }
      if (
        (replay !== undefined &&
          (operation === undefined || !consistentReplayOperation(replay, operation))) ||
        (replay === undefined &&
          operation?.requestFingerprint === requestFingerprint &&
          usesReplay)
      ) {
        return { kind: 'unsafe_record' };
      }
      if (protectedBeforeBoundary(replay, now) || protectedBeforeBoundary(operation, now)) {
        return { kind: 'in_flight' };
      }
      if (cooldownBeforeBoundary(replay, now) || cooldownBeforeBoundary(operation, now)) {
        return { kind: 'verification_pending' };
      }
      if (
        operation !== undefined &&
        now.getTime() < operation.lastGetStartedAt.getTime() + TOKEN_GET_COOLDOWN_MS
      ) {
        return { kind: 'rate_limited' };
      }

      const rate = await tx.get<RateLimitRecord>(COLLECTIONS.rateLimits, accountSubject);
      if (rate !== undefined && !validRateLimit(rate, accountSubject)) {
        return { kind: 'unsafe_record' };
      }
      const getStartedAt = recentStarts(rate?.getStartedAt ?? [], now);
      if (getStartedAt.length >= MAX_GETS_PER_SUBJECT_WINDOW) {
        return { kind: 'rate_limited' };
      }

      const highWater = Math.max(
        replay?.attemptGeneration ?? 0,
        operation?.attemptGeneration ?? 0,
        binding?.attemptGeneration ?? 0,
      );
      const nonce = this.nonces.nextNonce();
      if (!(nonce instanceof Uint8Array) || nonce.byteLength !== 16) {
        return { kind: 'unsafe_record' };
      }
      const owner: AttemptOwner = {
        requestFingerprint,
        attemptGeneration: highWater + 1,
        attemptNonce: new Uint8Array(nonce),
      };
      const leaseExpiresAt = addMs(now, ATTEMPT_LEASE_MS);
      const retentionExpiresAt = addMs(now, OPERATION_RETENTION_MS);
      const acknowledgementStartedAt = recentStarts(operation?.acknowledgementStartedAt ?? [], now);

      if (usesReplay) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, requestFingerprint, {
          contractVersion: CONTRACT_VERSION,
          keyVersion: ACTIVE_KEY_VERSION,
          ...owner,
          tokenFingerprint,
          phase: 'lookup_in_flight',
          outcomeCode: 'in_flight',
          leaseExpiresAt,
          createdAt: replay?.createdAt ?? now,
          updatedAt: now,
          retentionExpiresAt,
        });
      }
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, tokenFingerprint, {
        contractVersion: CONTRACT_VERSION,
        keyVersion: ACTIVE_KEY_VERSION,
        ...owner,
        tokenFingerprint,
        phase: 'lookup_in_flight',
        outcomeCode: 'in_flight',
        leaseExpiresAt,
        lastGetStartedAt: now,
        acknowledgementStartedAt,
        createdAt: operation?.createdAt ?? now,
        updatedAt: now,
        retentionExpiresAt,
      });
      tx.set<RateLimitRecord>(COLLECTIONS.rateLimits, accountSubject, {
        contractVersion: CONTRACT_VERSION,
        keyVersion: ACTIVE_KEY_VERSION,
        accountSubject,
        getStartedAt: [...getStartedAt, now],
        createdAt: rate?.createdAt ?? now,
        updatedAt: now,
        retentionExpiresAt,
      });
      return {
        kind: 'acquired',
        attempt: { tokenFingerprint, accountSubject, owner, usesReplay },
      };
    });
  }

  async markVerifiedOwner(
    attempt: AttemptHandle,
    productId: ProductId,
    now: Date,
  ): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const binding = await tx.get<PurchaseBindingRecord>(
        COLLECTIONS.bindings,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      if (
        !ownedOperation(operation, attempt, 'lookup_in_flight') ||
        (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['lookup_in_flight'])) ||
        (binding !== undefined && !validBinding(binding, attempt.tokenFingerprint)) ||
        (binding !== undefined &&
          (binding.accountSubject !== attempt.accountSubject ||
            binding.productId !== productId ||
            binding.bindingState === 'superseded'))
      ) {
        return false;
      }
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        accountSubject: attempt.accountSubject,
        phase: 'verified_owner',
        updatedAt: now,
      });
      return true;
    });
  }

  async closeAttempt(
    attempt: AttemptHandle,
    now: Date,
    phase: 'free' | 'canceled_pending_read_only' = 'free',
  ): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      if (!ownedOperationAny(operation, attempt, ['lookup_in_flight', 'verified_owner'])) {
        return false;
      }
      if (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['lookup_in_flight'])) {
        return false;
      }
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        phase,
        outcomeCode: 'free',
        leaseExpiresAt: undefined,
        updatedAt: now,
      });
      if (replay !== undefined) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint, {
          ...replay,
          phase,
          outcomeCode: 'free',
          leaseExpiresAt: undefined,
          updatedAt: now,
        });
      }
      return true;
    });
  }

  async commitDelivery(attempt: AttemptHandle, input: DeliveryInput): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      const existing = await tx.get<PurchaseBindingRecord>(
        COLLECTIONS.bindings,
        attempt.tokenFingerprint,
      );
      if (
        !ownedOperation(operation, attempt, 'verified_owner') ||
        (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['lookup_in_flight'])) ||
        (existing !== undefined && !validBinding(existing, attempt.tokenFingerprint)) ||
        (existing !== undefined &&
          (existing.accountSubject !== attempt.accountSubject ||
            existing.bindingState === 'superseded'))
      ) {
        return false;
      }
      let predecessor: PurchaseBindingRecord | undefined;
      if (input.predecessorFingerprint !== undefined) {
        predecessor = await tx.get<PurchaseBindingRecord>(
          COLLECTIONS.bindings,
          input.predecessorFingerprint,
        );
        if (
          predecessor !== undefined &&
          (!validBinding(predecessor, input.predecessorFingerprint) ||
            predecessor.accountSubject !== attempt.accountSubject ||
            (predecessor.successorFingerprint !== undefined &&
              predecessor.successorFingerprint !== attempt.tokenFingerprint))
        ) {
          return false;
        }
      }
      const binding: PurchaseBindingRecord = {
        contractVersion: CONTRACT_VERSION,
        keyVersion: ACTIVE_KEY_VERSION,
        tokenFingerprint: attempt.tokenFingerprint,
        accountSubject: attempt.accountSubject,
        planId: input.planId,
        productId: input.productId,
        basePlanId: 'monthly',
        offerIdAbsent: true,
        normalizedState: input.normalizedState,
        playExpiresAt: input.playExpiresAt,
        lastVerifiedAt: input.verifiedAt,
        deliveryState: 'committed',
        ackState:
          existing?.ackState === 'acknowledged'
            ? 'acknowledged'
            : input.playAcknowledged
              ? 'play_acknowledged'
              : 'pending',
        bindingState:
          existing?.ackState === 'acknowledged'
            ? 'acknowledged_delivery'
            : 'verified_delivery_committed',
        recoveryReason: 'none',
        attemptGeneration: attempt.owner.attemptGeneration,
        attemptNonce: new Uint8Array(attempt.owner.attemptNonce),
        attemptRequestFingerprint: attempt.owner.requestFingerprint,
        attemptPhase: 'delivery_committed',
        stagedPredecessorFingerprint: input.predecessorFingerprint,
        predecessorFingerprint: existing?.predecessorFingerprint,
        successorFingerprint: existing?.successorFingerprint,
        acknowledgementConfirmedAt: existing?.acknowledgementConfirmedAt,
        stateChangedAt: input.verifiedAt,
        createdAt: existing?.createdAt ?? input.verifiedAt,
        updatedAt: input.verifiedAt,
        retentionExpiresAt: addMs(
          new Date(Math.max(input.playExpiresAt.getTime(), input.verifiedAt.getTime())),
          BINDING_RETENTION_MS,
        ),
      };
      tx.set<PurchaseBindingRecord>(COLLECTIONS.bindings, attempt.tokenFingerprint, binding);
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        phase: 'delivery_committed',
        updatedAt: input.verifiedAt,
      });
      if (replay !== undefined) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint, {
          ...replay,
          phase: 'delivery_committed',
          updatedAt: input.verifiedAt,
        });
      }
      return true;
    });
  }

  async beginAcknowledgement(attempt: AttemptHandle, now: Date): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      const binding = await tx.get<PurchaseBindingRecord>(
        COLLECTIONS.bindings,
        attempt.tokenFingerprint,
      );
      if (
        !ownedOperation(operation, attempt, 'delivery_committed') ||
        (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['delivery_committed'])) ||
        !ownedBinding(binding, attempt, 'delivery_committed') ||
        binding.ackState !== 'pending'
      ) {
        return false;
      }
      const acknowledgementStartedAt = recentStarts(operation.acknowledgementStartedAt, now);
      if (acknowledgementStartedAt.length >= MAX_ACKS_PER_TOKEN_WINDOW) {
        return false;
      }
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        phase: 'ack_in_progress',
        acknowledgementStartedAt: [...acknowledgementStartedAt, now],
        updatedAt: now,
      });
      if (replay !== undefined) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint, {
          ...replay,
          phase: 'ack_in_progress',
          updatedAt: now,
        });
      }
      tx.set<PurchaseBindingRecord>(COLLECTIONS.bindings, attempt.tokenFingerprint, {
        ...binding,
        attemptPhase: 'ack_in_progress',
        updatedAt: now,
      });
      return true;
    });
  }

  async finalizePaid(
    attempt: AttemptHandle,
    now: Date,
    sourcePhase: 'delivery_committed' | 'ack_in_progress',
  ): Promise<PaidCommit | undefined> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      const binding = await tx.get<PurchaseBindingRecord>(
        COLLECTIONS.bindings,
        attempt.tokenFingerprint,
      );
      if (
        !ownedOperation(operation, attempt, sourcePhase) ||
        (attempt.usesReplay && !ownedReplayAny(replay, attempt, [sourcePhase])) ||
        !ownedBinding(binding, attempt, sourcePhase)
      ) {
        return undefined;
      }
      if (
        sourcePhase === 'delivery_committed' &&
        binding.ackState !== 'play_acknowledged' &&
        binding.ackState !== 'acknowledged'
      ) {
        return undefined;
      }
      if (sourcePhase === 'ack_in_progress' && binding.ackState === 'acknowledged') {
        return undefined;
      }
      let predecessor: PurchaseBindingRecord | undefined;
      if (binding.stagedPredecessorFingerprint !== undefined) {
        predecessor = await tx.get<PurchaseBindingRecord>(
          COLLECTIONS.bindings,
          binding.stagedPredecessorFingerprint,
        );
        if (
          predecessor !== undefined &&
          (!validBinding(predecessor, binding.stagedPredecessorFingerprint) ||
            predecessor.accountSubject !== attempt.accountSubject ||
            (predecessor.successorFingerprint !== undefined &&
              predecessor.successorFingerprint !== attempt.tokenFingerprint))
        ) {
          return undefined;
        }
      }
      const finalized: PurchaseBindingRecord = {
        ...binding,
        ackState: 'acknowledged',
        bindingState: 'acknowledged_delivery',
        recoveryReason: 'none',
        attemptPhase: 'paid',
        predecessorFingerprint: binding.stagedPredecessorFingerprint,
        stagedPredecessorFingerprint: undefined,
        acknowledgementConfirmedAt: binding.acknowledgementConfirmedAt ?? now,
        stateChangedAt: now,
        updatedAt: now,
      };
      tx.set<PurchaseBindingRecord>(COLLECTIONS.bindings, attempt.tokenFingerprint, finalized);
      if (predecessor !== undefined) {
        tx.set<PurchaseBindingRecord>(
          COLLECTIONS.bindings,
          predecessor.tokenFingerprint,
          {
            ...predecessor,
            bindingState: 'superseded',
            successorFingerprint: attempt.tokenFingerprint,
            stateChangedAt: now,
            updatedAt: now,
          },
        );
      }
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        phase: 'paid',
        outcomeCode: 'paid',
        leaseExpiresAt: undefined,
        updatedAt: now,
      });
      if (replay !== undefined) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint, {
          ...replay,
          phase: 'paid',
          outcomeCode: 'paid',
          leaseExpiresAt: undefined,
          updatedAt: now,
        });
      }
      return {
        planId: finalized.planId,
        productId: finalized.productId,
        normalizedState: finalized.normalizedState,
        playExpiresAt: finalized.playExpiresAt,
        verifiedAt: finalized.lastVerifiedAt,
      };
    });
  }

  async markAcknowledgementUnknown(attempt: AttemptHandle, now: Date): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(
        COLLECTIONS.operations,
        attempt.tokenFingerprint,
      );
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint)
        : undefined;
      const binding = await tx.get<PurchaseBindingRecord>(
        COLLECTIONS.bindings,
        attempt.tokenFingerprint,
      );
      if (
        !ownedOperation(operation, attempt, 'ack_in_progress') ||
        (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['ack_in_progress'])) ||
        !ownedBinding(binding, attempt, 'ack_in_progress') ||
        binding.ackState === 'acknowledged'
      ) {
        return false;
      }
      const cooldownUntil = addMs(now, ACK_COOLDOWN_MS);
      tx.set<PurchaseBindingRecord>(COLLECTIONS.bindings, attempt.tokenFingerprint, {
        ...binding,
        ackState: 'unknown',
        recoveryReason: 'acknowledgement_unknown',
        updatedAt: now,
      });
      tx.set<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint, {
        ...operation,
        phase: 'ack_unknown',
        outcomeCode: 'ack_unknown',
        leaseExpiresAt: undefined,
        cooldownUntil,
        updatedAt: now,
      });
      if (replay !== undefined) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint, {
          ...replay,
          phase: 'ack_unknown',
          outcomeCode: 'ack_unknown',
          leaseExpiresAt: undefined,
          cooldownUntil,
          updatedAt: now,
        });
      }
      return true;
    });
  }
}

export class UnsafeBillingRecordError extends Error {}

function addMs(date: Date, milliseconds: number): Date {
  return new Date(date.getTime() + milliseconds);
}

function validBase(record: Partial<BaseRecord>): boolean {
  return (
    record.contractVersion === CONTRACT_VERSION &&
    record.keyVersion === ACTIVE_KEY_VERSION &&
    record.createdAt instanceof Date &&
    record.updatedAt instanceof Date &&
    record.retentionExpiresAt instanceof Date
  );
}

function validOwner(record: Partial<AttemptOwner>): boolean {
  return (
    isFingerprint(record.requestFingerprint) &&
    Number.isSafeInteger(record.attemptGeneration) &&
    record.attemptGeneration! > 0 &&
    record.attemptNonce instanceof Uint8Array &&
    record.attemptNonce.byteLength === 16
  );
}

function validDisclosure(record: DisclosureRecord, accountSubject: string): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'assertionVersion',
      'accountSubject',
      'disclosureVersion',
      'purpose',
      'acceptedAt',
      'status',
      'statusChangedAt',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    validBase(record) &&
    record.assertionVersion === DISCLOSURE_ASSERTION_VERSION &&
    record.accountSubject === accountSubject &&
    record.disclosureVersion === DISCLOSURE_VERSION &&
    record.purpose === DISCLOSURE_PURPOSE &&
    record.acceptedAt instanceof Date &&
    record.statusChangedAt instanceof Date &&
    (record.status === 'accepted' || record.status === 'revoked')
  );
}

function validReplay(record: RequestReplayRecord, requestFingerprint: string): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'requestFingerprint',
      'attemptGeneration',
      'attemptNonce',
      'tokenFingerprint',
      'phase',
      'outcomeCode',
      'leaseExpiresAt',
      'cooldownUntil',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    validBase(record) &&
    validOwner(record) &&
    record.requestFingerprint === requestFingerprint &&
    isFingerprint(record.tokenFingerprint) &&
    isReplayPhase(record.phase) &&
    validPhaseOutcome(record.phase, record.outcomeCode) &&
    validLeaseAndCooldown(record.phase, record.leaseExpiresAt, record.cooldownUntil)
  );
}

function validOperation(record: TokenOperationRecord, tokenFingerprint: string): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'requestFingerprint',
      'attemptGeneration',
      'attemptNonce',
      'tokenFingerprint',
      'accountSubject',
      'phase',
      'outcomeCode',
      'leaseExpiresAt',
      'cooldownUntil',
      'lastGetStartedAt',
      'acknowledgementStartedAt',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    validBase(record) &&
    validOwner(record) &&
    record.tokenFingerprint === tokenFingerprint &&
    isFingerprint(record.tokenFingerprint) &&
    (record.accountSubject === undefined || isFingerprint(record.accountSubject)) &&
    record.lastGetStartedAt instanceof Date &&
    validRollingStarts(record.acknowledgementStartedAt, MAX_ACKS_PER_TOKEN_WINDOW) &&
    isOperationPhase(record.phase) &&
    validPhaseOutcome(record.phase, record.outcomeCode) &&
    validLeaseAndCooldown(record.phase, record.leaseExpiresAt, record.cooldownUntil)
  );
}

function validBinding(record: PurchaseBindingRecord, tokenFingerprint: string): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'tokenFingerprint',
      'accountSubject',
      'planId',
      'productId',
      'basePlanId',
      'offerIdAbsent',
      'normalizedState',
      'playExpiresAt',
      'lastVerifiedAt',
      'deliveryState',
      'ackState',
      'bindingState',
      'recoveryReason',
      'attemptGeneration',
      'attemptNonce',
      'attemptRequestFingerprint',
      'attemptPhase',
      'stagedPredecessorFingerprint',
      'predecessorFingerprint',
      'successorFingerprint',
      'acknowledgementConfirmedAt',
      'stateChangedAt',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    validBase(record) &&
    record.tokenFingerprint === tokenFingerprint &&
    isFingerprint(record.tokenFingerprint) &&
    isFingerprint(record.accountSubject) &&
    isProductId(record.productId) &&
    PRODUCT_ALLOWLIST[record.productId].planId === record.planId &&
    record.basePlanId === 'monthly' &&
    record.offerIdAbsent === true &&
    ['active', 'grace', 'canceled'].includes(record.normalizedState) &&
    record.deliveryState === 'committed' &&
    ['pending', 'play_acknowledged', 'unknown', 'acknowledged'].includes(record.ackState) &&
    ['verified_delivery_committed', 'acknowledged_delivery', 'superseded'].includes(
      record.bindingState,
    ) &&
    ['none', 'acknowledgement_unknown'].includes(record.recoveryReason) &&
    Number.isSafeInteger(record.attemptGeneration) &&
    record.attemptGeneration > 0 &&
    record.attemptNonce instanceof Uint8Array &&
    record.attemptNonce.byteLength === 16 &&
    isFingerprint(record.attemptRequestFingerprint) &&
    ['delivery_committed', 'ack_in_progress', 'paid'].includes(record.attemptPhase) &&
    optionalFingerprint(record.stagedPredecessorFingerprint) &&
    optionalFingerprint(record.predecessorFingerprint) &&
    optionalFingerprint(record.successorFingerprint) &&
    (record.acknowledgementConfirmedAt === undefined ||
      record.acknowledgementConfirmedAt instanceof Date) &&
    record.playExpiresAt instanceof Date &&
    record.lastVerifiedAt instanceof Date &&
    record.stateChangedAt instanceof Date &&
    (record.ackState !== 'acknowledged' ||
      (record.bindingState !== 'verified_delivery_committed' &&
        record.acknowledgementConfirmedAt instanceof Date))
  );
}

function validRateLimit(record: RateLimitRecord, accountSubject: string): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'accountSubject',
      'getStartedAt',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    validBase(record) &&
    record.accountSubject === accountSubject &&
    isFingerprint(record.accountSubject) &&
    validRollingStarts(record.getStartedAt, MAX_GETS_PER_SUBJECT_WINDOW)
  );
}

function recentStarts(starts: readonly Date[], now: Date): Date[] {
  return starts.filter((startedAt) => now.getTime() < startedAt.getTime() + RATE_WINDOW_MS);
}

function validRollingStarts(value: unknown, maximum: number): value is Date[] {
  return (
    Array.isArray(value) &&
    value.length <= maximum &&
    value.every((startedAt) => startedAt instanceof Date)
  );
}

function protectedBeforeBoundary(
  record: RequestReplayRecord | TokenOperationRecord | undefined,
  now: Date,
): boolean {
  return (
    record !== undefined &&
    PROTECTED_PHASES.has(record.phase) &&
    record.leaseExpiresAt instanceof Date &&
    now.getTime() < record.leaseExpiresAt.getTime()
  );
}

function cooldownBeforeBoundary(
  record: RequestReplayRecord | TokenOperationRecord | undefined,
  now: Date,
): boolean {
  return (
    record?.phase === 'ack_unknown' &&
    record.cooldownUntil instanceof Date &&
    now.getTime() < record.cooldownUntil.getTime()
  );
}

function sameOwner(record: AttemptOwner, attempt: AttemptHandle): boolean {
  return (
    record.requestFingerprint === attempt.owner.requestFingerprint &&
    record.attemptGeneration === attempt.owner.attemptGeneration &&
    bytesEqual(record.attemptNonce, attempt.owner.attemptNonce)
  );
}

function ownedOperation(
  record: TokenOperationRecord | undefined,
  attempt: AttemptHandle,
  phase: OperationPhase,
): record is TokenOperationRecord {
  return (
    record !== undefined &&
    validOperation(record, attempt.tokenFingerprint) &&
    sameOwner(record, attempt) &&
    record.phase === phase
  );
}

function ownedOperationAny(
  record: TokenOperationRecord | undefined,
  attempt: AttemptHandle,
  phases: OperationPhase[],
): record is TokenOperationRecord {
  return (
    record !== undefined &&
    validOperation(record, attempt.tokenFingerprint) &&
    sameOwner(record, attempt) &&
    phases.includes(record.phase)
  );
}

function ownedReplayAny(
  record: RequestReplayRecord | undefined,
  attempt: AttemptHandle,
  phases: OperationPhase[],
): record is RequestReplayRecord {
  return (
    record !== undefined &&
    validReplay(record, attempt.owner.requestFingerprint) &&
    sameOwner(record, attempt) &&
    phases.includes(record.phase)
  );
}

function ownedBinding(
  record: PurchaseBindingRecord | undefined,
  attempt: AttemptHandle,
  phase: PurchaseBindingRecord['attemptPhase'],
): record is PurchaseBindingRecord {
  return (
    record !== undefined &&
    validBinding(record, attempt.tokenFingerprint) &&
    record.attemptRequestFingerprint === attempt.owner.requestFingerprint &&
    record.attemptGeneration === attempt.owner.attemptGeneration &&
    bytesEqual(record.attemptNonce, attempt.owner.attemptNonce) &&
    record.attemptPhase === phase
  );
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) {
    return false;
  }
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function consistentReplayOperation(
  replay: RequestReplayRecord,
  operation: TokenOperationRecord,
): boolean {
  if (
    replay.tokenFingerprint !== operation.tokenFingerprint ||
    !sameOwner(replay, {
      tokenFingerprint: operation.tokenFingerprint,
      accountSubject: operation.accountSubject ?? '',
      owner: operation,
      usesReplay: true,
    })
  ) {
    return false;
  }
  if (operation.phase === 'verified_owner') {
    return replay.phase === 'lookup_in_flight';
  }
  return replay.phase === operation.phase && replay.outcomeCode === operation.outcomeCode;
}

function hasOnlyKeys(record: object, allowed: string[]): boolean {
  const allowedKeys = new Set(allowed);
  return Object.keys(record).every((key) => allowedKeys.has(key));
}

function isFingerprint(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function optionalFingerprint(value: unknown): boolean {
  return value === undefined || isFingerprint(value);
}

function isProductId(value: unknown): value is ProductId {
  return typeof value === 'string' && value in PRODUCT_ALLOWLIST;
}

function isReplayPhase(value: unknown): value is RequestReplayRecord['phase'] {
  return (
    typeof value === 'string' &&
    [
      'lookup_in_flight',
      'delivery_committed',
      'ack_in_progress',
      'ack_unknown',
      'paid',
      'free',
      'canceled_pending_read_only',
    ].includes(value)
  );
}

function isOperationPhase(value: unknown): value is OperationPhase {
  return typeof value === 'string' && [...PROTECTED_PHASES, 'ack_unknown', 'paid', 'free', 'canceled_pending_read_only'].includes(value as OperationPhase);
}

function validPhaseOutcome(
  phase: OperationPhase,
  outcome: RequestReplayRecord['outcomeCode'],
): boolean {
  if (PROTECTED_PHASES.has(phase)) {
    return outcome === 'in_flight';
  }
  if (phase === 'ack_unknown') {
    return outcome === 'ack_unknown';
  }
  if (phase === 'paid') {
    return outcome === 'paid';
  }
  return outcome === 'free';
}

function validLeaseAndCooldown(
  phase: OperationPhase,
  leaseExpiresAt: Date | undefined,
  cooldownUntil: Date | undefined,
): boolean {
  if (PROTECTED_PHASES.has(phase)) {
    return leaseExpiresAt instanceof Date && cooldownUntil === undefined;
  }
  if (phase === 'ack_unknown') {
    return leaseExpiresAt === undefined && cooldownUntil instanceof Date;
  }
  return leaseExpiresAt === undefined && cooldownUntil === undefined;
}
