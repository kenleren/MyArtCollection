import { fingerprint, type ObservationSource } from './account_authority.js';
import { BillingDeadline } from './deadline.js';
import { DisabledTokenCustody, validToken, type TokenCustody } from './token_custody.js';
import {
  CONTRACT_VERSION,
  DISCLOSURE_PURPOSE,
  DISCLOSURE_VERSION,
  PACKAGE_NAME,
  PAID_LEASE_MS,
  PRODUCT_ALLOWLIST,
  type ProductId,
} from './constants.js';
import type {
  BillingIdentity,
  Clock,
  DisclosureRequest,
  DisclosureResponse,
  FreeReason,
  FreeResponse,
  NormalizedPaidState,
  PaidResponse,
  PrepareResponse,
  PlayLineItem,
  PlaySubscriptionPurchase,
  PlaySubscriptionsAdapter,
  VerifyRequest,
  VerifyResponse,
} from './contracts.js';
import type { BillingIdentifiers } from './crypto.js';
import {
  BillingRepository,
  AccountConflictError,
  UnsafeBillingRecordError,
  type AttemptHandle,
  type PaidCommit,
} from './store.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_REQUEST_BYTES = 8_192;
const PLAY_PORTION_DEADLINE_MS = 45_000;
const PLAY_CALL_DEADLINE_MS = 10_000;

export interface VerificationHooks {
  afterDeliveryCommitted?: () => Promise<void>;
  afterAcknowledgementStarted?: () => Promise<void>;
}

export interface PlayBillingDependencies {
  repository: BillingRepository;
  identifiers: BillingIdentifiers;
  play: PlaySubscriptionsAdapter;
  clock: Clock;
  hooks?: VerificationHooks;
  custody?: TokenCustody;
}

interface EligiblePurchase {
  productId: ProductId;
  planId: PaidResponse['planId'];
  normalizedState: NormalizedPaidState;
  playExpiresAt: Date;
  playAcknowledged: boolean;
  linkedPurchaseToken?: string;
}

/** Server-internal context, derived by an authenticated adapter or trusted route resolver.
 * No callable consumes this shape. Repository reads remain the authority. */
export interface AccountObservationContext {
  accountSubject: string;
  requestFingerprint: string;
  source: ObservationSource;
}

export class PlayBillingService {
  constructor(private readonly dependencies: PlayBillingDependencies) {}

