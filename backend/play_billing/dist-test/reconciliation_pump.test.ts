import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createReconciliationAwareBillingRuntime,createReconciliationPumpRuntime,reconciliationRuntimeConfiguration,reconciliationHandlers,RECONCILIATION_RUNTIME_VERSION} from '../src/reconciliation_runtime.js';
import {ReconciliationPump} from '../src/reconciliation_pump.js';
import {ReconciliationProcessor} from '../src/reconciliation_processor.js';
import {GoogleAndroidPublisherTransport,AndroidPublisherSubscriptionsAdapter} from '../src/play_adapter.js';
import {GoogleKmsTokenCustody,GoogleKmsTransport} from '../src/kms_token_custody.js';
import {BillingDeadline} from '../src/deadline.js';
import {COLLECTIONS} from '../src/constants.js';
import {PlayBillingService} from '../src/verifier.js';
import type {ReconcileWork} from '../src/reconciliation_work.js';
import {createHarness,FakeClock,DeterministicNonceSource,acceptDisclosure,eligiblePurchase,purchaseToken,verifyRequest,deferred} from './test_helpers.js';
import {seedDispatch,testDispatchConfig} from './dispatch_fixtures.js';
import {TEST_KEY,FakeKmsTransport} from './fake_custody.js';
const policy={activeMs:60_000,retryMs:30_000,maxRetryMs:900_000};
const raw=JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:true,policy});
async function setup(){
 const h=createHarness();h.clock=new FakeClock(new Date());const config=testDispatchConfig();seedDispatch(h.database,h.clock.now(),config);
 const kms=new FakeKmsTransport(),counts={get:0,ack:0,kms:0};
 const auth={getClient:async()=>({getRequestHeaders:async()=>new Headers()})};
 const dependencies={database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,providerFactories:{
  play:(gate:import('../src/dispatch_gate.js').DispatchGate)=>new AndroidPublisherSubscriptionsAdapter(new GoogleAndroidPublisherTransport({gate,auth,fetch:async(url,init)=>{
   if(init.method==='GET'){counts.get++;return new Response(JSON.stringify(await h.play.getSubscription({packageName:'app.archivale',token:decodeURIComponent(url.split('/').pop()!),timeoutMs:10_000})));}counts.ack++;return new Response('');
  }})),
  custody:(gate:import('../src/dispatch_gate.js').DispatchGate)=>new GoogleKmsTokenCustody(TEST_KEY,[TEST_KEY],new GoogleKmsTransport({gate,auth,fetch:async(url,init)=>{
   counts.kms++;const action=url.endsWith(':encrypt')?'encrypt':'decrypt';return new Response(JSON.stringify(await kms.request(url.slice('https://cloudkms.googleapis.com/v1/'.length,url.lastIndexOf(':')),action,JSON.parse(init.body as string))));
  }})),
 }};
 const runtime=await createReconciliationAwareBillingRuntime({...dependencies,deadline:new BillingDeadline(),providersNeeded:true,configuration:JSON.stringify(config),publisherEnabled:true,accountCustody:{enabled:true,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]}},raw);
 h.repository=runtime.repository;h.service=new PlayBillingService({...h,...runtime});await acceptDisclosure(h);
 const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
 const env={PLAY_BILLING_RECONCILIATION_CONFIG:raw,GCLOUD_PROJECT:'my-art-collections',PLAY_BILLING_ROUTING_ENABLED:'enabled',PLAY_BILLING_RECOVERY_ENABLED:'enabled',
  PLAY_BILLING_ANDROID_PUBLISHER_ENABLED:'enabled',PLAY_BILLING_TOKEN_CUSTODY_ENABLED:'enabled',PLAY_BILLING_DISPATCH_CONFIG:JSON.stringify(config),PLAY_BILLING_TOKEN_KEY_VERSION:TEST_KEY,PLAY_BILLING_TOKEN_RETAINED_VERSIONS:TEST_KEY};
 return {...h,token,counts,dependencies,runtime,config,env,subject:h.identifiers.accountSubject(h.identity.uid)};
}
function work(h:Awaited<ReturnType<typeof setup>>){return h.database.snapshotForTest().get(COLLECTIONS.reconcileWork+'/'+h.subject) as ReconcileWork;}
for(const inactive of [undefined,'SUBSCRIPTION_STATE_EXPIRED','SUBSCRIPTION_STATE_ON_HOLD'] as const)test(`actual enabled factory/pump freshly rechecks retained custody (${inactive??'active'}) through shared transports`,async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});const h=await setup();const previous=work(h);assert.equal(previous.state,'ready');
 h.clock.advance(61_000);t.mock.timers.tick(61_000);
 if(inactive)h.play.setPurchase(h.token,eligiblePurchase(h,{state:inactive,expiryOffsetMs:inactive==='SUBSCRIPTION_STATE_EXPIRED'?-1:60_000}));
 const handler=reconciliationHandlers(()=>reconciliationRuntimeConfiguration(h.env),(c,d)=>createReconciliationPumpRuntime(c,d,()=>h.dependencies));
 const summary=await handler.pump();assert.equal(summary.outcome,'batch_finished');assert.equal(summary.startedCount,1);assert.equal(summary[inactive?'inactiveCount':'paidCount'],1);
 assert.deepEqual(h.counts,{get:2,ack:0,kms:2});
 const records=h.database.snapshotForTest(),budget=records.get(COLLECTIONS.dispatchControl+'/budget') as any;
 assert.deepEqual(budget.totals.reconciliation,{play_get:1,play_ack:0,kms_encrypt:0,kms_decrypt:1});
 const authority=records.get(COLLECTIONS.authorities+'/'+h.subject) as any,outbox=records.get(COLLECTIONS.authorityOutbox+'/'+h.subject) as any;
 assert.deepEqual(outbox.snapshot,authority.snapshot);assert.equal(work(h).completedObservation?.outcome,inactive?'inactive':'paid');
 if(inactive){assert.equal(work(h).currentDemand,undefined);assert.equal(work(h).state,'policy_blocked');assert.equal((await handler.pump()).selectedCount,0);}
});

