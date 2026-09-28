import { createHmac, randomBytes } from 'node:crypto';

import { ACTIVE_KEY_VERSION } from './constants.js';
import type { NonceSource } from './contracts.js';

export interface BillingIdentifiers {
  keyVersion: typeof ACTIVE_KEY_VERSION;
  accountSubject(uid: string): string;
  requestFingerprint(uid: string, requestId: string): string;
  tokenFingerprint(purchaseToken: string): string;
  routeFingerprint(obfuscatedAccountId: string): string;
  eventFingerprint(topic: string, messageId: string): string;
  eventOperationFingerprint(eventFingerprint: string, generation: number): string;
}

export function createBillingIdentifiers(key: Uint8Array): BillingIdentifiers {
  if (key.byteLength < 32) {
    throw new Error('billing fingerprint key is unavailable');
  }
  const hmac = (domain: string, value: string): string =>
    createHmac('sha256', key).update(`${domain}\n${value}`, 'utf8').digest('hex');
  return {
    keyVersion: ACTIVE_KEY_VERSION,
    accountSubject: (uid) => hmac('archivale-play-subject-v1', uid),
    requestFingerprint: (uid, requestId) =>
      hmac('archivale-play-request-v1', `${uid}\n${requestId}`),
    tokenFingerprint: (token) => hmac('archivale-play-token-v1', token),
    routeFingerprint: (route) => hmac('archivale-play-route-v1', route),
    eventFingerprint: (topic, id) => hmac('archivale-play-event-v1', `${topic}\n${id}`),
    eventOperationFingerprint: (event, generation) => hmac('archivale-play-event-operation-v1', `${event}\n${generation}`),
  };
}

export class CryptoNonceSource implements NonceSource {
  nextNonce(): Uint8Array {
    return randomBytes(16);
  }
}
