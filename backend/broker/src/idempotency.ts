import type { BrokerResponse } from './contracts.js';

interface StoredRequest {
  payloadHash: string;
  response: BrokerResponse;
}

export class InMemoryIdempotencyStore {
  private readonly requests = new Map<string, StoredRequest>();

  get(requestId: string): StoredRequest | undefined {
    return this.requests.get(requestId);
  }

  set(requestId: string, payloadHash: string, response: BrokerResponse): void {
    this.requests.set(requestId, { payloadHash, response });
  }
}
