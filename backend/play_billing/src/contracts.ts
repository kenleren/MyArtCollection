import type { PlanId, ProductId } from './constants.js';

export type FreeReason =
  | 'invalid_request'
  | 'identity_rejected'
  | 'disclosure_required'
  | 'replay_conflict'
  | 'in_flight'
  | 'rate_limited'
  | 'unsafe_record'
  | 'not_verified'
  | 'verification_pending'
  | 'temporarily_unavailable';

export type NormalizedPaidState = 'active' | 'grace' | 'canceled';

export interface VerifyRequest {
  requestId: string;
  billingDisclosureVersion: string;
  productId: string;
  purchaseToken: string;
}

export interface PaidResponse {
  version: 'play-billing-v1';
  requestId: string;
  planId: PlanId;
  productId: ProductId;
  state: NormalizedPaidState;
  verifiedAt: string;
  playExpiresAt: string;
  leaseExpiresAt: string;
}

export interface FreeResponse {
  version: 'play-billing-v1';
  requestId?: string;
  state: 'free';
  reason: FreeReason;
}

export type VerifyResponse = PaidResponse | FreeResponse;

export interface BillingIdentity {
  uid: string;
}

export interface DisclosureRequest {
  requestId: string;
  disclosureVersion: string;
  purpose: string;
  accepted?: boolean;
}

export interface DisclosureResponse {
  version: 'play-billing-v1';
  requestId: string;
  status: 'accepted' | 'revoked';
}

export type PlaySubscriptionState =
  | 'SUBSCRIPTION_STATE_UNSPECIFIED'
  | 'SUBSCRIPTION_STATE_PENDING'
  | 'SUBSCRIPTION_STATE_ACTIVE'
  | 'SUBSCRIPTION_STATE_PAUSED'
  | 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD'
  | 'SUBSCRIPTION_STATE_ON_HOLD'
  | 'SUBSCRIPTION_STATE_CANCELED'
  | 'SUBSCRIPTION_STATE_EXPIRED'
  | 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED'
  | 'SUBSCRIPTION_STATE_REVOKED'
  | string;

export type PlayAcknowledgementState =
  | 'ACKNOWLEDGEMENT_STATE_PENDING'
  | 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
  | 'ACKNOWLEDGEMENT_STATE_UNSPECIFIED'
  | string;

export interface PlayLineItem {
  productId?: string;
  expiryTime?: string;
  offerDetails?: {
    basePlanId?: string;
    offerId?: string;
  };
  autoRenewingPlan?: Record<string, unknown>;
}

export interface PlaySubscriptionPurchase {
  packageName?: string;
  subscriptionState?: PlaySubscriptionState;
  acknowledgementState?: PlayAcknowledgementState;
  linkedPurchaseToken?: string;
  externalAccountIdentifiers?: {
    obfuscatedExternalAccountId?: string;
  };
  lineItems?: PlayLineItem[];
}

export interface PlayGetArguments {
  packageName: 'app.archivale';
  token: string;
  timeoutMs: 10_000;
}

export interface PlayAcknowledgeArguments {
  packageName: 'app.archivale';
  subscriptionId: ProductId;
  token: string;
  body: Record<string, never>;
  timeoutMs: 10_000;
}

export interface PlaySubscriptionsAdapter {
  getSubscription(args: PlayGetArguments): Promise<PlaySubscriptionPurchase>;
  acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<void>;
}

export interface Clock {
  now(): Date;
}

export interface NonceSource {
  nextNonce(): Uint8Array;
}
