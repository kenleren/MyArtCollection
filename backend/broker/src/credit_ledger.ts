export type LedgerState = 'rejected-before-reserve' | 'reserved' | 'finalized' | 'refunded';

export interface LedgerRecord {
  requestId: string;
  quotaSubject: string;
  state: LedgerState;
  creditCost: number;
  reason?: string;
}

export interface ReserveCreditInput {
  requestId: string;
  quotaSubject: string;
  creditCost: number;
}

export interface ReserveCreditResult {
  ok: boolean;
  record: LedgerRecord;
  code?: 'quota_subject_monthly_cap_exceeded' | 'broker_monthly_cap_exceeded';
  message?: string;
}

export interface PlaceholderCreditLedgerOptions {
  perSubjectMonthlyCap?: number;
  brokerMonthlyCap?: number;
}

export class PlaceholderCreditLedger {
  readonly records: LedgerRecord[] = [];
  readonly perSubjectMonthlyCap: number;
  readonly brokerMonthlyCap: number;

  constructor(options: PlaceholderCreditLedgerOptions = {}) {
    this.perSubjectMonthlyCap = options.perSubjectMonthlyCap ?? 3;
    this.brokerMonthlyCap = options.brokerMonthlyCap ?? 100;
  }

  get reserveCount(): number {
    return this.records.filter((record) => record.state !== 'rejected-before-reserve').length;
  }

  get finalizeCount(): number {
    return this.records.filter((record) => record.state === 'finalized').length;
  }

  get refundCount(): number {
    return this.records.filter((record) => record.state === 'refunded').length;
  }

  get releaseCount(): number {
    return this.refundCount;
  }

  get spentCredits(): number {
    return this.records
      .filter((record) => record.state === 'finalized')
      .reduce((total, record) => total + record.creditCost, 0);
  }

  spentCreditsFor(quotaSubject: string): number {
    return this.records
      .filter((record) => record.state === 'finalized' && record.quotaSubject === quotaSubject)
      .reduce((total, record) => total + record.creditCost, 0);
  }

  reserve(input: ReserveCreditInput): ReserveCreditResult {
    const perSubjectProjected = this.spentCreditsFor(input.quotaSubject) + input.creditCost;
    if (perSubjectProjected > this.perSubjectMonthlyCap) {
      return this.rejectBeforeReserve(
        input,
        'quota_subject_monthly_cap_exceeded',
        'Quota subject monthly cap placeholder denied the request.',
      );
    }

    const brokerProjected = this.spentCredits + input.creditCost;
    if (brokerProjected > this.brokerMonthlyCap) {
      return this.rejectBeforeReserve(
        input,
        'broker_monthly_cap_exceeded',
        'Broker monthly cap placeholder denied the request.',
      );
    }

    const record: LedgerRecord = { ...input, state: 'reserved' };
    this.records.push(record);
    return { ok: true, record };
  }

  finalize(record: LedgerRecord): void {
    if (record.state === 'reserved') {
      record.state = 'finalized';
    }
  }

  refund(record: LedgerRecord, reason: string): void {
    if (record.state === 'reserved') {
      record.state = 'refunded';
      record.reason = reason;
    }
  }

  private rejectBeforeReserve(
    input: ReserveCreditInput,
    code: ReserveCreditResult['code'],
    message: string,
  ): ReserveCreditResult {
    const record: LedgerRecord = {
      ...input,
      state: 'rejected-before-reserve',
      reason: code,
    };
    this.records.push(record);
    return { ok: false, record, code, message };
  }
}
