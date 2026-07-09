import { createHmac } from 'node:crypto';

import type {
  BrokerCreditLedger,
  LedgerRecord,
  ReserveCreditInput,
  ReserveCreditResult,
} from './credit_ledger.js';
import type { BrokerIdempotencyStore, StoredRequest } from './idempotency.js';
import type { BrokerAdapterIdentity } from './adapter.js';

export const BROKER_FIREBASE_PROJECT_ID_ENV = 'BROKER_FIREBASE_PROJECT_ID';
export const BROKER_FIREBASE_PROJECT_NUMBER_ENV = 'BROKER_FIREBASE_PROJECT_NUMBER';
export const BROKER_APP_ID_ALLOWLIST_ENV = 'BROKER_APP_ID_ALLOWLIST';
export const BROKER_QUOTA_HMAC_SECRET_ENV = 'BROKER_QUOTA_HMAC_SECRET';
export const BROKER_DURABLE_STORE_CONFIGURED_ENV = 'BROKER_DURABLE_STORE_CONFIGURED';
export const MISSING_DURABLE_CONFIG_CODE = 'missing_durable_broker_config';
export const MISSING_QUOTA_SECRET_CODE = 'missing_quota_hmac_secret';

export interface DurableProtectionConfig {
  projectId: string;
  projectNumber?: string;
  allowedAppIds: ReadonlySet<string>;
  quotaHmacSecret: string;
}

export interface BrokerTokenVerifier {
  verify(input: VerifyBrokerTokensInput): Promise<VerifyBrokerTokensResult>;
}

export interface VerifyBrokerTokensInput {
  authorizationHeader?: string;
  appCheckToken?: string;
}

export type VerifyBrokerTokensResult =
  | {
      ok: true;
      auth: VerifiedAuthIdentity;
      app: VerifiedAppIdentity;
    }
  | {
      ok: false;
      code:
        | 'missing_auth_token'
        | 'invalid_auth_token'
        | 'missing_app_check_token'
        | 'invalid_app_check_token'
        | 'identity_project_mismatch'
        | 'unsupported_auth_provider'
        | 'unapproved_app';
    };

export type VerifyBrokerTokensErrorCode =
  Extract<VerifyBrokerTokensResult, { ok: false }>['code'];

export interface VerifiedAuthIdentity {
  uid: string;
  projectId: string;
  signInProvider: string;
}

export interface VerifiedAppIdentity {
  appId: string;
  projectId: string;
}

export interface DurableGateStore {
  readAccess(input: DurableAccessInput): Promise<DurableAccessResult>;
}

export interface DurableAccessInput {
  uid: string;
  appId: string;
  quotaSubject: string;
}

export interface DurableAccessResult {
  entitled: boolean;
  creditAvailable: boolean;
  breakerOpen: boolean;
}

export interface DurableBrokerProtection {
  verifyAndBuildIdentity(
    input: VerifyBrokerTokensInput,
  ): Promise<DurableBrokerIdentityResult>;
  createIdempotencyStore(): BrokerIdempotencyStore;
  createCreditLedger(): BrokerCreditLedger;
}

export type DurableBrokerIdentityResult =
  | {
      ok: true;
      identity: BrokerAdapterIdentity;
    }
  | {
      ok: false;
      code: VerifyBrokerTokensErrorCode | typeof MISSING_QUOTA_SECRET_CODE;
    };

export interface FirebaseAdminAuthLike {
  verifyIdToken(
    token: string,
    checkRevoked: boolean,
  ): Promise<{
    uid?: string;
    aud?: string;
    iss?: string;
    firebase?: {
      sign_in_provider?: string;
    };
  }>;
}

