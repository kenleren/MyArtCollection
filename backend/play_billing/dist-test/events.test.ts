import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {COLLECTIONS} from '../src/constants.js';
import {BillingDeadline} from '../src/deadline.js';
import {EventWorkRepository} from '../src/event_work.js';
import {EventProcessor} from '../src/event_processor.js';
import {KmsEventTokenCustody,eventCustodyAad} from '../src/event_token_custody.js';
import {EVENT_SOURCE,EVENT_TYPE,BOUNDED_EVENT_LIMITS,CLOSED_EVENT_LIMITS,type EventWorkRecord} from '../src/event_records.js';
import {eventHandlers,eventRuntimeConfiguration} from '../src/event_runtime.js';
import {parseRtdn} from '../src/rtdn.js';
import {receivePlayBillingEvent,pumpPlayBillingEvents} from '../src/event_firebase.js';
import {FakeKmsTransport,TEST_KEY,testCustody} from './fake_custody.js';
import {acceptDisclosure,createHarness,DeterministicNonceSource,eligiblePurchase,purchaseToken,verifyRequest,deferred} from './test_helpers.js';

export function notification(token?:string,id=randomUUID()):unknown {
 const body={version:'1.0',packageName:'app.archivale',eventTimeMillis:'1924992000000',...(token?
  {subscriptionNotification:{version:'1.0',notificationType:2,purchaseToken:token}}:{testNotification:{version:'1.0'}})};
 return {id,type:EVENT_TYPE,source:EVENT_SOURCE,data:{message:{messageId:id,data:Buffer.from(JSON.stringify(body)).toString('base64')}}};
}
function setup(limits=BOUNDED_EVENT_LIMITS) {
 const h=createHarness(),kms=new FakeKmsTransport(),eventCustody=new KmsEventTokenCustody(TEST_KEY,[TEST_KEY],kms);
 const work=new EventWorkRepository(h.database,new DeterministicNonceSource(),limits);
 const processor=new EventProcessor({work,repository:h.repository,identifiers:h.identifiers,eventCustody,accountCustody:h.custody,play:h.play,clock:h.clock});
 return {...h,kms,eventCustody,work,processor};
}
function jobs(h:ReturnType<typeof setup>):EventWorkRecord[] {return [...h.database.snapshotForTest()].filter(([k])=>k.startsWith(COLLECTIONS.eventWork+'/')).map(([,v])=>v as EventWorkRecord);}
const deadline=()=>new BillingDeadline();

test('actual SDK exports stay disabled before dependencies and configuration factories are skipped',async()=>{
 const previous=process.env.PLAY_BILLING_EVENTS_ENABLED;delete process.env.PLAY_BILLING_EVENTS_ENABLED;
 try {await assert.rejects(receivePlayBillingEvent.run({} as never),/disabled/);await pumpPlayBillingEvents.run({} as never);} finally {if(previous!==undefined)process.env.PLAY_BILLING_EVENTS_ENABLED=previous;}
 let creates=0;const handlers=eventHandlers(()=>undefined,()=>{creates++;throw Error('should not construct');});
 await assert.rejects(handlers.ingest({}),/disabled/);await handlers.pump();assert.equal(creates,0);
 assert.throws(()=>eventRuntimeConfiguration({PLAY_BILLING_EVENTS_ENABLED:'enabled'}),/configuration/);
 const failed=eventHandlers(()=>{throw Error('provider-secret-token');},()=>{creates++;throw Error();});
 await assert.rejects(failed.ingest({}),/^Error: billing event transient$/);assert.equal(creates,0);
 assert.equal(receivePlayBillingEvent.__endpoint.eventTrigger?.retry,true);
 assert.equal(receivePlayBillingEvent.__endpoint.concurrency,1);
});

