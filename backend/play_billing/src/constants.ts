export const CONTRACT_VERSION = 'play-billing-v1';
export const DISCLOSURE_VERSION = 'billing-verification-disclosure-v1';
export const DISCLOSURE_ASSERTION_VERSION = 'billing-disclosure-assertion-v1';
export const DISCLOSURE_PURPOSE = 'play_subscription_verification';
export const PACKAGE_NAME = 'app.archivale';
export const BILLING_DATABASE_ID = 'archivale-play-billing';
export const ACTIVE_KEY_VERSION = 'play-billing-fingerprint-v1';

export const ATTEMPT_LEASE_MS = 90_000;
export const ACK_COOLDOWN_MS = 15_000;
export const TOKEN_GET_COOLDOWN_MS = 15_000;
export const PAID_LEASE_MS = 15 * 60_000;
export const RATE_WINDOW_MS = 15 * 60_000;
export const MAX_GETS_PER_SUBJECT_WINDOW = 6;
export const MAX_ACKS_PER_TOKEN_WINDOW = 3;
export const OPERATION_RETENTION_MS = 24 * 60 * 60_000;
export const DISCLOSURE_RETENTION_MS = 365 * 24 * 60 * 60_000;
export const REVOKED_RETENTION_MS = 30 * 24 * 60 * 60_000;
export const BINDING_RETENTION_MS = 30 * 24 * 60 * 60_000;

export const COLLECTIONS = {
  disclosures: 'playBillingDisclosureAssertions',
  bindings: 'playBillingPurchaseBindings',
  replays: 'playBillingRequestReplays',
  operations: 'playBillingTokenOperations',
  rateLimits: 'playBillingRateLimits',
} as const;

export const PRODUCT_ALLOWLIST = {
  archivale_starter_monthly: {
    planId: 'starter',
    basePlanId: 'monthly',
  },
  archivale_collector_monthly: {
    planId: 'collector',
    basePlanId: 'monthly',
  },
  archivale_archive_monthly: {
    planId: 'archive',
    basePlanId: 'monthly',
  },
} as const;

export type ProductId = keyof typeof PRODUCT_ALLOWLIST;
export type PlanId = (typeof PRODUCT_ALLOWLIST)[ProductId]['planId'];
