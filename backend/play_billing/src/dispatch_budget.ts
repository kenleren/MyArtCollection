import { createHash } from 'node:crypto';
import { BILLING_DATABASE_ID, COLLECTIONS, PACKAGE_NAME } from './constants.js';
import { counter, fingerprint } from './account_authority.js';
import { COST_KINDS, EVENT_CONTROL_VERSION, emptyCosts, finiteDate, shape } from './event_records.js';
import type { BillingTransaction } from './store.js';

export const DISPATCH_VERSION = 'billing-dispatch-v1';
export const LOCAL_DISPATCH_VERSION = 'billing-local-dispatch-v1';
export const SOURCES = ['foreground','event','reconciliation'] as const;
export const ACTIONS = ['play_get','play_ack','kms_encrypt','kms_decrypt'] as const;
export const GROUPS = ['get','ack','kms'] as const;
export type DispatchSource = typeof SOURCES[number];
export type DispatchAction = typeof ACTIONS[number];
export type DispatchGroup = typeof GROUPS[number];
export type DispatchCounts = Record<DispatchGroup,number>;
export const HARD_CAPS: DispatchCounts = Object.freeze({get:120,ack:30,kms:60});
export const LOCAL_CAPS: DispatchCounts = Object.freeze({get:3,ack:1,kms:3});
export const WINDOW_MS = 900_000;
export const emptyDispatchCounts = ():DispatchCounts=>({get:0,ack:0,kms:0});
export class DispatchError extends Error {
  constructor(readonly reason:'unsafe'|'budget'|'configuration'|'stale'='unsafe'){super(`billing dispatch ${reason}`);}
}
function canonical(value:unknown):unknown {
  if(value instanceof Date)return value.toISOString();
  if(Array.isArray(value))return value.map(canonical);
  if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical((value as Record<string,unknown>)[k])]));
  return value;
}
export const digest=(value:unknown):string=>createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
export const groupFor=(action:DispatchAction):DispatchGroup=>action==='play_get'?'get':action==='play_ack'?'ack':'kms';
export function validCounts(v:DispatchCounts, caps:DispatchCounts=HARD_CAPS):boolean {
  return shape(v,[...GROUPS]) && GROUPS.every(g=>counter(v[g])&&v[g]<=caps[g]);
}
export interface DispatchConfiguration {
  enabled:boolean; epoch:string; global:DispatchCounts; sources:Record<DispatchSource,DispatchCounts>; digest:string;
}
export function configurationDigest(c:Omit<DispatchConfiguration,'digest'>):string {
  return digest([DISPATCH_VERSION,c.enabled,c.epoch,GROUPS.map(g=>c.global[g]),SOURCES.map(s=>GROUPS.map(g=>c.sources[s][g]))]);
}
export function validDispatchConfiguration(c:DispatchConfiguration):boolean {
  return shape(c,['enabled','epoch','global','sources','digest'])&&typeof c.enabled==='boolean'&&/^[a-f0-9]{32}$/.test(c.epoch)&&
    validCounts(c.global)&&shape(c.sources,[...SOURCES])&&SOURCES.every(s=>validCounts(c.sources[s],c.global))&&c.digest===configurationDigest(c);
}
/** Non-secret, exact configuration. No deployment allocation is supplied by source. */
export function dispatchConfiguration(raw:string|undefined):DispatchConfiguration|undefined {
  if(raw===undefined)return undefined;
  if(Buffer.byteLength(raw)>4096)throw new DispatchError('configuration');
  let c:DispatchConfiguration;try{c=JSON.parse(raw);}catch{throw new DispatchError('configuration');}
  if(!validDispatchConfiguration(c))throw new DispatchError('configuration');
  return c.enabled&&GROUPS.some(g=>c.global[g]>0)&&SOURCES.some(s=>GROUPS.some(g=>c.sources[s][g]>0))?c:undefined;
}
interface Binding {version:typeof DISPATCH_VERSION;project:'my-art-collections';packageName:typeof PACKAGE_NAME;database:typeof BILLING_DATABASE_ID;epoch:string;configDigest:string;revision:number;cutoverDigest:string}
export interface DispatchMarker extends Binding {}
export interface DispatchBudget extends Binding {
  lastReservationAt:Date;
  starts:Record<DispatchGroup,{at:Date;source:DispatchSource;action:DispatchAction}[]>;
  totals:Record<DispatchSource,Record<DispatchAction,number>>;
  circuit:{state:'closed'|'open';generation:number;reason?:'configuration';openedAt?:Date};
  legacyHead:{revision:number;digest:string};
  legacy:{kind:'verified_new'}|{kind:'retained';digest:string;revision:number;totals:Record<string,number>};
}
export interface DispatchControls {marker:DispatchMarker;budget:DispatchBudget}
const bindingKeys=['version','project','packageName','database','epoch','configDigest','revision','cutoverDigest'];
function validBinding(v:Binding,c:DispatchConfiguration):boolean {
  return v.version===DISPATCH_VERSION&&v.project==='my-art-collections'&&v.packageName===PACKAGE_NAME&&v.database===BILLING_DATABASE_ID&&
    v.epoch===c.epoch&&v.configDigest===c.digest&&counter(v.revision)&&fingerprint(v.cutoverDigest);
}
export function validateControls(v:DispatchControls,c:DispatchConfiguration,now:Date):void {
  const {marker:m,budget:b}=v;
  if(!validDispatchConfiguration(c)||!c.enabled||!m||!b||Buffer.byteLength(JSON.stringify(m))>65536||Buffer.byteLength(JSON.stringify(b))>65536||
    !shape(m,bindingKeys)||!shape(b,[...bindingKeys,'lastReservationAt','starts','totals','circuit','legacy','legacyHead'])||!validBinding(m,c)||!validBinding(b,c)||
    m.revision!==b.revision||m.cutoverDigest!==b.cutoverDigest||!finiteDate(now)||!finiteDate(b.lastReservationAt)||now<b.lastReservationAt||
    !shape(b.starts,[...GROUPS])||!shape(b.totals,[...SOURCES])||!SOURCES.every(s=>shape(b.totals[s],[...ACTIONS])&&ACTIONS.every(a=>counter(b.totals[s][a])))||
    !shape(b.circuit,['state','generation'],['reason','openedAt'])||!counter(b.circuit.generation)||
    (b.circuit.state==='closed'? b.circuit.reason!==undefined||b.circuit.openedAt!==undefined :
      b.circuit.state!=='open'||b.circuit.reason!=='configuration'||!finiteDate(b.circuit.openedAt)||b.circuit.openedAt>now))throw new DispatchError();
  if(!(shape(b.legacy,['kind'])&&b.legacy.kind==='verified_new') && !(shape(b.legacy,['kind','digest','revision','totals'])&&b.legacy.kind==='retained'&&
    fingerprint(b.legacy.digest)&&counter(b.legacy.revision)&&shape(b.legacy.totals,['discoveryGet','verificationGet','eventKms','accountKms','ack'])&&Object.values(b.legacy.totals).every(counter)))throw new DispatchError();
  if(!shape(b.legacyHead,['revision','digest'])||!counter(b.legacyHead.revision)||!fingerprint(b.legacyHead.digest)||(b.legacy.kind==='retained'&&b.legacyHead.revision<b.legacy.revision))throw new DispatchError();
  let sum=0;
  for(const s of SOURCES)for(const a of ACTIONS){sum+=b.totals[s][a];if(!Number.isSafeInteger(sum))throw new DispatchError();}
  if(sum!==b.revision-b.circuit.generation||b.circuit.generation>b.revision)throw new DispatchError();
  for(const g of GROUPS){
    const entries=b.starts[g];if(!Array.isArray(entries)||entries.length>HARD_CAPS[g])throw new DispatchError();
    let previous=-Infinity;
    const counts=new Map<string,number>();
    for(const e of entries){if(!shape(e,['at','source','action'])||!finiteDate(e.at)||+e.at<previous||e.at>b.lastReservationAt||!SOURCES.includes(e.source)||!ACTIONS.includes(e.action)||groupFor(e.action)!==g)throw new DispatchError();
      previous=+e.at;const k=e.source+'/'+e.action;counts.set(k,(counts.get(k)??0)+1);if(counts.get(k)!>b.totals[e.source][e.action])throw new DispatchError();}
  }
}
export async function readDispatchControls(tx:BillingTransaction,c:DispatchConfiguration,now:Date):Promise<DispatchControls>{
  const marker=await tx.get<DispatchMarker>(COLLECTIONS.dispatchControl,'marker');
  const budget=await tx.get<DispatchBudget>(COLLECTIONS.dispatchControl,'budget');
  if(!marker||!budget)throw new DispatchError();const controls={marker,budget};validateControls(controls,c,now);return controls;
}
export function proposeDispatch(v:DispatchControls,c:DispatchConfiguration,source:DispatchSource,action:DispatchAction,now:Date):DispatchControls {
  validateControls(v,c,now);if(v.budget.circuit.state!=='closed')throw new DispatchError('configuration');
  const group=groupFor(action);if(!SOURCES.includes(source)||!ACTIONS.includes(action))throw new DispatchError();
  const starts={...v.budget.starts};for(const g of GROUPS)starts[g]=starts[g].filter(e=>+e.at>=+now-WINDOW_MS);
  if(starts[group].length>=c.global[group]||starts[group].filter(e=>e.source===source).length>=c.sources[source][group])throw new DispatchError('budget');
  starts[group]=[...starts[group],{at:now,source,action}];
  const revision=v.budget.revision+1;const value=v.budget.totals[source][action]+1;
  if(!Number.isSafeInteger(revision)||!Number.isSafeInteger(value))throw new DispatchError();
  const next={marker:{...v.marker,revision},budget:{...v.budget,revision,lastReservationAt:now,starts,totals:{...v.budget.totals,[source]:{...v.budget.totals[source],[action]:value}}}};
  validateControls(next,c,now);return next;
}
export function writeDispatchControls(tx:BillingTransaction,c:DispatchControls):void {
  tx.set(COLLECTIONS.dispatchControl,'marker',c.marker);tx.set(COLLECTIONS.dispatchControl,'budget',c.budget);
}
/** Pure proposal only. Runtime callers never initialize missing controls. */
export function initialDispatchControls(c:DispatchConfiguration,now:Date,cutoverDigest:string,legacy:DispatchBudget['legacy']):DispatchControls {
  const binding:Binding={version:DISPATCH_VERSION,project:'my-art-collections',packageName:PACKAGE_NAME,database:BILLING_DATABASE_ID,epoch:c.epoch,configDigest:c.digest,revision:0,cutoverDigest};
  const totals=Object.fromEntries(SOURCES.map(s=>[s,Object.fromEntries(ACTIONS.map(a=>[a,0]))])) as DispatchBudget['totals'];
  const result={marker:{...binding},budget:{...binding,lastReservationAt:now,starts:{get:[],ack:[],kms:[]},totals,circuit:{state:'closed' as const,generation:0},legacy,legacyHead:legacy.kind==='retained'?{revision:legacy.revision,digest:legacy.digest}:{revision:0,digest:digest(emptyLegacyBudget())}}};
  validateControls(result,c,now);return result;
}
export function proposeOpenCircuit(c:DispatchControls,now:Date):DispatchControls {
  const revision=c.budget.revision+1,generation=c.budget.circuit.generation+1;
  if(!Number.isSafeInteger(revision)||!Number.isSafeInteger(generation))throw new DispatchError();
  return {marker:{...c.marker,revision},budget:{...c.budget,revision,circuit:{state:'open',generation,reason:'configuration',openedAt:now}}};
}

