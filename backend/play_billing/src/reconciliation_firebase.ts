import { getApp,getApps,initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret } from 'firebase-functions/params';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { info } from 'firebase-functions/logger';
import { BILLING_DATABASE_ID } from './constants.js';
import { createBillingIdentifiers,CryptoNonceSource } from './crypto.js';
import { FirestoreBillingDatabase } from './firestore_store.js';
import { createReconciliationPumpRuntime,reconciliationHandlers,reconciliationRuntimeConfiguration,ReconciliationPumpError,RECONCILIATION_DEPLOYMENT_CONTRACT as contract } from './reconciliation_runtime.js';
const key=defineSecret('PLAY_BILLING_FINGERPRINT_KEY');
const handlers=reconciliationHandlers(()=>reconciliationRuntimeConfiguration(process.env),(config,deadline)=>createReconciliationPumpRuntime(config,deadline,()=>{
  const raw=key.value(),bytes=Buffer.from(raw,'base64url');
  if(bytes.length<32||bytes.toString('base64url')!==raw)throw new ReconciliationPumpError('configuration_unavailable');
  const app=getApps().length?getApp():initializeApp();
  const identifiers=createBillingIdentifiers(bytes),nonces=new CryptoNonceSource(),clock={now:()=>new Date()};
  const database=new FirestoreBillingDatabase(getFirestore(app,BILLING_DATABASE_ID));
  return {database,identifiers,nonces,clock};
}),summary=>info('billing_reconciliation_run',summary));
// Scheduler authentication/invoker IAM is a separate provisioning/readback gate.
export const pumpPlayBillingReconciliation=onSchedule({region:contract.region,timeoutSeconds:contract.timeoutSeconds,memory:'512MiB',
  maxInstances:1,concurrency:1,minInstances:0,serviceAccount:contract.runtimeAccount,secrets:[key],
  schedule:contract.schedule,timeZone:'UTC',retryCount:0},async()=>{await handlers.pump();});
