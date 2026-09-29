import type { BillingDatabase } from './store.js';
import { BillingRepository } from './store.js';
import type { BillingIdentifiers } from './crypto.js';
import type { Clock, NonceSource, PlaySubscriptionsAdapter } from './contracts.js';
import { BillingDeadline } from './deadline.js';
import { dispatchConfiguration, readDispatchControls, readLegacyDispatchHistory, type DispatchConfiguration } from './dispatch_budget.js';
import { DispatchGate } from './dispatch_gate.js';
import { createConfiguredPlaySubscriptionsAdapter } from './play_adapter.js';
import { createConfiguredTokenCustody, GoogleKmsTransport } from './kms_token_custody.js';
import { DisabledTokenCustody, type TokenCustody } from './token_custody.js';
import { KmsEventTokenCustody, type EventTokenCustody } from './event_token_custody.js';
import { EventWorkRepository } from './event_work.js';
import type { EventLimits } from './event_records.js';
import type { ReconcilePolicy } from './reconciliation_work.js';

export interface BillingRuntimeOptions {
  database:BillingDatabase;identifiers:BillingIdentifiers;nonces:NonceSource;clock:Clock;deadline:BillingDeadline;
  providersNeeded:boolean;configuration?:string;publisherEnabled?:boolean;
  accountCustody?:{enabled:boolean;encryptionVersion:string;retainedVersions:readonly string[]};
  events?:{limits:EventLimits;encryptionVersion:string;retainedVersions:readonly string[]};
  reconciliationPolicy?:ReconcilePolicy;
  /** Tests inject at this actual production construction seam; never a callable option. */
  providerFactories?:{
    play?:(gate:DispatchGate)=>PlaySubscriptionsAdapter;
    custody?:(gate:DispatchGate)=>TokenCustody;
    eventCustody?:(gate:DispatchGate)=>EventTokenCustody;
  };
}
export interface BillingRuntime {
  repository:BillingRepository;play:PlaySubscriptionsAdapter;custody:TokenCustody;
  events?:EventWorkRepository;eventCustody?:EventTokenCustody;gate?:DispatchGate;
}
/** Safety-only operations do not parse/read common controls or construct provider/ADC dependencies. */
export async function createBillingRuntime(o:BillingRuntimeOptions):Promise<BillingRuntime> {
  const disabled=()=>({repository:new BillingRepository(o.database,o.nonces,o.identifiers,o.reconciliationPolicy),
    play:createConfiguredPlaySubscriptionsAdapter(),custody:new DisabledTokenCustody()});
  o.deadline.check();
  if(!o.providersNeeded)return disabled();
  let config:DispatchConfiguration|undefined;
  try{config=dispatchConfiguration(o.configuration);}catch{return disabled();}
  if(!config)return disabled();
  try{
    const valid=await o.deadline.run(()=>o.database.runTransaction(async tx=>{
      o.deadline.check();const controls=await readDispatchControls(tx,config!,o.clock.now());const legacy=await readLegacyDispatchHistory(tx,controls,o.clock.now());o.deadline.check();return controls.budget.circuit.state==='closed'&&!legacy.budget.circuit;
    }));
    o.deadline.check();if(!valid)return disabled();
  }catch{return disabled();}
  const events=o.events?new EventWorkRepository(o.database,o.nonces,o.events.limits,()=>Math.random(),config):undefined;
  const repository=new BillingRepository(o.database,o.nonces,o.identifiers,o.reconciliationPolicy,events,()=>o.clock.now());
  const gate=new DispatchGate(repository,config,o.identifiers,()=>+o.clock.now());
  const play=o.publisherEnabled?o.providerFactories?.play?.(gate)??createConfiguredPlaySubscriptionsAdapter({enabled:true,gate}):createConfiguredPlaySubscriptionsAdapter();
  const custody=o.accountCustody?.enabled?o.providerFactories?.custody?.(gate)??createConfiguredTokenCustody({...o.accountCustody,gate}):new DisabledTokenCustody();
  const eventCustody=o.events?o.providerFactories?.eventCustody?.(gate)??new KmsEventTokenCustody(o.events.encryptionVersion,o.events.retainedVersions,new GoogleKmsTransport({gate})):undefined;
  return {repository,play,custody,events,eventCustody,gate};
}
