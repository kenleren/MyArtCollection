import { createHmac } from 'node:crypto';

import type { BrokerAdapterIdentity } from './adapter.js';
import {
  CREDIT_LEDGER_RECORD_VERSION,
  applyFinalize,
  applyRefund,
  ledgerMatchesRequest,
  parseLedgerRecord,
  type LedgerRecord,
} from './credit_ledger.js';
import {
  REQUEST_LIFECYCLE_RECORD_VERSION,
  parseStoredRequest,
  storedRequestMatchesKey,
  type StoredRequestRecord,
} from './idempotency.js';
import {
  InMemoryRequestLifecycle,
  RESERVATION_LEASE_MILLISECONDS,
  RETENTION_MILLISECONDS,
  type AcquireRequestInput,
  type AcquireRequestResult,
  type DispatchStartResult,
  type RequestLifecycleStore,
  type SettlementIntent,
} from './request_lifecycle.js';
import type { BrokerTerminalOutcome } from './contracts.js';

export const BROKER_FIREBASE_PROJECT_ID_ENV = 'BROKER_FIREBASE_PROJECT_ID';
export const BROKER_FIREBASE_PROJECT_NUMBER_ENV = 'BROKER_FIREBASE_PROJECT_NUMBER';
export const BROKER_APP_ID_ALLOWLIST_ENV = 'BROKER_APP_ID_ALLOWLIST';
export const BROKER_QUOTA_HMAC_SECRET_ENV = 'BROKER_QUOTA_HMAC_SECRET';
export const BROKER_DURABLE_STORE_CONFIGURED_ENV = 'BROKER_DURABLE_STORE_CONFIGURED';
export const MISSING_DURABLE_CONFIG_CODE = 'missing_durable_broker_config';
export const MISSING_QUOTA_SECRET_CODE = 'missing_quota_hmac_secret';
export const CONTROL_RECORD_VERSION = 'broker-control-v1';
export const ENTITLEMENT_RECORD_VERSION = 'broker-entitlement-v1';
export const SUBJECT_CREDIT_RECORD_VERSION = 'broker-credit-subject-v1';
export const GLOBAL_CREDIT_RECORD_VERSION = 'broker-credit-global-v1';

export interface DurableProtectionConfig {
  projectId: string;
  projectNumber: string;
  allowedAppIds: ReadonlySet<string>;
  quotaHmacSecret: string;
}

export interface VerifyBrokerTokensInput {
  authorizationHeader?: string;
  appCheckToken?: string;
}

export type VerifyBrokerTokensErrorCode =
  | 'missing_auth_token'
  | 'invalid_auth_token'
  | 'wrong_project_auth'
  | 'missing_app_check_token'
  | 'invalid_app_check_token'
  | 'wrong_project_app_check'
  | 'app_check_replayed'
  | 'identity_project_mismatch'
  | 'unsupported_auth_provider'
  | 'unapproved_app';

export type VerifyBrokerTokensResult =
  | { ok: true; auth: VerifiedAuthIdentity; app: VerifiedAppIdentity }
  | { ok: false; code: VerifyBrokerTokensErrorCode };

export interface VerifiedAuthIdentity {
  uid: string;
  projectId: string;
  signInProvider: string;
}

export interface VerifiedAppIdentity {
  appId: string;
  projectId: string;
}

export interface BrokerTokenVerifier {
  verify(input: VerifyBrokerTokensInput): Promise<VerifyBrokerTokensResult>;
}

export interface DurableAccessInput {
  uid: string;
  appId: string;
  quotaSubject: string;
}

export interface DurableAccessResult {
  entitled: boolean;
  breakerOpen: boolean;
}

export interface DurableGateStore {
  readAccess(input: DurableAccessInput): Promise<DurableAccessResult>;
}

export interface DurableBrokerProtection {
  verifyIdentity(input: VerifyBrokerTokensInput): Promise<DurableBrokerIdentityResult>;
  readAccess(identity: VerifiedBrokerIdentity): Promise<DurableAccessResult>;
  createRequestLifecycle(): RequestLifecycleStore;
}

export type VerifiedBrokerIdentity = Omit<BrokerAdapterIdentity, 'entitled' | 'breakerOpen'>;

export type DurableBrokerIdentityResult =
  | { ok: true; identity: VerifiedBrokerIdentity }
  | {
      ok: false;
      code: VerifyBrokerTokensErrorCode | typeof MISSING_DURABLE_CONFIG_CODE | typeof MISSING_QUOTA_SECRET_CODE;
    };

