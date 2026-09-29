import { eventDispatch } from './dispatch_gate.js';
import {KmsConfigurationError} from './kms_token_custody.js';
import { randomUUID } from 'node:crypto';
import { BillingDeadline } from './deadline.js';
import { CONTRACT_VERSION, DISCLOSURE_VERSION, PACKAGE_NAME } from './constants.js';
import type { Clock, PlaySubscriptionsAdapter, PlaySubscriptionPurchase } from './contracts.js';
import type { BillingIdentifiers } from './crypto.js';
import { BillingRepository, UnsafeBillingRecordError } from './store.js';
import { PlayBillingService } from './verifier.js';
import type { TokenCustody } from './token_custody.js';
import type { EventTokenCustody } from './event_token_custody.js';
import { EventWorkRepository } from './event_work.js';
import { EVENT_TOPIC, EventWorkError, type EventEnvelope, type CostKind, type EventWorkRecord, type EventReason } from './event_records.js';
import { parseRtdn } from './rtdn.js';
import { classifyPlayAdapterError } from './play_adapter.js';

export interface EventProcessingDependencies {
  work: EventWorkRepository; repository: BillingRepository; identifiers: BillingIdentifiers;
  eventCustody: EventTokenCustody; accountCustody: TokenCustody; play: PlaySubscriptionsAdapter; clock: Clock;
}
/** No provider dispatch occurs without a durable reservation. All errors leaving
 * the ingress are fixed labels; SDK/provider messages never enter transport logs. */
