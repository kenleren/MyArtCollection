import type { BrokerTerminalOutcome } from './contracts.js';
import {
  CREDIT_LEDGER_RECORD_VERSION,
  ledgerMatchesRequest,
  parseLedgerRecord,
  type LedgerRecord,
} from './credit_ledger.js';
import {
  REQUEST_LIFECYCLE_RECORD_VERSION,
  parseStoredRequest,
  storedRequestMatchesKey,
  type StoredRequestRecord,
} from './idempotency.js';

export const RESERVATION_LEASE_MILLISECONDS = 60_000;
export const RETENTION_MILLISECONDS = 24 * 60 * 60 * 1000;

export type SettlementIntent = 'refund' | 'finalize';
export type LifecycleFaultPoint =
  | 'dispatch_persistence'
  | 'terminal_persistence'
  | 'refund'
  | 'finalize';

export interface AcquireRequestInput {
  quota_subject: string;
  request_id: string;
  payload_hash: string;
  credit_cost: 1;
  now: Date;
}

export type AcquireRequestResult =
  | { kind: 'reserved'; record: StoredRequestRecord }
  | { kind: 'replay'; record: StoredRequestRecord; outcome: BrokerTerminalOutcome }
  | { kind: 'conflict' }
  | { kind: 'in_flight' }
  | { kind: 'outcome_unknown' }
  | { kind: 'credits_exhausted' }
  | { kind: 'unsafe_record' };

export type DispatchStartResult =
  | { kind: 'started' }
  | { kind: 'lease_expired'; record: StoredRequestRecord; outcome: BrokerTerminalOutcome };

export interface RequestLifecycleStore {
  acquire(input: AcquireRequestInput): Promise<AcquireRequestResult>;
  markDispatchStarted(record: StoredRequestRecord, now: Date): Promise<DispatchStartResult>;
  persistTerminal(
    record: StoredRequestRecord,
    outcome: BrokerTerminalOutcome,
    settlement: SettlementIntent,
  ): Promise<void>;
  settle(record: StoredRequestRecord): Promise<void>;
}

export interface InMemoryRequestLifecycleOptions {
  perSubjectCreditCap?: number;
  brokerCreditCap?: number;
  oneInFlightPerSubject?: boolean;
  faults?: Partial<Record<LifecycleFaultPoint, () => void | Promise<void>>>;
}

export class InMemoryRequestLifecycle implements RequestLifecycleStore {
  readonly records = new Map<string, unknown>();
  readonly ledgerRecords = new Map<string, LedgerRecord>();
  private readonly perSubjectCreditCap: number;
  private readonly brokerCreditCap: number;
  private readonly oneInFlightPerSubject: boolean;
  private readonly faults: Partial<Record<LifecycleFaultPoint, () => void | Promise<void>>>;

  constructor(options: InMemoryRequestLifecycleOptions = {}) {
    this.perSubjectCreditCap = options.perSubjectCreditCap ?? 3;
    this.brokerCreditCap = options.brokerCreditCap ?? 100;
    this.oneInFlightPerSubject = options.oneInFlightPerSubject ?? true;
    this.faults = options.faults ?? {};
  }

  get reserveCount(): number {
    return this.ledgerRecords.size;
  }

  get finalizeCount(): number {
    return [...this.ledgerRecords.values()].filter((record) => record.state === 'finalized').length;
  }

  get refundCount(): number {
    return [...this.ledgerRecords.values()].filter((record) => record.state === 'refunded').length;
  }

  get exposedCredits(): number {
    return [...this.ledgerRecords.values()]
      .filter((record) => record.state === 'reserved' || record.state === 'finalized')
      .reduce((total, record) => total + record.credit_cost, 0);
  }

  exposedCreditsFor(quotaSubject: string): number {
    return [...this.ledgerRecords.values()]
      .filter(
        (record) => record.quota_subject === quotaSubject &&
          (record.state === 'reserved' || record.state === 'finalized'),
      )
      .reduce((total, record) => total + record.credit_cost, 0);
  }

  seedRaw(quotaSubject: string, requestId: string, value: unknown): void {
    this.records.set(this.key(quotaSubject, requestId), value);
  }