test('RTDN exact source, canonical base64, UTF8, package, subtype and decoded bounds reject',()=>{
 const good=notification('token') as any;assert.equal(parseRtdn(good).token,'token');
 for(const change of [(v:any)=>v.source='//other', (v:any)=>v.type='other', (v:any)=>v.id='different',
  (v:any)=>v.data.message.data+='\n', (v:any)=>v.data.message.data=Buffer.alloc(8193).toString('base64'),
  (v:any)=>v.data.message.data=Buffer.from([255]).toString('base64'),
  (v:any)=>{const body=JSON.parse(Buffer.from(v.data.message.data,'base64').toString());body.packageName='wrong';v.data.message.data=Buffer.from(JSON.stringify(body)).toString('base64');}]) {
   const value=structuredClone(good);change(value);assert.throws(()=>parseRtdn(value),/billing event unsafe/);
 }
});

test('durable encrypted acceptance deduplicates and never persists raw tokens/payload; conflict fails',async()=>{
 const h=setup(),token=purchaseToken(),event=notification(token);
 await h.processor.ingest(event);await h.processor.ingest(event);
 assert.equal(jobs(h).length,1);assert.equal(h.kms.calls.length,1);assert.equal(jobs(h)[0].state,'ready');
 const serialized=JSON.stringify([...h.database.snapshotForTest()]);assert.equal(serialized.includes(token),false);
 const changed=notification(purchaseToken(),(event as any).id);await assert.rejects(h.processor.ingest(changed),/unsafe/);
 assert.equal(jobs(h).length,1);
});

test('failed encryption keeps one capacity slot; only matching redelivery can repair reserving',async()=>{
 const h=setup({...BOUNDED_EVENT_LIMITS,rows:1}),event=notification(purchaseToken());h.kms.fail=true;
 await assert.rejects(h.processor.ingest(event),/transient/);h.clock.advance(90_000);
 await h.processor.pump();assert.equal(jobs(h)[0].state,'reserving');assert.equal(h.kms.calls.length,1);
 await assert.rejects(h.processor.ingest(notification(purchaseToken())),/budget/);
 h.kms.fail=false;await h.processor.ingest(event);assert.equal(jobs(h)[0].state,'ready');
 assert.equal(jobs(h)[0].dispatchTotals.eventKms,2);
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/capacity') as any).totalRows,1);
});

for(const loss of ['marker','capacity','budget','all']) test(`capacity high-water ${loss} loss cannot reset over existing work`,async()=>{
 const h=setup();await h.processor.ingest(notification());
 for(const key of loss==='all'?['marker','capacity','budget']:[loss]) h.database.deleteRecordForTest(COLLECTIONS.eventControl,key);
 await assert.rejects(h.processor.ingest(notification()),/unsafe/);assert.equal(jobs(h).length,1);
});

test('zero budgets fail closed and no custody dispatch',async()=>{const h=setup(CLOSED_EVENT_LIMITS);await assert.rejects(h.processor.ingest(notification('token')),/budget/);assert.equal(h.kms.calls.length,0);});

test('expired working is due, reclaimed with new owner; old completion/cost cannot mutate',async()=>{
 const h=setup();await h.processor.ingest(notification('token'));const id=jobs(h)[0].eventFingerprint;
 const first=await h.work.claim(id,h.clock.now(),deadline());assert.ok(first);
 await h.work.charge(first,'discoveryGet',h.clock.now(),deadline());h.clock.advance(90_000);
 assert.deepEqual(await h.database.dueEventWork(h.clock.now(),10),[id]);
 const second=await h.work.claim(id,h.clock.now(),deadline());assert.ok(second);assert.equal(second.generation,first.generation+1);
 assert.equal(second.dispatchTotals.discoveryGet,1);assert.equal(second.totalAttempts,2);
 await assert.rejects(h.work.finish(first,'completed','none',h.clock.now(),deadline()),/unsafe/);
 await assert.rejects(h.work.charge(first,'ack',h.clock.now(),deadline()),/unsafe/);
 await h.work.finish(second,'blocked','unsafe',h.clock.now(),deadline());
 await h.processor.ingest(notification('token',(notification() as any).id)).catch(()=>{});
});

