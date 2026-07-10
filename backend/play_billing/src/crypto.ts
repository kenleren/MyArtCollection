import { createHash, createHmac, randomBytes } from 'node:crypto';

import { ACTIVE_KEY_VERSION } from './constants.js';
import type { NonceSource } from './contracts.js';

export interface BillingIdentifiers {
  keyVersion: typeof ACTIVE_KEY_VERSION;
  accountSubject(uid: string): string;
  requestFingerprint(uid: string, requestId: string): string;
  tokenFingerprint(purchaseToken: string): string;
  obfuscatedAccountId(uid: string): string;
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
    obfuscatedAccountId: (uid) =>
      createHash('sha256')
        .update(`archivale-play-account-v1\n${uid}`, 'utf8')
        .digest('base64url'),
  };
}

export class CryptoNonceSource implements NonceSource {
  nextNonce(): Uint8Array {
    return randomBytes(16);
  }
}