  async acquire(input: AcquireRequestInput): Promise<AcquireRequestResult> {
    const key = this.key(input.quota_subject, input.request_id);
    const parsed = parseStoredRequest(this.records.get(key));
    const rawLedger = this.ledgerRecords.get(key);
    if (parsed.kind === 'unsafe') {
      return { kind: 'unsafe_record' };
    }
    if (parsed.kind === 'valid') {
      const existing = parsed.record;
      const ledger = parseLedgerRecord(rawLedger);
      if (
        !storedRequestMatchesKey(existing, input.quota_subject, input.request_id) ||
        ledger === undefined ||
        !ledgerMatchesRequest(ledger, existing)
      ) {
        return { kind: 'unsafe_record' };
      }
      if (existing.payload_hash !== input.payload_hash) {
        return { kind: 'conflict' };
      }
      if (existing.state === 'terminal') {
        return { kind: 'replay', record: existing, outcome: existing.terminal_outcome! };
      }
      if (existing.state === 'dispatch_started') {
        return input.now.getTime() < Date.parse(existing.reservation_lease_expires_at)
          ? { kind: 'in_flight' }
          : { kind: 'outcome_unknown' };
      }
      if (input.now.getTime() < Date.parse(existing.reservation_lease_expires_at)) {
        return { kind: 'in_flight' };
      }

      const outcome = reservationExpiredOutcome(existing.request_id);
      existing.state = 'terminal';
      existing.terminal_outcome = outcome;
      existing.settlement_state = 'pending_refund';
      this.records.set(key, existing);
      return { kind: 'replay', record: existing, outcome };
    }

    if (rawLedger !== undefined) {
      return { kind: 'unsafe_record' };
    }
    if ([...this.ledgerRecords.values()].some((record) => parseLedgerRecord(record) === undefined)) {
      return { kind: 'unsafe_record' };
    }

    if (
      this.oneInFlightPerSubject &&
      [...this.ledgerRecords.values()].some(
        (record) => record.quota_subject === input.quota_subject && record.state === 'reserved',
      )
    ) {
      return { kind: 'in_flight' };
    }
    if (
      this.exposedCreditsFor(input.quota_subject) + input.credit_cost > this.perSubjectCreditCap ||
      this.exposedCredits + input.credit_cost > this.brokerCreditCap
    ) {
      return { kind: 'credits_exhausted' };
    }

    const record: StoredRequestRecord = {
      record_version: REQUEST_LIFECYCLE_RECORD_VERSION,
      quota_subject: input.quota_subject,
      request_id: input.request_id,
      payload_hash: input.payload_hash,
      state: 'reserved',
      credit_cost: input.credit_cost,
      reservation_lease_expires_at: new Date(
        input.now.getTime() + RESERVATION_LEASE_MILLISECONDS,
      ).toISOString(),
      retention_expires_at: new Date(input.now.getTime() + RETENTION_MILLISECONDS).toISOString(),
      settlement_state: 'reserved',
    };
    const ledger: LedgerRecord = {
      record_version: CREDIT_LEDGER_RECORD_VERSION,
      quota_subject: input.quota_subject,
      request_id: input.request_id,
      state: 'reserved',
      credit_cost: 1,
    };

    // Both writes are synchronous in the fake so concurrent callers observe one reservation.
    this.records.set(key, record);
    this.ledgerRecords.set(key, ledger);
    return { kind: 'reserved', record };
  }

  async markDispatchStarted(record: StoredRequestRecord, now: Date): Promise<DispatchStartResult> {
    await this.inject('dispatch_persistence');
    const current = this.requireRecord(record);
    const ledger = parseLedgerRecord(
      this.ledgerRecords.get(this.key(record.quota_subject, record.request_id)),
    );
    if (
      !storedRequestMatchesKey(current, record.quota_subject, record.request_id) ||
      current.reservation_lease_expires_at !== record.reservation_lease_expires_at ||
      ledger === undefined ||
      !ledgerMatchesRequest(ledger, current)
    ) {
      throw new Error('unsafe_dispatch_transition');
    }
    if (current.state === 'terminal' && isReservationExpiry(current)) {
      Object.assign(record, current);
      return { kind: 'lease_expired', record: current, outcome: current.terminal_outcome! };
    }
    if (current.state !== 'reserved' || current.settlement_state !== 'reserved') {
      throw new Error('unsafe_dispatch_transition');
    }
    if (now.getTime() >= Date.parse(current.reservation_lease_expires_at)) {
      const outcome = reservationExpiredOutcome(current.request_id);
      current.state = 'terminal';
      current.terminal_outcome = outcome;
      current.settlement_state = 'pending_refund';
      this.records.set(this.key(record.quota_subject, record.request_id), current);
      Object.assign(record, current);
      return { kind: 'lease_expired', record: current, outcome };
    }
    current.state = 'dispatch_started';
    this.records.set(this.key(record.quota_subject, record.request_id), current);
    Object.assign(record, current);
    return { kind: 'started' };
  }

