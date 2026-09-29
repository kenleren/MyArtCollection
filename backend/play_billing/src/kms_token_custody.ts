import { DispatchGate, authFailure, type DispatchCapability } from './dispatch_gate.js';
import { GoogleAuth } from 'google-auth-library';
import { BillingDeadline } from './deadline.js';
import {
  CUSTODY_VERSION, DisabledTokenCustody, crc32c, custodyAad, custodyUnavailable,
  validBase64, validEnvelope, validKeyVersion, validToken,
  type TokenContext, type TokenCustody, type TokenEnvelope,
} from './token_custody.js';

export class KmsConfigurationError extends Error { constructor(){super('token custody configuration unavailable');} }
export interface KmsTransport {
  request(resource: string, action: 'encrypt' | 'decrypt', body: Record<string, string>, deadline: BillingDeadline, dispatch?: DispatchCapability): Promise<unknown>;
}
interface KmsAuth { getClient(): Promise<{ getRequestHeaders(url: string): Promise<Headers> }> }
type KmsFetch = (url: string, init: RequestInit) => Promise<Response>;

/** Actual REST adapter. Constructed only by explicit enabled configuration. */
export class GoogleKmsTransport implements KmsTransport {
  private readonly auth: KmsAuth;
  constructor(private readonly options: { auth?: KmsAuth; fetch?: KmsFetch; gate?:DispatchGate } = {}) {
    if(!options.gate)throw new KmsConfigurationError();
    this.auth = options.auth ?? new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloudkms'] });
    this.fetch = options.fetch ?? fetch;
  }
  private readonly fetch: KmsFetch;
  async request(resource: string, action: 'encrypt' | 'decrypt', body: Record<string, string>, deadline: BillingDeadline, dispatch?: DispatchCapability): Promise<unknown> {
    const gate=this.options.gate!;
    const serializedBody=JSON.stringify(body);
    const descriptor=gate.kmsDescriptor(dispatch,resource,action,JSON.parse(serializedBody));
    const call = new BillingDeadline(Math.min(deadline.expiresAt, Date.now() + 10_000));
    const controller = new AbortController();
    const cancel = () => { call.cancel(); controller.abort(); };
    deadline.signal.addEventListener('abort',cancel,{once:true});
    const timer = setTimeout(() => controller.abort(), Math.max(0, call.expiresAt - Date.now()));
    let authStage=false;
    try {
      return await call.run(async () => {
        deadline.check();
        const url = `https://cloudkms.googleapis.com/v1/${resource}:${action}`;
        const ticket=await gate.reserve(dispatch!,descriptor,call);
        authStage=true;
        const client = await this.auth.getClient();
        call.check(); deadline.check();
        const headers = await client.getRequestHeaders(url);
        call.check(); deadline.check();
        if(!(headers instanceof Headers))throw new KmsConfigurationError();
        headers.set('content-type', 'application/json');
        authStage=false;
        const response = await gate.consume(ticket,()=>this.fetch(url, {
          method: 'POST', headers, body: serializedBody, signal: controller.signal,
          redirect: 'error',
        }));
        if(response.status===401 || response.status===403) {await response.body?.cancel();throw new KmsConfigurationError();}
        if (!response.ok || response.body === null) {await response.body?.cancel();throw custodyUnavailable();}
        const reader = response.body.getReader();
        const chunks: Uint8Array[] = [];
        let count = 0;
        try {
          while (true) {
            call.check(); deadline.check();
            const next = await reader.read();
            if (next.done) break;
            count += next.value.length;
            if (count > 32 * 1024) throw custodyUnavailable();
            chunks.push(next.value);
          }
        } finally { await reader.cancel(); }
        call.check(); deadline.check();
        return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
      });
    } catch(error) {
      const configuration=error instanceof KmsConfigurationError||(authStage&&!deadline.signal.aborted&&!call.signal.aborted&&Date.now()<call.expiresAt&&authFailure(error)==='configuration');
      if(configuration){await gate.configurationFailure(call);throw new KmsConfigurationError();}
      throw custodyUnavailable();
    }
    finally { clearTimeout(timer); deadline.signal.removeEventListener('abort',cancel); controller.abort(); }
  }
}
export class GoogleKmsTokenCustody implements TokenCustody {
  private readonly retained: ReadonlySet<string>;
  constructor(private readonly encryptionVersion: string, retainedVersions: readonly string[], private readonly transport: KmsTransport) {
    if (!validKeyVersion(encryptionVersion) || retainedVersions.length < 1 || retainedVersions.length > 8 ||
        retainedVersions.some((v) => !validKeyVersion(v)) || !retainedVersions.includes(encryptionVersion)) throw custodyUnavailable();
    this.retained = new Set(retainedVersions);
  }
  async encrypt(token: string, context: TokenContext, deadline: BillingDeadline, dispatch?: DispatchCapability): Promise<TokenEnvelope> {
    try {
      if (!validToken(token)) throw custodyUnavailable();
      const plaintext = Buffer.from(token, 'utf8');
      const aad = custodyAad(context, this.encryptionVersion);
      const raw = await deadline.run(() => this.transport.request(this.encryptionVersion, 'encrypt', {
        plaintext: plaintext.toString('base64'), additionalAuthenticatedData: aad.toString('base64'),
        plaintextCrc32c: crc32c(plaintext), additionalAuthenticatedDataCrc32c: crc32c(aad),
      }, deadline, dispatch));
      const value = record(raw);
      if (value.name !== this.encryptionVersion || value.verifiedPlaintextCrc32c !== true ||
          value.verifiedAdditionalAuthenticatedDataCrc32c !== true || typeof value.ciphertext !== 'string' ||
          !validBase64(value.ciphertext, 16_384) ||
          crc32c(Buffer.from(value.ciphertext, 'base64')) !== value.ciphertextCrc32c) throw custodyUnavailable();
      return { version: CUSTODY_VERSION, keyVersion: this.encryptionVersion, ciphertext: value.ciphertext };
    } catch(error) { throw error instanceof KmsConfigurationError ? error : custodyUnavailable(); }
  }
  async decrypt(envelope: TokenEnvelope, context: TokenContext, deadline: BillingDeadline, dispatch?: DispatchCapability): Promise<string> {
    try {
      if (!validEnvelope(envelope) || !this.retained.has(envelope.keyVersion)) throw custodyUnavailable();
      const aad = custodyAad(context, envelope.keyVersion);
      const raw = await deadline.run(() => this.transport.request(
        envelope.keyVersion.slice(0, envelope.keyVersion.lastIndexOf('/cryptoKeyVersions/')), 'decrypt', {
          ciphertext: envelope.ciphertext, additionalAuthenticatedData: aad.toString('base64'),
          ciphertextCrc32c: crc32c(Buffer.from(envelope.ciphertext, 'base64')),
          additionalAuthenticatedDataCrc32c: crc32c(aad),
        }, deadline, dispatch));
      const value = record(raw);
      if (typeof value.plaintext !== 'string' || !validBase64(value.plaintext, 5464)) throw custodyUnavailable();
      const bytes = Buffer.from(value.plaintext, 'base64');
      const token = bytes.toString('utf8');
      if (crc32c(bytes) !== value.plaintextCrc32c || !validToken(token) || !Buffer.from(token).equals(bytes)) throw custodyUnavailable();
      return token;
    } catch(error) { throw error instanceof KmsConfigurationError ? error : custodyUnavailable(); }
  }
}
function record(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw custodyUnavailable();
  return value as Record<string, unknown>;
}
export function createConfiguredTokenCustody(configuration: {
  enabled?: boolean; encryptionVersion?: string; retainedVersions?: readonly string[];
  transportFactory?: () => KmsTransport; gate?:DispatchGate;
} = {}): TokenCustody {
  if (configuration.enabled !== true || !configuration.gate || !validKeyVersion(configuration.encryptionVersion) ||
      configuration.retainedVersions === undefined || !configuration.retainedVersions.includes(configuration.encryptionVersion) ||
      configuration.retainedVersions.length > 8 || configuration.retainedVersions.some((v) => !validKeyVersion(v))) {
    return new DisabledTokenCustody();
  }
  return new GoogleKmsTokenCustody(configuration.encryptionVersion, configuration.retainedVersions,
    configuration.transportFactory?.() ?? new GoogleKmsTransport({gate:configuration.gate}));
}
