import type { BrokerResponse } from './contracts.js';

export interface StoredRequest {
  payloadHash: string;
  requestId?: string;
  quotaSubject?: string;
  response?: BrokerResponse;
  inFlight?: Promise<BrokerResponse>;
  durableInFlight?: boolean;
  created?: boolean;
}

export type MaybePromise<T> = T | Promise<T>;

export interface BrokerIdempotencyStore {
  get(quotaSubject: string, requestId: string): MaybePromise<StoredRequest | undefined>;
  begin(quotaSubject: string, requestId: string, payloadHash: string): MaybePromise<StoredRequest>;
  setInFlight(entry: StoredRequest, inFlight: Promise<BrokerResponse>): MaybePromise<void>;
  complete(entry: StoredRequest, response: BrokerResponse): MaybePromise<void>;
  forget(quotaSubject: string, requestId: string): MaybePromise<void>;
}

export class InMemoryIdempotencyStore implements BrokerIdempotencyStore {
  private readonly requests = new Map<string, StoredRequest>();

  get(quotaSubject: string, requestId: string): StoredRequest | undefined {
    return this.requests.get(this.key(quotaSubject, requestId));
  }

  begin(quotaSubject: string, requestId: string, payloadHash: string): StoredRequest {
    const existing = this.requests.get(this.key(quotaSubject, requestId));
    if (existing !== undefined) {
      existing.created = false;
      return existing;
    }
    const entry: StoredRequest = { payloadHash, quotaSubject, requestId, created: true };
    this.requests.set(this.key(quotaSubject, requestId), entry);
    return entry;
  }

  setInFlight(entry: StoredRequest, inFlight: Promise<BrokerResponse>): void {
    entry.inFlight = inFlight;
  }

  complete(entry: StoredRequest, response: BrokerResponse): void {
    entry.response = response;
    entry.inFlight = undefined;
  }

  forget(quotaSubject: string, requestId: string): void {
    this.requests.delete(this.key(quotaSubject, requestId));
  }

  private key(quotaSubject: string, requestId: string): string {
    return `${quotaSubject}|${requestId}`;
  }
}