export interface FirebaseAdminAppCheckLike {
  verifyToken(
    token: string,
  ): Promise<{
    appId?: string;
    app_id?: string;
    aud?: string | string[];
    iss?: string;
    sub?: string;
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
    if (input.appCheckToken === undefined || input.appCheckToken.trim().length === 0) {
      return { ok: false, code: 'missing_app_check_token' };
    }

    let authTokenBody: Awaited<ReturnType<FirebaseAdminAuthLike['verifyIdToken']>>;
    let appCheckTokenBody: Awaited<ReturnType<FirebaseAdminAppCheckLike['verifyToken']>>;
    try {
      authTokenBody = await this.options.auth.verifyIdToken(authToken, true);
    } catch {
      return { ok: false, code: 'invalid_auth_token' };
    }
    try {
      appCheckTokenBody = await this.options.appCheck.verifyToken(input.appCheckToken);
    } catch {
      return { ok: false, code: 'invalid_app_check_token' };
    }

    const authProjectId = projectIdFromAuthToken(authTokenBody);
    const appProjectMatches = appCheckTokenMatchesProject(
      appCheckTokenBody,
      this.options.config.projectId,
      this.options.config.projectNumber,
    );
    const uid = authTokenBody.uid;
    const appId = appCheckTokenBody.appId ?? appCheckTokenBody.app_id ?? appCheckTokenBody.sub;
    const signInProvider = authTokenBody.firebase?.sign_in_provider;

    if (
      uid === undefined ||
      uid.length === 0 ||
      authProjectId !== this.options.config.projectId
    ) {
      return { ok: false, code: 'invalid_auth_token' };
    }
    if (
      appId === undefined ||
      appId.length === 0 ||
      !appProjectMatches
    ) {
      return { ok: false, code: 'invalid_app_check_token' };
    }
    if (authProjectId !== this.options.config.projectId) {
      return { ok: false, code: 'identity_project_mismatch' };
    }
    if (signInProvider !== 'anonymous') {
      return { ok: false, code: 'unsupported_auth_provider' };
    }
    if (!this.options.config.allowedAppIds.has(appId)) {
      return { ok: false, code: 'unapproved_app' };
    }

    return {
      ok: true,
      auth: {
        uid,
        projectId: authProjectId,
        signInProvider,
      },
      app: {
        appId,
        projectId: this.options.config.projectId,
      },
    };
  }
}

export class ConfiguredDurableBrokerProtection implements DurableBrokerProtection {
  constructor(
    private readonly verifier: BrokerTokenVerifier,
    private readonly gateStore: DurableGateStore,
    private readonly idempotency: BrokerIdempotencyStore,
    private readonly creditLedger: BrokerCreditLedger,
    private readonly config: DurableProtectionConfig,
  ) {}

  async verifyAndBuildIdentity(
    input: VerifyBrokerTokensInput,
  ): Promise<DurableBrokerIdentityResult> {
    if (this.config.quotaHmacSecret.trim().length === 0) {
      return { ok: false, code: MISSING_QUOTA_SECRET_CODE };
    }

    const verified = await this.verifier.verify(input);
    if (!verified.ok) {
      return verified;
    }

    const quotaSubject = deriveQuotaSubject({
      uid: verified.auth.uid,
      appId: verified.app.appId,
      projectId: verified.auth.projectId,
      secret: this.config.quotaHmacSecret,
    });
    const access = await this.gateStore.readAccess({
      uid: verified.auth.uid,
      appId: verified.app.appId,
      quotaSubject,
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
        app: {
          appId: verified.app.appId,
          appProjectId: verified.app.projectId,
        },
        quotaSubject,
        entitled: access.entitled,
        creditAvailable: access.creditAvailable,
        breakerOpen: access.breakerOpen,
      },
    };
  }

  createIdempotencyStore(): BrokerIdempotencyStore {
    return this.idempotency;
  }

  createCreditLedger(): BrokerCreditLedger {
    return this.creditLedger;
  }
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
  const allowedAppIds = parseAllowlist(env[BROKER_APP_ID_ALLOWLIST_ENV]);
  if (
    projectId === undefined ||
    projectId.length === 0 ||
    allowedAppIds.size === 0 ||
    env[BROKER_DURABLE_STORE_CONFIGURED_ENV] !== 'true'
  ) {
    return { ok: false, code: MISSING_DURABLE_CONFIG_CODE };
  }

  const quotaHmacSecret = env[BROKER_QUOTA_HMAC_SECRET_ENV];
  if (quotaHmacSecret === undefined || quotaHmacSecret.trim().length === 0) {
    return { ok: false, code: MISSING_QUOTA_SECRET_CODE };
  }

  return {
    ok: true,
    config: {
      projectId,
      projectNumber: env[BROKER_FIREBASE_PROJECT_NUMBER_ENV]?.trim(),
      allowedAppIds,
      quotaHmacSecret,
    },
  };
}

