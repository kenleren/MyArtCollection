export const BROKER_ADMISSION_MODE_ENV = 'BROKER_ADMISSION_MODE';
export const BROKER_INTERNAL_TEST_EXPIRES_AT_ENV = 'BROKER_INTERNAL_TEST_EXPIRES_AT';

export type ResearchAdmissionPolicy =
  | { mode: 'owner_only' }
  | { mode: 'verified_internal_app'; expiresAt: string; expiresAtMs: number };

export function canonicalExpiry(value: unknown): number | undefined {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) {
    return undefined;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === value ? parsed : undefined;
}

export function readResearchAdmissionPolicy(env: NodeJS.ProcessEnv): ResearchAdmissionPolicy | undefined {
  const mode = env[BROKER_ADMISSION_MODE_ENV] ?? 'owner_only';
  if (mode === 'owner_only') return { mode };
  if (mode !== 'verified_internal_app') return undefined;
  const expiresAt = env[BROKER_INTERNAL_TEST_EXPIRES_AT_ENV];
  const expiresAtMs = canonicalExpiry(expiresAt);
  return expiresAtMs === undefined ? undefined : { mode, expiresAt: expiresAt!, expiresAtMs };
}

export function researchAdmissionIsCurrent(policy: ResearchAdmissionPolicy, nowMs: number): boolean {
  return policy.mode === 'owner_only' || (Number.isFinite(nowMs) && nowMs < policy.expiresAtMs);
}
