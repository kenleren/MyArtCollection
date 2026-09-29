import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomUUID } from 'node:crypto';
import { createBillingRuntime } from '../src/billing_runtime.js';
import { DispatchGate, accountDispatch, eventDispatch } from '../src/dispatch_gate.js';
import { digest, configurationDigest, type DispatchConfiguration } from '../src/dispatch_budget.js';
import { GoogleAndroidPublisherTransport, AndroidPublisherSubscriptionsAdapter } from '../src/play_adapter.js';
import { GoogleKmsTransport, GoogleKmsTokenCustody } from '../src/kms_token_custody.js';
import { BillingRepository, type BillingTransaction,type BillingCollection } from '../src/store.js';
import { KmsEventTokenCustody } from '../src/event_token_custody.js';
import { EventProcessor } from '../src/event_processor.js';
import { EventWorkRepository } from '../src/event_work.js';
import { BOUNDED_EVENT_LIMITS, EVENT_CUSTODY_VERSION, EVENT_SOURCE, EVENT_TYPE } from '../src/event_records.js';
import { BillingDeadline } from '../src/deadline.js';
import { PlayBillingService } from '../src/verifier.js';
import { COLLECTIONS, CONTRACT_VERSION, DISCLOSURE_VERSION, DISCLOSURE_PURPOSE } from '../src/constants.js';
import { createHarness,FakeClock,DeterministicNonceSource,acceptDisclosure,eligiblePurchase,purchaseToken,verifyRequest,deferred } from './test_helpers.js';
import { TEST_KEY, FakeKmsTransport } from './fake_custody.js';
import { seedDispatch,testDispatchConfig } from './dispatch_fixtures.js';
const restore=()=>({version:CONTRACT_VERSION,requestId:randomUUID(),billingDisclosureVersion:DISCLOSURE_VERSION});
const auth={getClient:async()=>({getRequestHeaders:async()=>new Headers()})};
async function setup(config=testDispatchConfig(),events=false){
 const h=createHarness();h.clock=new FakeClock(new Date());seedDispatch(h.database,h.clock.now(),config);
 const counts={get:0,ack:0,kms:0,constructed:0};const kms=new FakeKmsTransport();const failure:{status?:number}={};
 const runtime=await createBillingRuntime({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,
  deadline:new BillingDeadline(),providersNeeded:true,configuration:JSON.stringify(config),publisherEnabled:true,
  ...(events?{events:{limits:BOUNDED_EVENT_LIMITS,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]}}:{}),
  accountCustody:{enabled:true,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]},providerFactories:{
   play:gate=>{counts.constructed++;return new AndroidPublisherSubscriptionsAdapter(new GoogleAndroidPublisherTransport({gate,auth,fetch:async(url,init)=>{
    if(init.method==='GET'){counts.get++;if(failure.status)return new Response('',{status:failure.status});const token=decodeURIComponent(url.split('/').pop()!);return new Response(JSON.stringify(await h.play.getSubscription({packageName:'app.archivale',token,timeoutMs:10_000})));}
    counts.ack++;return new Response('');
   }}));},
   custody:gate=>{counts.constructed++;return new GoogleKmsTokenCustody(TEST_KEY,[TEST_KEY],new GoogleKmsTransport({gate,auth,fetch:async(url,init)=>{
    counts.kms++;const action=url.endsWith(':encrypt')?'encrypt':'decrypt';const resource=url.slice('https://cloudkms.googleapis.com/v1/'.length,url.lastIndexOf(':'));
    return new Response(JSON.stringify(await kms.request(resource,action,JSON.parse(init.body as string))));
   }}));},
   eventCustody:gate=>new KmsEventTokenCustody(TEST_KEY,[TEST_KEY],new GoogleKmsTransport({gate,auth,fetch:async(url,init)=>{counts.kms++;const action=url.endsWith(':encrypt')?'encrypt':'decrypt';const resource=url.slice('https://cloudkms.googleapis.com/v1/'.length,url.lastIndexOf(':'));return new Response(JSON.stringify(await kms.request(resource,action,JSON.parse(init.body as string))));}})),
  }});
 h.repository=runtime.repository;h.custody=runtime.custody;h.service=new PlayBillingService({...h,play:runtime.play});
 return {...h,runtime,counts,kms,config,failure};
}
function control(h:Awaited<ReturnType<typeof setup>>){return h.database.snapshotForTest().get(COLLECTIONS.dispatchControl+'/budget') as any;}

