import { createBillingRuntime, type BillingRuntimeOptions, type BillingRuntime } from './billing_runtime.js';
import { BillingDeadline } from './deadline.js';
import { dispatchConfiguration } from './dispatch_budget.js';
import { validPolicy, shape, type ReconcilePolicy } from './reconciliation_work.js';
import { validKeyVersion } from './token_custody.js';
import { emptyReconciliationSummary, reconciliationDeadlineElapsed, type ReconciliationOutcome, type ReconciliationSummary } from './reconciliation_pump.js';
import { UnsafeBillingRecordError } from './store.js';
import { ReconciliationProcessor } from './reconciliation_processor.js';
import { ReconciliationPump } from './reconciliation_pump.js';

export const RECONCILIATION_RUNTIME_VERSION='play-billing-reconciliation-runtime-v1';
export const RECONCILIATION_DEPLOYMENT_CONTRACT=Object.freeze({enabled:false,project:'my-art-collections',database:'archivale-play-billing',
  packageName:'app.archivale',runtimeAccount:'archivale-play-lifecycle-worker@my-art-collections.iam.gserviceaccount.com',region:'us-central1',
  timeoutSeconds:60,memory:'512MiB',maxInstances:1,concurrency:1,minInstances:0,schedule:'every 1 minutes',timeZone:'UTC',retryCount:0,
  invocationMs:50_000,selectionLimit:10,jobConcurrency:1,minimumStartMs:5_000});
const messages={disabled:'billing reconciliation disabled',configuration_unavailable:'billing reconciliation configuration unavailable',
  batch_finished:'billing reconciliation batch finished',partial_deadline:'billing reconciliation deadline unavailable',
  partial_failure:'billing reconciliation partial failure',unsafe_state:'billing reconciliation unsafe state'} as const;
