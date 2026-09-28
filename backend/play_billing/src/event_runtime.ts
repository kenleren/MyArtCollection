import { EventWorkError, EVENT_SOURCE, EVENT_TYPE, EVENT_TOPIC, CLOSED_EVENT_LIMITS, BOUNDED_EVENT_LIMITS, type EventLimits } from './event_records.js';
import { validKeyVersion } from './token_custody.js';
// Filled only by a separately reviewed provisioning change; no live key is approved here.
export const APPROVED_EVENT_KEY_VERSIONS:readonly string[]=Object.freeze([]);
export const EVENT_RUNTIME_ACCOUNT='archivale-play-lifecycle-worker@my-art-collections.iam.gserviceaccount.com';
export const EVENT_TRIGGER_ACCOUNT='archivale-play-rtdn-trigger@my-art-collections.iam.gserviceaccount.com';
export const EVENT_DEPLOYMENT_CONTRACT=Object.freeze({project:'my-art-collections',topic:EVENT_TOPIC,source:EVENT_SOURCE,type:EVENT_TYPE,
  packageName:'app.archivale',database:'archivale-play-billing',runtimeAccount:EVENT_RUNTIME_ACCOUNT,triggerAccount:EVENT_TRIGGER_ACCOUNT,
  region:'us-central1',timeoutSeconds:60,memory:'512MiB',maxInstances:1,concurrency:1,defaultLimits:CLOSED_EVENT_LIMITS});
export interface EventRuntimeConfiguration {enabled:boolean; limits:EventLimits; encryptionVersion:string; retainedVersions:string[]}
/** Validates all non-secret configuration before constructing ADC or a database. */
export function eventRuntimeConfiguration(env:Record<string,string|undefined>, approvedVersions:readonly string[]=APPROVED_EVENT_KEY_VERSIONS):EventRuntimeConfiguration|undefined {
  if(env.PLAY_BILLING_EVENTS_ENABLED!=='enabled') return undefined;
  if(env.GCLOUD_PROJECT!=='my-art-collections') throw new EventWorkError('configuration');
  if(env.PLAY_BILLING_ROUTING_ENABLED!=='enabled'||env.PLAY_BILLING_RECOVERY_ENABLED!=='enabled'||
      env.PLAY_BILLING_ANDROID_PUBLISHER_ENABLED!=='enabled'||env.PLAY_BILLING_TOKEN_CUSTODY_ENABLED!=='enabled') throw new EventWorkError('configuration');
  const encryptionVersion=env.PLAY_BILLING_EVENT_KEY_VERSION??'';
  const retainedVersions=(env.PLAY_BILLING_EVENT_RETAINED_VERSIONS??'').split(',');
  const limits={} as EventLimits;
  for(const name of Object.keys(CLOSED_EVENT_LIMITS) as (keyof EventLimits)[]) {
    const raw=env[`PLAY_BILLING_EVENT_LIMIT_${name.toUpperCase()}`]??'0';
    if(!/^(0|[1-9][0-9]{0,5})$/.test(raw)||Number(raw)>BOUNDED_EVENT_LIMITS[name]) throw new EventWorkError('configuration');
    limits[name]=Number(raw);
  }
  if(Object.values(limits).some(n=>n===0)||!validKeyVersion(encryptionVersion)||retainedVersions.length>8||
      !retainedVersions.includes(encryptionVersion)||retainedVersions.some(v=>!validKeyVersion(v)||!approvedVersions.includes(v))) throw new EventWorkError('configuration');
  return {enabled:true,limits,encryptionVersion,retainedVersions};
}
export interface EventRuntime {ingest(event:unknown):Promise<void>;pump():Promise<void>}
/** Used by the actual exported SDK callbacks and directly injectable in tests. */
export function eventHandlers(configuration:()=>EventRuntimeConfiguration|undefined, create:(config:EventRuntimeConfiguration)=>EventRuntime) {
  const run=async(kind:'ingest'|'pump',event?:unknown)=>{
    try { const config=configuration(); if(!config) {if(kind==='ingest') throw new EventWorkError('disabled');return;} const service=create(config);
      if(kind==='ingest') await service.ingest(event); else await service.pump();
    } catch(error) {throw new EventWorkError(error instanceof EventWorkError?error.reason:'transient');}
  };
  return {ingest:(event:unknown)=>run('ingest',event),pump:()=>run('pump')};
}