  async persistTerminal(
    record: StoredRequestRecord,
    outcome: BrokerTerminalOutcome,
    settlement: SettlementIntent,
  ): Promise<void> {
    await this.inject('terminal_persistence');
    const current = this.requireRecord(record);
    const ledger = parseLedgerRecord(
      this.ledgerRecords.get(this.key(record.quota_subject, record.request_id)),
    );
    if (ledger === undefined || !ledgerMatchesRequest(ledger, current)) {
      throw new Error('unsafe_terminal_transition');
    }
    if (current.state !== 'reserved' && current.state !== 'dispatch_started') {
      throw new Error('unsafe_terminal_transition');
    }
    const terminal: StoredRequestRecord = {
      ...current,
      state: 'terminal',
      terminal_outcome: outcome,
      settlement_state: settlement === 'refund' ? 'pending_refund' : 'pending_finalize',
    };
    if (parseStoredRequest(terminal).kind !== 'valid') {
      throw new Error('unsafe_terminal_outcome');
    }
    this.records.set(this.key(record.quota_subject, record.request_id), terminal);
    Object.assign(record, terminal);
  }

  async settle(record: StoredRequestRecord): Promise<void> {
    const current = this.requireRecord(record);
    if (current.state !== 'terminal') {
      throw new Error('settlement_requires_terminal');
    }
    const key = this.key(record.quota_subject, record.request_id);
    const ledger = parseLedgerRecord(this.ledgerRecords.get(key));
    if (ledger === undefined || !ledgerMatchesRequest(ledger, current)) {
      throw new Error('unsafe_ledger_record');
    }
    if (current.settlement_state === 'refunded' || current.settlement_state === 'finalized') {
      Object.assign(record, current);
      return;
    }

    const intent = current.settlement_state === 'pending_refund' ? 'refund' : 'finalize';
    await this.inject(intent);
    if (ledger.state !== 'reserved') {
      throw new Error('unsafe_ledger_record');
    }
    ledger.state = intent === 'refund' ? 'refunded' : 'finalized';
    if (intent === 'refund') {
      ledger.reason = current.terminal_outcome?.kind === 'error'
        ? current.terminal_outcome.failure.condition
        : 'terminal_refund';
    }
    current.settlement_state = intent === 'refund' ? 'refunded' : 'finalized';
    this.ledgerRecords.set(key, ledger);
    this.records.set(key, current);
    Object.assign(record, current);
  }

  private requireRecord(record: StoredRequestRecord): StoredRequestRecord {
    const parsed = parseStoredRequest(this.records.get(this.key(record.quota_subject, record.request_id)));
    if (
      parsed.kind !== 'valid' ||
      !storedRequestMatchesKey(parsed.record, record.quota_subject, record.request_id)
    ) {
      throw new Error('unsafe_request_record');
    }
    return parsed.record;
  }

  private async inject(point: LifecycleFaultPoint): Promise<void> {
    await this.faults[point]?.();
  }

  private key(quotaSubject: string, requestId: string): string {
    return `${quotaSubject}|${requestId}`;
  }
}

function isReservationExpiry(record: StoredRequestRecord): boolean {
  return record.terminal_outcome?.kind === 'error' &&
    record.terminal_outcome.failure.condition === 'reservation_lease_expired';
}

function reservationExpiredOutcome(requestId: string): BrokerTerminalOutcome {
  return {
    kind: 'error',
    failure: {
      request_id: requestId,
      condition: 'reservation_lease_expired',
    },
  };
}