export interface FakeDurableBrokerStoreOptions {
  entitledUids?: Iterable<string>;
  breakerOpen?: boolean;
  perSubjectMonthlyCap?: number;
  brokerMonthlyCap?: number;
  oneInFlightPerSubject?: boolean;
}

export class FakeDurableBrokerStore implements DurableGateStore {
  readonly idempotency = new Map<string, StoredRequest>();
  readonly ledgerRecords: LedgerRecord[] = [];
  readonly entitledUids: Set<string>;
  breakerOpen: boolean;
  perSubjectMonthlyCap: number;
  brokerMonthlyCap: number;
  oneInFlightPerSubject: boolean;

  constructor(options: FakeDurableBrokerStoreOptions = {}) {
    this.entitledUids = new Set(options.entitledUids ?? ['owner-uid']);
    this.breakerOpen = options.breakerOpen ?? false;
    this.perSubjectMonthlyCap = options.perSubjectMonthlyCap ?? 3;
    this.brokerMonthlyCap = options.brokerMonthlyCap ?? 100;
    this.oneInFlightPerSubject = options.oneInFlightPerSubject ?? true;
  }

  async readAccess(input: DurableAccessInput): Promise<DurableAccessResult> {
    return {
      entitled: this.entitledUids.has(input.uid),
      creditAvailable:
        this.exposedCreditsFor(input.quotaSubject) + 1 <= this.perSubjectMonthlyCap &&
        this.exposedCredits + 1 <= this.brokerMonthlyCap,
      breakerOpen: this.breakerOpen,
    };
  }

  get reserveCount(): number {
    return this.ledgerRecords.filter((record) => record.state !== 'rejected-before-reserve').length;
  }

  get finalizeCount(): number {
    return this.ledgerRecords.filter((record) => record.state === 'finalized').length;
  }

  get refundCount(): number {
    return this.ledgerRecords.filter((record) => record.state === 'refunded').length;
  }

  get exposedCredits(): number {
    return this.ledgerRecords
      .filter((record) => record.state === 'reserved' || record.state === 'finalized')
      .reduce((total, record) => total + record.creditCost, 0);
  }

  exposedCreditsFor(quotaSubject: string): number {
    return this.ledgerRecords
      .filter(
        (record) =>
          record.quotaSubject === quotaSubject &&
          (record.state === 'reserved' || record.state === 'finalized'),
      )
      .reduce((total, record) => total + record.creditCost, 0);
  }

  hasReservedFor(quotaSubject: string): boolean {
    return this.ledgerRecords.some(
      (record) => record.quotaSubject === quotaSubject && record.state === 'reserved',
    );
  }
}

export class DurableIdempotencyStore implements BrokerIdempotencyStore {
  constructor(private readonly store: FakeDurableBrokerStore) {}

  get(quotaSubject: string, requestId: string): StoredRequest | undefined {
    return this.store.idempotency.get(this.key(quotaSubject, requestId));
  }

  begin(quotaSubject: string, requestId: string, payloadHash: string): StoredRequest {
    const existing = this.get(quotaSubject, requestId);
    if (existing !== undefined) {
      return existing;
    }
    const entry: StoredRequest = { payloadHash };
    this.store.idempotency.set(this.key(quotaSubject, requestId), entry);
    return entry;
  }

  setInFlight(entry: StoredRequest, inFlight: Promise<import('./contracts.js').BrokerResponse>): void {
    entry.inFlight = inFlight;
  }

  complete(entry: StoredRequest, response: import('./contracts.js').BrokerResponse): void {
    entry.response = response;
    entry.inFlight = undefined;
  }

  forget(quotaSubject: string, requestId: string): void {
    this.store.idempotency.delete(this.key(quotaSubject, requestId));
  }

  private key(quotaSubject: string, requestId: string): string {
    return `${quotaSubject}|${requestId}`;
  }
}

export class DurableCreditLedger implements BrokerCreditLedger {
  constructor(private readonly store: FakeDurableBrokerStore) {}

  get records(): LedgerRecord[] {
    return this.store.ledgerRecords;
  }

  get reserveCount(): number {
    return this.store.reserveCount;
  }

  get finalizeCount(): number {
    return this.store.finalizeCount;
  }

  get refundCount(): number {
    return this.store.refundCount;
  }

  get exposedCredits(): number {
    return this.store.exposedCredits;
  }

