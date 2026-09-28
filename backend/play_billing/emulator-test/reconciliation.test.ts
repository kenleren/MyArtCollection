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
async function setup(){
 const h=createHarness(),database=new FirestoreBillingDatabase(firestore),repository=new BillingRepository(database,new CryptoNonceSource(),h.identifiers,policy);
 const subject=h.identifiers.accountSubject(h.identity.uid);await repository.acceptDisclosure(subject,h.clock.now());const prepared=await repository.preparePurchase(subject,h.clock.now());assert.equal(prepared.kind,'ready');if(prepared.kind!=='ready')throw new Error('synthetic setup');
 const purchase=(expired=false)=>({...eligiblePurchase(h,expired?{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}:{}),externalAccountIdentifiers:{obfuscatedExternalAccountId:prepared.obfuscatedAccountId}});
 const service=new PlayBillingService({...h,repository}),token=purchaseToken();h.play.setPurchase(token,purchase());assert.equal((await service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
 const processor=new ReconciliationProcessor({...h,repository});h.clock.advance(61_000);return {...h,database,repository,service,processor,subject,token,purchase};
}
const get=async(c:string,id:string)=>(await firestore.collection(c).doc(id).get()).data()!;
test('named Firestore concurrent due claims preserve one work owner and root high-water',async()=>{
 const h=await setup();assert.ok((await h.database.dueReconciliationWork(h.clock.now(),10)).includes(h.subject));
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
