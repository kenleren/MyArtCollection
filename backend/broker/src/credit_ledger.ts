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
