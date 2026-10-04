import { canonicalExpiry } from './live_admission.js';

export const PROVIDER_BUDGET_RECORD_VERSION = 'broker-provider-budget-v1';
export const MAX_LIVE_PROVIDER_DISPATCHES = 30;

export interface ProviderDispatchBudget {
  record_version: typeof PROVIDER_BUDGET_RECORD_VERSION;
  dispatchLimit: number;
  dispatchCount: number;
  expiresAt: string;
}

const keys = new Set(['record_version', 'dispatchLimit', 'dispatchCount', 'expiresAt']);

export function parseProviderDispatchBudget(value: unknown): ProviderDispatchBudget | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (Object.keys(record).length !== keys.size || Object.keys(record).some(key => !keys.has(key)) ||
      record.record_version !== PROVIDER_BUDGET_RECORD_VERSION ||
      typeof record.dispatchLimit !== 'number' || !Number.isSafeInteger(record.dispatchLimit) ||
      record.dispatchLimit < 1 || record.dispatchLimit > MAX_LIVE_PROVIDER_DISPATCHES ||
      typeof record.dispatchCount !== 'number' || !Number.isSafeInteger(record.dispatchCount) ||
      record.dispatchCount < 0 || record.dispatchCount > record.dispatchLimit ||
      canonicalExpiry(record.expiresAt) === undefined) return undefined;
  return record as unknown as ProviderDispatchBudget;
}
