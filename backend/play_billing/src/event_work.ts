import { FINANCIAL_EVENT_VERSION, financialAnchor, validFinancialReciprocal, validFinancialVoid, type FinancialVoid, type FinancialOrder } from './financial_void.js';
import { DispatchError, LOCAL_DISPATCH_VERSION, digest, readLegacyDispatchHistory, proposeOpenCircuit, readDispatchControls, proposeDispatch, writeDispatchControls, type DispatchConfiguration, type DispatchAction } from './dispatch_budget.js';
import { eventFence, type DispatchCapability, type DispatchDescriptor, type DispatchReservation } from './dispatch_gate.js';
import { COLLECTIONS, PACKAGE_NAME } from './constants.js';
import { counter, fingerprint } from './account_authority.js';
import { BillingDeadline } from './deadline.js';
import {validDisclosure, type BillingDatabase, type BillingTransaction} from './store.js';
import type { NonceSource } from './contracts.js';
import {sameLifecycle,validLifecycleRoot,validReciprocalRoute,type LifecycleRoot,type LifecycleRoute} from './lifecycle.js';
import { BOUNDED_EVENT_LIMITS, COST_KINDS, EVENT_CONTROL_VERSION, EVENT_LEASE_MS, EVENT_WORK_VERSION, EventWorkError,
  emptyCosts, finiteDate, ownsEvent, shape, validEventWork, validEventEnvelope, validResolved,
  type EventDescriptor, type EventEnvelope, type EventLimits, type EventWorkFence, type EventWorkRecord,
  type CostKind, type EventReason, type ResolvedEventAccount } from './event_records.js';

interface Marker { version: typeof EVENT_CONTROL_VERSION; totalRows: number; budgetRevision: number }
interface Capacity { version: typeof EVENT_CONTROL_VERSION; totalRows: number; admissionStarts: Date[] }
interface Budget { version: typeof EVENT_CONTROL_VERSION; revision: number; starts: Record<CostKind, Date[]>; totals: Record<CostKind, number>; circuit: boolean }
const WINDOW_MS = 15 * 60_000;
const recent = (dates: Date[], now: Date, window = WINDOW_MS) => dates.filter(d => d.getTime() > now.getTime() - window);
const starts = (value: unknown, max: number): value is Date[] => Array.isArray(value) && value.length <= max && value.every(finiteDate);
function emptyBudget(): Budget { return { version:EVENT_CONTROL_VERSION, revision:0, starts:{discoveryGet:[],verificationGet:[],eventKms:[],accountKms:[],ack:[]}, totals:emptyCosts(), circuit:false }; }

