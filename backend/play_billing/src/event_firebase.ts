import { createReconciliationAwareBillingRuntime } from './reconciliation_runtime.js';
import { dispatchConfiguration } from './dispatch_budget.js';
import {getApp,getApps,initializeApp} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {defineSecret} from 'firebase-functions/params';
import {onMessagePublished} from 'firebase-functions/v2/pubsub';
import {onSchedule} from 'firebase-functions/v2/scheduler';
import {BILLING_DATABASE_ID} from './constants.js';
import {createBillingIdentifiers,CryptoNonceSource} from './crypto.js';
import {FirestoreBillingDatabase} from './firestore_store.js';
import {EventProcessor} from './event_processor.js';
import {EVENT_TOPIC,EventWorkError} from './event_records.js';
import {EVENT_RUNTIME_ACCOUNT,EVENT_TRIGGER_ACCOUNT,eventRuntimeConfiguration,eventHandlers} from './event_runtime.js';
import {validKeyVersion} from './token_custody.js';
const key=defineSecret('PLAY_BILLING_FINGERPRINT_KEY');
const options={region:'us-central1',timeoutSeconds:60,memory:'512MiB' as const,maxInstances:1,concurrency:1,minInstances:0,
  serviceAccount:EVENT_RUNTIME_ACCOUNT,secrets:[key]};
const handlers=eventHandlers(()=>{
  const config=eventRuntimeConfiguration(process.env); if(!config) return undefined;
  try{if(!dispatchConfiguration(process.env.PLAY_BILLING_DISPATCH_CONFIG))return undefined;}catch{throw new EventWorkError('configuration');}
  // Validate account custody configuration too, before initializeApp/ADC.
  const version=process.env.PLAY_BILLING_TOKEN_KEY_VERSION;
  const retained=(process.env.PLAY_BILLING_TOKEN_RETAINED_VERSIONS??'').split(',');
  if(!validKeyVersion(version)||retained.length>8||!retained.includes(version)||retained.some(v=>!validKeyVersion(v))) throw new EventWorkError('configuration');
  return config;
},async(config,deadline)=>{
  const raw=key.value();const bytes=Buffer.from(raw,'base64url');
  if(bytes.length<32||bytes.toString('base64url')!==raw) throw new EventWorkError('configuration');
  const app=getApps().length?getApp():initializeApp();
  const identifiers=createBillingIdentifiers(bytes), nonces=new CryptoNonceSource();
  const database=new FirestoreBillingDatabase(getFirestore(app,BILLING_DATABASE_ID));
  const clock={now:()=>new Date()};
  const runtime=await createReconciliationAwareBillingRuntime({database,identifiers,nonces,clock,deadline,providersNeeded:true,
    configuration:process.env.PLAY_BILLING_DISPATCH_CONFIG,publisherEnabled:true,events:config,
    accountCustody:{enabled:true,encryptionVersion:process.env.PLAY_BILLING_TOKEN_KEY_VERSION!,retainedVersions:process.env.PLAY_BILLING_TOKEN_RETAINED_VERSIONS!.split(',')}},process.env.PLAY_BILLING_RECONCILIATION_CONFIG);
  if(!runtime.events||!runtime.eventCustody||!runtime.gate)throw new EventWorkError('configuration');
  return new EventProcessor({identifiers,repository:runtime.repository,work:runtime.events,clock,
    eventCustody:runtime.eventCustody,accountCustody:runtime.custody,play:runtime.play});
});
export const receivePlayBillingEvent=onMessagePublished({...options,topic:EVENT_TOPIC,retry:true,serviceAccount:EVENT_RUNTIME_ACCOUNT},handlers.ingest);
// Scheduler identity/invoker IAM is validated at provisioning, never a public HTTP route.
export const pumpPlayBillingEvents=onSchedule({...options,schedule:'every 1 minutes',retryCount:0},handlers.pump);
export {EVENT_TRIGGER_ACCOUNT};