test('unseen direct route promotes encrypted account custody after a second GET and atomically grants',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 await h.processor.ingest(notification(token));await h.processor.pump();
 assert.equal(jobs(h)[0].state,'completed');assert.equal(h.play.getCalls.length,2);assert.equal(h.play.acknowledgeCalls.length,1);
 const binding=h.database.snapshotForTest().get(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)) as any;
 assert.equal(binding.ownershipProof.kind,'direct_route');assert.notEqual(binding.tokenEnvelope.version,jobs(h)[0].envelope?.version);
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.authorities+'/'+h.identifiers.accountSubject(h.identity.uid)) as any).snapshot.state,'active');
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.rateLimits+'/'+h.identifiers.accountSubject(h.identity.uid)),false);
});

test('known token expiry re-verifies without discovery, publishes none without ACK',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(token));
 h.clock.advance(20_000);h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'completed');
 assert.equal(h.play.getCalls.length,2);assert.equal(jobs(h)[0].dispatchTotals.discoveryGet,0);assert.equal(h.play.acknowledgeCalls.length,0);
});

test('unresolved event is durably blocked and duplicate does not silently requeue or reset costs',async()=>{
 const h=setup(),token=purchaseToken(),event=notification(token);const p=eligiblePurchase(h);delete p.externalAccountIdentifiers;h.play.setPurchase(token,p);
 await h.processor.ingest(event);await h.processor.pump();const before=jobs(h)[0];assert.equal(before.reason,'unresolved');
 await h.processor.ingest(event);assert.deepEqual(jobs(h)[0],before);assert.equal(h.play.getCalls.length,1);
});

test('linked token without external identifier resolves through bounded predecessor and preserves chain',async()=>{
 const h=setup();await acceptDisclosure(h);const old=purchaseToken();h.play.setPurchase(old,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(old));h.clock.advance(20_000);
 const token=purchaseToken(),p=eligiblePurchase(h);delete p.externalAccountIdentifiers;p.linkedPurchaseToken=old;h.play.setPurchase(token,p);
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'completed');
 const binding=h.database.snapshotForTest().get(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)) as any;assert.equal(binding.ownershipProof.kind,'linked_binding');
 assert.equal(binding.predecessorFingerprint,h.identifiers.tokenFingerprint(old));
});

test('expired-context replacement freshly checks competing current, ACKs route, and later tolerates omitted context',async()=>{
 const h=setup();await acceptDisclosure(h);const old=purchaseToken();h.play.setPurchase(old,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(old));h.clock.advance(20_000);
 h.play.setPurchase(old,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 const token=purchaseToken(),p=eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}),route=p.externalAccountIdentifiers!.obfuscatedExternalAccountId!;
 let acknowledgedBody:unknown;h.play.beforeAcknowledge=async args=>{acknowledgedBody=args.body;};
 delete p.externalAccountIdentifiers;p.outOfAppPurchaseContext={expiredPurchaseToken:old,expiredExternalAccountIdentifiers:{obfuscatedExternalAccountId:route}};h.play.setPurchase(token,p);
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'completed');
 assert.equal(jobs(h)[0].dispatchTotals.verificationGet,2);assert.deepEqual(acknowledgedBody,{externalAccountIds:{obfuscatedAccountId:route}});
 h.clock.advance(20_000);delete p.outOfAppPurchaseContext;p.acknowledgementState='ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED';h.play.setPurchase(token,p);
 const result=await h.service.verifySubscription(h.identity,verifyRequest(token));assert.equal(result.status,'paid');
});

test('expired historical context cannot replace a current chain that is still active',async()=>{
 const h=setup();await acceptDisclosure(h);const old=purchaseToken();h.play.setPurchase(old,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(old));h.clock.advance(20_000);
 const token=purchaseToken(),p=eligiblePurchase(h);p.outOfAppPurchaseContext={expiredPurchaseToken:old};delete p.externalAccountIdentifiers;h.play.setPurchase(token,p);
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'blocked');assert.equal(h.play.acknowledgeCalls.length,0);
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),false);
});