test('actual factory/Google transports: first replay-backed purchase, retained same-account restore and ACK are metered',async(t)=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});
 const h=await setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 assert.equal((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');assert.deepEqual(h.counts,{get:1,ack:1,kms:1,constructed:2});
 h.clock.advance(20_000);t.mock.timers.tick(20_000);h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.restoreEntitlement(h.identity,restore())).status,'paid');
 assert.deepEqual(control(h).totals.foreground,{play_get:2,play_ack:1,kms_encrypt:1,kms_decrypt:1});
 const owner=(h.database.snapshotForTest().get(COLLECTIONS.authorities+'/'+h.identifiers.accountSubject(h.identity.uid)) as any).owner;
 assert.deepEqual(owner.dispatchCounts,{get:1,ack:0,kms:1});
});

test('ACK budget denial preserves the intent barrier; acknowledged recovery fresh-GETs without another ACK',async(t)=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});
 const c=testDispatchConfig();c.global.ack=0;for(const s of Object.values(c.sources))s.ack=0;c.digest=configurationDigest(c);
 const h=await setup(c);await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 assert.notEqual((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');assert.equal(h.counts.ack,0);
 const subject=h.identifiers.accountSubject(h.identity.uid);const authority=h.database.snapshotForTest().get(COLLECTIONS.authorities+'/'+subject) as any;
 assert.equal(authority.owner.phase,'ack_unknown');assert.equal(authority.acknowledgementRecoveryToken,h.identifiers.tokenFingerprint(token));assert.equal(control(h).totals.foreground.play_ack,0);
 h.clock.advance(20_000);t.mock.timers.tick(20_000);h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.restoreEntitlement(h.identity,restore())).status,'paid');assert.equal(h.counts.get,2);assert.equal(h.counts.ack,0);
});

for(const config of [undefined,'{}',JSON.stringify({...testDispatchConfig(),enabled:false})])test(`closed actual factory constructs no providers (${config===undefined?'missing':config==='{}'?'invalid':'disabled'})`,async()=>{
 const h=createHarness();let reads=0,made=0;const run=h.database.runTransaction.bind(h.database);h.database.runTransaction=async f=>{reads++;return run(f);};
 const runtime=await createBillingRuntime({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,deadline:new BillingDeadline(),providersNeeded:true,configuration:config,publisherEnabled:true,
 providerFactories:{play:()=>{made++;throw Error('must not construct');}}});assert.equal(reads,0);assert.equal(made,0);await assert.rejects(runtime.play.getSubscription({packageName:'app.archivale',token:'synthetic',timeoutMs:10_000}));
});

test('safety-only factory skips even a never-resolving common read; accept/prepare/revoke/retire remain usable',async()=>{
 const h=createHarness(),original=h.database.runTransaction.bind(h.database);let commonReads=0;
 h.database.runTransaction=f=>original(tx=>f({...tx,get:async(c,id)=>{if(c===COLLECTIONS.dispatchControl){commonReads++;return new Promise(()=>{});}return tx.get(c,id);}}));
 const runtime=await createBillingRuntime({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,deadline:new BillingDeadline(Date.now()+1000),providersNeeded:false,configuration:JSON.stringify(testDispatchConfig()),publisherEnabled:true});
 const service=new PlayBillingService({...h,...runtime});const subject=h.identifiers.accountSubject(h.identity.uid);
 assert.equal((await service.acceptDisclosure(h.identity,{requestId:randomUUID(),disclosureVersion:DISCLOSURE_VERSION,purpose:DISCLOSURE_PURPOSE,accepted:true})).status,'accepted');
 assert.equal((await service.preparePurchase(h.identity,restore())).status,'ready');await runtime.repository.revokeDisclosure(subject,h.clock.now());
 const root=h.database.snapshotForTest().get(COLLECTIONS.lifecycles+'/'+subject) as any;assert.equal(await runtime.repository.retireLifecycle(subject,root,h.clock.now()),true);assert.equal(commonReads,0);
});

test('provider construction keeps the original already-spent invocation deadline',async()=>{
 const h=createHarness();seedDispatch(h.database,h.clock.now());let made=0;const deadline=new BillingDeadline(Date.now()+20);await new Promise(r=>setTimeout(r,25));
 await assert.rejects(createBillingRuntime({database:h.database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,deadline,providersNeeded:true,configuration:JSON.stringify(testDispatchConfig()),publisherEnabled:true,providerFactories:{play:()=>{made++;throw Error();}}}));assert.equal(made,0);
});
async function acquire(h:Awaited<ReturnType<typeof setup>>){await acceptDisclosure(h);const token=purchaseToken();const deadline=new BillingDeadline();const result=await h.repository.acquireAttempt(h.identifiers.accountSubject(h.identity.uid),h.identifiers.requestFingerprint(h.identity.uid,randomUUID()),h.identifiers.tokenFingerprint(token),h.clock.now(),deadline);assert.equal(result.kind,'acquired');if(result.kind!=='acquired')throw Error();return {attempt:result.attempt,token,deadline};}

