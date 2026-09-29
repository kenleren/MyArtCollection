import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { getApps } from 'firebase-admin/app';
import { BillingDeadline } from '../src/deadline.js';
import { COLLECTIONS, DISCLOSURE_PURPOSE, DISCLOSURE_VERSION } from '../src/constants.js';
import { configurationDigest } from '../src/dispatch_budget.js';
import { pumpPlayBillingReconciliation } from '../src/reconciliation_firebase.js';
import { createReconciliationAwareBillingRuntime, createReconciliationPumpRuntime, reconciliationHandlers, reconciliationPolicy,
  reconciliationRuntimeConfiguration, RECONCILIATION_RUNTIME_VERSION, RECONCILIATION_DEPLOYMENT_CONTRACT, ReconciliationPumpError } from '../src/reconciliation_runtime.js';
import { PlayBillingService } from '../src/verifier.js';
import { createHarness, DeterministicNonceSource, FakeClock } from './test_helpers.js';
import { seedDispatch, testDispatchConfig } from './dispatch_fixtures.js';
import { TEST_KEY } from './fake_custody.js';
const policy={activeMs:60_000,retryMs:30_000,maxRetryMs:900_000};
const raw=JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:true,policy});
function env(){return {PLAY_BILLING_RECONCILIATION_CONFIG:raw,GCLOUD_PROJECT:'my-art-collections',PLAY_BILLING_ROUTING_ENABLED:'enabled',
  PLAY_BILLING_RECOVERY_ENABLED:'enabled',PLAY_BILLING_ANDROID_PUBLISHER_ENABLED:'enabled',PLAY_BILLING_TOKEN_CUSTODY_ENABLED:'enabled',
  PLAY_BILLING_DISPATCH_CONFIG:JSON.stringify(testDispatchConfig()),PLAY_BILLING_TOKEN_KEY_VERSION:TEST_KEY,PLAY_BILLING_TOKEN_RETAINED_VERSIONS:TEST_KEY};}

test('strict policy parser is closed, bounded and snapshots numeric policy',()=>{
 assert.equal(reconciliationPolicy(undefined),undefined);
 assert.equal(reconciliationPolicy(JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:false})),undefined);
 const value=reconciliationPolicy(raw);assert.deepEqual(value,policy);assert.ok(Object.isFrozen(value));
 for(const invalid of ['', 'null','[]','{','x'.repeat(1025),JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:false,policy}),
  JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:1,policy}),JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:true,policy,extra:true}),
  ...[{...policy,activeMs:59_999},{...policy,activeMs:86_400_001},{...policy,retryMs:14_999},{...policy,maxRetryMs:29_999},{...policy,maxRetryMs:3_600_001},{...policy,retryMs:'30000'},{...policy,activeMs:60_000.1},null].map(policy=>JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:true,policy}))])assert.throws(()=>reconciliationPolicy(invalid),ReconciliationPumpError);
});

test('enabled config rejects every missing prerequisite and zero source allocation before dependency reads',async()=>{
 const good=env();assert.ok(reconciliationRuntimeConfiguration(good));
 const cases:Record<string,string|undefined>[]=[];
 for(const key of Object.keys(good).filter(k=>k!=='PLAY_BILLING_RECONCILIATION_CONFIG'))cases.push({...good,[key]:undefined});
 cases.push({...good,PLAY_BILLING_RECONCILIATION_CONFIG:'{'});
 cases.push({...good,PLAY_BILLING_TOKEN_RETAINED_VERSIONS:[TEST_KEY,TEST_KEY].join(',')});
 for(const dimension of ['get','ack','kms'] as const){const config=testDispatchConfig();config.sources.reconciliation[dimension]=0;config.digest=configurationDigest(config);cases.push({...good,PLAY_BILLING_DISPATCH_CONFIG:JSON.stringify(config)});}
 for(const supplied of cases){let loads=0;const h=reconciliationHandlers(()=>reconciliationRuntimeConfiguration(supplied),()=>{loads++;throw Error('must not construct');});await assert.rejects(h.pump(),e=>e instanceof ReconciliationPumpError&&e.outcome==='configuration_unavailable');assert.equal(loads,0);}
});

