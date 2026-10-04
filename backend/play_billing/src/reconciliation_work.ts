/** Source-only scheduling. No timers, credentials, provider clients or production policy. */
import { counter, fingerprint } from './account_authority.js';
import { sameLifecycle, validLifecycleFields, type LifecycleFields, type LifecycleRoot } from './lifecycle.js';
import type { EventWorkFence } from './event_records.js';
export const RECONCILE_VERSION = 'play-billing-reconcile-v1';
export interface ReconcilePolicy { activeMs: number; retryMs: number; maxRetryMs: number }
export function validPolicy(p: ReconcilePolicy): boolean {
  return shape(p,['activeMs','retryMs','maxRetryMs']) && Number.isSafeInteger(p.activeMs) && p.activeMs >= 60_000 && p.activeMs <= 86_400_000 &&
    Number.isSafeInteger(p.retryMs) && p.retryMs >= 15_000 && Number.isSafeInteger(p.maxRetryMs) && p.maxRetryMs >= p.retryMs && p.maxRetryMs <= 3_600_000;
}
export interface Demand { tokenFingerprint: string; demandRevision: number; dueAt: Date; lastObservedDemandRevision?: number }
export interface SelectedDemand { kind: 'ack'|'candidate'|'current'; tokenFingerprint: string; demandRevision: number; indexRevision: number }
export interface ReconcileFence extends LifecycleFields {
  accountSubject: string; assertionId: string; scheduleRevision: number; ownerGeneration: number; nonce: Uint8Array; selectedDemand: SelectedDemand;
}
export type InternalWork = {kind:'event'; fence:EventWorkFence} | {kind:'reconciliation'; fence:ReconcileFence};
export interface CompletedObservation extends ReconcileFence {
  requestFingerprint:string; observationGeneration:number; observationNonce:Uint8Array; publicationRevision:number; indexRevision:number;
  outcome:'paid'|'inactive'; reason?:string;
}
export interface ReconcileWork extends LifecycleFields {
  version: typeof RECONCILE_VERSION; accountSubject:string; assertionId:string;
  scheduleRevision:number; ownerGeneration:number;
  state:'idle'|'policy_blocked'|'ready'|'working'|'retry'|'blocked'|'retired'; dueAt:Date;
  observedPublicationRevision:number; lastSuccessfulVerificationAt?:Date;
  reason?:'consent'|'retired'|'retry'|'budget'; attemptStarts:Date[];
  dispatchTotals:{get:number;ack:number;kms:number};
  currentDemand?:Demand; candidateDemand?:Demand;
  selectedDemand?:SelectedDemand; nonce?:Uint8Array; leaseExpiresAt?:Date; completedObservation?:CompletedObservation;
}
export interface PointerIndex {revision:number;current?:string;candidate?:string}
export function increment(n:number):number { if (!counter(n) || n === Number.MAX_SAFE_INTEGER) throw new Error('billing reconciliation unsafe'); return n+1; }
export function shape(v:unknown, required:string[], optional:string[]=[]):boolean {
  return !!v && typeof v==='object' && !Array.isArray(v) && required.every(k=>Object.hasOwn(v,k)) && Object.keys(v).every(k=>required.includes(k)||optional.includes(k));
}
function date(v:unknown):v is Date{return v instanceof Date && Number.isFinite(v.getTime());}
function nonce(v:unknown):v is Uint8Array{return v instanceof Uint8Array&&v.byteLength===16;}
function demand(v:Demand):boolean{return shape(v,['tokenFingerprint','demandRevision','dueAt'],['lastObservedDemandRevision'])&&fingerprint(v.tokenFingerprint)&&counter(v.demandRevision)&&v.demandRevision>0&&date(v.dueAt)&&(v.lastObservedDemandRevision===undefined||(counter(v.lastObservedDemandRevision)&&v.lastObservedDemandRevision<=v.demandRevision));}
export function validSelected(v:SelectedDemand):boolean{return shape(v,['kind','tokenFingerprint','demandRevision','indexRevision'])&&['ack','current','candidate'].includes(v.kind)&&fingerprint(v.tokenFingerprint)&&counter(v.demandRevision)&&v.demandRevision>0&&counter(v.indexRevision);}
export function selectedEqual(a:SelectedDemand,b:SelectedDemand):boolean{return a.kind===b.kind&&a.tokenFingerprint===b.tokenFingerprint&&a.demandRevision===b.demandRevision&&a.indexRevision===b.indexRevision;}
export function bytesEqual(a:Uint8Array,b:Uint8Array):boolean{return a.byteLength===b.byteLength&&a.every((v,i)=>v===b[i]);}
export function validCompleted(v:CompletedObservation):boolean {
  return shape(v,['accountSubject','assertionId','lifecycleEpoch','lifecycleGeneration','scheduleRevision','ownerGeneration','nonce','selectedDemand','requestFingerprint','observationGeneration','observationNonce','publicationRevision','indexRevision','outcome'],['reason'])&&
    validLifecycleFields(v)&&fingerprint(v.accountSubject)&&/^[a-f0-9]{32}$/.test(v.assertionId)&&counter(v.scheduleRevision)&&counter(v.ownerGeneration)&&nonce(v.nonce)&&validSelected(v.selectedDemand)&&fingerprint(v.requestFingerprint)&&counter(v.observationGeneration)&&nonce(v.observationNonce)&&counter(v.publicationRevision)&&counter(v.indexRevision)&&
    ((v.outcome==='paid'&&v.reason===undefined)||(v.outcome==='inactive'&&['expired','on_hold','paused','revoked','pending'].includes(v.reason??'')));
}
export function validWork(w:ReconcileWork,root:LifecycleRoot):boolean {
  if (!shape(w,['version','accountSubject','assertionId','lifecycleEpoch','lifecycleGeneration','scheduleRevision','ownerGeneration','state','dueAt','observedPublicationRevision','attemptStarts','dispatchTotals'],['lastSuccessfulVerificationAt','reason','currentDemand','candidateDemand','selectedDemand','nonce','leaseExpiresAt','completedObservation'])||
    w.version!==RECONCILE_VERSION||w.accountSubject!==root.accountSubject||!sameLifecycle(w,root)||w.assertionId!==root.assertionId||root.reconcileVersion!==RECONCILE_VERSION||root.reconcileScheduleRevision!==w.scheduleRevision||root.reconcileOwnerGeneration!==w.ownerGeneration||
    !counter(w.scheduleRevision)||!counter(w.ownerGeneration)||!counter(w.observedPublicationRevision)||!date(w.dueAt)||!['idle','policy_blocked','ready','working','retry','blocked','retired'].includes(w.state)||
    !Array.isArray(w.attemptStarts)||w.attemptStarts.length>12||!w.attemptStarts.every(date)||!shape(w.dispatchTotals,['get','ack','kms'])||!Object.values(w.dispatchTotals).every(counter)||
    (w.currentDemand!==undefined&&!demand(w.currentDemand))||(w.candidateDemand!==undefined&&!demand(w.candidateDemand))||
    (w.lastSuccessfulVerificationAt!==undefined&&!date(w.lastSuccessfulVerificationAt))||(w.reason!==undefined&&!['consent','retired','retry','budget'].includes(w.reason))||Buffer.byteLength(JSON.stringify(w))>8192) return false;
  if (w.state==='working') {if(!nonce(w.nonce)||!date(w.leaseExpiresAt)||!w.selectedDemand||!validSelected(w.selectedDemand)||w.completedObservation!==undefined||+w.dueAt!==+w.leaseExpiresAt)return false;}
  else if(w.nonce!==undefined||w.leaseExpiresAt!==undefined||w.selectedDemand!==undefined)return false;
  if(w.completedObservation && (!validCompleted(w.completedObservation)||!sameLifecycle(w.completedObservation,w)||w.completedObservation.accountSubject!==w.accountSubject||w.completedObservation.assertionId!==w.assertionId||w.completedObservation.scheduleRevision!==w.scheduleRevision||w.completedObservation.ownerGeneration!==w.ownerGeneration))return false;
  return (root.status!=='retired'||w.state==='retired')&&(root.status!=='consent_paused'||w.state==='blocked');
}
export function marked(root:LifecycleRoot,w:ReconcileWork):LifecycleRoot{return {...root,reconcileVersion:RECONCILE_VERSION,reconcileScheduleRevision:w.scheduleRevision,reconcileOwnerGeneration:w.ownerGeneration};}
export function initialWork(root:LifecycleRoot,now:Date):ReconcileWork{return {version:RECONCILE_VERSION,accountSubject:root.accountSubject,lifecycleEpoch:root.lifecycleEpoch,lifecycleGeneration:root.lifecycleGeneration,assertionId:root.assertionId,scheduleRevision:0,ownerGeneration:0,state:'idle',dueAt:now,observedPublicationRevision:root.authorityPublicationRevision??0,attemptStarts:[],dispatchTotals:{get:0,ack:0,kms:0}};}
export function validFence(f:ReconcileFence):boolean{return shape(f,['accountSubject','assertionId','lifecycleEpoch','lifecycleGeneration','scheduleRevision','ownerGeneration','nonce','selectedDemand'])&&fingerprint(f.accountSubject)&&typeof f.assertionId==='string'&&/^[a-f0-9]{32}$/.test(f.assertionId)&&validLifecycleFields(f)&&counter(f.scheduleRevision)&&counter(f.ownerGeneration)&&nonce(f.nonce)&&validSelected(f.selectedDemand);}
export function ownsWork(w:ReconcileWork,f:ReconcileFence,now:Date):boolean{return validFence(f)&& w.state==='working'&&sameLifecycle(w,f)&&w.accountSubject===f.accountSubject&&w.assertionId===f.assertionId&&w.scheduleRevision===f.scheduleRevision&&w.ownerGeneration===f.ownerGeneration&&!!w.nonce&&bytesEqual(w.nonce,f.nonce)&&!!w.leaseExpiresAt&&w.leaseExpiresAt>now&&!!w.selectedDemand&&selectedEqual(w.selectedDemand,f.selectedDemand);}
export function fenceFor(w:ReconcileWork):ReconcileFence {if(w.state!=='working'||!w.nonce||!w.selectedDemand)throw new Error('billing reconciliation unsafe');return {accountSubject:w.accountSubject,lifecycleEpoch:w.lifecycleEpoch,lifecycleGeneration:w.lifecycleGeneration,assertionId:w.assertionId,scheduleRevision:w.scheduleRevision,ownerGeneration:w.ownerGeneration,nonce:new Uint8Array(w.nonce),selectedDemand:{...w.selectedDemand}};}
export function selection(w:ReconcileWork,index:PointerIndex,ack:string|undefined,now:Date):SelectedDemand|undefined {
  const c=w.candidateDemand, p=w.currentDemand;
  if((c!==undefined&&c.tokenFingerprint!==index.candidate)||(p!==undefined&&p.tokenFingerprint!==index.current))throw new Error('billing reconciliation unsafe');
  const selected=(d:Demand,kind:SelectedDemand['kind']):SelectedDemand=>({kind,tokenFingerprint:d.tokenFingerprint,demandRevision:d.demandRevision,indexRevision:index.revision});
  if(ack){const d=c?.tokenFingerprint===ack?c:p?.tokenFingerprint===ack?p:undefined;if(!d)throw new Error('billing reconciliation unsafe');return d.dueAt<=now?selected(d,'ack'):undefined;}
  if(c&&c.dueAt<=now&&c.lastObservedDemandRevision!==c.demandRevision)return selected(c,'candidate');
  if(p&&p.dueAt<=now)return selected(p,'current');
  if(c&&c.dueAt<=now)return selected(c,'candidate');
  return undefined;
}
/** Pure proposal. Caller commits it with the semantic source transition. */
export function reschedule(old:ReconcileWork,root:LifecycleRoot,index:PointerIndex|undefined,now:Date,policy:ReconcilePolicy|undefined,
  options:{own?:ReconcileFence; terminal?:{token:string;paid:boolean;expiresAt?:Date}; publicationRevision:number; ack?:string; previousIndex?:PointerIndex}):ReconcileWork {
  const revision=increment(old.scheduleRevision);
  const slot=(previous:Demand|undefined,token:string|undefined):Demand|undefined=>token===undefined?undefined:previous?.tokenFingerprint===token?{...previous}:{tokenFingerprint:token,demandRevision:revision,dueAt:now};
  let w:ReconcileWork={...old,lifecycleEpoch:root.lifecycleEpoch,lifecycleGeneration:root.lifecycleGeneration,assertionId:root.assertionId,scheduleRevision:revision,
    ownerGeneration:options.own?old.ownerGeneration:increment(old.ownerGeneration),currentDemand:slot(old.currentDemand,index?.current),candidateDemand:slot(old.candidateDemand,index?.candidate),
    nonce:undefined,selectedDemand:undefined,leaseExpiresAt:undefined,completedObservation:undefined,reason:undefined,observedPublicationRevision:options.publicationRevision};
  if(!old.currentDemand && options.previousIndex?.current===index?.current && root.assertionId===old.assertionId && !options.terminal?.paid)w.currentDemand=undefined;
  if(root.assertionId!==old.assertionId)for(const key of ['currentDemand','candidateDemand'] as const)if(w[key])w[key]={...w[key]!,demandRevision:revision,dueAt:now,lastObservedDemandRevision:undefined};
  if(options.terminal){
    w.lastSuccessfulVerificationAt=now;
    for(const key of ['currentDemand','candidateDemand'] as const){const d=w[key];if(d?.tokenFingerprint!==options.terminal.token)continue;
      // No policy authorizes repeated checks of a freshly inactive current.
      if(!options.terminal.paid&&key==='currentDemand'&&options.ack===undefined){w.currentDemand=undefined;continue;}
      const delay=options.terminal.paid?Math.min(policy?.activeMs??86_400_000,Math.max(0,+(options.terminal.expiresAt??now)-+now)):key==='candidateDemand'?(policy?.retryMs??30_000):86_400_000;
      w[key]={...d,lastObservedDemandRevision:d.demandRevision,dueAt:new Date(+now+delay)};
    }
  }
  const due=[w.currentDemand?.dueAt,w.candidateDemand?.dueAt].filter((d):d is Date=>!!d);
  w.dueAt=due.length?new Date(Math.min(...due.map(Number))):now;
  w.state=root.status==='retired'?'retired':root.status!=='active'?'blocked':due.length===0?'idle':policy?'ready':'policy_blocked';
  if(root.status!=='active')w.reason=root.status==='retired'?'retired':'consent';
  if(options.terminal&&!options.terminal.paid&&w.candidateDemand===undefined&&options.ack===undefined)w.state='policy_blocked';
  if(options.own&&!options.terminal&&root.status==='active'){w.state='working';w.nonce=options.own.nonce;w.leaseExpiresAt=old.leaseExpiresAt;w.dueAt=old.leaseExpiresAt!;
    const prior=options.own.selectedDemand;const d=w.candidateDemand?.tokenFingerprint===prior.tokenFingerprint?w.candidateDemand:w.currentDemand?.tokenFingerprint===prior.tokenFingerprint?w.currentDemand:undefined;
    if(!d)throw new Error('billing reconciliation unsafe');w.selectedDemand={...prior,demandRevision:d.demandRevision,indexRevision:index?.revision??0};}
  return w;
}

export interface MigrationException extends LifecycleFields {
  version:'play-billing-reconcile-exception-v1';accountSubject:string;reason:'unmarked_revoked'|'unmarked_retired';recordedAt:Date;
}
export function validMigrationException(e:MigrationException,root:LifecycleRoot):boolean {
  return shape(e,['version','accountSubject','lifecycleEpoch','lifecycleGeneration','reason','recordedAt'])&&
    e.version==='play-billing-reconcile-exception-v1'&&e.accountSubject===root.accountSubject&&sameLifecycle(e,root)&&date(e.recordedAt)&&
    root.reconcileVersion===undefined&&((e.reason==='unmarked_retired'&&root.status==='retired')||(e.reason==='unmarked_revoked'&&root.status==='consent_paused'));
}
