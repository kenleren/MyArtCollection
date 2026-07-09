export const CREDIT_LEDGER_RECORD_VERSION = 'broker-credit-ledger-v1';

export type LedgerState = 'reserved' | 'finalized' | 'refunded';

export interface LedgerRecord {
  record_version: typeof CREDIT_LEDGER_RECORD_VERSION;
  request_id: string;
  quota_subject: string;
  state: LedgerState;
  credit_cost: 1;
  reason?: string;
}

export interface CreditSnapshot {
  exposed_credits: number;
  reserved_count: number;
}

export function parseLedgerRecord(value: unknown): LedgerRecord | undefined {
  if (!isRecord(value) || !hasOnlyKeys(value, LEDGER_RECORD_KEYS)) {
    return undefined;
  }
  if (
    value.record_version !== CREDIT_LEDGER_RECORD_VERSION ||
    !nonEmptyString(value.request_id) ||
    !nonEmptyString(value.quota_subject) ||
    (value.state !== 'reserved' && value.state !== 'finalized' && value.state !== 'refunded') ||
    value.credit_cost !== 1 ||
    (value.state === 'refunded' ? !nonEmptyString(value.reason) : value.reason !== undefined)
  ) {
    return undefined;
  }
  return value as unknown as LedgerRecord;
}

export function ledgerMatchesRequest(
  ledger: LedgerRecord,
  request: {
    quota_subject: string;
    request_id: string;
    credit_cost: number;
    state: string;
    settlement_state: string;
    terminal_outcome?: { kind: string; failure?: { condition?: string } };
  },
): boolean {
  if (
    ledger.quota_subject !== request.quota_subject ||
    ledger.request_id !== request.request_id ||
    ledger.credit_cost !== request.credit_cost
  ) {
    return false;
  }
  if (request.state !== 'terminal') {
    return request.settlement_state === 'reserved' && ledger.state === 'reserved';
  }
  switch (request.settlement_state) {
    case 'pending_refund':
    case 'pending_finalize':
      return ledger.state === 'reserved';
    case 'refunded':
      return ledger.state === 'refunded' &&
        request.terminal_outcome?.kind === 'error' &&
        ledger.reason === request.terminal_outcome.failure?.condition;
    case 'finalized':
      return ledger.state === 'finalized';
    default:
      return false;
  }
}

export function applyFinalize(snapshot: CreditSnapshot, creditCost: number): CreditSnapshot {
  return {
    exposed_credits: snapshot.exposed_credits,
    reserved_count: Math.max(0, snapshot.reserved_count - creditCost),
  };
}

export function applyRefund(snapshot: CreditSnapshot, creditCost: number): CreditSnapshot {
  return {
    exposed_credits: Math.max(0, snapshot.exposed_credits - creditCost),
    reserved_count: Math.max(0, snapshot.reserved_count - creditCost),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

const LEDGER_RECORD_KEYS = new Set([
  'record_version',
  'request_id',
  'quota_subject',
  'state',
  'credit_cost',
  'reason',
]);