export function emptyLegacyBudget(){return {version:EVENT_CONTROL_VERSION,revision:0,starts:Object.fromEntries(COST_KINDS.map(k=>[k,[]])),totals:emptyCosts(),circuit:false};}
/** Exact current mirror prevents restoring local subcap headroom by partial rollback.
 * A coherent rollback of every control and source document remains outside this ledger's proof. */
export async function readLegacyDispatchHistory(tx:BillingTransaction,common:DispatchControls,now:Date):Promise<{budget:ReturnType<typeof emptyLegacyBudget>;open:()=>void;openedHead:{revision:number;digest:string}}>{
  const marker=await tx.get<any>(COLLECTIONS.eventControl,'marker'),capacity=await tx.get<any>(COLLECTIONS.eventControl,'capacity'),budget=await tx.get<any>(COLLECTIONS.eventControl,'budget');
  if(!marker||!capacity||!budget||!shape(marker,['version','totalRows','budgetRevision'])||!shape(capacity,['version','totalRows','admissionStarts'])||!shape(budget,['version','revision','starts','totals','circuit'])||
    [marker.version,capacity.version,budget.version].some(v=>v!==EVENT_CONTROL_VERSION)||!counter(marker.totalRows)||marker.totalRows>20_000||marker.totalRows!==capacity.totalRows||marker.budgetRevision!==budget.revision||
    !counter(budget.revision)||typeof budget.circuit!=='boolean'||!shape(budget.totals,[...COST_KINDS])||!shape(budget.starts,[...COST_KINDS])||
    budget.revision!==common.budget.legacyHead.revision||digest(budget)!==common.budget.legacyHead.digest)throw new DispatchError();
  let sum=0;
  for(const k of COST_KINDS){if(!counter(budget.totals[k]))throw new DispatchError();sum+=budget.totals[k];if(!Number.isSafeInteger(sum))throw new DispatchError();
    const dates=budget.starts[k];if(!Array.isArray(dates)||dates.length>120||dates.length>budget.totals[k])throw new DispatchError();let previous=-Infinity;
    for(const d of dates){if(!finiteDate(d)||d>now||+d<previous)throw new DispatchError();previous=+d;}
  }
  if(sum>budget.revision||!Array.isArray(capacity.admissionStarts)||capacity.admissionStarts.length>120)throw new DispatchError();
  let previous=-Infinity;for(const d of capacity.admissionStarts){if(!finiteDate(d)||d>now||+d<previous)throw new DispatchError();previous=+d;}
  const floor=common.budget.legacy.kind==='retained'?common.budget.legacy.totals:emptyCosts();
  if(COST_KINDS.some(k=>budget.totals[k]<floor[k])||(common.budget.legacy.kind==='retained'&&budget.revision<common.budget.legacy.revision))throw new DispatchError();
  const event=common.budget.totals.event;
  if(budget.totals.discoveryGet+budget.totals.verificationGet-floor.discoveryGet-floor.verificationGet<event.play_get||
    budget.totals.eventKms+budget.totals.accountKms-floor.eventKms-floor.accountKms<event.kms_encrypt+event.kms_decrypt||budget.totals.ack-floor.ack<event.play_ack)throw new DispatchError();
  if(budget.revision>=Number.MAX_SAFE_INTEGER)throw new DispatchError();
  const opened={...budget,revision:budget.revision+1,circuit:true};
  return {budget,openedHead:{revision:opened.revision,digest:digest(opened)},open:()=>{tx.set(COLLECTIONS.eventControl,'budget',opened);tx.set(COLLECTIONS.eventControl,'marker',{...marker,budgetRevision:opened.revision});}};
}