export interface FirebaseAdminAuthLike {
  verifyIdToken(
    token: string,
    checkRevoked: boolean,
  ): Promise<{
    uid?: string;
    aud?: string;
    iss?: string;
    firebase?: { sign_in_provider?: string };
  }>;
}

export interface FirebaseAdminAppCheckLike {
  verifyToken(
    token: string,
    options: { consume: boolean },
  ): Promise<{
    appId: string;
    token: {
      aud?: string | string[];
      iss?: string;
      sub?: string;
      app_id?: string;
    };
    alreadyConsumed?: boolean;
  }>;
}

export interface FirebaseAdminVerifierOptions {
  auth: FirebaseAdminAuthLike;
  appCheck: FirebaseAdminAppCheckLike;
  config: Omit<DurableProtectionConfig, 'quotaHmacSecret'>;
}

export class FirebaseAdminBrokerTokenVerifier implements BrokerTokenVerifier {
  constructor(private readonly options: FirebaseAdminVerifierOptions) {}

  async verify(input: VerifyBrokerTokensInput): Promise<VerifyBrokerTokensResult> {
    const authToken = bearerToken(input.authorizationHeader);
    if (authToken === undefined) {
      return { ok: false, code: 'missing_auth_token' };
    }

    let authBody: Awaited<ReturnType<FirebaseAdminAuthLike['verifyIdToken']>>;
    try {
      authBody = await this.options.auth.verifyIdToken(authToken, true);
    } catch {
      return { ok: false, code: 'invalid_auth_token' };
    }
    const authProjectId = projectIdFromAuthToken(authBody);
    if (
      authProjectId === undefined ||
      authProjectId !== this.options.config.projectId ||
      !nonEmptyString(authBody.uid)
    ) {
      return { ok: false, code: 'wrong_project_auth' };
    }
    const signInProvider = authBody.firebase?.sign_in_provider;
    if (signInProvider !== 'anonymous') {
      return { ok: false, code: 'unsupported_auth_provider' };
    }

    if (!nonEmptyString(input.appCheckToken)) {
      return { ok: false, code: 'missing_app_check_token' };
    }
    let appBody: Awaited<ReturnType<FirebaseAdminAppCheckLike['verifyToken']>>;
    try {
      appBody = await this.options.appCheck.verifyToken(input.appCheckToken, { consume: true });
    } catch {
      return { ok: false, code: 'invalid_app_check_token' };
    }
    if (appBody.alreadyConsumed === true) {
      return { ok: false, code: 'app_check_replayed' };
    }
    if (!appCheckTokenMatchesProject(
      appBody.token,
      this.options.config.projectId,
      this.options.config.projectNumber,
    )) {
      return { ok: false, code: 'wrong_project_app_check' };
    }
    const appId = appBody.appId;
    if (
      !nonEmptyString(appId) ||
      !nonEmptyString(appBody.token.sub) ||
      appBody.token.sub !== appId ||
      (appBody.token.app_id !== undefined && appBody.token.app_id !== appId)
    ) {
      return { ok: false, code: 'invalid_app_check_token' };
    }
    if (!this.options.config.allowedAppIds.has(appId)) {
      return { ok: false, code: 'unapproved_app' };
    }

    return {
      ok: true,
      auth: { uid: authBody.uid, projectId: authProjectId, signInProvider },
      app: { appId, projectId: this.options.config.projectId },
    };
  }
}

export class ConfiguredDurableBrokerProtection implements DurableBrokerProtection {
  constructor(
    private readonly verifier: BrokerTokenVerifier,
    private readonly gateStore: DurableGateStore,
    private readonly requestLifecycle: RequestLifecycleStore,
    private readonly config: DurableProtectionConfig,
  ) {}

  async verifyIdentity(input: VerifyBrokerTokensInput): Promise<DurableBrokerIdentityResult> {
    if (this.config.quotaHmacSecret.trim().length === 0) {
      return { ok: false, code: MISSING_QUOTA_SECRET_CODE };
    }
    const verified = await this.verifier.verify(input);
    if (!verified.ok) {
      return verified;
    }
    if (verified.auth.projectId !== verified.app.projectId) {
      return { ok: false, code: 'identity_project_mismatch' };
    }

    const quotaSubject = deriveQuotaSubject({
      uid: verified.auth.uid,
      appId: verified.app.appId,
      projectId: verified.auth.projectId,
      secret: this.config.quotaHmacSecret,
    });
    return {
      ok: true,
      identity: {
        auth: {
          appCheckVerified: true,
          authVerified: true,
          uid: verified.auth.uid,
          authProjectId: verified.auth.projectId,
          signInProvider: 'anonymous',
        },
        app: { appId: verified.app.appId, appProjectId: verified.app.projectId },
        quotaSubject,
      },
    };
  }

