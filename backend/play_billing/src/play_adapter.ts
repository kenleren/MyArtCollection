import { createHash } from 'node:crypto';

import type {
  PlayAcknowledgeArguments,
  PlayGetArguments,
  PlaySubscriptionPurchase,
  PlaySubscriptionsAdapter,
} from './contracts.js';

export interface SanitizedPlayGetCall {
  packageName: PlayGetArguments['packageName'];
  timeoutMs: PlayGetArguments['timeoutMs'];
}

export interface SanitizedPlayAcknowledgeCall {
  packageName: PlayAcknowledgeArguments['packageName'];
  subscriptionId: PlayAcknowledgeArguments['subscriptionId'];
  body: Record<string, never>;
  timeoutMs: PlayAcknowledgeArguments['timeoutMs'];
}

export class DisabledPlaySubscriptionsAdapter implements PlaySubscriptionsAdapter {
  async getSubscription(_args: PlayGetArguments): Promise<PlaySubscriptionPurchase> {
    throw new Error('play adapter is disabled');
  }

  async acknowledgeSubscription(_args: PlayAcknowledgeArguments): Promise<void> {
    throw new Error('play adapter is disabled');
  }
}

export class FakePlaySubscriptionsAdapter implements PlaySubscriptionsAdapter {
  readonly getCalls: SanitizedPlayGetCall[] = [];
  readonly acknowledgeCalls: SanitizedPlayAcknowledgeCall[] = [];
  private readonly purchases = new Map<string, PlaySubscriptionPurchase>();
  getError?: Error;
  acknowledgeError?: Error;
  beforeGet?: (args: PlayGetArguments) => Promise<void>;
  beforeAcknowledge?: (args: PlayAcknowledgeArguments) => Promise<void>;

  setPurchase(token: string, purchase: PlaySubscriptionPurchase): void {
    this.purchases.set(fakeLookupKey(token), structuredClone(purchase));
  }

  async getSubscription(args: PlayGetArguments): Promise<PlaySubscriptionPurchase> {
    this.getCalls.push({ packageName: args.packageName, timeoutMs: args.timeoutMs });
    await this.beforeGet?.(args);
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const purchase = this.purchases.get(fakeLookupKey(args.token));
    if (purchase === undefined) {
      throw new Error('fake purchase unavailable');
    }
    return structuredClone(purchase);
  }

  async acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<void> {
    this.acknowledgeCalls.push({
      packageName: args.packageName,
      subscriptionId: args.subscriptionId,
      body: {},
      timeoutMs: args.timeoutMs,
    });
    await this.beforeAcknowledge?.(args);
    if (this.acknowledgeError !== undefined) {
      throw this.acknowledgeError;
    }
  }
}

function fakeLookupKey(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}