export class ReconciliationPumpError extends Error {
  constructor(readonly outcome:ReconciliationOutcome){super(messages[outcome]);}
}
export function reconciliationPolicy(raw:string|undefined):Readonly<ReconcilePolicy>|undefined {
  if(raw===undefined)return undefined;
  if(typeof raw!=='string'||Buffer.byteLength(raw,'utf8')>1024)throw new ReconciliationPumpError('configuration_unavailable');
  let v:unknown;try{v=JSON.parse(raw);}catch{throw new ReconciliationPumpError('configuration_unavailable');}
  if(shape(v,['version','enabled'])&&(v as any).version===RECONCILIATION_RUNTIME_VERSION&&(v as any).enabled===false)return undefined;
  if(!shape(v,['version','enabled','policy'])||(v as any).version!==RECONCILIATION_RUNTIME_VERSION||(v as any).enabled!==true||!validPolicy((v as any).policy))throw new ReconciliationPumpError('configuration_unavailable');
  return Object.freeze({...((v as {policy:ReconcilePolicy}).policy)});
}
/** The real foreground, event and scheduled factories all use this optional-policy seam. */
export function createReconciliationAwareBillingRuntime(options:Omit<BillingRuntimeOptions,'reconciliationPolicy'>,raw:string|undefined):Promise<BillingRuntime>{
  let policy:Readonly<ReconcilePolicy>|undefined;try{policy=reconciliationPolicy(raw);}catch{policy=undefined;}
  return createBillingRuntime({...options,reconciliationPolicy:policy});
}
export interface ReconciliationRuntimeConfiguration {
  readonly rawConfiguration:string;readonly policy:Readonly<ReconcilePolicy>;readonly dispatchConfiguration:string;
  readonly encryptionVersion:string;readonly retainedVersions:readonly string[];
}
/** Reads non-secret supplied configuration only. No Admin, secret or ADC construction. */
export function reconciliationRuntimeConfiguration(env:Record<string,string|undefined>):ReconciliationRuntimeConfiguration|undefined {
  const rawConfiguration=env.PLAY_BILLING_RECONCILIATION_CONFIG;
  const policy=reconciliationPolicy(rawConfiguration);if(!policy)return undefined;
  if(env.GCLOUD_PROJECT!=='my-art-collections'||['PLAY_BILLING_ROUTING_ENABLED','PLAY_BILLING_RECOVERY_ENABLED','PLAY_BILLING_ANDROID_PUBLISHER_ENABLED','PLAY_BILLING_TOKEN_CUSTODY_ENABLED'].some(k=>env[k]!=='enabled'))throw new ReconciliationPumpError('configuration_unavailable');
  const raw=env.PLAY_BILLING_DISPATCH_CONFIG;
  let common;try{common=dispatchConfiguration(raw);}catch{throw new ReconciliationPumpError('configuration_unavailable');}
  if(!common||Object.values(common.global).some(n=>n===0)||Object.values(common.sources.reconciliation).some(n=>n===0))throw new ReconciliationPumpError('configuration_unavailable');
  const encryptionVersion=env.PLAY_BILLING_TOKEN_KEY_VERSION;
  const retainedRaw=env.PLAY_BILLING_TOKEN_RETAINED_VERSIONS??'';
  if(retainedRaw.length>4096)throw new ReconciliationPumpError('configuration_unavailable');
  const retainedVersions=retainedRaw.split(',');
  if(!validKeyVersion(encryptionVersion)||retainedVersions.length<1||retainedVersions.length>8||new Set(retainedVersions).size!==retainedVersions.length||!retainedVersions.includes(encryptionVersion)||retainedVersions.some(v=>!validKeyVersion(v)))throw new ReconciliationPumpError('configuration_unavailable');
  return Object.freeze({rawConfiguration:rawConfiguration!,policy,dispatchConfiguration:raw!,encryptionVersion,retainedVersions:Object.freeze(retainedVersions)});
}
export type ReconciliationDependencies=Pick<BillingRuntimeOptions,'database'|'identifiers'|'nonces'|'clock'|'providerFactories'>;
/** Actual enabled scheduled factory; injected loading is below the handler's strict config gate. */
export async function createReconciliationPumpRuntime(config:ReconciliationRuntimeConfiguration,deadline:BillingDeadline,
  load:()=>ReconciliationDependencies|Promise<ReconciliationDependencies>):Promise<ReconciliationPump>{
  deadline.check();
  const d=await deadline.run(()=>Promise.resolve(load()));
  deadline.check();
  const runtime=await createReconciliationAwareBillingRuntime({...d,deadline,providersNeeded:true,configuration:config.dispatchConfiguration,
    publisherEnabled:true,accountCustody:{enabled:true,encryptionVersion:config.encryptionVersion,retainedVersions:config.retainedVersions}},config.rawConfiguration);
  deadline.check();if(!runtime.gate)throw new ReconciliationPumpError('configuration_unavailable');
  return new ReconciliationPump({database:d.database,clock:d.clock,processor:new ReconciliationProcessor({...runtime,identifiers:d.identifiers,clock:d.clock})});
}
export interface ReconciliationRuntime {run(deadline:BillingDeadline):Promise<ReconciliationSummary>}
export type ReconciliationObserver=(summary:ReconciliationSummary)=>void|Promise<void>;
async function observeBounded(observer:ReconciliationObserver|undefined,summary:ReconciliationSummary,deadline:BillingDeadline):Promise<void>{
  if(!observer||reconciliationDeadlineElapsed(deadline))return;
  let timer:ReturnType<typeof setTimeout>|undefined;
  let cancel=()=>{};
  try{
    const work=Promise.resolve().then(()=>{if(!reconciliationDeadlineElapsed(deadline))return observer(summary);}).catch(()=>undefined);
    await Promise.race([work,new Promise<void>(resolve=>{
      cancel=resolve;deadline.signal.addEventListener('abort',cancel,{once:true});
      timer=setTimeout(resolve,Math.max(0,Math.min(250,deadline.expiresAt-Date.now())));
      if(deadline.signal.aborted)resolve();
    })]);
  }finally{clearTimeout(timer);deadline.signal.removeEventListener('abort',cancel);}
}
/** Optional deadline is an internal test seam; the exported scheduler supplies none. */
export function reconciliationHandlers(configuration:()=>ReconciliationRuntimeConfiguration|undefined,
  create:(configuration:ReconciliationRuntimeConfiguration,deadline:BillingDeadline)=>ReconciliationRuntime|Promise<ReconciliationRuntime>,observe?:ReconciliationObserver){
  return {pump:async(deadline=new BillingDeadline(Date.now()+50_000)):Promise<ReconciliationSummary>=>{
    let summary=emptyReconciliationSummary('configuration_unavailable'),constructed=false;
    try{
      deadline.check();const config=configuration();
      if(!config)return emptyReconciliationSummary('disabled');
      const runtime=await deadline.run(()=>Promise.resolve(create(config,deadline)));
      constructed=true;
      summary=await deadline.run(()=>runtime.run(deadline),Math.max(1,deadline.expiresAt-Date.now()));
    }catch(error){
      const outcome:ReconciliationOutcome=reconciliationDeadlineElapsed(deadline)?'partial_deadline':error instanceof UnsafeBillingRecordError?'unsafe_state':constructed?'partial_failure':'configuration_unavailable';
      summary=emptyReconciliationSummary(outcome);
    }
    await observeBounded(observe,summary,deadline);
    if(reconciliationDeadlineElapsed(deadline))summary=Object.freeze({...summary,outcome:'partial_deadline'});
    if(summary.outcome!=='batch_finished'&&summary.outcome!=='disabled')throw new ReconciliationPumpError(summary.outcome);
    return summary;
  }};
}
