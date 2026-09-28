import { validLifecycleFields, type LifecycleFields } from './lifecycle.js';
import { BILLING_DATABASE_ID, PACKAGE_NAME } from './constants.js';
import type { BillingDeadline } from './deadline.js';

export const CUSTODY_VERSION = 'play-token-custody-v2';
export const MAX_TOKEN_BYTES = 4096;
export interface TokenContext extends LifecycleFields { accountSubject: string; tokenFingerprint: string }
export interface TokenEnvelope {
  version: typeof CUSTODY_VERSION;
  keyVersion: string;
  ciphertext: string;
}
export interface TokenCustody {
  encrypt(token: string, context: TokenContext, deadline: BillingDeadline): Promise<TokenEnvelope>;
  decrypt(envelope: TokenEnvelope, context: TokenContext, deadline: BillingDeadline): Promise<string>;
}
export class DisabledTokenCustody implements TokenCustody {
  async encrypt(): Promise<TokenEnvelope> { throw custodyUnavailable(); }
  async decrypt(): Promise<string> { throw custodyUnavailable(); }
}
export function custodyUnavailable(): Error { return new Error('token custody unavailable'); }
export function validKeyVersion(value: unknown): value is string {
  return typeof value === 'string' && value.length <= 1024 &&
    /^projects\/[a-z][a-z0-9-]{4,61}[a-z0-9]\/locations\/[a-z0-9-]+\/keyRings\/[A-Za-z0-9_-]+\/cryptoKeys\/[A-Za-z0-9_-]+\/cryptoKeyVersions\/[1-9][0-9]*$/.test(value);
}
export function validEnvelope(value: unknown): value is TokenEnvelope {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return Object.keys(record).length === 3 && record.version === CUSTODY_VERSION &&
    validKeyVersion(record.keyVersion) && typeof record.ciphertext === 'string' &&
    validBase64(record.ciphertext, 16_384);
}
export function validToken(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= MAX_TOKEN_BYTES && Buffer.from(value, 'utf8').toString('utf8') === value;
}
export function validBase64(value: string, maximum: number): boolean {
  return value.length > 0 && value.length <= maximum &&
    /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value) &&
    Buffer.from(value, 'base64').toString('base64') === value;
}
export function custodyAad(context: TokenContext, keyVersion: string): Buffer {
  if (!validLifecycleFields(context) || !/^[a-f0-9]{64}$/.test(context.accountSubject) ||
      !/^[a-f0-9]{64}$/.test(context.tokenFingerprint) || !validKeyVersion(keyVersion)) {
    throw custodyUnavailable();
  }
  return Buffer.from(JSON.stringify([
    CUSTODY_VERSION, PACKAGE_NAME, BILLING_DATABASE_ID,
    context.accountSubject, context.lifecycleEpoch, String(context.lifecycleGeneration), context.tokenFingerprint, keyVersion,
  ]), 'utf8');
}
/** CRC32C is KMS transport integrity, not encryption or authentication. */
export function crc32c(bytes: Uint8Array): string {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0x82f63b78 : 0);
  }
  return String((crc ^ 0xffffffff) >>> 0);
}
