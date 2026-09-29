/** Explicit synthetic provisioning and metering for existing fake-provider tests.
 * Never imported by source; actual Google transport boundaries have separate tests. */
import { COLLECTIONS } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import { DispatchGate, type DispatchCapability } from '../src/dispatch_gate.js';
import { configurationDigest, initialDispatchControls, type DispatchConfiguration } from '../src/dispatch_budget.js';
import { COST_KINDS, EVENT_CONTROL_VERSION, emptyCosts } from '../src/event_records.js';
import { custodyAad, crc32c, type TokenCustody, type TokenContext } from '../src/token_custody.js';
import { eventCustodyAad, type EventTokenCustody, type EventTokenContext } from '../src/event_token_custody.js';
import type { InMemoryBillingDatabase } from '../src/in_memory_store.js';
import type { PlaySubscriptionsAdapter } from '../src/contracts.js';
import { createBillingIdentifiers } from '../src/crypto.js';
import { TEST_KEY } from './fake_custody.js';
export function testDispatchConfig():DispatchConfiguration {
 const caps={get:120,ack:30,kms:60};const c={enabled:true,epoch:'c'.repeat(32),global:caps,sources:{foreground:caps,event:caps,reconciliation:caps}};
 return {...c,digest:configurationDigest(c)};
}
export function legacyControls(){return {marker:{version:EVENT_CONTROL_VERSION,totalRows:0,budgetRevision:0},capacity:{version:EVENT_CONTROL_VERSION,totalRows:0,admissionStarts:[]},budget:{version:EVENT_CONTROL_VERSION,revision:0,starts:Object.fromEntries(COST_KINDS.map(k=>[k,[]])),totals:emptyCosts(),circuit:false}};}
export function seedDispatch(db:InMemoryBillingDatabase,now:Date,config=testDispatchConfig()):void {
 const control=initialDispatchControls(config,now,'e'.repeat(64),{kind:'verified_new'});
 for(const [id,value] of Object.entries(control))db.setUnsafeRecordForTest(COLLECTIONS.dispatchControl,id,value);
 for(const [id,value] of Object.entries(legacyControls()))db.setUnsafeRecordForTest(COLLECTIONS.eventControl,id,value);
}
export function meteredPlay(gate:DispatchGate,play:PlaySubscriptionsAdapter):PlaySubscriptionsAdapter {
 return {getSubscription:async args=>{const ticket=await gate.reserve(args.dispatch!,gate.playDescriptor(args.dispatch,'play_get',args.token),args.deadline!);return gate.consume(ticket,()=>play.getSubscription(args));},
 acknowledgeSubscription:async args=>{const ticket=await gate.reserve(args.dispatch!,gate.playDescriptor(args.dispatch,'play_ack',args.token,args.subscriptionId,args.body),args.deadline!);return gate.consume(ticket,()=>play.acknowledgeSubscription(args));}};
}
export function meteredCustody<T extends TokenCustody|EventTokenCustody>(gate:DispatchGate,custody:T,purpose:'account'|'event'='account'):T {
 const invoke=async(action:'encrypt'|'decrypt',value:any,context:any,deadline:BillingDeadline,cap?:DispatchCapability)=>{
  const key=action==='encrypt'?TEST_KEY:value.keyVersion;
  const aad=purpose==='account'?custodyAad(context,key):eventCustodyAad(context,key);
  const bytes=Buffer.from(action==='encrypt'?value:value.ciphertext,action==='encrypt'?'utf8':'base64');
  const body:Record<string,string>=action==='encrypt'?{plaintext:bytes.toString('base64'),plaintextCrc32c:crc32c(bytes),additionalAuthenticatedData:aad.toString('base64'),additionalAuthenticatedDataCrc32c:crc32c(aad)}:
   {ciphertext:value.ciphertext,ciphertextCrc32c:crc32c(bytes),additionalAuthenticatedData:aad.toString('base64'),additionalAuthenticatedDataCrc32c:crc32c(aad)};
  const resource=action==='encrypt'?key:key.slice(0,key.lastIndexOf('/cryptoKeyVersions/'));
  const ticket=await gate.reserve(cap!,gate.kmsDescriptor(cap,resource,action,body),deadline);
  return gate.consume<unknown>(ticket,()=>action==='encrypt'?custody.encrypt(value,context,deadline,cap):custody.decrypt(value,context,deadline,cap));
 };
 return {encrypt:(v:any,c:any,d:BillingDeadline,cap?:DispatchCapability)=>invoke('encrypt',v,c,d,cap),decrypt:(v:any,c:any,d:BillingDeadline,cap?:DispatchCapability)=>invoke('decrypt',v,c,d,cap)} as unknown as T;
}
/** Protocol-only tests isolate body/status/deadline parsing from repository authority.
 * The fake gate is not available in production. */
export function protocolGate():DispatchGate {
 return {playDescriptor:()=>({}),kmsDescriptor:()=>({}),reserve:async()=>({}),consume:async(_t:unknown,send:()=>Promise<unknown>)=>send(),configurationFailure:async()=>{}} as unknown as DispatchGate;
}
export const protocolCapability:DispatchCapability={kind:'event_reserving',eventFingerprint:'e'.repeat(64),payloadDigest:'d'.repeat(64),tokenFingerprint:'b'.repeat(64),generation:1,nonce:'1'.repeat(32)};