export class EventProcessor {
  constructor(private readonly d:EventProcessingDependencies) {}
  async ingest(event:unknown, deadline=new BillingDeadline()):Promise<void> {
    try {
      deadline.check(); const parsed=parseRtdn(event);
      const descriptor={eventFingerprint:this.d.identifiers.eventFingerprint(EVENT_TOPIC,parsed.messageId),payloadDigest:parsed.payloadDigest,
        category:parsed.category,...(parsed.token===undefined?{}:{tokenFingerprint:this.d.identifiers.tokenFingerprint(parsed.token)})};
      const reservation=await deadline.run(()=>this.d.work.reserve(descriptor,this.d.clock.now(),deadline));
      if(reservation.kind==='duplicate') return;
      let envelope:EventEnvelope|undefined;
      if(parsed.token!==undefined) {
        deadline.check();
        envelope=await deadline.run(()=>this.d.eventCustody.encrypt(parsed.token!,{...descriptor,tokenFingerprint:descriptor.tokenFingerprint!},deadline,eventDispatch(reservation.work,'reserving')));
      }
      await deadline.run(()=>this.d.work.admitCiphertext(reservation.work,envelope,this.d.clock.now(),deadline));
    } catch(error) {
      if(error instanceof EventWorkError && error.reason==='configuration') await this.d.work.openCircuit(this.d.clock.now(),deadline).catch(()=>undefined);
      throw new EventWorkError(error instanceof EventWorkError ? error.reason : 'transient');
    }
  }
  async pump(deadline=new BillingDeadline(Date.now()+50_000)):Promise<void> {
    try {
      const ids=await deadline.run(()=>this.d.work.database.dueEventWork(this.d.clock.now(),10));
      let cursor=0;
      const results=await Promise.allSettled([0,1].map(async()=>{
        while(cursor<ids.length) {
          deadline.check(); const id=ids[cursor++];
          const work=await deadline.run(()=>this.d.work.claim(id,this.d.clock.now(),deadline));
          if(work) await this.process(work,deadline);
        }
      }));
      const failed=results.find(result=>result.status==='rejected');
      if(failed?.status==='rejected') throw failed.reason;
    } catch(error) { throw new EventWorkError(error instanceof EventWorkError ? error.reason : 'transient'); }
  }
  private async process(work:EventWorkRecord, deadline:BillingDeadline):Promise<void> {
    let providerFailure:ReturnType<typeof classifyPlayAdapterError>|undefined;
    const get=async(args:Parameters<PlaySubscriptionsAdapter['getSubscription']>[0], discovery=false)=>{
      try { deadline.check(); return await deadline.run(()=>this.d.play.getSubscription(args)); }
      catch(error) { providerFailure=classifyPlayAdapterError(error); throw new EventWorkError(providerFailure==='configuration'?'configuration':'transient'); }
    };
    const play:PlaySubscriptionsAdapter={getSubscription:args=>get(args),acknowledgeSubscription:async args=>{
      try { deadline.check(); await deadline.run(()=>this.d.play.acknowledgeSubscription(args)); }
      catch(error) { providerFailure=classifyPlayAdapterError(error); throw new EventWorkError(providerFailure==='configuration'?'configuration':'transient'); }
    }};
    const custody:TokenCustody={encrypt:async(token,context,invocation,dispatch)=>{
      deadline.check(); try {return await this.d.accountCustody.encrypt(token,context,invocation,dispatch);} catch(error){if(error instanceof KmsConfigurationError) providerFailure='configuration';throw error;}
    },decrypt:async(envelope,context,invocation,dispatch)=>{
      deadline.check(); try {return await this.d.accountCustody.decrypt(envelope,context,invocation,dispatch);} catch(error){if(error instanceof KmsConfigurationError) providerFailure='configuration';throw error;}
    }};
    let outcome:'completed'|'retry'|'blocked'='retry', reason:EventReason='transient';
    try {
      if(!work.envelope || !work.tokenFingerprint) throw new EventWorkError('unsafe');
      const token=await deadline.run(()=>this.d.eventCustody.decrypt(work.envelope!,{eventFingerprint:work.eventFingerprint,payloadDigest:work.payloadDigest,tokenFingerprint:work.tokenFingerprint!},deadline,eventDispatch(work,'working')));
      if(this.d.identifiers.tokenFingerprint(token)!==work.tokenFingerprint) throw new EventWorkError('unsafe');
      let resolved=await deadline.run(()=>this.d.repository.resolveEventAccount(work.tokenFingerprint!,{routes:[],predecessorFingerprints:[]},deadline));
      let discovery:PlaySubscriptionPurchase|undefined;
      if(!resolved) {
        discovery=await get({packageName:PACKAGE_NAME,token,timeoutMs:10_000,deadline,dispatch:eventDispatch(work,'working')},true);
        const routes=[discovery.externalAccountIdentifiers?.obfuscatedExternalAccountId,
          discovery.outOfAppPurchaseContext?.expiredExternalAccountIdentifiers?.obfuscatedExternalAccountId].filter((s):s is string=>s!==undefined);
        const predecessorFingerprints=[discovery.linkedPurchaseToken,discovery.outOfAppPurchaseContext?.expiredPurchaseToken]
          .filter((s):s is string=>s!==undefined).map(s=>this.d.identifiers.tokenFingerprint(s));
        resolved=await deadline.run(()=>this.d.repository.resolveEventAccount(work.tokenFingerprint!,{routes,predecessorFingerprints},deadline));
      }
      if(!resolved) throw new EventWorkError('unresolved');
      const {superseded,productId,...account}=resolved;
      await deadline.run(()=>this.d.work.bind(work,account,this.d.clock.now(),deadline));
      const service=new PlayBillingService({repository:this.d.repository,identifiers:this.d.identifiers,clock:this.d.clock,play,custody});
      const input={version:CONTRACT_VERSION,requestId:randomUUID(),billingDisclosureVersion:DISCLOSURE_VERSION};
      const result=await deadline.run(()=>service.processAccountObservation({accountSubject:account.accountSubject,source:'background',
        requestFingerprint:this.d.identifiers.eventOperationFingerprint(work.eventFingerprint,work.generation),work:{kind:'event',fence:work}},
        superseded?{kind:'restore',input}:{kind:'verify',input:{...input,purchaseToken:token,productId:productId??discovery?.lineItems?.[0]?.productId}},deadline),50_000);
      if(result.status==='paid' || ('reason'in result && ['expired','on_hold','paused','play_pending'].includes(result.reason))) { outcome='completed'; reason='none'; }
      else if('reason'in result && ['unsafe_record','disclosure_required','recovery_required','account_conflict','invalid_request'].includes(result.reason)) {
        outcome='blocked'; reason=result.reason==='disclosure_required'?'consent':result.reason==='recovery_required'?'retired':'unsafe';
      }
    } catch(error) {
      if(error instanceof UnsafeBillingRecordError) {outcome='blocked';reason='unsafe';}
      else if(error instanceof EventWorkError) {if(error.reason==='configuration') providerFailure='configuration';reason=error.reason==='disabled'?'configuration':error.reason;outcome=['unsafe','unresolved','budget','configuration'].includes(reason)?'blocked':'retry';}
    }
    if(providerFailure==='configuration') { await deadline.run(()=>this.d.work.openCircuit(this.d.clock.now(),deadline)); outcome='blocked';reason='configuration'; }
    else if(providerFailure==='not_found'||providerFailure==='malformed'||providerFailure==='rejected') {outcome='blocked';reason='unsupported';}
    await deadline.run(()=>this.d.work.finish(work,outcome,reason,this.d.clock.now(),deadline));
  }
}
