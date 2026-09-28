import { type InternalWork, type ReconcileFence, type ReconcileWork, type ReconcilePolicy, type CompletedObservation, type MigrationException, validMigrationException, validPolicy, validWork, ownsWork, marked, initialWork, reschedule, fenceFor, selection, increment, selectedEqual } from './reconciliation_work.js';
import { ownsEvent, type EventWorkFence, type EventWorkRecord, type ResolvedEventAccount } from './event_records.js';
import { OWNERSHIP_PROOF_VERSION, validOwnershipProof, type OwnershipProof } from './ownership_proof.js';
import { AUTHORITY_VERSION, SNAPSHOT_VERSION, initialAuthority, validAuthority, outboxFor, fingerprint, type AccountAuthority, type AuthorityOutbox, type AuthoritySnapshot, type ObservationSource, type InactiveReason } from './account_authority.js';
import { LIFECYCLE_VERSION, validLifecycleFields, sameLifecycle, validLifecycleRoot, validReciprocalRoute, validOpaqueRoute, routeFor, type LifecycleFields, type LifecycleRoot, type LifecycleRoute } from './lifecycle.js';
import type { BillingIdentifiers } from './crypto.js';
import {
  ACK_COOLDOWN_MS,
  ACTIVE_KEY_VERSION,
  ATTEMPT_LEASE_MS,
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
import { BillingDeadline } from './deadline.js';
import { validEnvelope, type TokenEnvelope } from './token_custody.js';
import type { NonceSource, NormalizedPaidState } from './contracts.js';

export type BillingCollection = (typeof COLLECTIONS)[keyof typeof COLLECTIONS];

export interface BillingTransaction {
  get<T>(collection: BillingCollection, id: string): Promise<T | undefined>;
  findSubjectBinding(accountSubject: string): Promise<unknown | undefined>;
  findSubjectRoute(accountSubject: string): Promise<unknown | undefined>;
  findAnyEventWork(): Promise<unknown | undefined>;
  set<T>(collection: BillingCollection, id: string, value: T): void;
}

export interface BillingDatabase {
  readonly databaseId: string;
  dueEventWork(now: Date, limit: number): Promise<string[]>;
  dueReconciliationWork?(now: Date, limit: number): Promise<string[]>;
  runTransaction<T>(operation: (transaction: BillingTransaction) => Promise<T>): Promise<T>;
}

export interface AttemptOwner {
  requestFingerprint: string;
  attemptGeneration: number;
  attemptNonce: Uint8Array;
}

export interface AttemptHandle extends LifecycleFields {
  expectedPlayAccountId: string;
  tokenFingerprint: string;
  accountSubject: string;
  owner: AttemptOwner;
  usesReplay: boolean;
  fence?: { assertionId: string; indexRevision: number; deadline: BillingDeadline; kind: 'verify' | 'restore';
    observationGeneration: number; observationNonce: Uint8Array; source: ObservationSource; publicationRevision: number; work?: InternalWork };
  completedObservation?: CompletedObservation;
  envelope?: TokenEnvelope;
  ownershipProof?: OwnershipProof;
}
interface AccountIndex extends LifecycleFields {
  contractVersion: typeof CONTRACT_VERSION;
  keyVersion: typeof ACTIVE_KEY_VERSION;
  accountSubject: string;
  revision: number;
  current?: string;
  candidate?: string;
  inactive?: { tokenFingerprint: string; verifiedAt: Date; reason: string };
  updatedAt: Date;
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
  assertionId: string;
  assertionVersion: typeof DISCLOSURE_ASSERTION_VERSION;
  accountSubject: string;
  disclosureVersion: typeof DISCLOSURE_VERSION;
  purpose: typeof DISCLOSURE_PURPOSE;
  acceptedAt: Date;
  status: 'accepted' | 'revoked';
  statusChangedAt: Date;
}

interface RequestReplayRecord extends BaseRecord, AttemptOwner, LifecycleFields {
  operationKind: 'verify' | 'restore';
  tokenFingerprint: string;
  phase: OperationPhase;
  outcomeCode: 'in_flight' | 'ack_unknown' | 'paid' | 'free';
  leaseExpiresAt?: Date;
  cooldownUntil?: Date;
}

interface TokenOperationRecord extends BaseRecord, AttemptOwner, LifecycleFields {
  tokenFingerprint: string;
  accountSubject?: string;
  phase: OperationPhase;
  outcomeCode: 'in_flight' | 'ack_unknown' | 'paid' | 'free';
  leaseExpiresAt?: Date;
  cooldownUntil?: Date;
  lastGetStartedAt: Date;
  acknowledgementStartedAt: Date[];
}

interface PurchaseBindingRecord extends Omit<BaseRecord, 'retentionExpiresAt'>, LifecycleFields {
  retentionExpiresAt?: Date;
  tokenEnvelope: TokenEnvelope;
  ownershipProof?: OwnershipProof;
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
        | 'unsafe_record'
        | 'disclosure_required'
        | 'recovery_required'
        | 'no_known_purchase';
    };

export interface DeliveryInput {
  ownershipProof?: OwnershipProof;
  tokenEnvelope: TokenEnvelope;
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
  private readonly auxiliaryExpiry = new WeakMap<AttemptHandle, {current:string; revision:number; generation:number; verifiedAt:Date; expiresAt:number}>();
  constructor(
    private readonly database: BillingDatabase,
    private readonly nonces: NonceSource,
    private readonly identifiers: Pick<BillingIdentifiers, 'routeFingerprint'>,
    private readonly reconciliationPolicy?: ReconcilePolicy,
  ) { if (reconciliationPolicy && !validPolicy(reconciliationPolicy)) throw new Error('billing reconciliation policy unavailable'); }

  get databaseId(): string {
    return this.database.databaseId;
  }

  private async readLifecycle(tx: BillingTransaction, subject: string, allowUnmarked = false): Promise<LifecycleRoot | undefined> {
    const root = await tx.get<LifecycleRoot>(COLLECTIONS.lifecycles, subject);
    const work = await tx.get<ReconcileWork>(COLLECTIONS.reconcileWork, subject);
    const exception = await tx.get<MigrationException>(COLLECTIONS.reconcileExceptions, subject);
    if (root === undefined) {
      if (exception !== undefined || work !== undefined || await tx.findSubjectRoute(subject) !== undefined || await tx.get(COLLECTIONS.authorities, subject) !== undefined ||
          await tx.get(COLLECTIONS.authorityOutbox, subject) !== undefined) throw new UnsafeBillingRecordError();
      return undefined;
    }
    if (!validLifecycleRoot(root, subject) || this.identifiers.routeFingerprint(root.obfuscatedAccountId) !== root.routeFingerprint) {
      throw new UnsafeBillingRecordError();
    }
    if(exception !== undefined && !validMigrationException(exception,root))throw new UnsafeBillingRecordError();
    const route = await tx.get<LifecycleRoute>(COLLECTIONS.routes, root.routeFingerprint);
    if (!route || !validReciprocalRoute(route, root)) throw new UnsafeBillingRecordError();
    await this.readAuthority(tx, root);
    if (root.reconcileVersion === undefined && work === undefined) {
      if(root.status!=='retired'){
        const index=await tx.get<AccountIndex>(COLLECTIONS.accounts,subject);
        if(isLegacy(index))throw new MigrationRequiredError();
        await this.validatePointers(tx,root,index);
      }
      if (!allowUnmarked) throw new MigrationRequiredError();
    } else if (!work || !validWork(work, root)) throw new UnsafeBillingRecordError();
    return root;
  }

  private async readAuthority(tx: BillingTransaction, root: LifecycleRoot): Promise<AccountAuthority | undefined> {
    const authority = await tx.get<AccountAuthority>(COLLECTIONS.authorities, root.accountSubject);
    const outbox = await tx.get<AuthorityOutbox>(COLLECTIONS.authorityOutbox, root.accountSubject);
    if (root.authorityVersion === undefined && authority === undefined && outbox === undefined) return undefined;
    if (!authority || !outbox || !validAuthority(authority, root, outbox)) throw new UnsafeBillingRecordError();
    const recoveryToken = authority.acknowledgementRecoveryToken;
    if (recoveryToken !== undefined) {
      const index = await tx.get<AccountIndex>(COLLECTIONS.accounts, root.accountSubject);
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, recoveryToken);
      if (!index || !validIndex(index, root.accountSubject) || !sameLifecycle(index, root) ||
          (index.current !== recoveryToken && index.candidate !== recoveryToken) || !binding ||
          !validBinding(binding, recoveryToken) || binding.accountSubject !== root.accountSubject || !sameLifecycle(binding, root)) {
        throw new UnsafeBillingRecordError();
      }
    }
    return authority;
  }

  private async firstAuthority(tx: BillingTransaction, root: LifecycleRoot, now: Date): Promise<AccountAuthority> {
    const fresh = initialAuthority(root, now);
    // A retired L1 root cannot recover; its old-generation custody is retained,
    // not adopted. Active cutover must preserve any already-started ACK barrier.
    if (root.status === 'retired') return fresh;
    const index = await tx.get<AccountIndex>(COLLECTIONS.accounts, root.accountSubject);
    if (index !== undefined && (!validIndex(index, root.accountSubject) || !sameLifecycle(index, root))) throw new UnsafeBillingRecordError();
    if (index === undefined && await tx.findSubjectBinding(root.accountSubject) !== undefined) throw new UnsafeBillingRecordError();
    const bindings = new Map<string, PurchaseBindingRecord>();
    for (const pointer of new Set([index?.current, index?.candidate])) {
      if (pointer === undefined) continue;
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, pointer);
      if (!binding || !validBinding(binding, pointer) || binding.accountSubject !== root.accountSubject || !sameLifecycle(binding, root)) throw new UnsafeBillingRecordError();
      bindings.set(pointer, binding);
    }
    if (!validIndexedChain(index, bindings)) throw new UnsafeBillingRecordError();
    const recovery = [...bindings.values()].filter(binding => binding.attemptPhase === 'ack_in_progress' || binding.ackState === 'unknown');
    if (recovery.length > 1) throw new UnsafeBillingRecordError();
    return recovery.length === 0 ? fresh : { ...fresh, acknowledgementRecoveryToken: recovery[0].tokenFingerprint };
  }

  private writeAuthority(tx: BillingTransaction, root: LifecycleRoot, authority: AccountAuthority): void {
    const marked: LifecycleRoot = { ...root, authorityVersion: AUTHORITY_VERSION,
      authorityPublicationRevision: authority.publicationRevision };
    const outbox = outboxFor(authority.snapshot);
    if (!validAuthority(authority, marked, outbox)) throw new UnsafeBillingRecordError();
    tx.set(COLLECTIONS.lifecycles, root.accountSubject, marked);
    tx.set(COLLECTIONS.authorities, root.accountSubject, authority);
    tx.set(COLLECTIONS.authorityOutbox, root.accountSubject, outbox);
  }

  private publishAuthority(tx: BillingTransaction, root: LifecycleRoot, authority: AccountAuthority,
    fields: Pick<AuthoritySnapshot, 'state' | 'verifiedAt'> & Partial<Pick<AuthoritySnapshot, 'reason' | 'planId' | 'productId' | 'tokenFingerprint' | 'playExpiresAt'>>,
    clearAcknowledgement: boolean): void {
    if (authority.publicationRevision >= Number.MAX_SAFE_INTEGER) throw new UnsafeBillingRecordError();
    const publicationRevision = authority.publicationRevision + 1;
    const snapshot: AuthoritySnapshot = { version: SNAPSHOT_VERSION, accountSubject: root.accountSubject,
      lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration,
      observationGeneration: authority.observationGeneration, publicationRevision, ...fields };
    this.writeAuthority(tx, root, { ...authority, lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration,
      publicationRevision, snapshot,
      ...(clearAcknowledgement ? { acknowledgementRecoveryToken: undefined } : {}) });
  }

  private currentObservation(authority: AccountAuthority | undefined, attempt: AttemptHandle): boolean {
    const fence = attempt.fence; const owner = authority?.owner;
    return fence !== undefined && authority !== undefined && owner !== undefined &&
      authority.observationGeneration === fence.observationGeneration && bytesEqual(owner.nonce, fence.observationNonce) &&
      owner.requestFingerprint === attempt.owner.requestFingerprint && owner.tokenFingerprint === attempt.tokenFingerprint &&
      owner.source === fence.source;
  }

  private async validWorkFence(tx: BillingTransaction, fence: EventWorkFence, account: ResolvedEventAccount, now: Date): Promise<boolean> {
    const work = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork, fence.eventFingerprint);
    return ownsEvent(work, fence, now) && work.resolved !== undefined &&
      work.resolved.accountSubject === account.accountSubject && sameLifecycle(work.resolved, account);
  }

  private async readWork(tx: BillingTransaction, root: LifecycleRoot): Promise<ReconcileWork> {
    const w = await tx.get<ReconcileWork>(COLLECTIONS.reconcileWork, root.accountSubject);
    if (!w || !validWork(w, root)) throw new UnsafeBillingRecordError();
    return w;
  }
  private async validInternalWork(tx: BillingTransaction, work: InternalWork, root: LifecycleRoot, now: Date): Promise<boolean> {
    if (!work || Object.keys(work).length !== 2 || !Object.hasOwn(work,'kind') || !Object.hasOwn(work,'fence')) return false;
    if (work.kind === 'event') return this.validWorkFence(tx, work.fence, root, now);
    if (work.kind !== 'reconciliation') return false;
    return ownsWork(await this.readWork(tx, root), work.fence, now);
  }
  private async validatePointers(tx: BillingTransaction, root: LifecycleRoot, index: AccountIndex | undefined): Promise<void> {
    if (index && (!validIndex(index, root.accountSubject) || !sameLifecycle(index, root))) throw new UnsafeBillingRecordError();
    if (!index && await tx.findSubjectBinding(root.accountSubject) !== undefined) throw new UnsafeBillingRecordError();
    const bindings = new Map<string, PurchaseBindingRecord>();
    for (const id of new Set([index?.current,index?.candidate])) {
      if (!id) continue;
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,id);
      if (!binding || !validBinding(binding,id) || binding.accountSubject !== root.accountSubject || !sameLifecycle(binding,root)) throw new UnsafeBillingRecordError();
      bindings.set(id,binding);
    }
    if (!validIndexedChain(index,bindings)) throw new UnsafeBillingRecordError();
  }
  private scheduleConsent(tx: BillingTransaction, root: LifecycleRoot, old: ReconcileWork | undefined,
    index: AccountIndex | undefined, now: Date, publicationRevision: number): void {
    if (!old) {
      tx.set(COLLECTIONS.reconcileExceptions,root.accountSubject,{version:'play-billing-reconcile-exception-v1',accountSubject:root.accountSubject,
        lifecycleEpoch:root.lifecycleEpoch,lifecycleGeneration:root.lifecycleGeneration,reason:root.status==='retired'?'unmarked_retired':'unmarked_revoked',recordedAt:now});
      return;
    }
    const w = reschedule(old,root,index,now,this.reconciliationPolicy,{publicationRevision});
    Object.assign(root,marked(root,w));
    tx.set(COLLECTIONS.reconcileWork,root.accountSubject,w);
  }

  /** Claims only retained, validated custody; no event, UID or requested token. */
  async claimReconciliation(subject:string,now:Date,deadline:BillingDeadline):Promise<ReconcileFence|undefined> {
    if(!this.reconciliationPolicy)return undefined;
    return this.database.runTransaction(async tx=>{
      deadline.check();
      const root=await this.readLifecycle(tx,subject);
      if(!root||root.status!=='active')return undefined;
      const w=await this.readWork(tx,root);
      if(!['ready','retry','working'].includes(w.state)||w.dueAt>now)return undefined;
      const defer = (state:'retry'|'blocked',dueAt:Date,reason:'consent'|'budget'|'retry'):undefined => {
        const next:ReconcileWork={...w,state,dueAt,reason,scheduleRevision:increment(w.scheduleRevision),ownerGeneration:increment(w.ownerGeneration),
          nonce:undefined,selectedDemand:undefined,leaseExpiresAt:undefined,completedObservation:undefined};
        deadline.check();tx.set(COLLECTIONS.reconcileWork,subject,next);tx.set(COLLECTIONS.lifecycles,subject,marked(root,next));return undefined;
      };
      const disclosure=await tx.get<DisclosureRecord>(COLLECTIONS.disclosures,subject);
      if(disclosure && !validDisclosure(disclosure,subject))throw new UnsafeBillingRecordError();
      if(!disclosure||disclosure.status!=='accepted'||disclosure.assertionId!==root.assertionId||disclosure.retentionExpiresAt<=now)
        return defer('blocked',now,'consent');
      const index=await tx.get<AccountIndex>(COLLECTIONS.accounts,subject);
      await this.validatePointers(tx,root,index);
      const authority=await this.readAuthority(tx,root);
      if(!index||!authority)throw new UnsafeBillingRecordError();
      if(authority.owner?.leaseExpiresAt!==undefined&&authority.owner.leaseExpiresAt>now)return defer('retry',authority.owner.leaseExpiresAt,'retry');
      const chosen=selection(w,index,authority.acknowledgementRecoveryToken,now);
      if(!chosen){
        const ack=authority.acknowledgementRecoveryToken;
        const dates=[w.currentDemand,w.candidateDemand].filter(d=>d!==undefined&&(!ack||d.tokenFingerprint===ack)).map(d=>d!.dueAt).filter(d=>d>now);
        if(!dates.length)throw new UnsafeBillingRecordError();
        return defer('retry',new Date(Math.min(...dates.map(Number))),'retry');
      }
      const starts=w.attemptStarts.filter(d=>+d>+now-86_400_000);
      if(starts.some(d=>d>now)||starts.length>=12)return defer('retry',new Date(Math.min(...starts.map(Number))+86_400_000+1),'budget');
      const operation=await tx.get<TokenOperationRecord>(COLLECTIONS.operations,chosen.tokenFingerprint);
      if(operation&&(!validOperation(operation,chosen.tokenFingerprint)||!sameLifecycle(operation,root)))throw new UnsafeBillingRecordError();
      if(operation&&(protectedBeforeBoundary(operation,now)||cooldownBeforeBoundary(operation,now)||+now<+operation.lastGetStartedAt+TOKEN_GET_COOLDOWN_MS)){
        const until=Math.max(+(operation.leaseExpiresAt??now),+(operation.cooldownUntil??now),+operation.lastGetStartedAt+TOKEN_GET_COOLDOWN_MS);
        return defer('retry',new Date(until),'retry');
      }
      const claimed:ReconcileWork={...w,state:'working',scheduleRevision:increment(w.scheduleRevision),ownerGeneration:increment(w.ownerGeneration),
        nonce:this.nonce(),selectedDemand:chosen,leaseExpiresAt:addMs(now,ATTEMPT_LEASE_MS),dueAt:addMs(now,ATTEMPT_LEASE_MS),
        attemptStarts:[...starts,now],completedObservation:undefined,reason:undefined};
      deadline.check();tx.set(COLLECTIONS.reconcileWork,subject,claimed);tx.set(COLLECTIONS.lifecycles,subject,marked(root,claimed));
      return fenceFor(claimed);
    });
  }

  async reserveReconciliation(fence:ReconcileFence,kind:'get'|'ack'|'kms',now:Date,deadline:BillingDeadline,requestFingerprint:string):Promise<void> {
    await this.database.runTransaction(async tx=>{
      deadline.check();const root=await this.readLifecycle(tx,fence.accountSubject);
      if(!root||root.status!=='active')throw new UnsafeBillingRecordError();
      const w=await this.readWork(tx,root);
      const disclosure=await tx.get<DisclosureRecord>(COLLECTIONS.disclosures,root.accountSubject);
      const authority=await this.readAuthority(tx,root);
      const index=await tx.get<AccountIndex>(COLLECTIONS.accounts,root.accountSubject);
      if(!ownsWork(w,fence,now)||!disclosure||!validDisclosure(disclosure,root.accountSubject)||disclosure.status!=='accepted'||disclosure.retentionExpiresAt<=now||
        disclosure.assertionId!==fence.assertionId||!index||index.revision!==fence.selectedDemand.indexRevision||!authority||
        authority.owner?.source!=='background'||authority.owner.requestFingerprint!==requestFingerprint||authority.owner.tokenFingerprint!==fence.selectedDemand.tokenFingerprint||authority.owner.phase==='complete'||
        !authority.owner.leaseExpiresAt||authority.owner.leaseExpiresAt<=now)throw new UnsafeBillingRecordError();
      if(!['get','ack','kms'].includes(kind))throw new UnsafeBillingRecordError();
      deadline.check();tx.set(COLLECTIONS.reconcileWork,root.accountSubject,{...w,dispatchTotals:{...w.dispatchTotals,[kind]:increment(w.dispatchTotals[kind])}});
    });
  }

  async retryReconciliation(fence:ReconcileFence,now:Date,deadline:BillingDeadline):Promise<boolean> {
    return this.database.runTransaction(async tx=>{
      deadline.check();const root=await this.readLifecycle(tx,fence.accountSubject);
      if(!root||root.status!=='active')return false;
      const w=await this.readWork(tx,root);if(!ownsWork(w,fence,now))return false;
      const delay=Math.min(this.reconciliationPolicy?.maxRetryMs??900_000,(this.reconciliationPolicy?.retryMs??30_000)*2**Math.min(w.attemptStarts.length-1,5));
      const dueAt=addMs(now,delay);
      const next:ReconcileWork={...w,state:'retry',scheduleRevision:increment(w.scheduleRevision),ownerGeneration:increment(w.ownerGeneration),dueAt,
        nonce:undefined,leaseExpiresAt:undefined,selectedDemand:undefined,completedObservation:undefined,reason:'retry'};
      // Preserve age of an overdue other demand. Overall retry limits invocation cadence.
      const key=w.candidateDemand?.tokenFingerprint===fence.selectedDemand.tokenFingerprint?'candidateDemand':'currentDemand';
      if(next[key])next[key]={...next[key]!,dueAt};
      deadline.check();tx.set(COLLECTIONS.reconcileWork,root.accountSubject,next);tx.set(COLLECTIONS.lifecycles,root.accountSubject,marked(root,next));return true;
    });
  }

  private async validateCompleted(attempt:AttemptHandle,now:Date,outcome:'paid'|'inactive'):Promise<boolean> {
    return this.database.runTransaction(async tx=>{
      const receipt=attempt.completedObservation;const f=attempt.fence;
      if(!receipt||!f||receipt.outcome!==outcome)return false;
      f.deadline.check();const root=await this.readLifecycle(tx,attempt.accountSubject);
      if(!root||root.status!=='active'||!sameLifecycle(root,attempt)||root.assertionId!==f.assertionId||root.obfuscatedAccountId!==attempt.expectedPlayAccountId)return false;
      const w=await this.readWork(tx,root);const r=w.completedObservation;
      if(!r||r.scheduleRevision!==receipt.scheduleRevision||r.ownerGeneration!==receipt.ownerGeneration||!bytesEqual(r.nonce,receipt.nonce)||
        !selectedEqual(r.selectedDemand,receipt.selectedDemand)||r.requestFingerprint!==attempt.owner.requestFingerprint||r.observationGeneration!==f.observationGeneration||
        !bytesEqual(r.observationNonce,f.observationNonce)||r.publicationRevision!==f.publicationRevision||r.indexRevision!==f.indexRevision||r.outcome!==outcome||r.reason!==receipt.reason)return false;
      const disclosure=await tx.get<DisclosureRecord>(COLLECTIONS.disclosures,root.accountSubject);
      const index=await tx.get<AccountIndex>(COLLECTIONS.accounts,root.accountSubject);
      await this.validatePointers(tx,root,index);
      const authority=await this.readAuthority(tx,root);
      const operation=await tx.get<TokenOperationRecord>(COLLECTIONS.operations,attempt.tokenFingerprint);
      const replay=attempt.usesReplay?await tx.get<RequestReplayRecord>(COLLECTIONS.replays,attempt.owner.requestFingerprint):undefined;
      const binding=await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,attempt.tokenFingerprint);
      if(!disclosure||!validDisclosure(disclosure,root.accountSubject)||disclosure.status!=='accepted'||disclosure.retentionExpiresAt<=now||disclosure.assertionId!==root.assertionId||
        !index||!validIndex(index,root.accountSubject)||!sameLifecycle(index,root)||index.revision!==r.indexRevision||!this.currentObservation(authority,attempt)||authority!.owner!.phase!=='complete'||authority!.publicationRevision!==r.publicationRevision||
        !ownedOperation(operation,attempt,outcome==='paid'?'paid':'free')||(attempt.usesReplay&&!ownedReplayAny(replay,attempt,[outcome==='paid'?'paid':'free'])))return false;
      f.deadline.check();
      if(outcome==='inactive')return index.inactive?.tokenFingerprint===attempt.tokenFingerprint&&index.inactive.reason===r.reason;
      return authority!.snapshot.state!=='none'&&authority!.snapshot.observationGeneration===f.observationGeneration&&index.current===attempt.tokenFingerprint&&index.inactive?.tokenFingerprint!==attempt.tokenFingerprint&&
        ownedBinding(binding,attempt,'paid')&&binding.ackState==='acknowledged'&&binding.bindingState==='acknowledged_delivery'&&binding.playExpiresAt>now;
    });
  }

  /** Refresh an acknowledged current without restaging or erasing a pending candidate. */
  async finalizeReconciliationCurrent(attempt:AttemptHandle,input:PaidCommit,playAcknowledged:boolean,now:Date):Promise<PaidCommit|undefined> {
    if(attempt.fence?.work?.kind!=='reconciliation'||attempt.fence.work.fence.selectedDemand.kind!=='current'||!playAcknowledged)return undefined;
    const result=await this.guarded(attempt,async(tx,index,authority,root)=>{
      const binding=await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,attempt.tokenFingerprint);
      const operation=await tx.get<TokenOperationRecord>(COLLECTIONS.operations,attempt.tokenFingerprint);
      const replay=attempt.usesReplay?await tx.get<RequestReplayRecord>(COLLECTIONS.replays,attempt.owner.requestFingerprint):undefined;
      if(index?.current!==attempt.tokenFingerprint||!binding||!validBinding(binding,attempt.tokenFingerprint)||binding.ackState!=='acknowledged'||binding.bindingState!=='acknowledged_delivery'||
        !ownedOperation(operation,attempt,'verified_owner')||(attempt.usesReplay&&!ownedReplayAny(replay,attempt,['lookup_in_flight']))||binding.productId!==input.productId||input.playExpiresAt<=now||authority.acknowledgementRecoveryToken!==undefined)return undefined;
      tx.set(COLLECTIONS.bindings,attempt.tokenFingerprint,{...binding,planId:input.planId,productId:input.productId,normalizedState:input.normalizedState,playExpiresAt:input.playExpiresAt,lastVerifiedAt:input.verifiedAt,
        attemptGeneration:attempt.owner.attemptGeneration,attemptNonce:attempt.owner.attemptNonce,attemptRequestFingerprint:attempt.owner.requestFingerprint,
        attemptPhase:'paid',updatedAt:now});
      tx.set(COLLECTIONS.accounts,attempt.accountSubject,{...index,revision:index.revision+1,inactive:undefined,updatedAt:now});
      tx.set(COLLECTIONS.operations,attempt.tokenFingerprint,{...operation,phase:'paid',outcomeCode:'paid',leaseExpiresAt:undefined,updatedAt:now});
      if(replay)tx.set(COLLECTIONS.replays,attempt.owner.requestFingerprint,{...replay,phase:'paid',outcomeCode:'paid',leaseExpiresAt:undefined,updatedAt:now});
      this.publishAuthority(tx,root,{...authority,owner:{...authority.owner!,phase:'complete',leaseExpiresAt:undefined}},
        {state:input.normalizedState,planId:input.planId,productId:input.productId,tokenFingerprint:attempt.tokenFingerprint,verifiedAt:input.verifiedAt,playExpiresAt:input.playExpiresAt},true);
      return input;
    },undefined,now,'paid');
    if(result){attempt.fence!.indexRevision++;attempt.fence!.publicationRevision++;}return result;
  }

  private nonce(): Uint8Array {
    const nonce = this.nonces.nextNonce();
    if (!(nonce instanceof Uint8Array) || nonce.byteLength !== 16) throw new UnsafeBillingRecordError();
    return nonce;
  }

  async preparePurchase(subject: string, now: Date, deadline = new BillingDeadline()): Promise<
    { kind: 'ready'; obfuscatedAccountId: string; lifecycleEpoch: string } |
    { kind: 'disclosure_required' | 'recovery_required' | 'unsafe_record' }
  > {
    return this.database.runTransaction(async (tx) => {
      deadline.check();
      const disclosure = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, subject);
      if (!disclosure || !validDisclosure(disclosure, subject) || disclosure.status !== 'accepted' || disclosure.retentionExpiresAt <= now) {
        return { kind: 'disclosure_required' };
      }
      const root = await this.readLifecycle(tx, subject);
      if (root !== undefined) {
        const existingIndex=await tx.get<AccountIndex>(COLLECTIONS.accounts,subject);
        if(isLegacy(existingIndex))return {kind:'recovery_required'};
        if(root.status!=='retired')await this.validatePointers(tx,root,existingIndex);
        if (root.status === 'retired') return { kind: 'recovery_required' };
        if (root.status !== 'active' || root.assertionId !== disclosure.assertionId) return { kind: 'unsafe_record' };
        deadline.check();
        return { kind: 'ready', obfuscatedAccountId: root.obfuscatedAccountId, lifecycleEpoch: root.lifecycleEpoch };
      }
      // First registration cannot create authority beside old or orphan state,
      // even when a direct caller bypasses the mobile recovery preflight.
      const index = await tx.get<AccountIndex>(COLLECTIONS.accounts, subject);
      const orphan = await tx.findSubjectBinding(subject);
      if (index !== undefined || orphan !== undefined) {
        return { kind: isLegacy(index) || isLegacy(orphan) ? 'recovery_required' : 'unsafe_record' };
      }
      const obfuscatedAccountId = Buffer.concat([this.nonce(), this.nonce()]).toString('base64url');
      const routeFingerprint = this.identifiers.routeFingerprint(obfuscatedAccountId);
      if (await tx.get(COLLECTIONS.routes, routeFingerprint) !== undefined) return { kind: 'unsafe_record' };
      const created: LifecycleRoot = {
        version: LIFECYCLE_VERSION, accountSubject: subject, lifecycleEpoch: Buffer.from(this.nonce()).toString('hex'),
        lifecycleGeneration: 1, status: 'active', routeFingerprint, obfuscatedAccountId,
        assertionId: disclosure.assertionId, createdAt: now, updatedAt: now,
      };
      deadline.check();
      const work = initialWork(created, now);
      tx.set(COLLECTIONS.reconcileWork, subject, work);
      tx.set(COLLECTIONS.lifecycles, subject, marked(created, work));
      tx.set(COLLECTIONS.routes, routeFingerprint, routeFor(created));
      return { kind: 'ready', obfuscatedAccountId, lifecycleEpoch: created.lifecycleEpoch };
    });
  }

  async acceptDisclosure(accountSubject: string, now: Date, deadline = new BillingDeadline()): Promise<void> {
    return this.updateDisclosure(accountSubject, now, 'accepted', deadline);
  }
  async revokeDisclosure(accountSubject: string, now: Date, deadline = new BillingDeadline()): Promise<void> {
    return this.updateDisclosure(accountSubject, now, 'revoked', deadline);
  }
  private async updateDisclosure(accountSubject: string, now: Date, status: 'accepted' | 'revoked', deadline: BillingDeadline): Promise<void> {
    await this.database.runTransaction(async (tx) => {
      deadline.check();
      const existing = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject);
      if (existing !== undefined && !validDisclosure(existing, accountSubject, true)) throw new UnsafeBillingRecordError();
      const root = await this.readLifecycle(tx, accountSubject, status === 'revoked');
      const work = root ? await tx.get<ReconcileWork>(COLLECTIONS.reconcileWork, accountSubject) : undefined;
      const index = root ? await tx.get<AccountIndex>(COLLECTIONS.accounts, accountSubject) : undefined;
      if (root && root.status!=='retired') await this.validatePointers(tx, root, index);
      if (status === 'revoked' && existing === undefined && root === undefined) return;
      const authority = root === undefined ? undefined : await this.readAuthority(tx, root) ?? await this.firstAuthority(tx, root, now);
      if (authority && authority.observationGeneration >= Number.MAX_SAFE_INTEGER) throw new UnsafeBillingRecordError();
      const assertionId = Buffer.from(this.nonce()).toString('hex');
      deadline.check();
      tx.set<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject, {
        contractVersion: CONTRACT_VERSION, keyVersion: ACTIVE_KEY_VERSION, assertionId,
        assertionVersion: DISCLOSURE_ASSERTION_VERSION, accountSubject, disclosureVersion: DISCLOSURE_VERSION,
        purpose: DISCLOSURE_PURPOSE, acceptedAt: status === 'accepted' ? now : existing?.acceptedAt ?? now,
        status, statusChangedAt: now, createdAt: existing?.createdAt ?? now, updatedAt: now,
        retentionExpiresAt: addMs(now, status === 'accepted' ? DISCLOSURE_RETENTION_MS : REVOKED_RETENTION_MS),
      });
      if (root !== undefined) {
        const updated: LifecycleRoot = { ...root, assertionId,
          status: root.status === 'retired' ? 'retired' : status === 'accepted' ? 'active' : 'consent_paused', updatedAt: now };
        this.scheduleConsent(tx, updated, work, index, now, authority!.publicationRevision + 1);
        tx.set(COLLECTIONS.routes, root.routeFingerprint, routeFor(updated));
        this.publishAuthority(tx, updated, { ...authority!, observationGeneration: authority!.observationGeneration + 1, owner: undefined },
          { state: 'none', reason: updated.status === 'retired' ? 'retired' : status === 'revoked' ? 'revoked' : 'requires_verification', verifiedAt: now }, updated.status === 'retired');
      }
    });
  }

  /** Authority fence only: no public endpoint, identity deletion or retention cleanup. */
  async retireLifecycle(subject: string, expected: LifecycleFields, now: Date, deadline = new BillingDeadline()): Promise<boolean> {
    return this.database.runTransaction(async (tx) => {
      deadline.check();
      const root = await this.readLifecycle(tx, subject, true);
      const work = root ? await tx.get<ReconcileWork>(COLLECTIONS.reconcileWork, subject) : undefined;
      const index = root ? await tx.get<AccountIndex>(COLLECTIONS.accounts, subject) : undefined;
      if (root && root.status !== 'retired') await this.validatePointers(tx, root, index);
      if (!root || !sameLifecycle(root, expected) || root.status === 'retired' || root.lifecycleGeneration >= Number.MAX_SAFE_INTEGER) return false;
      const authority = await this.readAuthority(tx, root) ?? await this.firstAuthority(tx, root, now);
      if (authority.observationGeneration >= Number.MAX_SAFE_INTEGER) throw new UnsafeBillingRecordError();
      const retired: LifecycleRoot = { ...root, status: 'retired', lifecycleGeneration: root.lifecycleGeneration + 1, updatedAt: now };
      deadline.check();
      this.scheduleConsent(tx, retired, work, index, now, authority.publicationRevision + 1);
      tx.set(COLLECTIONS.routes, root.routeFingerprint, routeFor(retired));
      this.publishAuthority(tx, retired, { ...authority, observationGeneration: authority.observationGeneration + 1, owner: undefined },
        { state: 'none', reason: 'retired', verifiedAt: now }, true);
      return true;
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
    deadline = new BillingDeadline(),
    source: ObservationSource = 'foreground',
    work?: InternalWork,
  ): Promise<AcquireResult> {
    return this.acquire(accountSubject, requestFingerprint, tokenFingerprint, now, true, 'verify', deadline, source, undefined, work);
  }

  acquireAccountAttempt(accountSubject: string, requestFingerprint: string, now: Date, deadline: BillingDeadline, source: ObservationSource = 'foreground', work?: InternalWork): Promise<AcquireResult> {
    return this.acquire(accountSubject, requestFingerprint, undefined, now, true, 'restore', deadline, source, undefined, work);
  }

  async acquirePredecessorAttempt(
    accountSubject: string,
    requestFingerprint: string,
    tokenFingerprint: string,
    now: Date,
    deadline = new BillingDeadline(),
    previous?: AttemptHandle,
  ): Promise<AcquireResult> {
    const result = await this.acquire(accountSubject, requestFingerprint, tokenFingerprint, now, false, 'verify', deadline, previous?.fence?.source ?? 'foreground', previous, previous?.fence?.work);
    if (result.kind === 'acquired' && previous?.fence?.work?.kind === 'reconciliation' && result.attempt.fence?.work?.kind === 'reconciliation') {
      previous.fence.work.fence = result.attempt.fence.work.fence;
      result.attempt.fence.work = previous.fence.work;
    }
    return result;
  }

  private async acquire(
    accountSubject: string,
    requestFingerprint: string,
    requestedToken: string | undefined,
    now: Date,
    usesReplay: boolean,
    kind: 'verify' | 'restore',
    deadline: BillingDeadline,
    source: ObservationSource,
    previous?: AttemptHandle,
    work?: InternalWork,
  ): Promise<AcquireResult> {
    return this.database.runTransaction(async (tx) => {
      deadline.check();
      if (!fingerprint(accountSubject) || !fingerprint(requestFingerprint) ||
          (requestedToken !== undefined && !fingerprint(requestedToken)) || !['foreground','background'].includes(source)) return { kind: 'unsafe_record' };
      const disclosure = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, accountSubject);
      if (!disclosure || !validDisclosure(disclosure, accountSubject) || disclosure.status !== 'accepted' || disclosure.retentionExpiresAt <= now) return { kind: 'disclosure_required' };
      const root = await this.readLifecycle(tx, accountSubject);
      const index = await tx.get<AccountIndex>(COLLECTIONS.accounts, accountSubject);
      if (index !== undefined && isLegacy(index)) return { kind: 'recovery_required' };
      if (root === undefined) {
        const orphan = await tx.findSubjectBinding(accountSubject);
        if (index !== undefined || orphan !== undefined) return { kind: isLegacy(orphan) ? 'recovery_required' : 'unsafe_record' };
        return { kind: kind === 'restore' ? 'no_known_purchase' : 'recovery_required' };
      }
      if (root.status === 'retired') return { kind: 'recovery_required' };
      if (source === 'background' && (!work || !await this.validInternalWork(tx, work, root, now))) return { kind: 'unsafe_record' };
      if (source === 'foreground' && work !== undefined) return { kind: 'unsafe_record' };
      if (root.status !== 'active' || root.assertionId !== disclosure.assertionId) return { kind: 'disclosure_required' };
      if (index !== undefined && (!validIndex(index, accountSubject) || !sameLifecycle(index, root))) return { kind: 'unsafe_record' };
      if (index === undefined) {
        const orphan = await tx.findSubjectBinding(accountSubject);
        if (orphan !== undefined) return { kind: isLegacy(orphan) ? 'recovery_required' : 'unsafe_record' };
      }
      // Validate both references before choosing one; a valid candidate must not
      // hide an orphaned, cross-account or malformed current binding.
      const indexedBindings = new Map<string, PurchaseBindingRecord>();
      for (const pointer of new Set([index?.current, index?.candidate])) {
        if (pointer === undefined) continue;
        const referenced = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, pointer);
        if (referenced === undefined || !validBinding(referenced, pointer) ||
            referenced.accountSubject !== accountSubject || !sameLifecycle(referenced, root)) return { kind: 'unsafe_record' };
        indexedBindings.set(pointer, referenced);
      }
      if (!validIndexedChain(index, indexedBindings)) return { kind: 'unsafe_record' };
      const reconcile = work?.kind === 'reconciliation' ? work.fence : undefined;
      if (reconcile && (requestedToken !== undefined && previous === undefined)) return {kind:'unsafe_record'};
      if (reconcile && previous === undefined) {
        const w = await this.readWork(tx,root);
        const selected = w.selectedDemand;
        const pointer = selected?.kind === 'current' ? index?.current : selected?.kind === 'candidate' ? index?.candidate : selected?.tokenFingerprint;
        const slot = w.candidateDemand?.tokenFingerprint === selected?.tokenFingerprint ? w.candidateDemand : w.currentDemand;
        if (!selected || selected.indexRevision !== (index?.revision ?? 0) || pointer !== selected.tokenFingerprint ||
            slot?.tokenFingerprint !== selected.tokenFingerprint || slot.demandRevision !== selected.demandRevision) return {kind:'unsafe_record'};
      }
      const tokenFingerprint = requestedToken ?? reconcile?.selectedDemand.tokenFingerprint ?? index?.candidate ?? index?.current;
      if (tokenFingerprint === undefined) return { kind: 'no_known_purchase' };
      const replay = usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, requestFingerprint)
        : undefined;
      const operation = await tx.get<TokenOperationRecord>(COLLECTIONS.operations, tokenFingerprint);
      const binding = indexedBindings.get(tokenFingerprint) ??
        await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, tokenFingerprint);

      if (binding !== undefined && isLegacy(binding)) return { kind: 'recovery_required' };
      if (kind === 'restore' && (binding === undefined || binding.accountSubject !== accountSubject || !validEnvelope(binding.tokenEnvelope))) return { kind: 'unsafe_record' };
      if (replay !== undefined && replay.operationKind !== kind) return { kind: 'replay_conflict' };
      if (
        (replay !== undefined && (!validReplay(replay, requestFingerprint) || !sameLifecycle(replay, root))) ||
        (operation !== undefined && (!validOperation(operation, tokenFingerprint) ||
          (operation.accountSubject !== undefined && operation.accountSubject !== accountSubject) ||
          (!sameLifecycle(operation, root) && !unverifiedUnboundOperation(operation, binding)))) ||
        (binding !== undefined && (!validBinding(binding, tokenFingerprint) || !sameLifecycle(binding, root)))
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

      const authority = await this.readAuthority(tx, root) ?? await this.firstAuthority(tx, root, now);
      const continuing = previous !== undefined && this.currentObservation(authority, previous) &&
        previous.accountSubject === accountSubject && sameLifecycle(previous, root) &&
        previous.fence?.assertionId === disclosure.assertionId && previous.owner.requestFingerprint === requestFingerprint &&
        authority.owner?.phase === 'complete' && previous.fence.indexRevision === (index?.revision ?? 0);
      if (previous !== undefined && !continuing) return { kind: 'unsafe_record' };
      let admittedWork = work;
      if (reconcile && previous) {
        // The only permitted pointer switch is a freshly canceled staged successor
        // to its retained, indexed predecessor after the successor is closed.
        const w = await this.readWork(tx,root);
        const successor = indexedBindings.get(previous.tokenFingerprint);
        const d = w.currentDemand;
        if (index?.candidate !== previous.tokenFingerprint || index.current !== tokenFingerprint ||
          successor?.stagedPredecessorFingerprint !== tokenFingerprint || !d || d.tokenFingerprint !== tokenFingerprint ||
          authority.acknowledgementRecoveryToken !== undefined) return {kind:'unsafe_record'};
        const changed:ReconcileWork={...w,scheduleRevision:increment(w.scheduleRevision),selectedDemand:{kind:'current',tokenFingerprint,demandRevision:d.demandRevision,indexRevision:index.revision}};
        admittedWork={kind:'reconciliation',fence:fenceFor(changed)};
        // Defer these writes until every admission read has finished below.
      }
      if (reconcile?.selectedDemand.kind === 'ack' && !previous && authority.acknowledgementRecoveryToken !== tokenFingerprint) return {kind:'unsafe_record'};
      if (authority.acknowledgementRecoveryToken !== undefined && authority.acknowledgementRecoveryToken !== tokenFingerprint) return { kind: 'verification_pending' };
      if (authority.owner?.leaseExpiresAt !== undefined && authority.owner.leaseExpiresAt > now) return { kind: 'in_flight' };
      if ((!continuing && authority.observationGeneration >= Number.MAX_SAFE_INTEGER) ||
          authority.publicationRevision >= Number.MAX_SAFE_INTEGER) return { kind: 'unsafe_record' };
      const rate = source === 'foreground' ? await tx.get<RateLimitRecord>(COLLECTIONS.rateLimits, accountSubject) : undefined;
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
      if (highWater >= Number.MAX_SAFE_INTEGER) return { kind: 'unsafe_record' };
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

      const observationGeneration = continuing ? authority.observationGeneration : authority.observationGeneration + 1;
      const observationNonce = continuing ? authority.owner!.nonce : this.nonce();
      deadline.check();
      if (admittedWork?.kind === 'reconciliation' && admittedWork !== work) {
        const old = await this.readWork(tx,root);
        const changed:ReconcileWork={...old,scheduleRevision:admittedWork.fence.scheduleRevision,selectedDemand:admittedWork.fence.selectedDemand};
        Object.assign(root,marked(root,changed));tx.set(COLLECTIONS.reconcileWork,accountSubject,changed);
      }
      this.writeAuthority(tx, root, { ...authority, observationGeneration, owner: { requestFingerprint, nonce: observationNonce,
        tokenFingerprint, source, phase: 'working', leaseExpiresAt } });
      if (usesReplay) {
        tx.set<RequestReplayRecord>(COLLECTIONS.replays, requestFingerprint, {
          contractVersion: CONTRACT_VERSION,
          keyVersion: ACTIVE_KEY_VERSION,
          ...owner,
          lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration,
          operationKind: kind,
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
        lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration,
        tokenFingerprint,
        // A new lookup must not erase a prior verified-owner claim when custody
        // was interrupted. Unverified attempts have no accountSubject to retain.
        ...(operation?.accountSubject === undefined ? {} : { accountSubject: operation.accountSubject }),
        phase: 'lookup_in_flight',
        outcomeCode: 'in_flight',
        leaseExpiresAt,
        lastGetStartedAt: now,
        acknowledgementStartedAt,
        createdAt: operation?.createdAt ?? now,
        updatedAt: now,
        retentionExpiresAt,
      });
      if (source === 'foreground') tx.set<RateLimitRecord>(COLLECTIONS.rateLimits, accountSubject, {
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
        attempt: { tokenFingerprint, accountSubject, owner, usesReplay, envelope: binding?.tokenEnvelope, ownershipProof: binding?.ownershipProof,
          lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration,
          expectedPlayAccountId: root.obfuscatedAccountId,
          fence: { assertionId: disclosure.assertionId, indexRevision: index?.revision ?? 0, deadline, kind,
            observationGeneration, observationNonce, source, publicationRevision: authority.publicationRevision, work: admittedWork } },
      };
    });
  }

  /** Bounded opaque routing only; notification claims never establish ownership. */
  async resolveEventAccount(token: string, signals: { routes: string[]; predecessorFingerprints: string[] }, deadline: BillingDeadline): Promise<(ResolvedEventAccount & { superseded: boolean; productId?: ProductId }) | undefined> {
    return this.database.runTransaction(async tx => {
      deadline.check();
      if (!fingerprint(token) || signals.routes.length > 2 || signals.predecessorFingerprints.length > 2 ||
          signals.routes.some(route => !validOpaqueRoute(route)) || signals.predecessorFingerprints.some(value => !fingerprint(value))) throw new UnsafeBillingRecordError();
      const roots: LifecycleRoot[] = [];
      let superseded = false;
      let productId: ProductId | undefined;
      for (const id of new Set([token, ...signals.predecessorFingerprints])) {
        const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, id);
        if (binding === undefined) continue;
        if (!validBinding(binding, id)) throw new UnsafeBillingRecordError();
        const root = await this.readLifecycle(tx, binding.accountSubject);
        if (!root || !sameLifecycle(binding, root)) throw new UnsafeBillingRecordError();
        roots.push(root);
        if (id === token) { superseded = binding.bindingState === 'superseded'; productId = binding.productId; }
      }
      for (const route of new Set(signals.routes)) {
        const mapped = await tx.get<LifecycleRoute>(COLLECTIONS.routes, this.identifiers.routeFingerprint(route));
        if (!mapped) throw new UnsafeBillingRecordError();
        const root = await this.readLifecycle(tx, mapped.accountSubject);
        if (!root || root.obfuscatedAccountId !== route || !validReciprocalRoute(mapped, root)) throw new UnsafeBillingRecordError();
        roots.push(root);
      }
      const root = roots[0];
      if (!root) return undefined;
      if (roots.some(other => other.accountSubject !== root.accountSubject || !sameLifecycle(other, root))) throw new UnsafeBillingRecordError();
      deadline.check();
      return { accountSubject: root.accountSubject, lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration, superseded, productId };
    });
  }

  /** Fresh GET signals are checked against the admitted account, never against event data. */
  async proveOwnership(attempt: AttemptHandle, signals: { directRoute?: string; expiredRoute?: string; linkedFingerprint?: string; expiredFingerprint?: string }, now: Date): Promise<OwnershipProof | undefined> {
    return this.guarded(attempt, async tx => {
      if ([signals.directRoute,signals.expiredRoute].some(route => route !== undefined && route !== attempt.expectedPlayAccountId)) return undefined;
      const peers = new Map<string, PurchaseBindingRecord>();
      for (const id of new Set([signals.linkedFingerprint, signals.expiredFingerprint])) {
        if (id === undefined) continue;
        if (!fingerprint(id) || id === attempt.tokenFingerprint) return undefined;
        const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,id);
        if (binding !== undefined) {
          if (!validBinding(binding,id) || binding.accountSubject !== attempt.accountSubject || !sameLifecycle(binding,attempt) ||
              (binding.successorFingerprint !== undefined && binding.successorFingerprint !== attempt.tokenFingerprint)) return undefined;
          peers.set(id,binding);
        }
      }
      const existing = attempt.ownershipProof;
      if (existing && ((signals.linkedFingerprint !== undefined && existing.predecessorFingerprint !== undefined && existing.predecessorFingerprint !== signals.linkedFingerprint) ||
          (signals.expiredFingerprint !== undefined && existing.predecessorFingerprint !== undefined && existing.predecessorFingerprint !== signals.expiredFingerprint))) return undefined;
      const base = {version:OWNERSHIP_PROOF_VERSION as typeof OWNERSHIP_PROOF_VERSION,accountSubject:attempt.accountSubject,tokenFingerprint:attempt.tokenFingerprint,
        lifecycleEpoch:attempt.lifecycleEpoch,lifecycleGeneration:attempt.lifecycleGeneration};
      if (signals.expiredRoute !== undefined || (signals.expiredFingerprint !== undefined && peers.has(signals.expiredFingerprint))) {
        return {...base,kind:'expired_context' as const,...(signals.expiredFingerprint === undefined ? {} : {predecessorFingerprint:signals.expiredFingerprint})};
      }
      if (signals.directRoute !== undefined) return existing ?? {...base,kind:'direct_route' as const};
      if (signals.linkedFingerprint !== undefined && peers.has(signals.linkedFingerprint)) return {...base,kind:'linked_binding' as const,predecessorFingerprint:signals.linkedFingerprint};
      return existing;
    }, undefined, now);
  }

  async competingCurrent(attempt: AttemptHandle, now: Date): Promise<{ tokenFingerprint: string; tokenEnvelope: TokenEnvelope; ownershipProof?: OwnershipProof } | undefined> {
    return this.guarded(attempt, async (tx,index) => {
      if (!index?.current || index.current === attempt.tokenFingerprint) return undefined;
      if (index.candidate !== undefined && index.candidate !== index.current && index.candidate !== attempt.tokenFingerprint) throw new AccountConflictError();
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,index.current);
      if (!binding || !validBinding(binding,index.current) || binding.accountSubject !== attempt.accountSubject || !sameLifecycle(binding,attempt)) throw new UnsafeBillingRecordError();
      return {tokenFingerprint:binding.tokenFingerprint,tokenEnvelope:binding.tokenEnvelope,ownershipProof:binding.ownershipProof};
    }, undefined, now);
  }

  /** Call only immediately after a fresh expiry GET under this exact admitted attempt.
   * The proof is scoped by the closure/attempt owner and index revision, never serialized. */
  async recordAuxiliaryExpiry(attempt: AttemptHandle, current: string, verifiedAt: Date): Promise<boolean> {
    const result = await this.guarded(attempt, async (tx,index) => {
      if (!index || index.current !== current || current === attempt.tokenFingerprint ||
          (index.candidate !== undefined && index.candidate !== current && index.candidate !== attempt.tokenFingerprint)) return false;
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings,current);
      if (!binding || !validBinding(binding,current) || binding.accountSubject !== attempt.accountSubject || !sameLifecycle(binding,attempt)) return false;
      attempt.fence!.deadline.check();
      return true;
    }, false, verifiedAt);
    if (result) this.auxiliaryExpiry.set(attempt,{current,revision:attempt.fence!.indexRevision,generation:attempt.fence!.observationGeneration,verifiedAt,expiresAt:Date.now()+TOKEN_GET_COOLDOWN_MS});
    return result;
  }

  async markVerifiedOwner(
    attempt: AttemptHandle,
    productId: ProductId,
    now: Date,
  ): Promise<boolean> {
    return this.guarded(attempt, async (tx, index) => {
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
    }, false, now);
  }

  async closeAttempt(
    attempt: AttemptHandle,
    now: Date,
    phase: 'free' | 'canceled_pending_read_only' = 'free',
  ): Promise<boolean> {
    return this.guarded(attempt, async (tx, index, authority, root) => {
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
      this.writeAuthority(tx, root, { ...authority, owner: { ...authority.owner!, phase: 'complete', leaseExpiresAt: undefined } });
      return true;
    }, false, now);
  }

  async commitDelivery(attempt: AttemptHandle, input: DeliveryInput, now = input.verifiedAt): Promise<boolean> {
    const result = await this.guarded(attempt, async (tx, index) => {
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
            predecessor.accountSubject !== attempt.accountSubject || !sameLifecycle(predecessor, attempt) ||
            (predecessor.successorFingerprint !== undefined &&
              predecessor.successorFingerprint !== attempt.tokenFingerprint))
        ) {
          return false;
        }
      }
      if (!validEnvelope(input.tokenEnvelope) || (input.ownershipProof !== undefined && !validOwnershipProof(input.ownershipProof, attempt))) return false;
      const previous = index?.candidate ?? index?.current;
      const freshlyExpired = (fingerprint: string): boolean => {
        const proof = this.auxiliaryExpiry.get(attempt);
        if (proof && proof.current === fingerprint && proof.revision === (index?.revision ?? 0) &&
            proof.generation === attempt.fence!.observationGeneration && Date.now() <= proof.expiresAt && now.getTime() >= proof.verifiedAt.getTime() &&
            now.getTime() - proof.verifiedAt.getTime() <= TOKEN_GET_COOLDOWN_MS) return true;
        const observation = index?.inactive;
        // Custody may finish after verification; both proof paths expire at commit time.
        const age = observation ? now.getTime() - observation.verifiedAt.getTime() : -1;
        return observation?.tokenFingerprint === fingerprint && observation.reason === 'expired' &&
          age >= 0 && age <= TOKEN_GET_COOLDOWN_MS;
      };
      if (previous !== undefined && previous !== attempt.tokenFingerprint && previous !== input.predecessorFingerprint &&
          !freshlyExpired(previous)) throw new AccountConflictError();
      let current = index?.current;
      if (current !== undefined && current !== attempt.tokenFingerprint && current !== input.predecessorFingerprint) {
        // An unrelated replacement cannot leave an apparently linked pair.
        // Remove only the freshly expired current pointer in the same atomic
        // delivery commit; retained custody remains available for audit/deletion.
        if (!freshlyExpired(current)) throw new AccountConflictError();
        current = undefined;
      }
      const binding: PurchaseBindingRecord = {
        lifecycleEpoch: attempt.lifecycleEpoch, lifecycleGeneration: attempt.lifecycleGeneration,
        contractVersion: CONTRACT_VERSION,
        keyVersion: ACTIVE_KEY_VERSION,
        tokenEnvelope: input.tokenEnvelope,
        ownershipProof: input.ownershipProof ?? existing?.ownershipProof,
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

      };
      tx.set<AccountIndex>(COLLECTIONS.accounts, attempt.accountSubject, {
        lifecycleEpoch: attempt.lifecycleEpoch, lifecycleGeneration: attempt.lifecycleGeneration,
        contractVersion: CONTRACT_VERSION, keyVersion: ACTIVE_KEY_VERSION, accountSubject: attempt.accountSubject,
        revision: (index?.revision ?? 0) + 1, current,
        candidate: attempt.tokenFingerprint, updatedAt: input.verifiedAt,
      });
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
    }, false, now, 'delivery');
    if (result) { attempt.fence!.indexRevision++; this.auxiliaryExpiry.delete(attempt); }
    return result;
  }

  async beginAcknowledgement(attempt: AttemptHandle, now: Date): Promise<boolean> {
    return this.guarded(attempt, async (tx, index, authority, root) => {
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
      this.writeAuthority(tx, root, { ...authority, acknowledgementRecoveryToken: attempt.tokenFingerprint,
        owner: { ...authority.owner!, phase: 'ack_in_progress' } });
      return true;
    }, false, now, 'ack');
  }

  async finalizePaid(
    attempt: AttemptHandle,
    now: Date,
    sourcePhase: 'delivery_committed' | 'ack_in_progress',
  ): Promise<PaidCommit | undefined> {
    const result = await this.guarded(attempt, async (tx, index, authority, root) => {
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
            predecessor.accountSubject !== attempt.accountSubject || !sameLifecycle(predecessor, attempt) ||
            (predecessor.successorFingerprint !== undefined &&
              predecessor.successorFingerprint !== attempt.tokenFingerprint))
        ) {
          return undefined;
        }
      }
      if (index?.candidate !== attempt.tokenFingerprint) return undefined;
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
      tx.set<AccountIndex>(COLLECTIONS.accounts, attempt.accountSubject, {
        ...index, current: attempt.tokenFingerprint, candidate: undefined,
        revision: index.revision + 1, inactive: undefined, updatedAt: now,
      });
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
      this.publishAuthority(tx, root, { ...authority, owner: { ...authority.owner!, phase: 'complete', leaseExpiresAt: undefined } },
        { state: finalized.normalizedState, planId: finalized.planId, productId: finalized.productId,
          tokenFingerprint: attempt.tokenFingerprint, verifiedAt: finalized.lastVerifiedAt, playExpiresAt: finalized.playExpiresAt }, true);
      return {
        planId: finalized.planId,
        productId: finalized.productId,
        normalizedState: finalized.normalizedState,
        playExpiresAt: finalized.playExpiresAt,
        verifiedAt: finalized.lastVerifiedAt,
      };
    }, undefined, now, 'paid');
    if (result) { attempt.fence!.indexRevision++; attempt.fence!.publicationRevision++; }
    return result;
  }

  async markAcknowledgementUnknown(attempt: AttemptHandle, now: Date): Promise<boolean> {
    return this.guarded(attempt, async (tx, index, authority, root) => {
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
      this.writeAuthority(tx, root, { ...authority, acknowledgementRecoveryToken: attempt.tokenFingerprint,
        owner: { ...authority.owner!, phase: 'ack_unknown', leaseExpiresAt: undefined } });
      return true;
    }, false, now, 'ack');
  }
  async isCurrentAttempt(attempt: AttemptHandle, now: Date, phase: 'lookup_in_flight' | 'verified_owner' | 'ack_in_progress' = 'lookup_in_flight'): Promise<boolean> {
    return this.guarded(attempt, async (tx) => {
      const operation = await tx.get<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint);
      return ownedOperation(operation, attempt, phase) && operation.leaseExpiresAt !== undefined && operation.leaseExpiresAt > now;
    }, false, now);
  }

  async isCurrentGrant(attempt: AttemptHandle, now: Date): Promise<boolean> {
    if(attempt.completedObservation)return this.validateCompleted(attempt,now,'paid');
    return this.guarded(attempt, async (tx, index, authority) => {
      const binding = await tx.get<PurchaseBindingRecord>(COLLECTIONS.bindings, attempt.tokenFingerprint);
      const operation = await tx.get<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint);
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint) : undefined;
      return authority.publicationRevision === attempt.fence!.publicationRevision &&
        authority.snapshot.observationGeneration === attempt.fence!.observationGeneration && authority.snapshot.state !== 'none' &&
        index?.current === attempt.tokenFingerprint && index.inactive?.tokenFingerprint !== attempt.tokenFingerprint &&
        ownedOperation(operation, attempt, 'paid') &&
        (!attempt.usesReplay || ownedReplayAny(replay, attempt, ['paid'])) && ownedBinding(binding, attempt, 'paid') &&
        binding.bindingState === 'acknowledged_delivery' && binding.ackState === 'acknowledged' && binding.playExpiresAt > now;
    }, false, now);
  }

  async isCurrentResponse(attempt: AttemptHandle, now: Date): Promise<boolean> {
    if(attempt.completedObservation)return this.validateCompleted(attempt,now,'inactive');
    return this.guarded(attempt, async (_tx, _index, authority) =>
      authority.owner?.phase === 'complete' && authority.publicationRevision === attempt.fence!.publicationRevision,
    false, now);
  }

  private async guarded<T>(attempt: AttemptHandle, action: (tx: BillingTransaction, index: AccountIndex | undefined, authority: AccountAuthority, root: LifecycleRoot) => Promise<T>, fallback: T, now: Date,
    transition?: 'delivery'|'ack'|'paid'|'inactive', inactiveReason?: string): Promise<T> {
    const committed = await this.database.runTransaction(async (tx) => {
      const rejected = {result:fallback,next:undefined as ReconcileFence|undefined,completed:undefined as CompletedObservation|undefined};
      const fence = attempt.fence;
      if (!fence || attempt.completedObservation) return rejected;
      fence.deadline.check();
      const disclosure = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, attempt.accountSubject);
      const root = await this.readLifecycle(tx, attempt.accountSubject);
      const index = await tx.get<AccountIndex>(COLLECTIONS.accounts, attempt.accountSubject);
      if (!root || root.status !== 'active' || !sameLifecycle(root, attempt) ||
          root.obfuscatedAccountId !== attempt.expectedPlayAccountId || root.assertionId !== fence.assertionId ||
          (index !== undefined && !sameLifecycle(index, attempt))) return rejected;
      if (!disclosure || !validDisclosure(disclosure, attempt.accountSubject) || disclosure.status !== 'accepted' || disclosure.retentionExpiresAt <= now ||
          disclosure.assertionId !== fence.assertionId || (index !== undefined && !validIndex(index, attempt.accountSubject)) ||
          (index?.revision ?? 0) !== fence.indexRevision) return rejected;
      const authority = await this.readAuthority(tx, root);
      if (!this.currentObservation(authority, attempt) ||
          (authority!.owner!.leaseExpiresAt !== undefined && authority!.owner!.leaseExpiresAt! <= now)) return rejected;
      if (fence.source === 'background' && (!fence.work || !await this.validInternalWork(tx, fence.work, root, now))) return rejected;
      const old = await this.readWork(tx,root);
      if(index && index.revision >= Number.MAX_SAFE_INTEGER)return rejected;
      // Buffer writes so all semantic preimages are read before any Firestore write.
      const writes = new Map<string,{collection:BillingCollection;id:string;value:unknown}>();
      const buffered:BillingTransaction={...tx,set:(collection,id,value)=>{writes.set(collection+'/'+id,{collection,id,value});}};
      const result = await action(buffered, index, authority!, root);
      let next: ReconcileFence | undefined; let completed: CompletedObservation | undefined;
      if (transition && result !== false && result !== undefined) {
        const finalIndex = (writes.get(COLLECTIONS.accounts+'/'+attempt.accountSubject)?.value as AccountIndex|undefined) ?? index;
        const finalRoot = (writes.get(COLLECTIONS.lifecycles+'/'+attempt.accountSubject)?.value as LifecycleRoot|undefined) ?? root;
        const finalAuthority = (writes.get(COLLECTIONS.authorities+'/'+attempt.accountSubject)?.value as AccountAuthority|undefined) ?? authority!;
        const own = fence.work?.kind==='reconciliation' ? fence.work.fence : undefined;
        const terminal = own && (transition==='paid'||transition==='inactive');
        const binding = writes.get(COLLECTIONS.bindings+'/'+attempt.tokenFingerprint)?.value as PurchaseBindingRecord|undefined;
        const w = reschedule(old,finalRoot,finalIndex,now,this.reconciliationPolicy,{own,
          terminal:(transition==='paid'||transition==='inactive')?{token:attempt.tokenFingerprint,paid:transition==='paid',expiresAt:binding?.playExpiresAt}:undefined,
          publicationRevision:finalAuthority.publicationRevision,ack:finalAuthority.acknowledgementRecoveryToken,previousIndex:index});
        if (terminal) {
          completed={...own,scheduleRevision:w.scheduleRevision,ownerGeneration:w.ownerGeneration,
            requestFingerprint:attempt.owner.requestFingerprint,observationGeneration:fence.observationGeneration,observationNonce:fence.observationNonce,
            publicationRevision:finalAuthority.publicationRevision,indexRevision:finalIndex?.revision??0,outcome:transition==='paid'?'paid':'inactive',
            ...(transition==='inactive'?{reason:inactiveReason}: {})};
          w.completedObservation=completed;
        } else if (own) next=fenceFor(w);
        const merged=marked(finalRoot,w);
        if(!validWork(w,merged))throw new UnsafeBillingRecordError();
        buffered.set(COLLECTIONS.reconcileWork,attempt.accountSubject,w);
        buffered.set(COLLECTIONS.lifecycles,attempt.accountSubject,merged);
      }
      fence.deadline.check();
      for(const write of writes.values())tx.set(write.collection,write.id,write.value);
      return {result,next,completed};
    });
    // Firestore may retry the closure. Only its committed result may advance handles.
    if (committed.next && attempt.fence?.work?.kind==='reconciliation') attempt.fence.work.fence=committed.next;
    if (committed.completed) attempt.completedObservation=committed.completed;
    return committed.result;
  }

  async recordInactive(attempt: AttemptHandle, reason: Exclude<InactiveReason, 'requires_verification' | 'retired'>, now: Date,
    acknowledgementConfirmed = false): Promise<boolean> {
    const terminal = attempt.fence?.work?.kind === 'reconciliation';
    const committed = await this.guarded(attempt, async (tx, index, authority, root) => {
      const operation = await tx.get<TokenOperationRecord>(COLLECTIONS.operations, attempt.tokenFingerprint);
      const replay = attempt.usesReplay
        ? await tx.get<RequestReplayRecord>(COLLECTIONS.replays, attempt.owner.requestFingerprint) : undefined;
      if (!ownedOperation(operation, attempt, 'lookup_in_flight') ||
          (attempt.usesReplay && !ownedReplayAny(replay, attempt, ['lookup_in_flight']))) return false;
      const indexed = index !== undefined && (index.current === attempt.tokenFingerprint || index.candidate === attempt.tokenFingerprint);
      if (indexed) tx.set<AccountIndex>(COLLECTIONS.accounts, attempt.accountSubject, {
        ...index, revision: index.revision + 1,
        inactive: { tokenFingerprint: attempt.tokenFingerprint, reason, verifiedAt: now }, updatedAt: now,
      });
      const publicationChanged = index === undefined || index.current === attempt.tokenFingerprint ||
        (index.current === undefined && index.candidate === attempt.tokenFingerprint);
      const finalAuthority = terminal ? {...authority,owner:{...authority.owner!,phase:'complete' as const,leaseExpiresAt:undefined}} : authority;
      if (publicationChanged) this.publishAuthority(tx, root, finalAuthority,
        { state: 'none', reason, tokenFingerprint: attempt.tokenFingerprint, verifiedAt: now },
        acknowledgementConfirmed || reason === 'expired' || reason === 'revoked');
      else if (acknowledgementConfirmed || reason === 'expired' || reason === 'revoked') {
        this.writeAuthority(tx, root, { ...finalAuthority, acknowledgementRecoveryToken: undefined });
      } else if (terminal) this.writeAuthority(tx,root,finalAuthority);
      if (terminal) {
        tx.set(COLLECTIONS.operations,attempt.tokenFingerprint,{...operation,phase:'free',outcomeCode:'free',leaseExpiresAt:undefined,updatedAt:now});
        if(replay) tx.set(COLLECTIONS.replays,attempt.owner.requestFingerprint,{...replay,phase:'free',outcomeCode:'free',leaseExpiresAt:undefined,updatedAt:now});
      }
      return { indexed, publicationChanged };
    }, false as false | { indexed: boolean; publicationChanged: boolean }, now, 'inactive', reason);
    if (committed) {
      if (committed.indexed) attempt.fence!.indexRevision++;
      if (committed.publicationChanged) attempt.fence!.publicationRevision++;
    }
    return committed !== false;
  }

}