export class EventWorkRepository {
  constructor(readonly database: BillingDatabase, private readonly nonces: NonceSource, readonly limits: EventLimits, private readonly jitter:()=>number=()=>Math.random(), private readonly commonConfig?:DispatchConfiguration, readonly fullVoidsEnabled = false) {
    if (typeof fullVoidsEnabled !== 'boolean' || !shape(limits, Object.keys(BOUNDED_EVENT_LIMITS)) || Object.entries(limits).some(([k,v]) => !counter(v) || v > BOUNDED_EVENT_LIMITS[k as keyof EventLimits])) throw new EventWorkError('configuration');
  }
  private nonce(): Uint8Array { const n = this.nonces.nextNonce(); if (!(n instanceof Uint8Array) || n.byteLength !==16) throw new EventWorkError('unsafe'); return new Uint8Array(n); }
  private async controls(tx: BillingTransaction): Promise<{ marker:Marker; capacity:Capacity; budget:Budget }> {
    const marker = await tx.get<Marker>(COLLECTIONS.eventControl, 'marker');
    const capacity = await tx.get<Capacity>(COLLECTIONS.eventControl, 'capacity');
    const budget = await tx.get<Budget>(COLLECTIONS.eventControl, 'budget');
    if (!marker || !capacity || !budget || !shape(marker,['version','totalRows','budgetRevision']) || !shape(capacity,['version','totalRows','admissionStarts']) ||
        !shape(budget,['version','revision','starts','totals','circuit']) || [marker.version,capacity.version,budget.version].some(v => v !== EVENT_CONTROL_VERSION) ||
        !counter(marker.totalRows) || marker.totalRows > BOUNDED_EVENT_LIMITS.rows || marker.totalRows !== capacity.totalRows ||
        !counter(marker.budgetRevision) || marker.budgetRevision !== budget.revision || !starts(capacity.admissionStarts,120) ||
        !shape(budget.starts,[...COST_KINDS]) || !shape(budget.totals,[...COST_KINDS]) || typeof budget.circuit !== 'boolean' ||
        COST_KINDS.some(k => !starts(budget.starts[k],120) || !counter(budget.totals[k]))) throw new EventWorkError('unsafe');
    return {marker,capacity,budget};
  }
  private writeControls(tx: BillingTransaction, control: {marker:Marker; capacity:Capacity; budget:Budget}): void {
    tx.set(COLLECTIONS.eventControl,'marker',control.marker); tx.set(COLLECTIONS.eventControl,'capacity',control.capacity); tx.set(COLLECTIONS.eventControl,'budget',control.budget);
  }
  async reserve(descriptor: EventDescriptor, now: Date, deadline: BillingDeadline, financial?: FinancialVoid): Promise<{kind:'duplicate'} | {kind:'reserved';work:EventWorkRecord}> {
    return this.database.runTransaction(async tx => {
      deadline.check();
      if (!shape(descriptor,['eventFingerprint','payloadDigest','category'],['tokenFingerprint']) || !fingerprint(descriptor.eventFingerprint) || !fingerprint(descriptor.payloadDigest) ||
          (descriptor.tokenFingerprint !== undefined && !fingerprint(descriptor.tokenFingerprint)) || !['subscription','unsupported','test','one_time','void','refund_review'].includes(descriptor.category) ||
          (['test','refund_review'].includes(descriptor.category) ? descriptor.tokenFingerprint!==undefined : descriptor.tokenFingerprint===undefined)) throw new EventWorkError('unsafe');
      const control = await this.controls(tx);
      if (!this.commonConfig) throw new EventWorkError('configuration');
      const common = await readDispatchControls(tx,this.commonConfig,now);
      const history = await readLegacyDispatchHistory(tx,common,now);
      if (history.budget.circuit || common.budget.circuit.state !== 'closed') throw new EventWorkError('configuration');
      const existing = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,descriptor.eventFingerprint);
      // The baseline descriptor recognizes exact retained v1 deliveries BEFORE stricter v2 bounds.
      if (existing) {
        if (!validEventWork(existing,descriptor.eventFingerprint) || existing.payloadDigest !== descriptor.payloadDigest ||
            existing.tokenFingerprint !== descriptor.tokenFingerprint || existing.category !== descriptor.category) throw new EventWorkError('unsafe');
        if (existing.version === FINANCIAL_EVENT_VERSION) {
          if (!financial || !validFinancialVoid(financial,descriptor.tokenFingerprint) || financial.semanticDigest !== existing.financial?.semanticDigest ||
              !await validFinancialReciprocal(tx,existing)) throw new EventWorkError('unsafe');
          if (['completed','blocked'].includes(existing.state)) return {kind:'duplicate'};
          if (!this.fullVoidsEnabled) {
            deadline.check();
            tx.set(COLLECTIONS.eventWork,existing.eventFingerprint,{...existing,state:'blocked',reason:'configuration',leaseExpiresAt:undefined,dueAt:now});
            return {kind:'duplicate'};
          }
        }
        if (existing.state !== 'reserving') return {kind:'duplicate'};
        if (existing.leaseExpiresAt! > now) throw new EventWorkError('transient');
        if (existing.generation >= Number.MAX_SAFE_INTEGER) throw new EventWorkError('unsafe');
        const expires = new Date(now.getTime()+EVENT_LEASE_MS);
        const work: EventWorkRecord = {...existing,generation:existing.generation+1,nonce:this.nonce(),leaseExpiresAt:expires,dueAt:expires,dispatchVersion:LOCAL_DISPATCH_VERSION,dispatchBase:{...existing.dispatchTotals}};
        deadline.check(); tx.set(COLLECTIONS.eventWork,work.eventFingerprint,work);
        return {kind:'reserved',work};
      }

      let anchor: FinancialOrder | undefined;
      let role: EventWorkRecord['financialRole'];
      let reason: EventReason = 'none';
      if (this.fullVoidsEnabled && descriptor.category === 'void') {
        if (!financial || !validFinancialVoid(financial,descriptor.tokenFingerprint)) throw new EventWorkError('unsafe');
        anchor = await financialAnchor(tx,financial.orderFingerprint);
        if (anchor && (anchor.tokenFingerprint !== descriptor.tokenFingerprint ||
            ([1,2].includes(financial.productType) && financial.productType !== anchor.productType))) {
          role = 'conflict'; reason = 'financial_conflict';
        } else if (financial.disposition !== 'supported_full_subscription') {
          role = 'quarantine'; reason = financial.disposition;
        } else if (anchor) {
          if (anchor.semanticDigest !== financial.semanticDigest) throw new EventWorkError('unsafe');
          role = 'alias'; reason = 'duplicate_order';
        } else {
          if (!tx.findFinancialAnchorHistory || await tx.findFinancialAnchorHistory(financial.orderFingerprint) !== undefined) throw new EventWorkError('unsafe');
          role = 'owner';
        }
      }
      const admissionStarts = recent(control.capacity.admissionStarts,now);
      if (control.capacity.totalRows >= this.limits.rows || admissionStarts.length >= this.limits.admissions) throw new EventWorkError('budget');
      control.capacity = {...control.capacity,totalRows:control.capacity.totalRows+1,admissionStarts:[...admissionStarts,now]};
      control.marker = {...control.marker,totalRows:control.capacity.totalRows};
      const terminal = role !== undefined && role !== 'owner';
      const expires = new Date(now.getTime()+EVENT_LEASE_MS);
      const work: EventWorkRecord = {version:role ? FINANCIAL_EVENT_VERSION : EVENT_WORK_VERSION,...descriptor,
        generation:1,nonce:this.nonce(),state:terminal?'blocked':'reserving',receivedAt:now,dueAt:terminal?now:expires,
        ...(terminal?{}:{leaseExpiresAt:expires}),reason,attemptStarts:[],totalAttempts:0,dispatchTotals:emptyCosts(),
        dispatchVersion:LOCAL_DISPATCH_VERSION,dispatchBase:emptyCosts(),
        ...(role?{financial,financialRole:role,...(role==='owner'||role==='alias'?{financialOwnerEventFingerprint:anchor?.ownerEventFingerprint??descriptor.eventFingerprint}:{})}:{})};
      if (!validEventWork(work,work.eventFingerprint)) throw new EventWorkError('unsafe');
      deadline.check();
      if (role === 'owner') {
        const created: FinancialOrder = {version:'play-financial-order-v1',packageName:PACKAGE_NAME,
          orderFingerprint:financial!.orderFingerprint,tokenFingerprint:descriptor.tokenFingerprint!,productType:1,refundType:1,
          semanticDigest:financial!.semanticDigest,ownerEventFingerprint:work.eventFingerprint,createdAt:now};
        tx.set(COLLECTIONS.financialOrders,created.orderFingerprint,created);
      }
      this.writeControls(tx,control);
      tx.set(COLLECTIONS.eventWork,work.eventFingerprint,work);
      return terminal ? {kind:'duplicate'} : {kind:'reserved',work};
    });
  }
  async admitCiphertext(fence:EventWorkFence, envelope:EventEnvelope | undefined, now:Date, deadline:BillingDeadline): Promise<void> {
    await this.database.runTransaction(async tx => {
      deadline.check(); await this.controls(tx);
      const work = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,fence.eventFingerprint);
      if (!ownsEvent(work,fence,now,'reserving') || !await validFinancialReciprocal(tx,work) || (work.tokenFingerprint !== undefined ? !validEventEnvelope(envelope) : envelope !== undefined)) throw new EventWorkError('unsafe');
      const supported = work.category==='subscription' || (work.version===FINANCIAL_EVENT_VERSION && work.financialRole==='owner' && this.fullVoidsEnabled);
      const state = work.category==='test' ? 'completed' : supported ? 'ready' : 'blocked';
      deadline.check(); tx.set(COLLECTIONS.eventWork,fence.eventFingerprint,{...work,envelope,state,reason:state==='blocked' ? (work.version===FINANCIAL_EVENT_VERSION?'configuration':'unsupported') : 'none',leaseExpiresAt:undefined,dueAt:now});
    });
  }
  async claim(id:string, now:Date, deadline:BillingDeadline):Promise<EventWorkRecord | undefined> {
    return this.database.runTransaction(async tx => {
      deadline.check(); await this.controls(tx);
      const work = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,id);
      if (!work || !validEventWork(work,id) || !await validFinancialReciprocal(tx,work)) throw new EventWorkError('unsafe');
      if (!['ready','retry','working'].includes(work.state) || work.dueAt > now) return undefined;
      if (work.version===FINANCIAL_EVENT_VERSION && !this.fullVoidsEnabled) {
        deadline.check();tx.set(COLLECTIONS.eventWork,id,{...work,state:'blocked',reason:'configuration',leaseExpiresAt:undefined,dueAt:now});return undefined;
      }
      const attempts = recent(work.attemptStarts,now,24*60*60_000);
      if (attempts.length >=12 || recent(attempts,now,60*60_000).length >=6 || work.totalAttempts >=Number.MAX_SAFE_INTEGER || work.generation >=Number.MAX_SAFE_INTEGER) {
        deadline.check(); tx.set(COLLECTIONS.eventWork,id,{...work,state:'blocked',reason:'budget',leaseExpiresAt:undefined}); return undefined;
      }
      const expiry = new Date(now.getTime()+EVENT_LEASE_MS);
      const claimed:EventWorkRecord = {...work,state:'working',generation:work.generation+1,nonce:this.nonce(),leaseExpiresAt:expiry,dueAt:expiry,
        totalAttempts:work.totalAttempts+1,attemptStarts:[...attempts,now],reason:'none',dispatchVersion:LOCAL_DISPATCH_VERSION,dispatchBase:{...work.dispatchTotals}};
      deadline.check(); tx.set(COLLECTIONS.eventWork,id,claimed); return claimed;
    });
  }
  async bind(fence:EventWorkFence, resolved:ResolvedEventAccount, now:Date, deadline:BillingDeadline):Promise<void> {
    await this.database.runTransaction(async tx => {
      deadline.check(); await this.controls(tx); const work = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,fence.eventFingerprint);
      if (!ownsEvent(work,fence,now) || !await validFinancialReciprocal(tx,work) || !validResolved(resolved) || (work.resolved !==undefined &&
          (work.resolved.accountSubject !==resolved.accountSubject || !sameLifecycle(work.resolved,resolved)))) throw new EventWorkError('unsafe');
      deadline.check(); tx.set(COLLECTIONS.eventWork,fence.eventFingerprint,{...work,resolved});
    });
  }
  /** Read/propose only; the owning transaction commits local, legacy and common writes together. */
  async prepareDispatch(tx:BillingTransaction,fence:EventWorkFence,kind:CostKind,now:Date,reserve:boolean,phase:'reserving'|'working'='working'):Promise<{expiresAt:number;write:()=>void;work:EventWorkRecord;legacyHead:{revision:number;digest:string}}> {
    const control=await this.controls(tx),work=await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,fence.eventFingerprint);
      if (!COST_KINDS.includes(kind) || !ownsEvent(work,fence,now,phase) || !await validFinancialReciprocal(tx,work) ||
          (work.version===FINANCIAL_EVENT_VERSION && (!this.fullVoidsEnabled || work.financialRole!=='owner'))) throw new EventWorkError('unsafe');
      let consentExpiry=Infinity;
      if (work.resolved) {
        const root=await tx.get<LifecycleRoot>(COLLECTIONS.lifecycles,work.resolved.accountSubject);
        if(!root || !validLifecycleRoot(root,work.resolved.accountSubject) || !sameLifecycle(root,work.resolved)) throw new EventWorkError('retired');
        const route=await tx.get<LifecycleRoute>(COLLECTIONS.routes,root.routeFingerprint);
        if(!route || !validReciprocalRoute(route,root)) throw new EventWorkError('unsafe');
        if(root.status==='retired') throw new EventWorkError('retired');
        const disclosure=await tx.get<Parameters<typeof validDisclosure>[0]>(COLLECTIONS.disclosures,root.accountSubject);
        if(root.status!=='active'||!disclosure||!validDisclosure(disclosure,root.accountSubject)||disclosure.status!=='accepted'||
            disclosure.assertionId!==root.assertionId||disclosure.retentionExpiresAt<=now) throw new EventWorkError('consent');
        consentExpiry=+disclosure.retentionExpiresAt;
      }

    if(work.dispatchVersion!==LOCAL_DISPATCH_VERSION||!work.dispatchBase)throw new EventWorkError('unsafe');
    for(const k of COST_KINDS){let previous=-Infinity;for(const date of control.budget.starts[k]){if(+date<previous||date>now)throw new EventWorkError('unsafe');previous=+date;}
      if(control.budget.totals[k]<control.budget.starts[k].length)throw new EventWorkError('unsafe');}
    if(control.budget.circuit)throw new EventWorkError('configuration');
    if(!reserve)return {legacyHead:{revision:control.budget.revision,digest:digest(control.budget)},work,expiresAt:Math.min(+work.leaseExpiresAt!,consentExpiry),write:()=>{}};
    const used=Object.fromEntries(COST_KINDS.map(k=>[k,work.dispatchTotals[k]-work.dispatchBase![k]])) as Record<CostKind,number>;
    if((phase==='reserving'&&(kind!=='eventKms'||used.eventKms>=1))||
      ((kind==='discoveryGet'||kind==='verificationGet')&&used.discoveryGet+used.verificationGet>=3)||
      ((kind==='eventKms'||kind==='accountKms')&&used.eventKms+used.accountKms>=3)||(kind==='ack'&&used.ack>=1))throw new EventWorkError('budget');
    const window=Object.fromEntries(COST_KINDS.map(k=>[k,recent(control.budget.starts[k],now)])) as Record<CostKind,Date[]>;
    if((kind==='discoveryGet'&&window.discoveryGet.length>=this.limits.discoveries)||
      ((kind==='discoveryGet'||kind==='verificationGet')&&window.discoveryGet.length+window.verificationGet.length>=this.limits.gets)||
      ((kind==='eventKms'||kind==='accountKms')&&window.eventKms.length+window.accountKms.length>=this.limits.kms)||(kind==='ack'&&window.ack.length>=this.limits.acknowledgements))throw new EventWorkError('budget');
    if([control.budget.revision,control.budget.totals[kind],work.dispatchTotals[kind]].some(n=>n>=Number.MAX_SAFE_INTEGER))throw new EventWorkError('unsafe');
    window[kind].push(now);control.budget={...control.budget,revision:control.budget.revision+1,starts:window,totals:{...control.budget.totals,[kind]:control.budget.totals[kind]+1}};
    control.marker={...control.marker,budgetRevision:control.budget.revision};
    return {legacyHead:{revision:control.budget.revision,digest:digest(control.budget)},work,expiresAt:Math.min(+work.leaseExpiresAt!,consentExpiry),write:()=>{this.writeControls(tx,control);tx.set(COLLECTIONS.eventWork,fence.eventFingerprint,{...work,dispatchTotals:{...work.dispatchTotals,[kind]:work.dispatchTotals[kind]+1}});}};
  }
  async dispatch(cap:Exclude<DispatchCapability,{attempt:string}>,d:DispatchDescriptor,c:DispatchConfiguration,deadline:BillingDeadline,minimumRevision:number|undefined,clock:()=>Date):Promise<DispatchReservation>{
    return this.database.runTransaction(async tx=>{
      deadline.check();const controls=await readDispatchControls(tx,c,clock());
      const history=await readLegacyDispatchHistory(tx,controls,clock());if(history.budget.circuit)throw new DispatchError('configuration');
      const phase=cap.kind==='event_reserving'?'reserving':'working';
      if((phase==='reserving'&&(d.action!=='kms_encrypt'||d.purpose!=='event'))||
        (phase==='working'&&!(d.action==='kms_decrypt'&&d.purpose==='event'||d.action==='play_get'&&d.purpose==='subscription')))throw new DispatchError();
      const p=await this.prepareDispatch(tx,eventFence(cap),d.action==='play_get'?'discoveryGet':'eventKms',clock(),minimumRevision===undefined,phase);
      if(p.work.tokenFingerprint!==cap.tokenFingerprint||p.work.payloadDigest!==cap.payloadDigest||
        (p.work.resolved?JSON.stringify(p.work.resolved):undefined)!==cap.resolved||
        (phase==='working'&&digest(p.work.envelope)!==cap.envelopeDigest)||
        (d.action==='kms_decrypt'&&d.envelopeDigest!==cap.envelopeDigest))throw new DispatchError();
      const now=clock();deadline.check();if(+now>=p.expiresAt||controls.budget.circuit.state!=='closed')throw new DispatchError('stale');
      if(minimumRevision!==undefined){if(controls.budget.revision<minimumRevision)throw new DispatchError();return {source:'event',revision:controls.budget.revision,expiresAt:p.expiresAt};}
      const next=proposeDispatch(controls,c,'event',d.action,now);next.budget.legacyHead=p.legacyHead;p.write();writeDispatchControls(tx,next);
      return {source:'event',revision:next.budget.revision,expiresAt:p.expiresAt};
    });
  }
  async prepareCircuit(tx:BillingTransaction):Promise<()=>void>{
    const control=await this.controls(tx);if(control.budget.revision>=Number.MAX_SAFE_INTEGER)throw new EventWorkError('unsafe');
    control.budget={...control.budget,revision:control.budget.revision+1,circuit:true};control.marker={...control.marker,budgetRevision:control.budget.revision};
    return ()=>this.writeControls(tx,control);
  }
  /** Legacy test seam; production dispatch uses the composed common transaction. */
  async charge(fence:EventWorkFence,kind:CostKind,now:Date,deadline:BillingDeadline,phase:'reserving'|'working'='working'):Promise<void>{
    await this.database.runTransaction(async tx=>{deadline.check();if(!this.commonConfig)throw new EventWorkError('configuration');const c=await readDispatchControls(tx,this.commonConfig,now);await readLegacyDispatchHistory(tx,c,now);const p=await this.prepareDispatch(tx,fence,kind,now,true,phase);deadline.check();p.write();writeDispatchControls(tx,{...c,budget:{...c.budget,legacyHead:p.legacyHead}});});
  }
  async finish(fence:EventWorkFence, outcome:'completed'|'retry'|'blocked', reason:EventReason, now:Date, deadline:BillingDeadline):Promise<void> {
    await this.database.runTransaction(async tx => {
      deadline.check(); await this.controls(tx); const work = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork,fence.eventFingerprint);
      if (!ownsEvent(work,fence,now) || !await validFinancialReciprocal(tx,work) || (work.version===FINANCIAL_EVENT_VERSION && outcome==='completed')) throw new EventWorkError('unsafe');
      const random=this.jitter();
      if(!Number.isFinite(random)||random<0||random>=1) throw new EventWorkError('unsafe');
      const delay = Math.min(900_000,30_000 * 2 ** Math.min(5,work.totalAttempts-1)+Math.floor(random*5001));
      deadline.check(); tx.set(COLLECTIONS.eventWork,fence.eventFingerprint,{...work,state:outcome,reason,leaseExpiresAt:undefined,dueAt:new Date(now.getTime()+(outcome==='retry'?delay:0))});
    });
  }
  async openCircuit(now:Date,deadline:BillingDeadline):Promise<void>{
    await this.database.runTransaction(async tx=>{
      deadline.check();if(!this.commonConfig)throw new EventWorkError('configuration');
      const c=await readDispatchControls(tx,this.commonConfig,now),legacy=await readLegacyDispatchHistory(tx,c,now);
      const next=proposeOpenCircuit(c,now);next.budget.legacyHead=legacy.openedHead;deadline.check();legacy.open();writeDispatchControls(tx,next);
    });
  }
}