test('actual policy seam does not enroll policy-blocked or mutate ready history on construction',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});const h=await setup();const before=h.database.snapshotForTest();
 for(const config of [undefined,'{',raw])await createReconciliationAwareBillingRuntime({...h.dependencies,providersNeeded:false,deadline:new BillingDeadline()},config);
 assert.deepEqual(h.database.snapshotForTest(),before);
 // A genuine publication without policy preserves history and stops scheduling.
 const disabled=await createReconciliationAwareBillingRuntime({...h.dependencies,providersNeeded:true,deadline:new BillingDeadline(),configuration:JSON.stringify(h.config),publisherEnabled:true,accountCustody:{enabled:true,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]}},undefined);
 h.clock.advance(20_000);t.mock.timers.tick(20_000);
 await new PlayBillingService({...h,...disabled}).verifySubscription(h.identity,verifyRequest(h.token));
 assert.equal(work(h).state,'policy_blocked');const blocked=h.database.snapshotForTest();
 const pump=await createReconciliationPumpRuntime(reconciliationRuntimeConfiguration(h.env)!,new BillingDeadline(),()=>h.dependencies);
 assert.equal((await pump.run(new BillingDeadline())).selectedCount,0);assert.deepEqual(h.database.snapshotForTest(),blocked);
});

test('overlapping actual pumps admit one owner; retirement while GET is held prevents paid publication',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});const h=await setup();h.clock.advance(61_000);t.mock.timers.tick(61_000);
 const entered=deferred(),release=deferred();h.play.beforeGet=async()=>{entered.resolve();await release.promise;};
 const pump=await createReconciliationPumpRuntime(reconciliationRuntimeConfiguration(h.env)!,new BillingDeadline(),()=>h.dependencies);
 const first=pump.run(new BillingDeadline());await entered.promise;
 const second=await pump.run(new BillingDeadline());assert.equal(second.startedCount,0);
 const root=h.database.snapshotForTest().get(COLLECTIONS.lifecycles+'/'+h.subject) as any;assert.equal(await h.repository.retireLifecycle(h.subject,root,h.clock.now()),true);
 release.resolve();const result=await first;assert.equal(result.paidCount,0);assert.equal(work(h).state,'retired');assert.equal(h.counts.get,2);
});