  async preparePurchase(identity: BillingIdentity, input: unknown, deadline = new BillingDeadline()): Promise<PrepareResponse | FreeResponse> {
    if (!isPlainObject(input) || serializedSize(input) > 1024 ||
        !hasExactKeys(input, ['version','requestId','billingDisclosureVersion']) ||
        input.version !== CONTRACT_VERSION || !isCanonicalUuid(input.requestId) ||
        input.billingDisclosureVersion !== DISCLOSURE_VERSION) return free(validRequestIdFrom(input), 'invalid_request');
    try {
      const result = await this.dependencies.repository.preparePurchase(this.dependencies.identifiers.accountSubject(identity.uid),
        this.dependencies.clock.now(), deadline);
      deadline.check();
      return result.kind === 'ready'
        ? { version: CONTRACT_VERSION, requestId: input.requestId, status: 'ready',
          obfuscatedAccountId: result.obfuscatedAccountId, lifecycleEpoch: result.lifecycleEpoch }
        : free(input.requestId, result.kind);
    } catch (error) {
      return free(input.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
  }

  async acceptDisclosure(
    identity: BillingIdentity,
    input: unknown,
    deadline = new BillingDeadline(),
  ): Promise<DisclosureResponse | FreeResponse> {
    const request = parseDisclosureRequest(input, true);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }
    try {
      deadline.check();
      const subject = this.dependencies.identifiers.accountSubject(identity.uid);
      await this.dependencies.repository.acceptDisclosure(subject, this.dependencies.clock.now(), deadline);
      return { version: CONTRACT_VERSION, requestId: request.requestId, status: 'accepted' };
    } catch (error) {
      return free(request.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
  }

  async revokeDisclosure(
    identity: BillingIdentity,
    input: unknown,
    deadline = new BillingDeadline(),
  ): Promise<DisclosureResponse | FreeResponse> {
    const request = parseDisclosureRequest(input, false);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }
    try {
      deadline.check();
      const subject = this.dependencies.identifiers.accountSubject(identity.uid);
      await this.dependencies.repository.revokeDisclosure(subject, this.dependencies.clock.now(), deadline);
      return { version: CONTRACT_VERSION, requestId: request.requestId, status: 'revoked' };
    } catch (error) {
      return free(request.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
  }

  async verifySubscription(identity: BillingIdentity, input: unknown, deadline = new BillingDeadline()): Promise<VerifyResponse> {
    const request = parseVerifyRequest(input);
    if (!request) return free(validRequestIdFrom(input), 'invalid_request');
    return this.processAccountObservation({ accountSubject: this.dependencies.identifiers.accountSubject(identity.uid),
      requestFingerprint: this.dependencies.identifiers.requestFingerprint(identity.uid, request.requestId), source: 'foreground' },
      { kind: 'verify', input }, deadline);
  }

  /** Shared source-only entry: background adapters must resolve an opaque subject first. */
  async processAccountObservation(context: AccountObservationContext,
    observation: { kind: 'verify' | 'restore'; input: unknown }, deadline = new BillingDeadline()): Promise<VerifyResponse> {
    if (!context || !fingerprint(context.accountSubject) || !fingerprint(context.requestFingerprint) ||
        !['foreground','background'].includes(context.source) ||
        Object.keys(context).some(key => !['accountSubject','requestFingerprint','source'].includes(key))) return free(undefined, 'invalid_request');
    if (observation.kind === 'verify') return this.verifyObservation(context, observation.input, deadline);
    if (observation.kind === 'restore') return this.restoreObservation(context, observation.input, deadline);
    return free(undefined, 'invalid_request');
  }

  private async verifyObservation(context: AccountObservationContext, input: unknown, deadline: BillingDeadline): Promise<VerifyResponse> {
    deadline.check();
    const request = parseVerifyRequest(input);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }

    const { identifiers, repository } = this.dependencies;
    const accountSubject = context.accountSubject;
    try {
      if (!(await repository.hasCurrentDisclosure(accountSubject, this.dependencies.clock.now()))) {
        return free(request.requestId, 'disclosure_required');
      }
    } catch (error) {
      return free(request.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }

    const tokenFingerprint = identifiers.tokenFingerprint(request.purchaseToken);
    const requestFingerprint = context.requestFingerprint;
    let acquisition;
    try {
      acquisition = await repository.acquireAttempt(
        accountSubject,
        requestFingerprint,
        tokenFingerprint,
        this.dependencies.clock.now(),
        deadline,
        context.source,
      );
    } catch (error) {
      return free(request.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
    if (acquisition.kind !== 'acquired') {
      return free(request.requestId, acquisition.kind);
    }

    const attempt = acquisition.attempt;
    const playDeadline = Math.min(deadline.expiresAt, Date.now() + PLAY_PORTION_DEADLINE_MS);
    let purchase: PlaySubscriptionPurchase;
    try {
      if (!await repository.isCurrentAttempt(attempt, this.dependencies.clock.now())) return free(request.requestId, 'not_verified');
      purchase = await this.getSubscription(request.purchaseToken, playDeadline, deadline);
    } catch {
      await this.closeWithoutThrow(attempt);
      return free(request.requestId, 'temporarily_unavailable');
    }

    const successorShape = validateLineItemShape(purchase, request.productId);
    if (successorShape === undefined) {
      await this.closeWithoutThrow(attempt);
      return free(request.requestId, 'not_verified');
    }
    if (purchase.subscriptionState === 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED') {
      return this.verifyCanceledPendingPredecessor(
        request,
        purchase,
        attempt,
        accountSubject,
        requestFingerprint,
        playDeadline,
      );
    }
    return this.finishOrdinaryVerification(
      request.requestId,
      request.purchaseToken,
      purchase,
      attempt,
      request.productId,
      playDeadline,
    );
  }

  async restoreEntitlement(identity: BillingIdentity, input: unknown, deadline = new BillingDeadline()): Promise<VerifyResponse> {
    const requestId = validRequestIdFrom(input);
    if (!requestId) return free(undefined, 'invalid_request');
    return this.processAccountObservation({ accountSubject: this.dependencies.identifiers.accountSubject(identity.uid),
      requestFingerprint: this.dependencies.identifiers.requestFingerprint(identity.uid, requestId), source: 'foreground' },
      { kind: 'restore', input }, deadline);
  }

  private async restoreObservation(context: AccountObservationContext, input: unknown, deadline: BillingDeadline): Promise<VerifyResponse> {
    if (!isPlainObject(input) || serializedSize(input) > 1024 ||
        !hasExactKeys(input, ['version','requestId','billingDisclosureVersion']) ||
        input.version !== CONTRACT_VERSION || !isCanonicalUuid(input.requestId) ||
        input.billingDisclosureVersion !== DISCLOSURE_VERSION) return free(validRequestIdFrom(input), 'invalid_request');
    const requestId = input.requestId;
    const { repository, identifiers, clock } = this.dependencies;
    let attempt: AttemptHandle | undefined;
    try {
      deadline.check();
      const acquired = await repository.acquireAccountAttempt(context.accountSubject,
        context.requestFingerprint, clock.now(), deadline, context.source);
      if (acquired.kind !== 'acquired') return free(requestId, acquired.kind);
      attempt = acquired.attempt;
      if (!attempt.envelope) return free(requestId, 'unsafe_record');
      if (!await repository.isCurrentAttempt(attempt, clock.now())) return free(requestId, 'not_verified');
      const token = await (this.dependencies.custody ?? new DisabledTokenCustody()).decrypt(attempt.envelope, attempt, deadline);
      if (!validToken(token) || identifiers.tokenFingerprint(token) !== attempt.tokenFingerprint) return free(requestId, 'unsafe_record');
      deadline.check();
      if (!await repository.isCurrentAttempt(attempt, clock.now())) return free(requestId, 'not_verified');
      const purchase = await this.getSubscription(token, deadline.expiresAt, deadline);
      if (purchase.subscriptionState === 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED') {
        const product = purchase.lineItems?.[0]?.productId;
        if (typeof product !== 'string' || !validateLineItemShape(purchase, product)) return free(requestId, 'not_verified');
        return await this.verifyCanceledPendingPredecessor({
          version: CONTRACT_VERSION, requestId, purchaseToken: token, productId: product,
          billingDisclosureVersion: DISCLOSURE_VERSION,
        }, purchase, attempt, attempt.accountSubject, context.requestFingerprint, deadline.expiresAt);
      }
      return await this.finishOrdinaryVerification(requestId, token, purchase, attempt, undefined, deadline.expiresAt);
    } catch (error) {
      if (attempt) await this.closeWithoutThrow(attempt);
      return free(requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
  }

  private async verifyCanceledPendingPredecessor(
    request: VerifyRequest,
    successor: PlaySubscriptionPurchase,
    successorAttempt: AttemptHandle,
    accountSubject: string,
    requestFingerprint: string,
    playDeadline: number,
  ): Promise<VerifyResponse> {
    const linkedToken = successor.linkedPurchaseToken;
    const closed = await this.dependencies.repository
      .closeAttempt(successorAttempt, this.dependencies.clock.now(), 'canceled_pending_read_only')
      .catch(() => false);
    if (!closed || typeof linkedToken !== 'string' || linkedToken.length === 0) {
      return free(request.requestId, 'not_verified');
    }

    const predecessorFingerprint = this.dependencies.identifiers.tokenFingerprint(linkedToken);
    if (predecessorFingerprint === successorAttempt.tokenFingerprint) {
      return free(request.requestId, 'not_verified');
    }
    let acquisition;
    try {
      acquisition = await this.dependencies.repository.acquirePredecessorAttempt(
        accountSubject,
        requestFingerprint,
        predecessorFingerprint,
        this.dependencies.clock.now(),
        successorAttempt.fence!.deadline,
        successorAttempt,
      );
    } catch (error) {
      return free(request.requestId, error instanceof UnsafeBillingRecordError ? 'unsafe_record' : 'temporarily_unavailable');
    }
    if (acquisition.kind !== 'acquired') {
      return free(request.requestId, acquisition.kind);
    }

    let predecessor: PlaySubscriptionPurchase;
    try {
      if (!await this.dependencies.repository.isCurrentAttempt(acquisition.attempt, this.dependencies.clock.now())) return free(request.requestId, 'not_verified');
      predecessor = await this.getSubscription(linkedToken, playDeadline, successorAttempt.fence!.deadline);
    } catch {
      await this.closeWithoutThrow(acquisition.attempt);
      return free(request.requestId, 'temporarily_unavailable');
    }
    return this.finishOrdinaryVerification(
      request.requestId,
      linkedToken,
      predecessor,
      acquisition.attempt,
      undefined,
      playDeadline,
    );
  }

  private async finishOrdinaryVerification(
    requestId: string,
    rawToken: string,
    purchase: PlaySubscriptionPurchase,
    attempt: AttemptHandle,
    requestedProduct: string | undefined,
    playDeadline: number,
  ): Promise<VerifyResponse> {
    const eligible = validateEligiblePurchase(
      purchase,
      requestedProduct,
      attempt.expectedPlayAccountId,
      this.dependencies.clock.now(),
    );
    if (eligible === undefined) {
      const inactive = validatedInactive(purchase, requestedProduct,
        attempt.expectedPlayAccountId, this.dependencies.clock.now());
      if (inactive !== undefined) {
        try {
          if (!await this.dependencies.repository.recordInactive(attempt, inactive, this.dependencies.clock.now(),
                purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED') ||
              !await this.dependencies.repository.closeAttempt(attempt, this.dependencies.clock.now()) ||
              !await this.dependencies.repository.isCurrentResponse(attempt, this.dependencies.clock.now())) {
            return free(requestId, 'not_verified');
          }
          attempt.fence!.deadline.check();
          return free(requestId, inactive === 'pending' ? 'play_pending' : inactive);
        }
        catch { return free(requestId, 'temporarily_unavailable'); }
      }
      await this.closeWithoutThrow(attempt);
      return free(requestId, inactive === 'pending' ? 'play_pending' : inactive ?? 'not_verified');
    }

    const verifiedAt = this.dependencies.clock.now();
    try {
      const ownerAccepted = await this.dependencies.repository.markVerifiedOwner(
        attempt,
        eligible.productId,
        verifiedAt,
      );
      if (!ownerAccepted) {
        return free(requestId, 'not_verified');
      }
      const predecessorFingerprint =
        eligible.linkedPurchaseToken === undefined
          ? undefined
          : this.dependencies.identifiers.tokenFingerprint(eligible.linkedPurchaseToken);
      if (predecessorFingerprint === attempt.tokenFingerprint) {
        await this.closeWithoutThrow(attempt);
        return free(requestId, 'not_verified');
      }
      if (!await this.dependencies.repository.isCurrentAttempt(attempt, this.dependencies.clock.now(), 'verified_owner')) return free(requestId, 'not_verified');
      const tokenEnvelope = attempt.envelope ?? await (this.dependencies.custody ?? new DisabledTokenCustody()).encrypt(
        rawToken, attempt, attempt.fence!.deadline);
      attempt.fence!.deadline.check();
      const delivered = await this.dependencies.repository.commitDelivery(attempt, {
        tokenEnvelope,
        planId: eligible.planId,
        productId: eligible.productId,
        normalizedState: eligible.normalizedState,
        playExpiresAt: eligible.playExpiresAt,
        verifiedAt,
        playAcknowledged: eligible.playAcknowledged,
        predecessorFingerprint,
      });
      if (!delivered) {
        return free(requestId, 'not_verified');
      }
      await this.dependencies.hooks?.afterDeliveryCommitted?.();

      let commit = await this.dependencies.repository.finalizePaid(
        attempt,
        this.dependencies.clock.now(),
        'delivery_committed',
      );
      if (commit === undefined) {
        const acknowledgementStarted = await this.dependencies.repository.beginAcknowledgement(
          attempt,
          this.dependencies.clock.now(),
        );
        if (!acknowledgementStarted) {
          return free(requestId, 'verification_pending');
        }
        await this.dependencies.hooks?.afterAcknowledgementStarted?.();
        try {
          if (!await this.dependencies.repository.isCurrentAttempt(attempt, this.dependencies.clock.now(), 'ack_in_progress')) return free(requestId, 'not_verified');
          await withAbsoluteDeadline(
            () => this.dependencies.play.acknowledgeSubscription({
              packageName: PACKAGE_NAME,
              subscriptionId: eligible.productId,
              token: rawToken,
              body: {},
              timeoutMs: PLAY_CALL_DEADLINE_MS,
            }),
            Math.min(playDeadline, Date.now() + PLAY_CALL_DEADLINE_MS),
            attempt.fence!.deadline,
          );
        } catch {
          await this.dependencies.repository
            .markAcknowledgementUnknown(attempt, this.dependencies.clock.now())
            .catch(() => false);
          return free(requestId, 'verification_pending');
        }
        commit = await this.dependencies.repository.finalizePaid(
          attempt,
          this.dependencies.clock.now(),
          'ack_in_progress',
        );
      }
      if (commit === undefined || !await this.dependencies.repository.isCurrentGrant(attempt, this.dependencies.clock.now())) return free(requestId, 'not_verified');
      attempt.fence!.deadline.check();
      return paid(requestId, commit);
    } catch (error) {
      if (error instanceof AccountConflictError) return free(requestId, 'account_conflict');
      if (error instanceof UnsafeBillingRecordError) {
        return free(requestId, 'unsafe_record');
      }
      return free(requestId, 'temporarily_unavailable');
    }
  }

  private async closeWithoutThrow(attempt: AttemptHandle): Promise<void> {
    await this.dependencies.repository.closeAttempt(attempt, this.dependencies.clock.now()).catch(() => false);
  }

  private getSubscription(
    token: string,
    playDeadline: number,
    invocation: BillingDeadline,
  ): Promise<PlaySubscriptionPurchase> {
    return withAbsoluteDeadline(
      () => this.dependencies.play.getSubscription({
        packageName: PACKAGE_NAME,
        token,
        timeoutMs: PLAY_CALL_DEADLINE_MS,
      }),
      Math.min(playDeadline, Date.now() + PLAY_CALL_DEADLINE_MS),
      invocation,
    );
  }
}

function parseVerifyRequest(input: unknown): VerifyRequest | undefined {
  if (!isPlainObject(input) || serializedSize(input) > MAX_REQUEST_BYTES) {
    return undefined;
  }
  if (!hasExactKeys(input, ['version', 'billingDisclosureVersion', 'productId', 'purchaseToken', 'requestId'])) {
    return undefined;
  }
  if (
    input.version !== CONTRACT_VERSION ||
    !isCanonicalUuid(input.requestId) ||
    input.billingDisclosureVersion !== DISCLOSURE_VERSION ||
    typeof input.productId !== 'string' ||
    input.productId.length === 0 ||
    input.productId.length > 128 ||
    !validToken(input.purchaseToken)
  ) {
    return undefined;
  }
  return input as unknown as VerifyRequest;
}

function parseDisclosureRequest(input: unknown, accepting: boolean): DisclosureRequest | undefined {
  if (!isPlainObject(input) || serializedSize(input) > 1_024) {
    return undefined;
  }
  const keys = accepting
    ? ['accepted', 'disclosureVersion', 'purpose', 'requestId']
    : ['disclosureVersion', 'purpose', 'requestId'];
  if (
    !hasExactKeys(input, keys) ||
    !isCanonicalUuid(input.requestId) ||
    input.disclosureVersion !== DISCLOSURE_VERSION ||
    input.purpose !== DISCLOSURE_PURPOSE ||
    (accepting && input.accepted !== true)
  ) {
    return undefined;
  }
  return input as unknown as DisclosureRequest;
}

function validateLineItemShape(
  purchase: PlaySubscriptionPurchase,
  requestedProduct: string,
): PlayLineItem | undefined {
  if (!Array.isArray(purchase.lineItems) || purchase.lineItems.length !== 1) {
    return undefined;
  }
  const lineItem = purchase.lineItems[0];
  if (
    lineItem === undefined ||
    typeof lineItem.productId !== 'string' ||
    !(lineItem.productId in PRODUCT_ALLOWLIST) ||
    lineItem.productId !== requestedProduct
  ) {
    return undefined;
  }
  return lineItem;
}

function validateEligiblePurchase(
  purchase: PlaySubscriptionPurchase,
  requestedProduct: string | undefined,
  expectedAccountBinding: string,
  now: Date,
): EligiblePurchase | undefined {
  if (!Array.isArray(purchase.lineItems) || purchase.lineItems.length !== 1) {
    return undefined;
  }
  const lineItem = purchase.lineItems[0];
  const productId = lineItem?.productId;
  if (
    typeof productId !== 'string' ||
    !(productId in PRODUCT_ALLOWLIST) ||
    (requestedProduct !== undefined && productId !== requestedProduct) ||
    lineItem.autoRenewingPlan === undefined ||
    lineItem.offerDetails?.basePlanId !== 'monthly' ||
    lineItem.offerDetails.offerId !== undefined ||
    purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId !== expectedAccountBinding
  ) {
    return undefined;
  }
  const expiry = parseTimestamp(lineItem.expiryTime);
  const normalizedState = normalizeState(purchase.subscriptionState);
  if (expiry === undefined || expiry.getTime() <= now.getTime() || normalizedState === undefined) {
    return undefined;
  }
  let playAcknowledged: boolean;
  if (purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED') {
    playAcknowledged = true;
  } else if (purchase.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING') {
    playAcknowledged = false;
  } else {
    return undefined;
  }
  const allowed = PRODUCT_ALLOWLIST[productId as ProductId];
  return {
    productId: productId as ProductId,
    planId: allowed.planId,
    normalizedState,
    playExpiresAt: expiry,
    playAcknowledged,
    linkedPurchaseToken:
      typeof purchase.linkedPurchaseToken === 'string' && purchase.linkedPurchaseToken.length > 0
        ? purchase.linkedPurchaseToken
        : undefined,
  };
}

function normalizeState(state: string | undefined): NormalizedPaidState | undefined {
  switch (state) {
    case 'SUBSCRIPTION_STATE_ACTIVE':
      return 'active';
    case 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD':
      return 'grace';
    case 'SUBSCRIPTION_STATE_CANCELED':
      return 'canceled';
    default:
      return undefined;
  }
}

function parseTimestamp(value: string | undefined): Date | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const timestamp = new Date(value);
  return Number.isFinite(timestamp.getTime()) ? timestamp : undefined;
}

function paid(requestId: string, commit: PaidCommit): PaidResponse {
  const leaseExpiresAt = new Date(
    Math.min(commit.verifiedAt.getTime() + PAID_LEASE_MS, commit.playExpiresAt.getTime()),
  );
  return {
    version: CONTRACT_VERSION,
    requestId,
    status: 'paid',
    planId: commit.planId,
    productId: commit.productId,
    state: commit.normalizedState,
    verifiedAt: commit.verifiedAt.toISOString(),
    playExpiresAt: commit.playExpiresAt.toISOString(),
    leaseExpiresAt: leaseExpiresAt.toISOString(),
  };
}

function free(requestId: string | undefined, reason: FreeReason): FreeResponse {
  return {
    version: CONTRACT_VERSION,
    ...(requestId === undefined ? {} : { requestId }),
    state: 'free',
    status: ['no_known_purchase','expired','on_hold','paused','revoked'].includes(reason) ? 'none'
      : ['in_flight','verification_pending','play_pending'].includes(reason) ? 'pending'
      : ['temporarily_unavailable','rate_limited'].includes(reason) ? 'unavailable' : 'rejected',
    reason,
  };
}

function validRequestIdFrom(input: unknown): string | undefined {
  return isPlainObject(input) && isCanonicalUuid(input.requestId) ? input.requestId : undefined;
}

function isCanonicalUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: string[]): boolean {
  const actual = Object.keys(value).sort();
  expected = [...expected].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function serializedSize(value: unknown): number {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8');
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

async function withAbsoluteDeadline<T>(operation: () => Promise<T>, deadline: number, invocation: BillingDeadline): Promise<T> {
  // Keep dispatch deferred until both the wall-time budget and permanent
  // invocation cancellation have been checked, including after late DB results.
  invocation.check();
  const remaining = deadline - Date.now();
  if (remaining <= 0) {
    invocation.cancel();
    throw new Error('play deadline exceeded');
  }
  return invocation.run(operation, remaining);
}

function validatedInactive(purchase: PlaySubscriptionPurchase, product: string | undefined, account: string, now: Date): 'expired' | 'on_hold' | 'paused' | 'revoked' | 'pending' | undefined {
  const line = purchase.lineItems?.[0];
  if (purchase.lineItems?.length !== 1 || !line || typeof line.productId !== 'string' ||
      !(line.productId in PRODUCT_ALLOWLIST) || (product !== undefined && line.productId !== product) ||
      line.offerDetails?.basePlanId !== 'monthly' || line.offerDetails.offerId !== undefined ||
      line.autoRenewingPlan === undefined || purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId !== account) return undefined;
  const expiry = parseTimestamp(line.expiryTime);
  if (!expiry) return undefined;
  switch (purchase.subscriptionState) {
    case 'SUBSCRIPTION_STATE_EXPIRED': return expiry <= now ? 'expired' : undefined;
    case 'SUBSCRIPTION_STATE_ON_HOLD': return 'on_hold';
    case 'SUBSCRIPTION_STATE_PAUSED': return 'paused';
    case 'SUBSCRIPTION_STATE_REVOKED': return 'revoked';
    case 'SUBSCRIPTION_STATE_PENDING': return 'pending';
    case 'SUBSCRIPTION_STATE_CANCELED': return expiry <= now ? 'expired' : undefined;
    default: return undefined;
  }
}