export class MigrationRequiredError extends Error {}
export class UnsafeBillingRecordError extends Error {}
export class AccountConflictError extends Error {}

function addMs(date: Date, milliseconds: number): Date {
  return new Date(date.getTime() + milliseconds);
}

function validBase(record: Partial<BaseRecord>, withoutTtl = false): boolean {
  return (
    record.contractVersion === CONTRACT_VERSION &&
    record.keyVersion === ACTIVE_KEY_VERSION &&
    record.createdAt instanceof Date &&
    record.updatedAt instanceof Date &&
    (withoutTtl ? record.retentionExpiresAt === undefined : record.retentionExpiresAt instanceof Date)
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

export function validDisclosure(record: DisclosureRecord, accountSubject: string, allowPrevious = false): boolean {
  return (
    hasOnlyKeys(record, [
      'contractVersion',
      'keyVersion',
      'assertionId',
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
    (validBase(record) || (allowPrevious && ['play-billing-v1','play-billing-v2'].includes(record.contractVersion as string) && record.keyVersion === ACTIVE_KEY_VERSION && record.createdAt instanceof Date && record.updatedAt instanceof Date && record.retentionExpiresAt instanceof Date)) &&
    ((allowPrevious && record.contractVersion as string === 'play-billing-v1') || /^[a-f0-9]{32}$/.test(record.assertionId)) &&
    record.assertionVersion === DISCLOSURE_ASSERTION_VERSION &&
    record.accountSubject === accountSubject &&
    (record.disclosureVersion === DISCLOSURE_VERSION ||
      (allowPrevious && ['billing-verification-disclosure-v1', 'billing-verification-disclosure-v2', 'billing-verification-disclosure-v3'].includes(record.disclosureVersion))) &&
    record.purpose === DISCLOSURE_PURPOSE &&
    record.acceptedAt instanceof Date &&
    record.statusChangedAt instanceof Date &&
    (record.status === 'accepted' || record.status === 'revoked')
  );
}

function validReplay(record: RequestReplayRecord, requestFingerprint: string): boolean {
  return (
    hasOnlyKeys(record, [
      'lifecycleEpoch',
      'lifecycleGeneration',
      'contractVersion',
      'keyVersion',
      'requestFingerprint',
      'attemptGeneration',
      'attemptNonce',
      'operationKind',
      'tokenFingerprint',
      'phase',
      'outcomeCode',
      'leaseExpiresAt',
      'cooldownUntil',
      'createdAt',
      'updatedAt',
      'retentionExpiresAt',
    ]) &&
    (record.operationKind === 'verify' || record.operationKind === 'restore') &&
    validBase(record) &&
    validLifecycleFields(record) &&
    validOwner(record) &&
    record.requestFingerprint === requestFingerprint &&
    isFingerprint(record.tokenFingerprint) &&
    isReplayPhase(record.phase) &&
    validPhaseOutcome(record.phase, record.outcomeCode) &&
    validLeaseAndCooldown(record.phase, record.leaseExpiresAt, record.cooldownUntil)
  );
}

// An unverified global token attempt is a rate/lease record, not account ownership.
// Only this narrow pre-ownership state may be reclaimed by another lifecycle;
// the existing lease, cooldown, nonce/generation and replay checks still apply.
function unverifiedUnboundOperation(
  operation: TokenOperationRecord,
  binding: PurchaseBindingRecord | undefined,
): boolean {
  return binding === undefined && operation.accountSubject === undefined &&
    operation.acknowledgementStartedAt.length === 0 &&
    (operation.phase === 'lookup_in_flight' || operation.phase === 'free' ||
      operation.phase === 'canceled_pending_read_only');
}

function validOperation(record: TokenOperationRecord, tokenFingerprint: string): boolean {
  return (
    hasOnlyKeys(record, [
      'lifecycleEpoch',
      'lifecycleGeneration',
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
    validLifecycleFields(record) &&
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
      'lifecycleEpoch',
      'lifecycleGeneration',
      'contractVersion',
      'keyVersion',
      'tokenEnvelope',
      'ownershipProof',
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
    validLifecycleFields(record) && validBase(record, true) && validEnvelope(record.tokenEnvelope) &&
    (record.ownershipProof === undefined || validOwnershipProof(record.ownershipProof, record)) &&
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

function sameOwner(record: AttemptOwner, attempt: Pick<AttemptHandle, 'owner'>): boolean {
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
    sameLifecycle(record, attempt) && sameOwner(record, attempt) &&
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
    sameLifecycle(record, attempt) && sameOwner(record, attempt) &&
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
    sameLifecycle(record, attempt) && sameOwner(record, attempt) &&
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
    sameLifecycle(record, attempt) && record.attemptRequestFingerprint === attempt.owner.requestFingerprint &&
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
    !sameLifecycle(replay, operation) || !sameOwner(replay, { owner: operation })
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
  return typeof value === 'string' && Object.hasOwn(PRODUCT_ALLOWLIST, value);
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

function isLegacy(value: unknown): boolean {
  return value !== null && typeof value === 'object' && 'contractVersion' in value && ['play-billing-v1','play-billing-v2'].includes(value.contractVersion as string);
}
function validIndex(record: AccountIndex, subject: string): boolean {
  return hasOnlyKeys(record, ['lifecycleEpoch','lifecycleGeneration','contractVersion','keyVersion','accountSubject','revision','current','candidate','inactive','updatedAt']) &&
    validLifecycleFields(record) && record.contractVersion === CONTRACT_VERSION && record.keyVersion === ACTIVE_KEY_VERSION && record.accountSubject === subject &&
    Number.isSafeInteger(record.revision) && record.revision > 0 && record.updatedAt instanceof Date &&
    (record.current !== undefined || record.candidate !== undefined) &&
    (record.current === undefined || isFingerprint(record.current)) &&
    (record.candidate === undefined || isFingerprint(record.candidate)) &&
    (record.inactive === undefined || (hasOnlyKeys(record.inactive, ['tokenFingerprint','verifiedAt','reason']) &&
      isFingerprint(record.inactive.tokenFingerprint) && record.inactive.verifiedAt instanceof Date &&
      ['expired','on_hold','paused','revoked','pending'].includes(record.inactive.reason)));
}

/** At most the two index-selected records; no unbounded lineage traversal. */
function validIndexedChain(index: AccountIndex | undefined, bindings: ReadonlyMap<string, PurchaseBindingRecord>): boolean {
  if (index === undefined) return true;
  const current = index.current === undefined ? undefined : bindings.get(index.current);
  const candidate = index.candidate === undefined ? undefined : bindings.get(index.candidate);
  if (current?.bindingState === 'superseded' || current?.successorFingerprint !== undefined ||
      candidate?.bindingState === 'superseded' || candidate?.successorFingerprint !== undefined) return false;
  if (candidate !== undefined && !['delivery_committed', 'ack_in_progress'].includes(candidate.attemptPhase)) return false;
  if (current !== undefined && index.current !== index.candidate &&
      (current.attemptPhase !== 'paid' || current.bindingState !== 'acknowledged_delivery')) return false;
  if (current !== undefined && candidate !== undefined && index.current !== index.candidate) {
    return candidate.stagedPredecessorFingerprint === index.current &&
      (candidate.predecessorFingerprint === undefined || candidate.predecessorFingerprint === index.current);
  }
  return true;
}