test('query cap, serial execution, immutable selection and one pass across eleven due rows',async()=>{
 const h=createHarness(),now=new Date();let concurrent=0,maximum=0,queries=0;const visited:string[]=[];
 for(let i=1;i<=11;i++)h.database.setUnsafeRecordForTest(COLLECTIONS.reconcileWork,i.toString(16).padStart(64,'0'),{state:'ready',dueAt:new Date(+now-1)});
 const query=h.database.dueReconciliationWork.bind(h.database);
 const pump=new ReconciliationPump({clock:{now:()=>now},database:{dueReconciliationWork:async(n,l)=>{queries++;return query(n,l);}},processor:{processOne:async subject=>{
  concurrent++;maximum=Math.max(maximum,concurrent);await Promise.resolve();visited.push(subject);h.database.setUnsafeRecordForTest(COLLECTIONS.reconcileWork,subject,{state:'ready',dueAt:new Date(+now+60_000)});concurrent--;return undefined;
 }}});
 const first=await pump.run(new BillingDeadline());assert.equal(first.selectedCount,10);assert.equal(first.startedCount,10);assert.equal(maximum,1);assert.equal(queries,1);
 const second=await pump.run(new BillingDeadline());assert.equal(second.startedCount,1);assert.equal(new Set(visited).size,11);assert.equal(queries,2);
});
for(const corruption of ['duplicate','order','future','subject','extra','overflow'] as const)test(`malformed bounded cohort ${corruption} makes no claims`,async()=>{
 const now=new Date();let claims=0;const a={accountSubject:'a'.repeat(64),dueAt:now},b={accountSubject:'b'.repeat(64),dueAt:now};
 const rows=corruption==='duplicate'?[a,a]:corruption==='order'?[b,a]:corruption==='future'?[{...a,dueAt:new Date(+now+1)}]:corruption==='subject'?[{...a,accountSubject:'unsafe'}]:corruption==='extra'?[{...a,token:'forbidden'}]:Array.from({length:11},()=>a);
 const result=await new ReconciliationPump({clock:{now:()=>now},database:{dueReconciliationWork:async()=>rows},processor:{processOne:async()=>{claims++;return undefined;}}}).run(new BillingDeadline());assert.equal(result.outcome,'unsafe_state');assert.equal(claims,0);
});

test('held query times out under original budget and never reaches a late claim',async()=>{
 const entered=deferred(),release=deferred();let claims=0;const now=new Date();
 const pending=new ReconciliationPump({clock:{now:()=>now},database:{dueReconciliationWork:async()=>{entered.resolve();await release.promise;return [{accountSubject:'a'.repeat(64),dueAt:now}];}},processor:{processOne:async()=>{claims++;return undefined;}}}).run(new BillingDeadline(Date.now()+25));
 await entered.promise;assert.equal((await pending).outcome,'partial_deadline');release.resolve();await new Promise<void>(r=>setImmediate(r));assert.equal(claims,0);
});

test('pump preserves retained attempt budget by deferring exhausted due head',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});const h=await setup();h.clock.advance(61_000);t.mock.timers.tick(61_000);
 h.database.setUnsafeRecordForTest(COLLECTIONS.reconcileWork,h.subject,{...work(h),attemptStarts:Array.from({length:12},()=>h.clock.now())});
 const pump=await createReconciliationPumpRuntime(reconciliationRuntimeConfiguration(h.env)!,new BillingDeadline(),()=>h.dependencies);
 const result=await pump.run(new BillingDeadline());assert.equal(result.unclaimedCount,1);assert.equal(work(h).reason,'budget');assert.equal(work(h).attemptStarts.length,12);assert.ok(work(h).dueAt>h.clock.now());assert.equal((await pump.run(new BillingDeadline())).selectedCount,0);assert.equal(h.counts.get,1);
});

test('concurrent success newer than query cutoff is advisory unknown lag, not unsafe authority',async()=>{
 const cutoff=new Date(),entered=deferred(),release=deferred();let claims=0;
 const pending=new ReconciliationPump({clock:{now:()=>cutoff},database:{dueReconciliationWork:async(now)=>{
  assert.equal(+now,+cutoff);entered.resolve();await release.promise;
  return [{accountSubject:'a'.repeat(64),dueAt:new Date(+cutoff-1),lastSuccessfulVerificationAt:new Date(+cutoff+1)}];
 }},processor:{processOne:async()=>{claims++;return undefined;}}}).run(new BillingDeadline());
 await entered.promise;release.resolve();const result=await pending;assert.equal(result.outcome,'batch_finished');assert.equal(result.selectedOldestKnownVerificationLagBucket,'unknown');assert.equal(result.selectedMissingSuccessCount,0);assert.equal(claims,1);
});
