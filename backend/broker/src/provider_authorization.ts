import type { BrokerRequest } from './contracts.js';

const authorizedRequests = new WeakSet<BrokerRequest>();

export function authorizeProviderRequest(request: BrokerRequest): void {
  authorizedRequests.add(request);
}

export function consumeProviderRequestAuthorization(request: BrokerRequest): boolean {
  const authorized = authorizedRequests.has(request);
  if (authorized) {
    authorizedRequests.delete(request);
  }
  return authorized;
}