test('purpose and full KMS version are authenticated; event ciphertext cannot be account custody',async()=>{
 const kms=new FakeKmsTransport(),custody=new KmsEventTokenCustody(TEST_KEY,[TEST_KEY,TEST_KEY.replace('/1','/2')],kms);
 const context={eventFingerprint:'a'.repeat(64),payloadDigest:'b'.repeat(64),tokenFingerprint:'c'.repeat(64)};
 const envelope=await custody.encrypt('synthetic-token',context,deadline());
 await assert.rejects(custody.decrypt({...envelope,keyVersion:TEST_KEY.replace('/1','/2')},context,deadline()));
 await assert.rejects(custody.decrypt(envelope,{...context,payloadDigest:'d'.repeat(64)},deadline()));
 await assert.rejects(testCustody(kms).decrypt(envelope as never,{accountSubject:'a'.repeat(64),tokenFingerprint:'c'.repeat(64),lifecycleEpoch:'a'.repeat(32),lifecycleGeneration:1},deadline()));
 assert.equal(eventCustodyAad(context,TEST_KEY).includes(Buffer.from(TEST_KEY)),true);
});

test('stale resolved job cannot dispatch or publish after epoch retirement',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));
 const entered=deferred(),release=deferred();let calls=0;h.play.beforeGet=async()=>{if(++calls===2){entered.resolve();await release.promise;}};
 await h.processor.ingest(notification(token));const running=h.processor.pump();await entered.promise;
 const row=jobs(h)[0];assert.ok(row.resolved);await h.repository.retireLifecycle(row.resolved.accountSubject,row.resolved,h.clock.now());
 release.resolve();await running;assert.equal(h.play.acknowledgeCalls.length,0);
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),false);
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.authorities+'/'+row.resolved.accountSubject) as any).snapshot.reason,'retired');
});

test('reclaimed job fences late second GET before account custody or authority commit',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));
 const entered=deferred(),release=deferred();let calls=0;h.play.beforeGet=async()=>{if(++calls===2){entered.resolve();await release.promise;}};
 await h.processor.ingest(notification(token));const running=h.processor.pump();await entered.promise;const old=jobs(h)[0];
 h.clock.advance(90_000);const replacement=await h.work.claim(old.eventFingerprint,h.clock.now(),deadline());assert.ok(replacement);
 release.resolve();await assert.rejects(running,/unsafe/);assert.equal(h.play.acknowledgeCalls.length,0);
 assert.equal(jobs(h)[0].generation,replacement.generation);
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),false);
});

test('provider configuration error opens durable circuit without retrying or logging provider data',async()=>{
 const h=setup();const {PlayAdapterError}=await import('../src/play_adapter.js');h.play.getError=new PlayAdapterError('configuration');
 await h.processor.ingest(notification(purchaseToken()));await h.processor.pump();assert.equal(jobs(h)[0].reason,'configuration');
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/budget') as any).circuit,true);
 const calls=h.kms.calls.length;await assert.rejects(h.processor.ingest(notification(purchaseToken())),/configuration/);assert.equal(h.kms.calls.length,calls);
});

test('crash after remote ACK retains ownership proof and next delivery uses fresh GET without blind ACK',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken(),p=eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'});
 const route=p.externalAccountIdentifiers!.obfuscatedExternalAccountId!;delete p.externalAccountIdentifiers;
 p.outOfAppPurchaseContext={expiredExternalAccountIdentifiers:{obfuscatedExternalAccountId:route}};h.play.setPurchase(token,p);
 h.play.beforeAcknowledge=async()=>{delete p.outOfAppPurchaseContext;p.acknowledgementState='ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED';h.play.setPurchase(token,p);throw Error('synthetic lost response');};
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'retry');assert.equal(h.play.acknowledgeCalls.length,1);
 h.clock.advance(90_000);await h.processor.pump();assert.equal(jobs(h)[0].state,'completed');assert.equal(h.play.acknowledgeCalls.length,1);
 assert.equal(jobs(h)[0].totalAttempts,2);assert.equal(jobs(h)[0].dispatchTotals.ack,1);
});