test('disabled config and real exported scheduled run do not initialize Admin or read dependencies',async()=>{
 let reads=0;const supplied=new Proxy({} as Record<string,string|undefined>,{get(_t,key){if(key==='PLAY_BILLING_RECONCILIATION_CONFIG')return undefined;reads++;throw Error('disabled dependency read');}});
 const handlers=reconciliationHandlers(()=>reconciliationRuntimeConfiguration(supplied),()=>{reads++;throw Error('disabled construction');});
 assert.equal((await handlers.pump()).outcome,'disabled');assert.equal(reads,0);
 const before=getApps().length;
 const old=process.env.PLAY_BILLING_RECONCILIATION_CONFIG;
 delete process.env.PLAY_BILLING_RECONCILIATION_CONFIG;
 try{await pumpPlayBillingReconciliation.run({scheduleTime:'not-authority',jobName:'do-not-log'});}finally{if(old!==undefined)process.env.PLAY_BILLING_RECONCILIATION_CONFIG=old;}
 assert.equal(getApps().length,before);
});

for(const configuration of [undefined,'{'])test(`safety-only actual seam ignores ${configuration===undefined?'missing':'malformed'} policy and never reads budgets`,async()=>{
 const h=createHarness();let reads=0;const transaction=h.database.runTransaction.bind(h.database);
 h.database.runTransaction=f=>transaction(tx=>f({...tx,get:async(c,id)=>{if(c===COLLECTIONS.dispatchControl){reads++;return new Promise(()=>{});}return tx.get(c,id);}}));
 const runtime=await createReconciliationAwareBillingRuntime({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,deadline:new BillingDeadline(),providersNeeded:false},configuration);
 const service=new PlayBillingService({...h,...runtime}),subject=h.identifiers.accountSubject(h.identity.uid);
 const input={requestId:randomUUID(),disclosureVersion:DISCLOSURE_VERSION,purpose:DISCLOSURE_PURPOSE,accepted:true};
 assert.equal((await service.acceptDisclosure(h.identity,input)).status,'accepted');assert.equal((await runtime.repository.preparePurchase(subject,h.clock.now())).kind,'ready');
 await runtime.repository.revokeDisclosure(subject,h.clock.now());const root=h.database.snapshotForTest().get(COLLECTIONS.lifecycles+'/'+subject) as any;
 assert.equal(await runtime.repository.retireLifecycle(subject,root,h.clock.now()),true);assert.equal(reads,0);
});

test('actual enabled scheduled factory checks original controls before provider construction or due query',async()=>{
 const h=createHarness();h.clock=new FakeClock(new Date());seedDispatch(h.database,h.clock.now());h.database.deleteRecordForTest(COLLECTIONS.dispatchControl,'marker');
 let providers=0,queries=0;h.database.dueReconciliationWork=async()=>{queries++;return [];};
 const config=reconciliationRuntimeConfiguration(env())!;
 await assert.rejects(createReconciliationPumpRuntime(config,new BillingDeadline(),()=>({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,
  providerFactories:{play:()=>{providers++;throw Error('must not construct');},custody:()=>{providers++;throw Error('must not construct');}}})),ReconciliationPumpError);
 assert.equal(providers,0);assert.equal(queries,0);
});

test('delayed dependency loading cannot renew invocation or continue into shared construction',async()=>{
 const h=createHarness();let reads=0;h.database.runTransaction=async()=>{reads++;throw Error('late read');};
 let release!:()=>void;const held=new Promise<void>(r=>release=r);
 const deadline=new BillingDeadline(Date.now()+25);
 const pending=assert.rejects(createReconciliationPumpRuntime(reconciliationRuntimeConfiguration(env())!,deadline,async()=>{await held;return {database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock};}));
 await pending;release();await new Promise<void>(r=>setImmediate(r));assert.equal(reads,0);
});

test('deployment fixture agrees with actual SDK schedule but does not claim provisioned IAM',async()=>{
 const fixture=JSON.parse(await readFile(new URL('../../fixtures/reconciliation-deployment-contract.json',import.meta.url),'utf8'));
 const endpoint=pumpPlayBillingReconciliation.__endpoint;
 assert.deepEqual(fixture.sourceContract,RECONCILIATION_DEPLOYMENT_CONTRACT);
 assert.equal(endpoint.serviceAccountEmail,fixture.sourceContract.runtimeAccount);
 assert.equal(endpoint.scheduleTrigger?.schedule,fixture.sourceContract.schedule);
 assert.equal(endpoint.scheduleTrigger?.retryConfig?.retryCount,0);
 assert.equal(endpoint.scheduleTrigger?.timeZone,'UTC');assert.equal(fixture.schedulerIdentityConfiguredBySdk,false);assert.equal(fixture.productionCadenceApproved,false);
});