  spentCreditsFor(quotaSubject: string): number {
    return this.store.ledgerRecords
      .filter((record) => record.state === 'finalized' && record.quotaSubject === quotaSubject)
      .reduce((total, record) => total + record.creditCost, 0);
  }

  exposedCreditsFor(quotaSubject: string): number {
    return this.store.exposedCreditsFor(quotaSubject);
  }

  reserve(input: ReserveCreditInput): ReserveCreditResult {
    if (this.store.oneInFlightPerSubject && this.store.hasReservedFor(input.quotaSubject)) {
      return this.rejectBeforeReserve(
        input,
        'quota_subject_in_flight',
        'Quota subject already has an in-flight request.',
      );
    }

    const perSubjectProjected = this.store.exposedCreditsFor(input.quotaSubject) + input.creditCost;
    if (perSubjectProjected > this.store.perSubjectMonthlyCap) {
      return this.rejectBeforeReserve(
        input,
        'quota_subject_monthly_cap_exceeded',
        'Quota subject monthly cap denied the request.',
      );
    }

    const brokerProjected = this.store.exposedCredits + input.creditCost;
    if (brokerProjected > this.store.brokerMonthlyCap) {
      return this.rejectBeforeReserve(
        input,
        'broker_monthly_cap_exceeded',
        'Broker monthly cap denied the request.',
      );
    }

    const record: LedgerRecord = { ...input, state: 'reserved' };
    this.store.ledgerRecords.push(record);
    return { ok: true, record };
  }

  finalize(record: LedgerRecord): void {
    if (record.state === 'reserved') {
      record.state = 'finalized';
    }
  }

  refund(record: LedgerRecord, reason: string): void {
    if (record.state === 'reserved') {
      record.state = 'refunded';
      record.reason = reason;
    }
  }

  private rejectBeforeReserve(
    input: ReserveCreditInput,
    code: NonNullable<ReserveCreditResult['code']>,
    message: string,
  ): ReserveCreditResult {
    const record: LedgerRecord = {
      ...input,
      state: 'rejected-before-reserve',
      reason: code,
    };
    this.store.ledgerRecords.push(record);
    return { ok: false, record, code, message };
  }
}

export class FakeBrokerTokenVerifier implements BrokerTokenVerifier {
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
    if (input.appCheckToken === undefined || input.appCheckToken.trim().length === 0) {
      return { ok: false, code: 'missing_app_check_token' };
    }

    const mapped = this.tokenMap.get(`${authToken}|${input.appCheckToken}`);
    if (mapped === undefined) {
      return { ok: false, code: 'invalid_auth_token' };
    }

    const projectId = mapped.projectId ?? this.config.projectId;
    const signInProvider = mapped.signInProvider ?? 'anonymous';
    if (projectId !== this.config.projectId) {
      return { ok: false, code: 'identity_project_mismatch' };
    }
    if (signInProvider !== 'anonymous') {
      return { ok: false, code: 'unsupported_auth_provider' };
    }
    if (!this.config.allowedAppIds.has(mapped.appId)) {
      return { ok: false, code: 'unapproved_app' };
    }

    return {
      ok: true,
      auth: {
        uid: mapped.uid,
        projectId,
        signInProvider,
      },
      app: {
        appId: mapped.appId,
        projectId,
      },
    };
  }
}

function projectIdFromAuthToken(token: { aud?: string; iss?: string }): string | undefined {
  if (token.aud !== undefined && token.iss === `https://securetoken.google.com/${token.aud}`) {
    return token.aud;
  }
  return undefined;
}

function appCheckTokenMatchesProject(
  token: { aud?: string | string[]; iss?: string },
  projectId: string,
  projectNumber: string | undefined,
): boolean {
  const audiences = Array.isArray(token.aud) ? token.aud : [token.aud];
  if (!audiences.includes(projectId)) {
    return false;
  }
  if (projectNumber !== undefined && projectNumber.length > 0) {
    return token.iss === `https://firebaseappcheck.googleapis.com/${projectNumber}`;
  }
  return true;
}

function bearerToken(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  const match = /^Bearer (.+)$/i.exec(value.trim());
  return match?.[1];
}

function parseAllowlist(value: string | undefined): Set<string> {
  if (value === undefined) {
    return new Set();
  }

  return new Set(
    value
      .split(',')
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0),
  );
}