test('blocked and completed rows retain capacity; retries preserve charged costs and attempt ceiling',async()=>{
 const h=setup({...BOUNDED_EVENT_LIMITS,rows:2});await h.processor.ingest(notification());
 const token=purchaseToken(),event=notification(token);await h.processor.ingest(event);const id=jobs(h).find(row=>row.tokenFingerprint)?.eventFingerprint!;
 for(let i=0;i<6;i++){const work=await h.work.claim(id,h.clock.now(),deadline());assert.ok(work);await h.work.charge(work,'verificationGet',h.clock.now(),deadline());await h.work.finish(work,'retry','transient',h.clock.now(),deadline());h.clock.advance(35_000*2**Math.min(i,4));}
 // The attempt timestamps are retained (bounded per rolling day), never reset by retry.
 assert.equal(jobs(h).find(row=>row.eventFingerprint===id)?.totalAttempts,6);
 assert.equal(jobs(h).find(row=>row.eventFingerprint===id)?.dispatchTotals.verificationGet,6);
 await assert.rejects(h.processor.ingest(notification()),/budget/);
});

test('production runtime configuration defaults budgets to zero even with every enable flag present',()=>{
 const env={GCLOUD_PROJECT:'my-art-collections',PLAY_BILLING_EVENTS_ENABLED:'enabled',PLAY_BILLING_ROUTING_ENABLED:'enabled',PLAY_BILLING_RECOVERY_ENABLED:'enabled',
 PLAY_BILLING_ANDROID_PUBLISHER_ENABLED:'enabled',PLAY_BILLING_TOKEN_CUSTODY_ENABLED:'enabled',PLAY_BILLING_EVENT_KEY_VERSION:TEST_KEY,PLAY_BILLING_EVENT_RETAINED_VERSIONS:TEST_KEY};
 assert.throws(()=>eventRuntimeConfiguration(env),/configuration/);
 const enabled={...env,...Object.fromEntries(Object.keys(BOUNDED_EVENT_LIMITS).map(key=>[`PLAY_BILLING_EVENT_LIMIT_${key.toUpperCase()}`,'1']))};
 assert.throws(()=>eventRuntimeConfiguration(enabled),/configuration/);assert.ok(eventRuntimeConfiguration(enabled,[TEST_KEY]));
});

test('KMS authentication or headers completing after parent cancellation never start fetch',async()=>{
 const {GoogleKmsTransport}=await import('../src/kms_token_custody.js');
 for(const phase of ['auth','headers'] as const){
  const entered=deferred(),release=deferred();let fetches=0;
  const transport=new GoogleKmsTransport({auth:{getClient:async()=>{if(phase==='auth'){entered.resolve();await release.promise;}return {getRequestHeaders:async()=>{if(phase==='headers'){entered.resolve();await release.promise;}return new Headers();}};}},fetch:async()=>{fetches++;throw Error('must not fetch');}});
  const invocation=deadline();const pending=transport.request(TEST_KEY,'encrypt',{},invocation);await entered.promise;invocation.cancel();release.resolve();
  await assert.rejects(pending,/custody unavailable/);assert.equal(fetches,0);
 }
});

test('unknown subscription type preserves encrypted token blocked; void and refund review are explicit non-granting outcomes',async()=>{
 const h=setup();
 for(const notificationBody of [
  {subscriptionNotification:{version:'1.0',notificationType:999,purchaseToken:'unknown-token'}},
  {subscriptionNotification:{version:'1.0',notificationType:14,purchaseToken:'gap-token'}},
  {voidedPurchaseNotification:{purchaseToken:'void-token',orderId:'synthetic-order',productType:1,refundType:1}},
  {pendingRefundReviewNotification:{version:'1.0',pendingRefundToken:'must-not-retain-refund-secret',orderId:'must-not-retain-order',refundReason:7}},
 ]) {
  const event=notification() as any;event.data.message.data=Buffer.from(JSON.stringify({version:'1.0',packageName:'app.archivale',eventTimeMillis:'1',...notificationBody})).toString('base64');
  await h.processor.ingest(event);
 }
 assert.deepEqual(jobs(h).map(row=>row.category),['unsupported','unsupported','void','refund_review']);
 assert.ok(jobs(h).every(row=>row.state==='blocked'));assert.equal(h.kms.calls.length,3);
 await h.processor.pump();assert.equal(h.play.getCalls.length,0);
 const stored=JSON.stringify([...h.database.snapshotForTest()]);assert.equal(stored.includes('must-not-retain'),false);assert.equal(stored.includes('synthetic-order'),false);
 const outer=notification() as any;for(let n=0;n<17;n++)outer['extra'+n]=0;assert.throws(()=>parseRtdn(outer),/unsafe/);
 const message=notification() as any;for(let n=0;n<9;n++)message.data.message['extra'+n]=0;assert.throws(()=>parseRtdn(message),/unsafe/);
});

