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
  PlayLineItem,
  PlaySubscriptionPurchase,
  PlaySubscriptionsAdapter,
  VerifyRequest,
  VerifyResponse,
} from './contracts.js';
import type { BillingIdentifiers } from './crypto.js';
import {
  BillingRepository,
  UnsafeBillingRecordError,
  type AttemptHandle,
  type PaidCommit,
} from './store.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_REQUEST_BYTES = 8_192;
const MAX_TOKEN_LENGTH = 4_096;
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
}

interface EligiblePurchase {
  productId: ProductId;
  planId: PaidResponse['planId'];
  normalizedState: NormalizedPaidState;
  playExpiresAt: Date;
  playAcknowledged: boolean;
  linkedPurchaseToken?: string;
}

export class PlayBillingService {
  constructor(private readonly dependencies: PlayBillingDependencies) {}

  async acceptDisclosure(
    identity: BillingIdentity,
    input: unknown,
  ): Promise<DisclosureResponse | FreeResponse> {
    const request = parseDisclosureRequest(input, true);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }
    try {
      const subject = this.dependencies.identifiers.accountSubject(identity.uid);
      await this.dependencies.repository.acceptDisclosure(subject, this.dependencies.clock.now());
      return { version: CONTRACT_VERSION, requestId: request.requestId, status: 'accepted' };
    } catch {
      return free(request.requestId, 'temporarily_unavailable');
    }
  }

  async revokeDisclosure(
    identity: BillingIdentity,
    input: unknown,
  ): Promise<DisclosureResponse | FreeResponse> {
    const request = parseDisclosureRequest(input, false);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }
    try {
      const subject = this.dependencies.identifiers.accountSubject(identity.uid);
      await this.dependencies.repository.revokeDisclosure(subject, this.dependencies.clock.now());
      return { version: CONTRACT_VERSION, requestId: request.requestId, status: 'revoked' };
    } catch {
      return free(request.requestId, 'temporarily_unavailable');
    }
  }

  async verifySubscription(identity: BillingIdentity, input: unknown): Promise<VerifyResponse> {
    const request = parseVerifyRequest(input);
    if (request === undefined) {
      return free(validRequestIdFrom(input), 'invalid_request');
    }

    const { identifiers, repository } = this.dependencies;
    const accountSubject = identifiers.accountSubject(identity.uid);
    try {
      if (!(await repository.hasCurrentDisclosure(accountSubject, this.dependencies.clock.now()))) {
        return free(request.requestId, 'disclosure_required');
      }
    } catch {
      return free(request.requestId, 'temporarily_unavailable');
    }

    const tokenFingerprint = identifiers.tokenFingerprint(request.purchaseToken);
    const requestFingerprint = identifiers.requestFingerprint(identity.uid, request.requestId);
    let acquisition;
    try {
      acquisition = await repository.acquireAttempt(
        accountSubject,
        requestFingerprint,
        tokenFingerprint,
        this.dependencies.clock.now(),
      );
    } catch {
      return free(request.requestId, 'temporarily_unavailable');
    }
    if (acquisition.kind !== 'acquired') {
      return free(request.requestId, acquisition.kind);
    }

    const attempt = acquisition.attempt;
    const playDeadline = Date.now() + PLAY_PORTION_DEADLINE_MS;
    let purchase: PlaySubscriptionPurchase;
    try {
      purchase = await this.getSubscription(request.purchaseToken, playDeadline);
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
        identity,
        request,
        purchase,
        attempt,
        accountSubject,
        requestFingerprint,
        playDeadline,
      );
    }
    return this.finishOrdinaryVerification(
      identity,
      request.requestId,
      request.purchaseToken,
      purchase,
      attempt,
      request.productId,
      playDeadline,
    );
  }

  private async verifyCanceledPendingPredecessor(
    identity: BillingIdentity,
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
      );
    } catch {
      return free(request.requestId, 'temporarily_unavailable');
    }
    if (acquisition.kind !== 'acquired') {
      return free(request.requestId, acquisition.kind);
    }

    let predecessor: PlaySubscriptionPurchase;
    try {
      predecessor = await this.getSubscription(linkedToken, playDeadline);
    } catch {
      await this.closeWithoutThrow(acquisition.attempt);
      return free(request.requestId, 'temporarily_unavailable');
    }
    return this.finishOrdinaryVerification(
      identity,
      request.requestId,
      linkedToken,
      predecessor,
      acquisition.attempt,
      undefined,
      playDeadline,
    );
  }

  private async finishOrdinaryVerification(
    identity: BillingIdentity,
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
      this.dependencies.identifiers.obfuscatedAccountId(identity.uid),
      this.dependencies.clock.now(),
    );
    if (eligible === undefined) {
      await this.closeWithoutThrow(attempt);
      return free(requestId, 'not_verified');
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
      const delivered = await this.dependencies.repository.commitDelivery(attempt, {
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
          await withAbsoluteDeadline(
            this.dependencies.play.acknowledgeSubscription({
              packageName: PACKAGE_NAME,
              subscriptionId: eligible.productId,
              token: rawToken,
              body: {},
              timeoutMs: PLAY_CALL_DEADLINE_MS,
            }),
            Math.min(playDeadline, Date.now() + PLAY_CALL_DEADLINE_MS),
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
      return commit === undefined ? free(requestId, 'not_verified') : paid(requestId, commit);
    } catch (error) {
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
  ): Promise<PlaySubscriptionPurchase> {
    return withAbsoluteDeadline(
      this.dependencies.play.getSubscription({
        packageName: PACKAGE_NAME,
        token,
        timeoutMs: PLAY_CALL_DEADLINE_MS,
      }),
      Math.min(playDeadline, Date.now() + PLAY_CALL_DEADLINE_MS),
    );
  }
}

function parseVerifyRequest(input: unknown): VerifyRequest | undefined {
  if (!isPlainObject(input) || serializedSize(input) > MAX_REQUEST_BYTES) {
    return undefined;
  }
  if (!hasExactKeys(input, ['billingDisclosureVersion', 'productId', 'purchaseToken', 'requestId'])) {
    return undefined;
  }
  if (
    !isCanonicalUuid(input.requestId) ||
    input.billingDisclosureVersion !== DISCLOSURE_VERSION ||
    typeof input.productId !== 'string' ||
    input.productId.length === 0 ||
    input.productId.length > 128 ||
    typeof input.purchaseToken !== 'string' ||
    input.purchaseToken.length === 0 ||
    input.purchaseToken.length > MAX_TOKEN_LENGTH
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
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function serializedSize(value: unknown): number {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8');
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

async function withAbsoluteDeadline<T>(operation: Promise<T>, deadline: number): Promise<T> {
  const remaining = deadline - Date.now();
  if (remaining <= 0) {
    throw new Error('play deadline exceeded');
  }
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error('play deadline exceeded')), remaining);
    timer.unref();
  });
  try {
    return await Promise.race([operation, timeout]);
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer);
    }
  }
}
