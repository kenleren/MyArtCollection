import { randomBytes } from 'node:crypto';
import { fingerprint, counter } from './account_authority.js';
import { validOpaqueRoute } from './lifecycle.js';
import { PACKAGE_NAME, BILLING_DATABASE_ID, PRODUCT_ALLOWLIST } from './constants.js';
import { BillingDeadline } from './deadline.js';
import type { BillingIdentifiers } from './crypto.js';
import type { AttemptHandle } from './store.js';
import type { EventWorkRecord } from './event_records.js';
import { shape } from './event_records.js';
import { CUSTODY_VERSION, validKeyVersion, type TokenEnvelope } from './token_custody.js';
import { EVENT_CUSTODY_VERSION } from './event_records.js';
import { DispatchError, digest, type DispatchAction, type DispatchConfiguration, type DispatchSource } from './dispatch_budget.js';

export type DispatchPhase = 'lookup_in_flight'|'verified_owner'|'ack_in_progress';
export type DispatchCapability =
  | Readonly<{kind:'account_selected'|'account_auxiliary_current';attempt:string;tokenFingerprint:string;phase:DispatchPhase;envelopeDigest?:string}>
  | Readonly<{kind:'event_reserving'|'event_discovery';eventFingerprint:string;generation:number;nonce:string;payloadDigest:string;tokenFingerprint:string;envelopeDigest?:string;resolved?:string}>;