test('inherited product names are never members of the closed subscription catalogue',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken(),p=eligiblePurchase(h);p.lineItems![0].productId='constructor';h.play.setPurchase(token,p);
 await h.processor.ingest(notification(token));await h.processor.pump();
 assert.notEqual(jobs(h)[0].state,'completed');assert.equal(h.play.acknowledgeCalls.length,0);
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),false);
});

test('KMS 401/403 uses fixed configuration classification and opens ingress circuit',async()=>{
 const {KmsConfigurationError,GoogleKmsTransport}=await import('../src/kms_token_custody.js');
 for(const status of [401,403]){
  const transport=new GoogleKmsTransport({auth:{getClient:async()=>({getRequestHeaders:async()=>new Headers()})},fetch:async()=>new Response('untrusted-provider-detail',{status})});
  await assert.rejects(transport.request(TEST_KEY,'encrypt',{},deadline()),error=>error instanceof KmsConfigurationError && !error.message.includes('untrusted'));
 }
 const h=setup();h.kms.beforeCall=async()=>{throw new KmsConfigurationError();};
 await assert.rejects(h.processor.ingest(notification('token')),/configuration/);
 assert.equal((h.database.snapshotForTest().get(COLLECTIONS.eventControl+'/budget') as any).circuit,true);
 assert.equal(jobs(h)[0].state,'reserving');
});

test('expired-current auxiliary proof cannot survive delayed custody beyond its freshness bound',async()=>{
 const h=setup();await acceptDisclosure(h);const old=purchaseToken();h.play.setPurchase(old,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(old));h.clock.advance(20_000);
 h.play.setPurchase(old,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 const token=purchaseToken(),p=eligiblePurchase(h);p.outOfAppPurchaseContext={expiredPurchaseToken:old};delete p.externalAccountIdentifiers;h.play.setPurchase(token,p);
 const encrypt=h.custody.encrypt.bind(h.custody);h.custody.encrypt=async(...args)=>{const envelope=await encrypt(...args);h.clock.advance(20_000);return envelope;};
 await h.processor.ingest(notification(token));await h.processor.pump();assert.equal(jobs(h)[0].state,'blocked');
 assert.equal(h.database.snapshotForTest().has(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),false);
});

test('deployment fixture matches exported private-delivery contract and requires trigger identity provisioning',async()=>{
 const {readFile}=await import('node:fs/promises');const fixture=JSON.parse(await readFile(new URL('../../fixtures/event-deployment-contract.json',import.meta.url),'utf8'));
 const {EVENT_DEPLOYMENT_CONTRACT,APPROVED_EVENT_KEY_VERSIONS}=await import('../src/event_runtime.js');
 assert.equal(fixture.topic,EVENT_DEPLOYMENT_CONTRACT.topic);assert.equal(fixture.runtimeAccount,receivePlayBillingEvent.__endpoint.serviceAccountEmail);
 assert.equal(fixture.topic,receivePlayBillingEvent.__endpoint.eventTrigger?.eventFilters.topic);
 assert.equal(fixture.triggerIdentityConfiguredBySdk,false);assert.deepEqual(fixture.approvedEventKeyVersions,APPROVED_EVENT_KEY_VERSIONS);
 assert.deepEqual(fixture.defaultLimits,CLOSED_EVENT_LIMITS);assert.equal(fixture.enabled,false);
});