  async readAccess(identity: VerifiedBrokerIdentity): Promise<DurableAccessResult> {
    return this.gateStore.readAccess({
      uid: identity.auth.uid ?? '',
      appId: identity.app.appId ?? '',
      quotaSubject: identity.quotaSubject ?? '',
    });
  }

  createRequestLifecycle(): RequestLifecycleStore {
    return this.requestLifecycle;
  }
}

export interface DurableFirestoreDocumentSnapshot {
  readonly exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface DurableFirestoreDocumentRef {
  readonly path: string;
  get(): Promise<DurableFirestoreDocumentSnapshot>;
  set(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<unknown>;
  update(data: Record<string, unknown>): Promise<unknown>;
  delete(): Promise<unknown>;
}

export interface DurableFirestoreTransaction {
  get(ref: DurableFirestoreDocumentRef): Promise<DurableFirestoreDocumentSnapshot>;
  set(
    ref: DurableFirestoreDocumentRef,
    data: Record<string, unknown>,
    options?: { merge?: boolean },
  ): DurableFirestoreTransaction;
  update(ref: DurableFirestoreDocumentRef, data: Record<string, unknown>): DurableFirestoreTransaction;
  delete(ref: DurableFirestoreDocumentRef): DurableFirestoreTransaction;
}

export interface DurableFirestoreLike {
  doc(path: string): DurableFirestoreDocumentRef;
  runTransaction<T>(
    updateFunction: (transaction: DurableFirestoreTransaction) => Promise<T>,
  ): Promise<T>;
}

export interface FirestoreDurableBrokerStoreOptions {
  collectionPrefix?: string;
}

export class FirestoreDurableBrokerStore implements DurableGateStore {
  readonly collectionPrefix: string;

  constructor(
    readonly firestore: DurableFirestoreLike,
    options: FirestoreDurableBrokerStoreOptions = {},
  ) {
    this.collectionPrefix = options.collectionPrefix ?? 'brokerDurable';
  }

  async readAccess(input: DurableAccessInput): Promise<DurableAccessResult> {
    const [control, entitlement] = await Promise.all([
      this.controlRef().get(),
      this.entitlementRef(input.uid).get(),
    ]);
    const controlData = controlRecordFromSnapshot(control);
    const entitlementData = entitlement.exists
      ? entitlementRecordFromSnapshot(entitlement)
      : { entitled: false };
    if (controlData === undefined) {
      throw new Error('unsafe_control_record');
    }
    if (entitlementData === undefined) {
      throw new Error('unsafe_entitlement_record');
    }
    return {
      entitled: entitlementData.entitled,
      breakerOpen: controlData.breakerOpen,
    };
  }

  createRequestLifecycle(): RequestLifecycleStore {
    return new FirestoreRequestLifecycle(this);
  }

  requestRef(quotaSubject: string, requestId: string): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}Idempotency/${docKey(`${quotaSubject}|${requestId}`)}`);
  }

  ledgerRef(quotaSubject: string, requestId: string): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}Ledger/${docKey(`${quotaSubject}|${requestId}`)}`);
  }

  subjectRef(quotaSubject: string): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}QuotaSubjects/${docKey(quotaSubject)}`);
  }

  globalUsageRef(): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}Control/globalUsage`);
  }

  controlRef(): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}Control/live`);
  }

  entitlementRef(uid: string): DurableFirestoreDocumentRef {
    return this.firestore.doc(`${this.collectionPrefix}Entitlements/${docKey(uid)}`);
  }

  transaction<T>(callback: (transaction: DurableFirestoreTransaction) => Promise<T>): Promise<T> {
    return this.firestore.runTransaction(callback);
  }
}

export class FirestoreRequestLifecycle implements RequestLifecycleStore {
  constructor(private readonly store: FirestoreDurableBrokerStore) {}

  async acquire(input: AcquireRequestInput): Promise<AcquireRequestResult> {
    return this.store.transaction(async (transaction) => {
      const requestRef = this.store.requestRef(input.quota_subject, input.request_id);
      const ledgerRef = this.store.ledgerRef(input.quota_subject, input.request_id);
      const [requestSnapshot, ledgerSnapshot] = await Promise.all([
        transaction.get(requestRef),
        transaction.get(ledgerRef),
      ]);
      const parsed = parseStoredRequest(requestSnapshot.exists ? requestSnapshot.data() : undefined);
      const existingLedger = ledgerRecordFromSnapshot(ledgerSnapshot);
      if (parsed.kind === 'unsafe') {
        return { kind: 'unsafe_record' };
      }
      if (parsed.kind === 'valid') {
        const existing = parsed.record;
        if (
          !storedRequestMatchesKey(existing, input.quota_subject, input.request_id) ||
          existingLedger === undefined ||
          !ledgerMatchesRequest(existingLedger, existing)
        ) {
          return { kind: 'unsafe_record' };
        }
        if (existing.payload_hash !== input.payload_hash) {
          return { kind: 'conflict' };
        }
        if (existing.state === 'terminal') {
          return { kind: 'replay', record: existing, outcome: existing.terminal_outcome! };
        }
        if (existing.state === 'dispatch_started') {
          return input.now.getTime() < Date.parse(existing.reservation_lease_expires_at)
            ? { kind: 'in_flight' }
            : { kind: 'outcome_unknown' };
        }
        if (input.now.getTime() < Date.parse(existing.reservation_lease_expires_at)) {
          return { kind: 'in_flight' };
        }

        const outcome = reservationExpiredOutcome(existing.request_id);
        const terminal = {
          ...existing,
          state: 'terminal' as const,
          settlement_state: 'pending_refund' as const,
          terminal_outcome: outcome,
        };
        transaction.set(requestRef, terminal);
        return { kind: 'replay', record: terminal, outcome };
      }

      if (ledgerSnapshot.exists) {
        return { kind: 'unsafe_record' };
      }

      const controlRef = this.store.controlRef();
      const subjectRef = this.store.subjectRef(input.quota_subject);
      const globalRef = this.store.globalUsageRef();
      const [controlSnapshot, subjectSnapshot, globalSnapshot] = await Promise.all([
        transaction.get(controlRef),
        transaction.get(subjectRef),
        transaction.get(globalRef),
      ]);
      const control = controlRecordFromSnapshot(controlSnapshot);
      const subject = subjectSnapshot.exists
        ? subjectCreditFromSnapshot(subjectSnapshot)
        : { exposed_credits: 0, reserved_count: 0 };
      const global = globalSnapshot.exists
        ? globalCreditFromSnapshot(globalSnapshot)
        : { exposed_credits: 0 };
      if (control === undefined || subject === undefined || global === undefined) {
        return { kind: 'unsafe_record' };
      }
      if (
        subject.reserved_count > subject.exposed_credits ||
        global.exposed_credits < subject.exposed_credits ||
        (subjectSnapshot.exists && !globalSnapshot.exists)
      ) {
        return { kind: 'unsafe_record' };
      }
      if (control.oneInFlightPerSubject && subject.reserved_count > 0) {
        return { kind: 'in_flight' };
      }
      if (
        subject.exposed_credits + input.credit_cost > control.perSubjectCreditCap ||
        global.exposed_credits + input.credit_cost > control.brokerCreditCap
      ) {
        return { kind: 'credits_exhausted' };
      }

      const record: StoredRequestRecord = {
        record_version: REQUEST_LIFECYCLE_RECORD_VERSION,
        quota_subject: input.quota_subject,
        request_id: input.request_id,
        payload_hash: input.payload_hash,
        state: 'reserved',
        credit_cost: 1,
        reservation_lease_expires_at: new Date(
          input.now.getTime() + RESERVATION_LEASE_MILLISECONDS,
        ).toISOString(),
        retention_expires_at: new Date(input.now.getTime() + RETENTION_MILLISECONDS).toISOString(),
        settlement_state: 'reserved',
      };
      const ledger: LedgerRecord = {
        record_version: CREDIT_LEDGER_RECORD_VERSION,
        quota_subject: input.quota_subject,
        request_id: input.request_id,
        state: 'reserved',
        credit_cost: 1,
      };
      transaction.set(requestRef, { ...record });
      transaction.set(ledgerRef, { ...ledger });
      transaction.set(subjectRef, {
        record_version: SUBJECT_CREDIT_RECORD_VERSION,
        exposed_credits: subject.exposed_credits + 1,
        reserved_count: subject.reserved_count + 1,
      }, { merge: true });
      transaction.set(globalRef, {
        record_version: GLOBAL_CREDIT_RECORD_VERSION,
        exposed_credits: global.exposed_credits + 1,
      }, { merge: true });
      return { kind: 'reserved', record };
    });
  }

  async markDispatchStarted(record: StoredRequestRecord, now: Date): Promise<DispatchStartResult> {
    const result = await this.store.transaction(async (transaction): Promise<DispatchStartResult> => {
      const ref = this.store.requestRef(record.quota_subject, record.request_id);
      const ledgerRef = this.store.ledgerRef(record.quota_subject, record.request_id);
      const [requestSnapshot, ledgerSnapshot] = await Promise.all([
        transaction.get(ref),
        transaction.get(ledgerRef),
      ]);
      const current = validRecordFromSnapshot(requestSnapshot);
      const ledger = ledgerRecordFromSnapshot(ledgerSnapshot);
      if (
        !storedRequestMatchesKey(current, record.quota_subject, record.request_id) ||
        current.reservation_lease_expires_at !== record.reservation_lease_expires_at ||
        ledger === undefined ||
        !ledgerMatchesRequest(ledger, current)
      ) {
        throw new Error('unsafe_dispatch_transition');
      }
      if (current.state === 'terminal' && isReservationExpiry(current)) {
        return { kind: 'lease_expired', record: current, outcome: current.terminal_outcome! };
      }
      if (current.state !== 'reserved' || current.settlement_state !== 'reserved') {
        throw new Error('unsafe_dispatch_transition');
      }
      if (now.getTime() >= Date.parse(current.reservation_lease_expires_at)) {
        const outcome = reservationExpiredOutcome(current.request_id);
        const terminal: StoredRequestRecord = {
          ...current,
          state: 'terminal',
          settlement_state: 'pending_refund',
          terminal_outcome: outcome,
        };
        transaction.set(ref, { ...terminal });
        return { kind: 'lease_expired', record: terminal, outcome };
      }
      transaction.set(ref, { state: 'dispatch_started' }, { merge: true });
      return { kind: 'started' };
    });
    if (result.kind === 'started') {
      record.state = 'dispatch_started';
    } else {
      Object.assign(record, result.record);
    }
    return result;
  }

  async persistTerminal(
    record: StoredRequestRecord,
    outcome: BrokerTerminalOutcome,
    settlement: SettlementIntent,
  ): Promise<void> {
    await this.store.transaction(async (transaction) => {
      const ref = this.store.requestRef(record.quota_subject, record.request_id);
      const ledgerRef = this.store.ledgerRef(record.quota_subject, record.request_id);
      const [requestSnapshot, ledgerSnapshot] = await Promise.all([
        transaction.get(ref),
        transaction.get(ledgerRef),
      ]);
      const current = validRecordFromSnapshot(requestSnapshot);
      const ledger = ledgerRecordFromSnapshot(ledgerSnapshot);
      if (
        !storedRequestMatchesKey(current, record.quota_subject, record.request_id) ||
        ledger === undefined ||
        !ledgerMatchesRequest(ledger, current)
      ) {
        throw new Error('unsafe_terminal_transition');
      }
      if (current.state !== 'reserved' && current.state !== 'dispatch_started') {
        throw new Error('unsafe_terminal_transition');
      }
      const terminal: StoredRequestRecord = {
        ...current,
        state: 'terminal',
        terminal_outcome: outcome,
        settlement_state: settlement === 'refund' ? 'pending_refund' : 'pending_finalize',
      };
      if (parseStoredRequest(terminal).kind !== 'valid') {
        throw new Error('unsafe_terminal_outcome');
      }
      transaction.set(ref, { ...terminal });
    });
    record.state = 'terminal';
    record.terminal_outcome = outcome;
    record.settlement_state = settlement === 'refund' ? 'pending_refund' : 'pending_finalize';
  }

  async settle(record: StoredRequestRecord): Promise<void> {
    await this.store.transaction(async (transaction) => {
      const requestRef = this.store.requestRef(record.quota_subject, record.request_id);
      const ledgerRef = this.store.ledgerRef(record.quota_subject, record.request_id);
      const subjectRef = this.store.subjectRef(record.quota_subject);
      const globalRef = this.store.globalUsageRef();
      const [requestSnapshot, ledgerSnapshot, subjectSnapshot, globalSnapshot] = await Promise.all([
        transaction.get(requestRef),
        transaction.get(ledgerRef),
        transaction.get(subjectRef),
        transaction.get(globalRef),
      ]);
      const current = validRecordFromSnapshot(requestSnapshot);
      const ledger = ledgerRecordFromSnapshot(ledgerSnapshot);
      if (
        !storedRequestMatchesKey(current, record.quota_subject, record.request_id) ||
        current.state !== 'terminal' ||
        ledger === undefined ||
        !ledgerMatchesRequest(ledger, current)
      ) {
        throw new Error('unsafe_ledger_record');
      }
      if (current.settlement_state === 'refunded' || current.settlement_state === 'finalized') {
        record.settlement_state = current.settlement_state;
        return;
      }
      if (ledger.state !== 'reserved') {
        throw new Error('unsafe_ledger_record');
      }
      const subject = subjectCreditFromSnapshot(subjectSnapshot);
      const global = globalCreditFromSnapshot(globalSnapshot);
      if (
        subject === undefined ||
        global === undefined ||
        subject.reserved_count < 1 ||
        subject.exposed_credits < 1 ||
        global.exposed_credits < subject.exposed_credits ||
        global.exposed_credits < 1
      ) {
        throw new Error('unsafe_credit_aggregate');
      }
      const refund = current.settlement_state === 'pending_refund';
      const nextSubject = refund ? applyRefund(subject, 1) : applyFinalize(subject, 1);

      transaction.set(ledgerRef, {
        state: refund ? 'refunded' : 'finalized',
        ...(refund ? { reason: terminalReason(current.terminal_outcome) } : {}),
      }, { merge: true });
      transaction.set(subjectRef, { ...nextSubject }, { merge: true });
      if (refund) {
        transaction.set(globalRef, {
          record_version: GLOBAL_CREDIT_RECORD_VERSION,
          exposed_credits: global.exposed_credits - 1,
        }, { merge: true });
      }
      transaction.set(requestRef, {
        settlement_state: refund ? 'refunded' : 'finalized',
      }, { merge: true });
      record.settlement_state = refund ? 'refunded' : 'finalized';
    });
  }
}

export interface FakeDurableBrokerStoreOptions {
  entitledUids?: Iterable<string>;
  breakerOpen?: boolean;
  perSubjectCreditCap?: number;
  brokerCreditCap?: number;
  oneInFlightPerSubject?: boolean;
}

export class FakeDurableBrokerStore implements DurableGateStore {
  readonly entitledUids: Set<string>;
  readonly lifecycle: InMemoryRequestLifecycle;
  breakerOpen: boolean;
  accessReadCount = 0;

  constructor(options: FakeDurableBrokerStoreOptions = {}) {
    this.entitledUids = new Set(options.entitledUids ?? ['owner-uid']);
    this.breakerOpen = options.breakerOpen ?? false;
    this.lifecycle = new InMemoryRequestLifecycle({
      perSubjectCreditCap: options.perSubjectCreditCap,
      brokerCreditCap: options.brokerCreditCap,
      oneInFlightPerSubject: options.oneInFlightPerSubject,
    });
  }

  async readAccess(input: DurableAccessInput): Promise<DurableAccessResult> {
    this.accessReadCount += 1;
    return {
      entitled: this.entitledUids.has(input.uid),
      breakerOpen: this.breakerOpen,
    };
  }

  get reserveCount(): number {
    return this.lifecycle.reserveCount;
  }

  get finalizeCount(): number {
    return this.lifecycle.finalizeCount;
  }

  get refundCount(): number {
    return this.lifecycle.refundCount;
  }
}

export class FakeBrokerTokenVerifier implements BrokerTokenVerifier {
  private readonly consumedAppCheckTokens = new Set<string>();

  constructor(
    private readonly config: Omit<DurableProtectionConfig, 'quotaHmacSecret'>,
    private readonly tokenMap: ReadonlyMap<
      string,
      { uid: string; appId: string; projectId?: string; signInProvider?: string }
    > = new Map([
      ['owner-auth-token|owner-app-check-token', { uid: 'owner-uid', appId: 'owner-test-app' }],
    ]),
  ) {}

  async verify(input: VerifyBrokerTokensInput): Promise<VerifyBrokerTokensResult> {
    const authToken = bearerToken(input.authorizationHeader);
    if (authToken === undefined) {
      return { ok: false, code: 'missing_auth_token' };
    }
    const appCheckToken = input.appCheckToken;
    if (!nonEmptyString(appCheckToken)) {
      return { ok: false, code: 'missing_app_check_token' };
    }
    const mapped = this.tokenMap.get(`${authToken}|${appCheckToken}`);
    if (mapped === undefined) {
      return { ok: false, code: 'invalid_auth_token' };
    }
    const projectId = mapped.projectId ?? this.config.projectId;
    if (projectId !== this.config.projectId) {
      return { ok: false, code: 'wrong_project_auth' };
    }
    if ((mapped.signInProvider ?? 'anonymous') !== 'anonymous') {
      return { ok: false, code: 'unsupported_auth_provider' };
    }
    if (this.consumedAppCheckTokens.has(appCheckToken)) {
      return { ok: false, code: 'app_check_replayed' };
    }
    this.consumedAppCheckTokens.add(appCheckToken);
    if (!this.config.allowedAppIds.has(mapped.appId)) {
      return { ok: false, code: 'unapproved_app' };
    }
    return {
      ok: true,
      auth: { uid: mapped.uid, projectId, signInProvider: 'anonymous' },
      app: { appId: mapped.appId, projectId },
    };
  }
}

export interface FirebaseDurableBrokerProtectionOptions {
  auth: FirebaseAdminAuthLike;
  appCheck: FirebaseAdminAppCheckLike;
  firestore: DurableFirestoreLike;
  env?: NodeJS.ProcessEnv;
}

export function createFirebaseAdminDurableBrokerProtection(
  options: FirebaseDurableBrokerProtectionOptions,
): { ok: true; protection: DurableBrokerProtection } | { ok: false; code: string } {
  const configured = durableConfigFromEnv(options.env ?? process.env);
  if (!configured.ok) {
    return configured;
  }
  const store = new FirestoreDurableBrokerStore(options.firestore);
  const verifier = new FirebaseAdminBrokerTokenVerifier({
    auth: options.auth,
    appCheck: options.appCheck,
    config: configured.config,
  });
  return {
    ok: true,
    protection: new ConfiguredDurableBrokerProtection(
      verifier,
      store,
      store.createRequestLifecycle(),
      configured.config,
    ),
  };
}

export function deriveQuotaSubject(input: {
  uid: string;
  appId: string;
  projectId: string;
  secret: string;
}): string {
  const digest = createHmac('sha256', input.secret)
    .update(`quota_subject_v1\0${input.projectId}\0${input.appId}\0${input.uid}`)
    .digest('hex');
  return `quota_subject_v1_${digest}`;
}

export function durableConfigFromEnv(
  env: NodeJS.ProcessEnv,
): { ok: true; config: DurableProtectionConfig } | { ok: false; code: string } {
  const projectId = env[BROKER_FIREBASE_PROJECT_ID_ENV]?.trim();
  const projectNumber = env[BROKER_FIREBASE_PROJECT_NUMBER_ENV]?.trim();
  const allowedAppIds = parseAllowlist(env[BROKER_APP_ID_ALLOWLIST_ENV]);
  if (
    !nonEmptyString(projectId) ||
    !nonEmptyString(projectNumber) ||
    allowedAppIds.size === 0 ||
    env[BROKER_DURABLE_STORE_CONFIGURED_ENV] !== 'true'
  ) {
    return { ok: false, code: MISSING_DURABLE_CONFIG_CODE };
  }
  const quotaHmacSecret = env[BROKER_QUOTA_HMAC_SECRET_ENV];
  if (!nonEmptyString(quotaHmacSecret?.trim())) {
    return { ok: false, code: MISSING_QUOTA_SECRET_CODE };
  }
  return {
    ok: true,
    config: { projectId, projectNumber, allowedAppIds, quotaHmacSecret },
  };
}

function validRecordFromSnapshot(snapshot: DurableFirestoreDocumentSnapshot): StoredRequestRecord {
  const parsed = parseStoredRequest(snapshot.exists ? snapshot.data() : undefined);
  if (parsed.kind !== 'valid') {
    throw new Error('unsafe_request_record');
  }
  return parsed.record;
}

function ledgerRecordFromSnapshot(snapshot: DurableFirestoreDocumentSnapshot): LedgerRecord | undefined {
  return snapshot.exists ? parseLedgerRecord(snapshot.data()) : undefined;
}

function controlRecordFromSnapshot(snapshot: DurableFirestoreDocumentSnapshot): {
  breakerOpen: boolean;
  perSubjectCreditCap: number;
  brokerCreditCap: number;
  oneInFlightPerSubject: boolean;
} | undefined {
  const data = snapshot.data();
  if (
    !snapshot.exists ||
    !isRecord(data) ||
    !hasExactKeys(data, CONTROL_RECORD_KEYS) ||
    data.record_version !== CONTROL_RECORD_VERSION ||
    typeof data.breakerOpen !== 'boolean' ||
    nonNegativeInteger(data.perSubjectCreditCap) === undefined ||
    nonNegativeInteger(data.brokerCreditCap) === undefined ||
    typeof data.oneInFlightPerSubject !== 'boolean'
  ) {
    return undefined;
  }
  return {
    breakerOpen: data.breakerOpen,
    perSubjectCreditCap: data.perSubjectCreditCap as number,
    brokerCreditCap: data.brokerCreditCap as number,
    oneInFlightPerSubject: data.oneInFlightPerSubject,
  };
}

function entitlementRecordFromSnapshot(
  snapshot: DurableFirestoreDocumentSnapshot,
): { entitled: boolean } | undefined {
  const data = snapshot.data();
  if (
    !snapshot.exists ||
    !isRecord(data) ||
    !hasExactKeys(data, ENTITLEMENT_RECORD_KEYS) ||
    data.record_version !== ENTITLEMENT_RECORD_VERSION ||
    typeof data.entitled !== 'boolean'
  ) {
    return undefined;
  }
  return { entitled: data.entitled };
}

function subjectCreditFromSnapshot(
  snapshot: DurableFirestoreDocumentSnapshot,
): { exposed_credits: number; reserved_count: number } | undefined {
  const data = snapshot.data();
  if (
    !snapshot.exists ||
    !isRecord(data) ||
    !hasExactKeys(data, SUBJECT_RECORD_KEYS) ||
    data.record_version !== SUBJECT_CREDIT_RECORD_VERSION ||
    nonNegativeInteger(data.exposed_credits) === undefined ||
    nonNegativeInteger(data.reserved_count) === undefined
  ) {
    return undefined;
  }
  return {
    exposed_credits: data.exposed_credits as number,
    reserved_count: data.reserved_count as number,
  };
}

function globalCreditFromSnapshot(
  snapshot: DurableFirestoreDocumentSnapshot,
): { exposed_credits: number } | undefined {
  const data = snapshot.data();
  if (
    !snapshot.exists ||
    !isRecord(data) ||
    !hasExactKeys(data, GLOBAL_RECORD_KEYS) ||
    data.record_version !== GLOBAL_CREDIT_RECORD_VERSION ||
    nonNegativeInteger(data.exposed_credits) === undefined
  ) {
    return undefined;
  }
  return { exposed_credits: data.exposed_credits as number };
}

function reservationExpiredOutcome(requestId: string): BrokerTerminalOutcome {
  return {
    kind: 'error',
    failure: { request_id: requestId, condition: 'reservation_lease_expired' },
  };
}

function terminalReason(outcome: BrokerTerminalOutcome | undefined): string {
  return outcome?.kind === 'error' ? outcome.failure.condition : 'terminal_refund';
}

function isReservationExpiry(record: StoredRequestRecord): boolean {
  return record.terminal_outcome?.kind === 'error' &&
    record.terminal_outcome.failure.condition === 'reservation_lease_expired';
}

function projectIdFromAuthToken(token: { aud?: string; iss?: string }): string | undefined {
  return token.aud !== undefined && token.iss === `https://securetoken.google.com/${token.aud}`
    ? token.aud
    : undefined;
}

