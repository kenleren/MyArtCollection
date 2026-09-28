// Synthetic KMS transport only. Never imported by production source.
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { GoogleKmsTokenCustody, type KmsTransport } from '../src/kms_token_custody.js';
import { crc32c } from '../src/token_custody.js';
export const TEST_KEY = 'projects/synthetic-billing/locations/us-central1/keyRings/testing/cryptoKeys/tokens/cryptoKeyVersions/1';
export class FakeKmsTransport implements KmsTransport {
  private readonly key = randomBytes(32);
  calls: ('encrypt' | 'decrypt')[] = [];
  beforeCall?: () => Promise<void>;
  fail = false;
  async request(resource: string, action: 'encrypt' | 'decrypt', body: Record<string, string>): Promise<unknown> {
    this.calls.push(action);
    await this.beforeCall?.();
    if (this.fail) throw new Error('synthetic custody failure');
    const aad = Buffer.from(body.additionalAuthenticatedData!, 'base64');
    if (action === 'encrypt') {
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', this.key, nonce);
      cipher.setAAD(aad);
      const data = Buffer.concat([cipher.update(Buffer.from(body.plaintext!, 'base64')), cipher.final()]);
      const encrypted = Buffer.concat([nonce, cipher.getAuthTag(), data]);
      return { name: resource, ciphertext: encrypted.toString('base64'), ciphertextCrc32c: crc32c(encrypted),
        verifiedPlaintextCrc32c: true, verifiedAdditionalAuthenticatedDataCrc32c: true };
    }
    const bytes = Buffer.from(body.ciphertext!, 'base64');
    const cipher = createDecipheriv('aes-256-gcm', this.key, bytes.subarray(0, 12));
    cipher.setAuthTag(bytes.subarray(12, 28)); cipher.setAAD(aad);
    const plaintext = Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]);
    return { plaintext: plaintext.toString('base64'), plaintextCrc32c: crc32c(plaintext) };
  }
}
export function testCustody(transport = new FakeKmsTransport()): GoogleKmsTokenCustody {
  return new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY], transport);
}

export const syntheticEnvelopeForRepositoryTests = { version: 'play-token-custody-v1' as const, keyVersion: TEST_KEY, ciphertext: Buffer.alloc(48, 7).toString('base64') };
