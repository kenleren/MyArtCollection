export const BETA_SIGNUP_CONSENT_VERSION = "beta-signup-2026-07-08";
export const BETA_SIGNUP_RETENTION_VERSION =
  "beta-signup-retention-2026-07-08";

export type PlatformInterest = "android" | "ios" | "both";

export type BetaSignupPayload = {
  email: string;
  name?: string;
  platform: PlatformInterest;
  country?: string;
  notes?: string;
  consent: true;
  consentVersion: typeof BETA_SIGNUP_CONSENT_VERSION;
  retentionVersion: typeof BETA_SIGNUP_RETENTION_VERSION;
  sourceRoute: "/beta/";
  submittedAtClientMs: number;
  website?: string;
};

export type BetaSignupQueueRecord = {
  formType: "beta_signup";
  normalizedEmail: string;
  email: string;
  name?: string;
  platform: PlatformInterest;
  country?: string;
  notes?: string;
  consentVersion: typeof BETA_SIGNUP_CONSENT_VERSION;
  retentionVersion: typeof BETA_SIGNUP_RETENTION_VERSION;
  sourceRoute: "/beta/";
  status: "pending";
  submittedAtIso: string;
};

export type BetaSignupQueue = {
  hasDuplicate(normalizedEmail: string, nowMs: number): Promise<boolean>;
  isRateLimited(submitterKey: string | undefined, nowMs: number): Promise<boolean>;
  enqueue(
    record: BetaSignupQueueRecord,
    nowMs: number,
    options?: { rateLimitKey?: string },
  ): Promise<void>;
};
