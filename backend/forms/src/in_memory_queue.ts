import type { BetaSignupQueue, BetaSignupQueueRecord } from "./contracts.js";

export type InMemoryBetaSignupQueueOptions = {
  duplicateWindowMs?: number;
  rateLimitWindowMs?: number;
};

export class InMemoryBetaSignupQueue implements BetaSignupQueue {
  readonly records: BetaSignupQueueRecord[] = [];
  private readonly duplicateWindowMs: number;
  private readonly rateLimitWindowMs: number;
  private readonly recentEmails = new Map<string, number>();
  private readonly recentSubmitters = new Map<string, number>();

  constructor(options: InMemoryBetaSignupQueueOptions = {}) {
    this.duplicateWindowMs = options.duplicateWindowMs ?? 30 * 24 * 60 * 60 * 1000;
    this.rateLimitWindowMs = options.rateLimitWindowMs ?? 15 * 60 * 1000;
  }

  async hasDuplicate(normalizedEmail: string, nowMs: number): Promise<boolean> {
    const lastSeenMs = this.recentEmails.get(normalizedEmail);
    return lastSeenMs !== undefined && nowMs - lastSeenMs < this.duplicateWindowMs;
  }

  async isRateLimited(
    submitterKey: string | undefined,
    nowMs: number,
  ): Promise<boolean> {
    if (!submitterKey) {
      return false;
    }
    const lastSeenMs = this.recentSubmitters.get(submitterKey);
    return lastSeenMs !== undefined && nowMs - lastSeenMs < this.rateLimitWindowMs;
  }

  async enqueue(record: BetaSignupQueueRecord, nowMs: number): Promise<void> {
    this.records.push(record);
    this.recentEmails.set(record.normalizedEmail, nowMs);
    if (record.requestMeta.submitterKey) {
      this.recentSubmitters.set(record.requestMeta.submitterKey, nowMs);
    }
  }
}

export function createInMemoryBetaSignupQueue(
  options: InMemoryBetaSignupQueueOptions = {},
): InMemoryBetaSignupQueue {
  return new InMemoryBetaSignupQueue(options);
}