export interface DispatchDescriptor {
  readonly action:DispatchAction;readonly tokenFingerprint:string;readonly purpose:'subscription'|'account'|'event';
  readonly product?:string;readonly bodyDigest?:string;readonly keyVersion?:string;readonly resource?:string;readonly aadDigest?:string;
  readonly envelopeDigest?:string;
}
export interface DispatchReservation {revision:number;expiresAt:number;source:DispatchSource}
export interface DispatchRepository {
  dispatch(capability:DispatchCapability,descriptor:DispatchDescriptor,config:DispatchConfiguration,deadline:BillingDeadline,minimumRevision?:number):Promise<DispatchReservation>;
  openDispatchCircuit(config:DispatchConfiguration,deadline:BillingDeadline):Promise<void>;
}
function plain<T>(value:T):T {
  if(value && typeof value==='object'){if(Array.isArray(value))value.forEach(plain);else for(const v of Object.values(value))plain(v);Object.freeze(value);}return value;
}
function nonce(value:Uint8Array):string {if(!(value instanceof Uint8Array)||value.length!==16)throw new DispatchError();return Buffer.from(value).toString('hex');}
function validCapability(cap:DispatchCapability):boolean {
  if(!cap||!fingerprint(cap.tokenFingerprint))return false;
  if('attempt'in cap){
    if(!shape(cap,['kind','attempt','tokenFingerprint','phase'],['envelopeDigest'])||!['account_selected','account_auxiliary_current'].includes(cap.kind)||
      !['lookup_in_flight','verified_owner','ack_in_progress'].includes(cap.phase)||typeof cap.attempt!=='string'||Buffer.byteLength(cap.attempt)>8192||
      (cap.envelopeDigest!==undefined&&!fingerprint(cap.envelopeDigest)))return false;
    let a:any;try{a=JSON.parse(cap.attempt);}catch{return false;}
    if(!shape(a,['expectedPlayAccountId','tokenFingerprint','accountSubject','lifecycleEpoch','lifecycleGeneration','usesReplay','owner','fence'])||
      !validOpaqueRoute(a.expectedPlayAccountId)||!fingerprint(a.tokenFingerprint)||!fingerprint(a.accountSubject)||!/^[a-f0-9]{32}$/.test(a.lifecycleEpoch)||!counter(a.lifecycleGeneration)||a.lifecycleGeneration<1||typeof a.usesReplay!=='boolean'||
      !shape(a.owner,['requestFingerprint','attemptGeneration','attemptNonce'])||!fingerprint(a.owner.requestFingerprint)||!counter(a.owner.attemptGeneration)||a.owner.attemptGeneration<1||!/^[a-f0-9]{32}$/.test(a.owner.attemptNonce)||
      !shape(a.fence,['assertionId','indexRevision','kind','observationGeneration','observationNonce','source','publicationRevision'],['work'])||!/^[a-f0-9]{32}$/.test(a.fence.assertionId)||
      ![a.fence.indexRevision,a.fence.observationGeneration,a.fence.publicationRevision].every(counter)||!/^[a-f0-9]{32}$/.test(a.fence.observationNonce)||!['verify','restore'].includes(a.fence.kind)||!['foreground','background'].includes(a.fence.source))return false;
    const w=a.fence.work;
    if(w!==undefined){if(!shape(w,['kind','fence']))return false;
      if(w.kind==='event'){if(!shape(w.fence,['eventFingerprint','generation','nonce'])||!fingerprint(w.fence.eventFingerprint)||!counter(w.fence.generation)||!/^[a-f0-9]{32}$/.test(w.fence.nonce))return false;}
      else if(w.kind==='reconciliation'){if(!shape(w.fence,['accountSubject','assertionId','lifecycleEpoch','lifecycleGeneration','scheduleRevision','ownerGeneration','nonce','selectedDemand'])||
        !fingerprint(w.fence.accountSubject)||!/^([a-f0-9]{32})$/.test(w.fence.assertionId)||!/^([a-f0-9]{32})$/.test(w.fence.lifecycleEpoch)||!/^([a-f0-9]{32})$/.test(w.fence.nonce)||
        ![w.fence.lifecycleGeneration,w.fence.scheduleRevision,w.fence.ownerGeneration].every(counter)||!shape(w.fence.selectedDemand,['kind','tokenFingerprint','demandRevision','indexRevision'])||!['ack','candidate','current'].includes(w.fence.selectedDemand.kind)||
        !fingerprint(w.fence.selectedDemand.tokenFingerprint)||![w.fence.selectedDemand.demandRevision,w.fence.selectedDemand.indexRevision].every(counter))return false;}
      else return false;
    }
    return (a.fence.source==='foreground')===(!w);
  }
  return shape(cap,['kind','eventFingerprint','generation','nonce','payloadDigest','tokenFingerprint'],['envelopeDigest','resolved'])&&['event_reserving','event_discovery'].includes(cap.kind)&&fingerprint(cap.eventFingerprint)&&
    fingerprint(cap.payloadDigest)&&counter(cap.generation)&&cap.generation>0&&/^[a-f0-9]{32}$/.test(cap.nonce)&&
    (cap.envelopeDigest===undefined||fingerprint(cap.envelopeDigest))&&(cap.resolved===undefined||(typeof cap.resolved==='string'&&cap.resolved.length<=512&&(()=>{try{const r=JSON.parse(cap.resolved!);return shape(r,['accountSubject','lifecycleEpoch','lifecycleGeneration'])&&fingerprint(r.accountSubject)&&/^[a-f0-9]{32}$/.test(r.lifecycleEpoch)&&counter(r.lifecycleGeneration)&&r.lifecycleGeneration>0;}catch{return false;}})()));
}
function validDescriptor(d:DispatchDescriptor):boolean {
  if(!d||!fingerprint(d.tokenFingerprint))return false;
  if(d.action==='play_get')return shape(d,['action','tokenFingerprint','purpose'])&&d.purpose==='subscription';
  if(d.action==='play_ack')return shape(d,['action','tokenFingerprint','purpose','product','bodyDigest'])&&d.purpose==='subscription'&&typeof d.product==='string'&&Object.hasOwn(PRODUCT_ALLOWLIST,d.product)&&fingerprint(d.bodyDigest);
  return ['kms_encrypt','kms_decrypt'].includes(d.action)&&shape(d,['action','tokenFingerprint','purpose','keyVersion','resource','aadDigest','bodyDigest'],d.action==='kms_decrypt'?['envelopeDigest']:[])&&
    ['account','event'].includes(d.purpose)&&validKeyVersion(d.keyVersion)&&typeof d.resource==='string'&&d.resource.length<=1024&&fingerprint(d.aadDigest)&&fingerprint(d.bodyDigest)&&(d.action!=='kms_decrypt'||fingerprint(d.envelopeDigest));
}
export function accountDispatch(attempt:AttemptHandle,phase:DispatchPhase,auxiliary?:{tokenFingerprint:string;tokenEnvelope:TokenEnvelope}):DispatchCapability {
  if(!attempt.fence||attempt.completedObservation)throw new DispatchError();
  const {deadline:_,work,...f}=attempt.fence;
  let workSnapshot:unknown;
  if(work?.kind==='event')workSnapshot={kind:work.kind,fence:{eventFingerprint:work.fence.eventFingerprint,generation:work.fence.generation,nonce:nonce(work.fence.nonce)}};
  if(work?.kind==='reconciliation')workSnapshot={kind:work.kind,fence:{...work.fence,nonce:nonce(work.fence.nonce),selectedDemand:{...work.fence.selectedDemand}}};
  const snapshot={expectedPlayAccountId:attempt.expectedPlayAccountId,tokenFingerprint:attempt.tokenFingerprint,accountSubject:attempt.accountSubject,
    lifecycleEpoch:attempt.lifecycleEpoch,lifecycleGeneration:attempt.lifecycleGeneration,usesReplay:attempt.usesReplay,
    owner:{...attempt.owner,attemptNonce:nonce(attempt.owner.attemptNonce)},fence:{...f,observationNonce:nonce(f.observationNonce),...(workSnapshot?{work:workSnapshot}:{})}};
  const envelope=auxiliary?.tokenEnvelope??attempt.envelope;
  return plain({kind:auxiliary?'account_auxiliary_current':'account_selected',attempt:JSON.stringify(snapshot),phase,
    tokenFingerprint:auxiliary?.tokenFingerprint??attempt.tokenFingerprint,...(envelope?{envelopeDigest:digest(envelope)}:{})});
}
export function attemptFrom(cap:Extract<DispatchCapability,{attempt:string}>,deadline:BillingDeadline):AttemptHandle {
  if(typeof cap.attempt!=='string'||Buffer.byteLength(cap.attempt)>8192)throw new DispatchError();
  const a=JSON.parse(cap.attempt, (key,value)=>['attemptNonce','observationNonce','nonce'].includes(key)?
    typeof value==='string'&&/^[a-f0-9]{32}$/.test(value)?Buffer.from(value,'hex'):undefined:value) as AttemptHandle;
  if(!a.fence||!a.owner||a.completedObservation||a.envelope)throw new DispatchError();a.fence.deadline=deadline;return a;
}
export function eventDispatch(work:EventWorkRecord,phase:'reserving'|'working'):DispatchCapability {
  if(!work.tokenFingerprint)throw new DispatchError();
  return plain({kind:phase==='reserving'?'event_reserving':'event_discovery',eventFingerprint:work.eventFingerprint,generation:work.generation,
    nonce:nonce(work.nonce),payloadDigest:work.payloadDigest,tokenFingerprint:work.tokenFingerprint,
    ...(work.envelope?{envelopeDigest:digest(work.envelope)}:{}),...(work.resolved?{resolved:JSON.stringify(work.resolved)}:{})});
}
export function eventFence(cap:Extract<DispatchCapability,{eventFingerprint:string}>){
  if(!/^[a-f0-9]{32}$/.test(cap.nonce))throw new DispatchError();return {eventFingerprint:cap.eventFingerprint,generation:cap.generation,nonce:Buffer.from(cap.nonce,'hex')};
}
export interface DispatchTicket {
  readonly id:string;readonly version:'billing-dispatch-ticket-v1';readonly epoch:string;readonly configDigest:string;
  readonly revision:number;readonly source:DispatchSource;readonly capability:DispatchCapability;readonly descriptor:DispatchDescriptor;readonly expiresAt:number;
}
interface TicketState {state:'fresh'|'checking'|'spent';deadline:BillingDeadline;signal:AbortSignal}
/** Process-local single-use tickets. Durable aggregate charge lives only in repository transactions. */
export class DispatchGate {
  private readonly tickets=new WeakMap<DispatchTicket,TicketState>();
  private poisoned=false;
  readonly config:DispatchConfiguration;
  constructor(private readonly repository:DispatchRepository,config:DispatchConfiguration,private readonly identifiers:Pick<BillingIdentifiers,'tokenFingerprint'>,private readonly now:()=>number=Date.now){this.config=plain(JSON.parse(JSON.stringify(config)));}
  playDescriptor(cap:DispatchCapability|undefined,action:'play_get'|'play_ack',token:string,product?:string,body?:unknown):DispatchDescriptor {
    if(!cap||this.identifiers.tokenFingerprint(token)!==cap.tokenFingerprint)throw new DispatchError();
    if(action==='play_ack'&&(!product||!Object.hasOwn(PRODUCT_ALLOWLIST,product)))throw new DispatchError();
    return plain({action,tokenFingerprint:cap.tokenFingerprint,purpose:'subscription',...(action==='play_ack'?{product,bodyDigest:digest(body)}:{})});
  }
  kmsDescriptor(cap:DispatchCapability|undefined,resource:string,action:'encrypt'|'decrypt',body:Record<string,string>):DispatchDescriptor {
    if(!cap||!shape(body,action==='encrypt'?['plaintext','additionalAuthenticatedData','plaintextCrc32c','additionalAuthenticatedDataCrc32c']:['ciphertext','additionalAuthenticatedData','ciphertextCrc32c','additionalAuthenticatedDataCrc32c']))throw new DispatchError();
    if(Object.values(body).some(v=>typeof v!=='string'||v.length>22_000)||body.additionalAuthenticatedData.length>4096)throw new DispatchError();
    const aad=Buffer.from(body.additionalAuthenticatedData,'base64');let fields:unknown;try{fields=JSON.parse(aad.toString('utf8'));}catch{throw new DispatchError();}
    const purpose=cap.kind.startsWith('account_')?'account':'event';
    const keyIndex=purpose==='account'?7:6, tokenIndex=keyIndex-1;
    if(!Array.isArray(fields)||fields.length!==keyIndex+1||fields[1]!==PACKAGE_NAME||fields[2]!==BILLING_DATABASE_ID||fields[tokenIndex]!==cap.tokenFingerprint||!validKeyVersion(fields[keyIndex]))throw new DispatchError();
    if(aad.toString('utf8')!==JSON.stringify(fields)||aad.toString('base64')!==body.additionalAuthenticatedData)throw new DispatchError();
    const keyVersion=fields[keyIndex] as string;
    return this.kmsDescriptorChecked(cap,resource,action,body,aad,fields,keyVersion,purpose);
  }
  private kmsDescriptorChecked(cap:DispatchCapability,resource:string,action:'encrypt'|'decrypt',body:Record<string,string>,aad:Buffer,fields:unknown[],keyVersion:string,purpose:'account'|'event'):DispatchDescriptor {
    if(resource!==(action==='encrypt'?keyVersion:keyVersion.slice(0,keyVersion.lastIndexOf('/cryptoKeyVersions/'))))throw new DispatchError();
    if('attempt'in cap){
      const a=attemptFrom(cap,new BillingDeadline(this.now()));
      if(fields[0]!==CUSTODY_VERSION||fields[3]!==a.accountSubject||fields[4]!==a.lifecycleEpoch||fields[5]!==String(a.lifecycleGeneration))throw new DispatchError();
    }else if(fields[0]!==EVENT_CUSTODY_VERSION||fields[3]!==cap.eventFingerprint||fields[4]!==cap.payloadDigest)throw new DispatchError();
    if(action==='encrypt'&&this.identifiers.tokenFingerprint(Buffer.from(body.plaintext,'base64').toString('utf8'))!==cap.tokenFingerprint)throw new DispatchError();
    const envelopeDigest=action==='decrypt'?digest({version:purpose==='account'?CUSTODY_VERSION:EVENT_CUSTODY_VERSION,keyVersion,ciphertext:body.ciphertext}):undefined;
    if(action==='decrypt'&&envelopeDigest!==cap.envelopeDigest)throw new DispatchError();
    return plain({action:`kms_${action}`,purpose,tokenFingerprint:cap.tokenFingerprint,keyVersion,resource,aadDigest:digest(aad.toString('base64')),bodyDigest:digest(body),...(envelopeDigest?{envelopeDigest}:{})});
  }
  async reserve(cap:DispatchCapability,descriptor:DispatchDescriptor,parent:{expiresAt:number;signal:AbortSignal}):Promise<DispatchTicket> {
    if(this.poisoned)throw new DispatchError('configuration');
    if(!validCapability(cap)||!validDescriptor(descriptor)||descriptor.tokenFingerprint!==cap.tokenFingerprint)throw new DispatchError();
    const immutableCap=plain(JSON.parse(JSON.stringify(cap))) as DispatchCapability;
    const immutableDescriptor=plain(JSON.parse(JSON.stringify(descriptor))) as DispatchDescriptor;
    const deadline=new BillingDeadline(Math.min(parent.expiresAt,this.now()+10_000));
    const cancel=()=>deadline.cancel();if(parent.signal.aborted)cancel();else parent.signal.addEventListener('abort',cancel,{once:true});
    try{
      deadline.check();const r=await deadline.run(()=>this.repository.dispatch(immutableCap,immutableDescriptor,this.config,deadline));deadline.check();
      const ticket=plain({id:randomBytes(16).toString('hex'),version:'billing-dispatch-ticket-v1' as const,epoch:this.config.epoch,configDigest:this.config.digest,
        revision:r.revision,source:r.source,capability:immutableCap,descriptor:immutableDescriptor,expiresAt:Math.min(deadline.expiresAt,r.expiresAt)});
      if(this.now()>=ticket.expiresAt)throw new DispatchError('stale');
      this.tickets.set(ticket,{state:'fresh',deadline,signal:parent.signal});return ticket;
    }finally{parent.signal.removeEventListener('abort',cancel);}
  }
  async consume<T>(ticket:DispatchTicket,fetch:()=>Promise<T>):Promise<T> {
    const state=this.tickets.get(ticket);if(!state||state.state!=='fresh')throw new DispatchError('stale');state.state='checking';
    const cancel=()=>state.deadline.cancel();
    if(state.signal.aborted)cancel();else state.signal.addEventListener('abort',cancel,{once:true});
    try{
      this.check(ticket,state);
      const validated=await state.deadline.run(()=>this.repository.dispatch(ticket.capability,ticket.descriptor,this.config,state.deadline,ticket.revision));
      state.state='spent';this.check(ticket,state);if(this.now()>=validated.expiresAt)throw new DispatchError('stale');
      return fetch(); // no await between the final clock/owner fence and physical dispatch
    }finally{state.state='spent';state.signal.removeEventListener('abort',cancel);}
  }
  private check(ticket:DispatchTicket,state:TicketState):void {state.deadline.check();if(this.poisoned||state.signal.aborted||this.now()>=ticket.expiresAt)throw new DispatchError('stale');}
  async configurationFailure(deadline:BillingDeadline):Promise<void>{this.poisoned=true;await deadline.run(()=>this.repository.openDispatchCircuit(this.config,deadline)).catch(()=>undefined);}
}
/** Never inspect SDK messages, paths, payloads or headers for diagnosis. */
export function authFailure(error:unknown):'configuration'|'transient' {
  const e=error as {code?:unknown;status?:unknown;response?:{status?:unknown}}|undefined;
  const status=e?.status??e?.response?.status;
  if([408,409,429].includes(status as number)||(typeof status==='number'&&status>=500&&status<=599)||
    ['ETIMEDOUT','ECONNRESET','ECONNREFUSED','EAI_AGAIN','ENOTFOUND'].includes(e?.code as string))return 'transient';
  return 'configuration';
}