test('local denial leaves both ledgers unchanged and source cannot be relabeled',async()=>{
 const h=await setup(),a=await acquire(h),cap=accountDispatch(a.attempt,'lookup_in_flight'),gate=h.runtime.gate!;
 for(let n=0;n<3;n++)await gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline);
 const before=h.database.snapshotForTest();await assert.rejects(gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline));assert.deepEqual(h.database.snapshotForTest(),before);
 const changed=JSON.parse(cap.kind.startsWith('account')&&(cap as any).attempt);changed.fence.source='background';const forged={...cap,attempt:JSON.stringify(changed)};
 await assert.rejects(gate.reserve(forged,gate.playDescriptor(forged,'play_get',a.token),a.deadline));assert.deepEqual(h.database.snapshotForTest(),before);
});
for(const change of ['revoke','retire','phase','index','lease','consent'] as const)test(`final repository read fences ${change} before fetch while retaining physical charge`,async()=>{
 const h=await setup(),a=await acquire(h),cap=accountDispatch(a.attempt,'lookup_in_flight'),gate=h.runtime.gate!,subject=a.attempt.accountSubject;
 const ticket=await gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline);const budget=control(h);
 if(change==='revoke')await h.repository.revokeDisclosure(subject,h.clock.now());
 else if(change==='retire')await h.repository.retireLifecycle(subject,a.attempt,h.clock.now());
 else if(change==='phase')await h.repository.markVerifiedOwner(a.attempt,'archivale_starter_monthly',h.clock.now());
 else if(change==='index'){const key=COLLECTIONS.accounts;const old=h.database.snapshotForTest().get(key+'/'+subject) as any;h.database.setUnsafeRecordForTest(key,subject,{...old,revision:10});}
 else if(change==='lease')h.clock.advance(90_000);
 else {const old=h.database.snapshotForTest().get(COLLECTIONS.disclosures+'/'+subject) as any;h.database.setUnsafeRecordForTest(COLLECTIONS.disclosures,subject,{...old,retentionExpiresAt:h.clock.now()});}
 let calls=0;await assert.rejects(gate.consume(ticket,async()=>{calls++;}));assert.equal(calls,0);assert.deepEqual(control(h),budget);
});

test('final asynchronous control read cannot hide expiry after earlier owner reads',async()=>{
 const h=await setup(),a=await acquire(h),cap=accountDispatch(a.attempt,'lookup_in_flight'),gate=h.runtime.gate!;
 const ticket=await gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline);const run=h.database.runTransaction.bind(h.database);
 h.database.runTransaction=f=>run(tx=>f({...tx,get:async<T>(c:BillingCollection,id:string)=>{const v=await tx.get<T>(c,id);if(c===COLLECTIONS.dispatchControl&&id==='budget')h.clock.advance(90_000);return v;}}));
 let calls=0;await assert.rejects(gate.consume(ticket,async()=>{calls++;}));assert.equal(calls,0);
});

test('lost committed reservation result retains counters but issues no usable ticket or fetch',async()=>{
 const h=await setup(),a=await acquire(h),cap=accountDispatch(a.attempt,'lookup_in_flight'),gate=h.runtime.gate!;const run=h.database.runTransaction.bind(h.database);
 h.database.runTransaction=async f=>{await run(f);throw Error('synthetic committed result lost');};
 await assert.rejects(gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline));assert.equal(control(h).totals.foreground.play_get,1);assert.equal(h.counts.get,0);
});

