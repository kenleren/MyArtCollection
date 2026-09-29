import type { DispatchCapability } from './dispatch_gate.js';
import { BILLING_DATABASE_ID, PACKAGE_NAME } from './constants.js';
import { fingerprint } from './account_authority.js';
import { BillingDeadline } from './deadline.js';
import {KmsConfigurationError, type KmsTransport } from './kms_token_custody.js';
import { crc32c, validBase64, validKeyVersion, validToken } from './token_custody.js';
import { EVENT_CUSTODY_VERSION, EventWorkError, record, validEventEnvelope, type EventEnvelope } from './event_records.js';

export interface EventTokenContext { eventFingerprint:string; payloadDigest:string; tokenFingerprint:string }
export interface EventTokenCustody {
  encrypt(token:string, context:EventTokenContext, deadline:BillingDeadline, dispatch?:DispatchCapability):Promise<EventEnvelope>;
  decrypt(envelope:EventEnvelope, context:EventTokenContext, deadline:BillingDeadline, dispatch?:DispatchCapability):Promise<string>;
}
export function eventCustodyAad(context:EventTokenContext, keyVersion:string):Buffer {
  if(!fingerprint(context.eventFingerprint)||!fingerprint(context.payloadDigest)||!fingerprint(context.tokenFingerprint)||!validKeyVersion(keyVersion)) throw new EventWorkError('unsafe');
  return Buffer.from(JSON.stringify([EVENT_CUSTODY_VERSION,PACKAGE_NAME,BILLING_DATABASE_ID,context.eventFingerprint,context.payloadDigest,context.tokenFingerprint,keyVersion]),'utf8');
}
/** Same reviewed KMS transport; distinct ciphertext purpose, envelope and AAD. */
export class KmsEventTokenCustody implements EventTokenCustody {
  private readonly retained:ReadonlySet<string>;
  constructor(private readonly encryptionVersion:string, retainedVersions:readonly string[], private readonly transport:KmsTransport) {
    if(!validKeyVersion(encryptionVersion)||retainedVersions.length<1||retainedVersions.length>8||!retainedVersions.includes(encryptionVersion)||retainedVersions.some(v=>!validKeyVersion(v))) throw new EventWorkError('configuration');
    this.retained=new Set(retainedVersions);
  }
  async encrypt(token:string, context:EventTokenContext, deadline:BillingDeadline, dispatch?:DispatchCapability):Promise<EventEnvelope> {
    try {
      if(!validToken(token)) throw new EventWorkError('unsafe');
      const bytes=Buffer.from(token,'utf8'); const aad=eventCustodyAad(context,this.encryptionVersion);
      const value=await deadline.run(()=>this.transport.request(this.encryptionVersion,'encrypt',{
        plaintext:bytes.toString('base64'),additionalAuthenticatedData:aad.toString('base64'),
        plaintextCrc32c:crc32c(bytes),additionalAuthenticatedDataCrc32c:crc32c(aad),
      },deadline,dispatch));
      if(!record(value)||value.name!==this.encryptionVersion||value.verifiedPlaintextCrc32c!==true||value.verifiedAdditionalAuthenticatedDataCrc32c!==true||
          typeof value.ciphertext!=='string'||!validBase64(value.ciphertext,8192)||crc32c(Buffer.from(value.ciphertext,'base64'))!==value.ciphertextCrc32c) throw new EventWorkError('transient');
      return {version:EVENT_CUSTODY_VERSION,keyVersion:this.encryptionVersion,ciphertext:value.ciphertext};
    } catch(error) { throw new EventWorkError(error instanceof KmsConfigurationError ? 'configuration' : error instanceof EventWorkError ? error.reason : 'transient'); }
  }
  async decrypt(envelope:EventEnvelope, context:EventTokenContext, deadline:BillingDeadline, dispatch?:DispatchCapability):Promise<string> {
    try {
      if(!validEventEnvelope(envelope)||!this.retained.has(envelope.keyVersion)) throw new EventWorkError('unsafe');
      const aad=eventCustodyAad(context,envelope.keyVersion);
      const value=await deadline.run(()=>this.transport.request(envelope.keyVersion.slice(0,envelope.keyVersion.lastIndexOf('/cryptoKeyVersions/')),'decrypt',{
        ciphertext:envelope.ciphertext,additionalAuthenticatedData:aad.toString('base64'),
        ciphertextCrc32c:crc32c(Buffer.from(envelope.ciphertext,'base64')),additionalAuthenticatedDataCrc32c:crc32c(aad),
      },deadline,dispatch));
      if(!record(value)||typeof value.plaintext!=='string'||!validBase64(value.plaintext,5464)) throw new EventWorkError('transient');
      const bytes=Buffer.from(value.plaintext,'base64'); const token=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
      if(crc32c(bytes)!==value.plaintextCrc32c||!validToken(token)) throw new EventWorkError('transient');
      return token;
    } catch(error) { throw new EventWorkError(error instanceof KmsConfigurationError ? 'configuration' : error instanceof EventWorkError ? error.reason : 'transient'); }
  }
}
