import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {test,after} from 'node:test';
import {initializeApp,deleteApp} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {BILLING_DATABASE_ID,COLLECTIONS} from '../src/constants.js';
import {createHarness,eligiblePurchase,purchaseToken,verifyRequest} from '../dist-test/test_helpers.js';
import {CryptoNonceSource} from '../src/crypto.js';
import {BillingRepository} from '../src/store.js';
import {FirestoreBillingDatabase} from '../src/firestore_store.js';
import {PlayBillingService} from '../src/verifier.js';
import {BillingDeadline} from '../src/deadline.js';
import {ReconciliationProcessor} from '../src/reconciliation_processor.js';
if(!process.env.FIRESTORE_EMULATOR_HOST)throw new Error('isolated emulator required');
const app=initializeApp({projectId:'demo-archivale-billing'},'reconciliation-'+randomUUID());
const firestore=getFirestore(app,BILLING_DATABASE_ID);after(()=>deleteApp(app));
const policy={activeMs:60_000,retryMs:30_000,maxRetryMs:900_000};
async function setup(target=firestore){
 const h=createHarness(),database=new FirestoreBillingDatabase(target),repository=new BillingRepository(database,new CryptoNonceSource(),h.identifiers,policy);
 const subject=h.identifiers.accountSubject(h.identity.uid);await repository.acceptDisclosure(subject,h.clock.now());const prepared=await repository.preparePurchase(subject,h.clock.now());assert.equal(prepared.kind,'ready');if(prepared.kind!=='ready')throw new Error('synthetic setup');
 const purchase=(expired=false)=>({...eligiblePurchase(h,expired?{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}:{}),externalAccountIdentifiers:{obfuscatedExternalAccountId:prepared.obfuscatedAccountId}});
 const service=new PlayBillingService({...h,repository}),token=purchaseToken();h.play.setPurchase(token,purchase());assert.equal((await service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
 const processor=new ReconciliationProcessor({...h,repository});h.clock.advance(61_000);return {...h,database,repository,service,processor,subject,token,purchase};
}
const get=async(c:string,id:string)=>(await firestore.collection(c).doc(id).get()).data()!;
test('named Firestore concurrent due claims preserve one work owner and root high-water',async()=>{
 const h=await setup();assert.ok(((await h.database.dueReconciliationWork(h.clock.now(),10)).map(r=>r.accountSubject)).includes(h.subject));
 const claims=await Promise.all([0,1,2].map(()=>h.repository.claimReconciliation(h.subject,h.clock.now(),new BillingDeadline())));assert.equal(claims.filter(Boolean).length,1);
 const work=await get(COLLECTIONS.reconcileWork,h.subject),root=await get(COLLECTIONS.lifecycles,h.subject);assert.equal(work.scheduleRevision,root.reconcileScheduleRevision);assert.equal(work.ownerGeneration,root.reconcileOwnerGeneration);assert.equal(work.attemptStarts.length,1);
});
test('named Firestore retained-custody expiry atomically closes operation and response receipt',async()=>{
 const h=await setup();h.play.setPurchase(h.token,h.purchase(true));const result=await h.processor.processOne(h.subject);assert.equal(result&&'reason'in result&&result.reason,'expired');
 const work=await get(COLLECTIONS.reconcileWork,h.subject),authority=await get(COLLECTIONS.authorities,h.subject),outbox=await get(COLLECTIONS.authorityOutbox,h.subject),root=await get(COLLECTIONS.lifecycles,h.subject);
 assert.equal(work.state,'policy_blocked');assert.equal(work.currentDemand,undefined);assert.equal(work.completedObservation.outcome,'inactive');assert.equal(root.reconcileScheduleRevision,work.scheduleRevision);assert.equal(authority.owner.phase,'complete');assert.deepEqual(outbox.snapshot,authority.snapshot);
 assert.equal((await get(COLLECTIONS.operations,h.identifiers.tokenFingerprint(h.token))).phase,'free');
});
test('named Firestore foreground versus reconciliation shares one account owner',async()=>{
 const h=await setup();const claimed=await h.repository.claimReconciliation(h.subject,h.clock.now(),new BillingDeadline());assert.ok(claimed);
 const outcomes=await Promise.all([
  h.repository.acquireAccountAttempt(h.subject,'a'.repeat(64),h.clock.now(),new BillingDeadline(),'background',{kind:'reconciliation',fence:claimed}),
  h.repository.acquireAttempt(h.subject,'b'.repeat(64),h.identifiers.tokenFingerprint(h.token),h.clock.now(),new BillingDeadline()),
 ]);assert.equal(outcomes.filter(x=>x.kind==='acquired').length,1);assert.equal(outcomes.filter(x=>x.kind==='in_flight').length,1);
});
test('named Firestore reclaim preserves attempts/cost high-water and fences late owner',async()=>{
 const h=await setup();const first=await h.repository.claimReconciliation(h.subject,h.clock.now(),new BillingDeadline());assert.ok(first);h.clock.advance(91_000);
 const second=await h.repository.claimReconciliation(h.subject,h.clock.now(),new BillingDeadline());assert.ok(second);assert.equal(second.ownerGeneration,first.ownerGeneration+1);
 assert.equal(await h.repository.retryReconciliation(first,h.clock.now(),new BillingDeadline()),false);const work=await get(COLLECTIONS.reconcileWork,h.subject);assert.equal(work.attemptStarts.length,2);assert.equal(work.ownerGeneration,second.ownerGeneration);
});
test('named Firestore paid current completion validates after successful transaction and loss cannot reset schedule',async()=>{
 const h=await setup();assert.equal((await h.processor.processOne(h.subject))?.status,'paid');const before=await get(COLLECTIONS.lifecycles,h.subject);
 await firestore.collection(COLLECTIONS.reconcileWork).doc(h.subject).delete();h.clock.advance(61_000);await assert.rejects(h.repository.claimReconciliation(h.subject,h.clock.now(),new BillingDeadline()));assert.deepEqual(await get(COLLECTIONS.lifecycles,h.subject),before);
});

// These use the existing authoritative processor and synthetic providers; B1's
// named dispatch cases separately prove the shared project last-unit boundary.
test('named Firestore pump projection is bounded and overlapping callbacks claim one account',async()=>{
 const {ReconciliationPump}=await import('../src/reconciliation_pump.js');
 const isolatedApp=initializeApp({projectId:'demo-archivale-pump-overlap'},'pump-overlap-'+randomUUID());
 after(()=>deleteApp(isolatedApp));const isolated=getFirestore(isolatedApp,BILLING_DATABASE_ID);
 const h=await setup(isolated),entered=await import('../dist-test/test_helpers.js').then(x=>x.deferred()),release=await import('../dist-test/test_helpers.js').then(x=>x.deferred());
 // Explicit local demo-project isolation; no other worker's cohort or controls.
 const query=h.database;
 const rows=await query.dueReconciliationWork(h.clock.now(),10);assert.equal(rows.length,1);assert.deepEqual(Object.keys(rows[0]).sort(),['accountSubject','dueAt','lastSuccessfulVerificationAt']);
 assert.ok(rows[0].dueAt instanceof Date);assert.ok(rows[0].lastSuccessfulVerificationAt instanceof Date);
 h.play.beforeGet=async()=>{entered.resolve();await release.promise;};
 const pump=new ReconciliationPump({database:query,processor:h.processor,clock:h.clock});
 const first=pump.run(new BillingDeadline());await entered.promise;
 const second=await pump.run(new BillingDeadline());assert.equal(second.startedCount,0);
 release.resolve();assert.equal((await first).paidCount,1);
 const work=(await isolated.collection(COLLECTIONS.reconcileWork).doc(h.subject).get()).data()!,root=(await isolated.collection(COLLECTIONS.lifecycles).doc(h.subject).get()).data()!;assert.equal(work.attemptStarts.length,1);assert.equal(work.ownerGeneration,root.reconcileOwnerGeneration);
});

test('named Firestore consent-blocked oldest pump work yields next selected account without counter reset',async()=>{
 const {ReconciliationPump}=await import('../src/reconciliation_pump.js');
 const isolatedApp=initializeApp({projectId:'demo-archivale-pump-consent'},'pump-consent-'+randomUUID());
 after(()=>deleteApp(isolatedApp));const isolated=getFirestore(isolatedApp,BILLING_DATABASE_ID);
 const read=async(c:string,id:string)=>(await isolated.collection(c).doc(id).get()).data()!;
 const old=await setup(isolated),healthy=await setup(isolated);
 const disclosure=await read(COLLECTIONS.disclosures,old.subject);
 // Move consent expiry into the past with internally consistent old timestamps.
 const expired=new Date(+old.clock.now()-1),accepted=new Date(+expired-90*86_400_000);
 await isolated.collection(COLLECTIONS.disclosures).doc(old.subject).set({...disclosure,acceptedAt:accepted,retentionExpiresAt:expired});
 const query=old.database;
 const processor={processOne:(subject:string,d?:BillingDeadline)=>(subject===old.subject?old:healthy).processor.processOne(subject,d)};
 const before=await read(COLLECTIONS.reconcileWork,old.subject);
 const pump=new ReconciliationPump({database:query,processor,clock:old.clock});const result=await pump.run(new BillingDeadline());
 assert.equal(result.unclaimedCount,1);assert.equal(result.paidCount,1);
 const blocked=await read(COLLECTIONS.reconcileWork,old.subject);assert.equal(blocked.state,'blocked');assert.equal(blocked.reason,'consent');assert.deepEqual(blocked.dispatchTotals,before.dispatchTotals);assert.deepEqual(blocked.attemptStarts,before.attemptStarts);
 assert.equal((await query.dueReconciliationWork(old.clock.now(),10)).length,0);
});

test('named isolated B2 factory pump and foreground contend for the same last project GET',async()=>{
 const {FakeClock,DeterministicNonceSource}=await import('../dist-test/test_helpers.js');
 const {initialDispatchControls,configurationDigest}=await import('../src/dispatch_budget.js');
 const {testDispatchConfig,legacyControls,meteredPlay,meteredCustody}=await import('../dist-test/dispatch_fixtures.js');
 const {createReconciliationAwareBillingRuntime,createReconciliationPumpRuntime,reconciliationRuntimeConfiguration,RECONCILIATION_RUNTIME_VERSION}=await import('../src/reconciliation_runtime.js');
 const {TEST_KEY}=await import('../dist-test/fake_custody.js');
 const isolatedApp=initializeApp({projectId:'demo-archivale-pump-budget'},'pump-budget-'+randomUUID());after(()=>deleteApp(isolatedApp));
 const isolated=getFirestore(isolatedApp,BILLING_DATABASE_ID),database=new FirestoreBillingDatabase(isolated),h=createHarness();
 h.clock=new FakeClock(new Date(Date.now()-61_000));
 const repository=new BillingRepository(database,new CryptoNonceSource(),h.identifiers,policy),service=new PlayBillingService({...h,repository});
 const second={uid:randomUUID()},tokens=[purchaseToken(),purchaseToken()],identities=[h.identity,second];
 for(let i=0;i<2;i++){
  const identity=identities[i],subject=h.identifiers.accountSubject(identity.uid);await repository.acceptDisclosure(subject,h.clock.now());
  const prepared=await repository.preparePurchase(subject,h.clock.now());assert.equal(prepared.kind,'ready');if(prepared.kind!=='ready')throw Error('synthetic preparation');
  h.play.setPurchase(tokens[i],{...eligiblePurchase(h),externalAccountIdentifiers:{obfuscatedExternalAccountId:prepared.obfuscatedAccountId}});
  assert.equal((await service.verifySubscription(identity,verifyRequest(tokens[i]))).status,'paid');
 }
 h.clock.advance(61_000);
 // Only first account belongs to this pump cohort; second remains foreground work.
 const secondSubject=h.identifiers.accountSubject(second.uid),secondRef=isolated.collection(COLLECTIONS.reconcileWork).doc(secondSubject);
 const secondWork=(await secondRef.get()).data()!;await secondRef.update({dueAt:new Date(+h.clock.now()+60_000),currentDemand:{...secondWork.currentDemand,dueAt:new Date(+h.clock.now()+60_000)}});
 const config=testDispatchConfig();config.global.get=1;for(const value of Object.values(config.sources))value.get=1;config.digest=configurationDigest(config);
 const controls=initialDispatchControls(config,h.clock.now(),'e'.repeat(64),{kind:'verified_new'}),legacy=legacyControls(),batch=isolated.batch();
 for(const [id,value] of Object.entries(controls))batch.set(isolated.collection(COLLECTIONS.dispatchControl).doc(id),value);
 for(const [id,value] of Object.entries(legacy))batch.set(isolated.collection(COLLECTIONS.eventControl).doc(id),value);
 await batch.commit();
 const raw=JSON.stringify({version:RECONCILIATION_RUNTIME_VERSION,enabled:true,policy});
 const dependencies={database,identifiers:h.identifiers,nonces:new DeterministicNonceSource(),clock:h.clock,
  providerFactories:{play:(gate:import('../src/dispatch_gate.js').DispatchGate)=>meteredPlay(gate,h.play),custody:(gate:import('../src/dispatch_gate.js').DispatchGate)=>meteredCustody(gate,h.custody)}};
 const env={GCLOUD_PROJECT:'my-art-collections',PLAY_BILLING_RECONCILIATION_CONFIG:raw,PLAY_BILLING_ROUTING_ENABLED:'enabled',PLAY_BILLING_RECOVERY_ENABLED:'enabled',PLAY_BILLING_ANDROID_PUBLISHER_ENABLED:'enabled',PLAY_BILLING_TOKEN_CUSTODY_ENABLED:'enabled',PLAY_BILLING_TOKEN_KEY_VERSION:TEST_KEY,PLAY_BILLING_TOKEN_RETAINED_VERSIONS:TEST_KEY,PLAY_BILLING_DISPATCH_CONFIG:JSON.stringify(config)};
 const runtime=await createReconciliationAwareBillingRuntime({...dependencies,deadline:new BillingDeadline(),providersNeeded:true,configuration:JSON.stringify(config),publisherEnabled:true,accountCustody:{enabled:true,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]}},raw);
 const pump=await createReconciliationPumpRuntime(reconciliationRuntimeConfiguration(env)!,new BillingDeadline(),()=>dependencies);
 const before=h.play.getCalls.length;
 const [summary,response]=await Promise.all([pump.run(new BillingDeadline()),new PlayBillingService({...h,...runtime}).verifySubscription(second,verifyRequest(tokens[1]))]);
 assert.equal(summary.selectedCount,1);assert.equal(summary.startedCount,1);assert.equal(h.play.getCalls.length-before,1);
 assert.equal(Number(summary.paidCount===1)+Number(response.status==='paid'),1);
 const budget=(await isolated.collection(COLLECTIONS.dispatchControl).doc('budget').get()).data()!;
 assert.equal(budget.totals.foreground.play_get+budget.totals.reconciliation.play_get,1);assert.equal(budget.totals.event.play_get,0);
 assert.equal((await isolated.collection(COLLECTIONS.reconcileWork).doc(h.identifiers.accountSubject(h.identity.uid)).get()).data()!.attemptStarts.length,1);
});