function event(token:string){const id=randomUUID();return {id,type:EVENT_TYPE,source:EVENT_SOURCE,data:{message:{messageId:id,data:Buffer.from(JSON.stringify({version:'1.0',packageName:'app.archivale',eventTimeMillis:String(Date.now()),subscriptionNotification:{version:'1.0',notificationType:2,purchaseToken:token}})).toString('base64')}}};}
test('actual event factory transports meter inbox/discovery/fresh account GET/encrypt/ACK in one shared ledger',async()=>{
 const h=await setup(testDispatchConfig(),true);await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 const p=new EventProcessor({identifiers:h.identifiers,clock:h.clock,repository:h.repository,work:h.runtime.events!,eventCustody:h.runtime.eventCustody!,accountCustody:h.runtime.custody,play:h.runtime.play});
 await p.ingest(event(token));await p.pump();
 assert.deepEqual(control(h).totals.event,{play_get:2,play_ack:1,kms_encrypt:2,kms_decrypt:1});
 const work=[...h.database.snapshotForTest()].find(([k])=>k.startsWith(COLLECTIONS.eventWork+'/'))![1] as any;
 assert.equal(work.state,'completed');assert.deepEqual(work.dispatchTotals,{discoveryGet:1,verificationGet:1,eventKms:2,accountKms:1,ack:1});
 assert.equal(h.counts.get,2);assert.equal(h.counts.ack,1);assert.equal(h.counts.kms,3);
});
for(const corruption of ['pair_reset','lost_start','decreased_kind','retained_floor'])test(`continuing legacy ${corruption} fails before dispatch and does not repair history`,async()=>{
 const h=await setup(testDispatchConfig(),true);const p=new EventProcessor({identifiers:h.identifiers,clock:h.clock,repository:h.repository,work:h.runtime.events!,eventCustody:h.runtime.eventCustody!,accountCustody:h.runtime.custody,play:h.runtime.play});
 await p.ingest(event(purchaseToken()));
 const marker=h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/marker') as any;
 const budget=h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/budget') as any;
 if(corruption==='pair_reset'){budget.revision=0;budget.totals.eventKms=0;budget.starts.eventKms=[];marker.budgetRevision=0;}
 if(corruption==='lost_start')budget.starts.eventKms=[];
 if(corruption==='decreased_kind')budget.totals.eventKms--;
 if(corruption==='retained_floor'){
  const c=control(h);c.legacy={kind:'retained',digest:digest(budget),revision:budget.revision,totals:{...budget.totals,discoveryGet:5}};
  h.database.setUnsafeRecordForTest(COLLECTIONS.dispatchControl,'budget',c);
 }
 h.database.setUnsafeRecordForTest(COLLECTIONS.eventControl,'marker',marker);h.database.setUnsafeRecordForTest(COLLECTIONS.eventControl,'budget',budget);
 const before=h.database.snapshotForTest(),calls=h.counts.kms;await assert.rejects(p.ingest(event(purchaseToken())));assert.equal(h.counts.kms,calls);assert.deepEqual(h.database.snapshotForTest(),before);
});
test('configuration failure opens common and legacy circuit, blocks another source, but safety operations remain available',async()=>{
 const h=await setup(testDispatchConfig(),true);await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));h.failure.status=403;
 assert.notEqual((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');assert.equal(control(h).circuit.state,'open');
 const old=h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/budget') as any;assert.equal(old.circuit,true);assert.deepEqual(control(h).legacyHead,{revision:old.revision,digest:digest(old)});
 const p=new EventProcessor({identifiers:h.identifiers,clock:h.clock,repository:h.repository,work:h.runtime.events!,eventCustody:h.runtime.eventCustody!,accountCustody:h.runtime.custody,play:h.runtime.play});
 await assert.rejects(p.ingest(event(purchaseToken())));assert.equal(h.counts.kms,0);
 await h.repository.revokeDisclosure(h.identifiers.accountSubject(h.identity.uid),h.clock.now());
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.disclosures+'/'+h.identifiers.accountSubject(h.identity.uid)) as any).status,'revoked');
});

test('old owner without paired dispatch metadata cannot adopt fresh local counters',async()=>{
 const h=await setup(),a=await acquire(h),subject=a.attempt.accountSubject;
 const old=h.database.snapshotForTest().get(COLLECTIONS.authorities+'/'+subject) as any;delete old.owner.dispatchVersion;delete old.owner.dispatchCounts;
 h.database.setUnsafeRecordForTest(COLLECTIONS.authorities,subject,old);const before=h.database.snapshotForTest();
 const cap=accountDispatch(a.attempt,'lookup_in_flight'),gate=h.runtime.gate!;await assert.rejects(gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline));assert.deepEqual(h.database.snapshotForTest(),before);
});
for(const alteration of ['token','phase','owner','raw_field'] as const)test(`closed capability rejects ${alteration} before any physical charge`,async()=>{
 const h=await setup(),a=await acquire(h),original=accountDispatch(a.attempt,'lookup_in_flight'),cap:any=JSON.parse(JSON.stringify(original));
 if(alteration==='token')cap.tokenFingerprint='a'.repeat(64);else if(alteration==='phase')cap.phase='verified_owner';
 else if(alteration==='raw_field')cap.rawToken=a.token;else {const snapshot=JSON.parse(cap.attempt);snapshot.owner.attemptGeneration++;cap.attempt=JSON.stringify(snapshot);}
 const before=h.database.snapshotForTest(),gate=h.runtime.gate!;
 await assert.rejects(async()=>gate.reserve(cap,gate.playDescriptor(cap,'play_get',a.token),a.deadline));assert.deepEqual(h.database.snapshotForTest(),before);
});