function appCheckTokenMatchesProject(
  token: { aud?: string | string[]; iss?: string },
  projectId: string,
  projectNumber: string,
): boolean {
  const audiences = Array.isArray(token.aud) ? token.aud : [token.aud];
  return audiences.includes(projectId) &&
    audiences.includes(projectNumber) &&
    token.iss === `https://firebaseappcheck.googleapis.com/${projectNumber}`;
}

function nonNegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).length === allowed.size &&
    Object.keys(value).every((key) => allowed.has(key));
}

const CONTROL_RECORD_KEYS = new Set([
  'record_version',
  'breakerOpen',
  'perSubjectCreditCap',
  'brokerCreditCap',
  'oneInFlightPerSubject',
]);
const ENTITLEMENT_RECORD_KEYS = new Set(['record_version', 'entitled']);
const SUBJECT_RECORD_KEYS = new Set(['record_version', 'exposed_credits', 'reserved_count']);
const GLOBAL_RECORD_KEYS = new Set(['record_version', 'exposed_credits']);

function docKey(value: string): string {
  return Buffer.from(value, 'utf8').toString('base64url').slice(0, 512);
}

function bearerToken(value: string | undefined): string | undefined {
  const match = value === undefined ? undefined : /^Bearer (.+)$/i.exec(value.trim());
  return match?.[1];
}

function parseAllowlist(value: string | undefined): Set<string> {
  return new Set(
    (value ?? '')
      .split(',')
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0),
  );
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}
