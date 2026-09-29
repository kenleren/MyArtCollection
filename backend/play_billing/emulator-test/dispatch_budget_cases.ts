import assert from 'node:assert/strict';
import { test, beforeEach, after, describe } from 'node:test';
import { randomUUID } from 'node:crypto';
import { initializeApp, deleteApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { COLLECTIONS, BILLING_DATABASE_ID } from '../src/constants.js';
import { FirestoreBillingDatabase } from '../src/firestore_store.js';
import { BillingRepository } from '../src/store.js';
import { EventWorkRepository } from '../src/event_work.js';
import { DispatchGate, accountDispatch, eventDispatch } from '../src/dispatch_gate.js';
import { initialDispatchControls, configurationDigest, digest } from '../src/dispatch_budget.js';
import { BillingDeadline } from '../src/deadline.js';
import { CryptoNonceSource,createBillingIdentifiers } from '../src/crypto.js';
import { BOUNDED_EVENT_LIMITS, EVENT_CUSTODY_VERSION } from '../src/event_records.js';
import { PlayBillingService } from '../src/verifier.js';
import { createHarness,FakeClock,eligiblePurchase,purchaseToken,verifyRequest } from '../dist-test/test_helpers.js';
import { testDispatchConfig,legacyControls } from '../dist-test/dispatch_fixtures.js';
import { TEST_KEY } from '../dist-test/fake_custody.js';
export function registerDispatchBudgetTests():void { describe('named shared dispatch budgets',()=>{
if(!/^127\.0\.0\.1:\d+$/.test(process.env.FIRESTORE_EMULATOR_HOST??''))throw Error('isolated local emulator required');
const app=initializeApp({projectId:'demo-archivale-billing'},'dispatch-'+randomUUID()),firestore=getFirestore(app,BILLING_DATABASE_ID);
const database=new FirestoreBillingDatabase(firestore),nonces=new CryptoNonceSource();
after(()=>deleteApp(app));
let config=testDispatchConfig();let now=new Date();
beforeEach(async()=>{
 now=new Date();config=testDispatchConfig();config.global.get=1;for(const source of Object.values(config.sources))source.get=1;config.digest=configurationDigest(config);
 const pair=initialDispatchControls(config,new Date(+now-120_000),'e'.repeat(64),{kind:'verified_new'});
 await firestore.runTransaction(async tx=>{for(const [id,value]of Object.entries(pair))tx.set(firestore.collection(COLLECTIONS.dispatchControl).doc(id),value);
  for(const [id,value]of Object.entries(legacyControls()))tx.set(firestore.collection(COLLECTIONS.eventControl).doc(id),value);});
});
async function account(reconciliation=false){
 const h=createHarness();h.clock=new FakeClock(new Date(+now-(reconciliation?61_000:0)));
 const work=new EventWorkRepository(database,nonces,BOUNDED_EVENT_LIMITS,()=>0,config);
 const repository=new BillingRepository(database,nonces,h.identifiers,{activeMs:60_000,retryMs:30_000,maxRetryMs:900_000},work,()=>now);
 const subject=h.identifiers.accountSubject(h.identity.uid),token=purchaseToken();await repository.acceptDisclosure(subject,h.clock.now());const prepared=await repository.preparePurchase(subject,h.clock.now());if(prepared.kind!=='ready')throw Error('fixture');
 const deadline=new BillingDeadline();let acquired;
 if(reconciliation){const service=new PlayBillingService({...h,repository});h.play.setPurchase(token,{...eligiblePurchase(h),externalAccountIdentifiers:{obfuscatedExternalAccountId:prepared.obfuscatedAccountId}});
  assert.equal((await service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
  const claim=await repository.claimReconciliation(subject,now,deadline);assert.ok(claim);
  acquired=await repository.acquireAccountAttempt(subject,h.identifiers.requestFingerprint(h.identity.uid,randomUUID()),now,deadline,'background',{kind:'reconciliation',fence:claim});
 }else acquired=await repository.acquireAttempt(subject,h.identifiers.requestFingerprint(h.identity.uid,randomUUID()),h.identifiers.tokenFingerprint(token),now,deadline);
 assert.equal(acquired.kind,'acquired');if(acquired.kind!=='acquired')throw Error('fixture');
 const cap=accountDispatch(acquired.attempt,'lookup_in_flight'),gate=new DispatchGate(repository,config,h.identifiers);
 return {repository,gate,cap,token,deadline,subject};
}
async function eventAccount(){
 const identifiers=createBillingIdentifiers(Buffer.alloc(32,9)),work=new EventWorkRepository(database,nonces,BOUNDED_EVENT_LIMITS,()=>0,config);
 const repository=new BillingRepository(database,nonces,identifiers,undefined,work,()=>now),token=purchaseToken(),deadline=new BillingDeadline();
 const descriptor={eventFingerprint:identifiers.eventFingerprint('synthetic',randomUUID()),payloadDigest:'a'.repeat(64),tokenFingerprint:identifiers.tokenFingerprint(token),category:'subscription' as const};
 const reserved=await work.reserve(descriptor,now,deadline);if(reserved.kind!=='reserved')throw Error('fixture');
 await work.admitCiphertext(reserved.work,{version:EVENT_CUSTODY_VERSION,keyVersion:TEST_KEY,ciphertext:'AAAA'},now,deadline);
 const claimed=await work.claim(descriptor.eventFingerprint,now,deadline);assert.ok(claimed);
 return {gate:new DispatchGate(repository,config,identifiers),cap:eventDispatch(claimed,'working'),token,deadline,repository,work,claimed};
}
const budget=async()=>(await firestore.collection(COLLECTIONS.dispatchControl).doc('budget').get()).data()!;

test('named Firestore one shared unit admits at most one foreground/event/reconciliation physical dispatch',async()=>{
 const sources=await Promise.all([account(),eventAccount(),account(true)]);let fetches=0;
 const settled=await Promise.allSettled(sources.map(async s=>{const ticket=await s.gate.reserve(s.cap,s.gate.playDescriptor(s.cap,'play_get',s.token),s.deadline);return s.gate.consume(ticket,async()=>{fetches++;});}));
 assert.equal(settled.filter(s=>s.status==='fulfilled').length,1);assert.equal(fetches,1);
 const b=await budget();assert.equal(b.starts.get.length,1);assert.equal(Object.values(b.totals as Record<string,{play_get:number}>).reduce((n,v)=>n+v.play_get,0),1);
});

test('named Firestore denied event reservation preserves both physical ledgers and earlier inbox capacity',async()=>{
 const a=await account(),e=await eventAccount();await a.gate.reserve(a.cap,a.gate.playDescriptor(a.cap,'play_get',a.token),a.deadline);
 const before=await budget(),legacy=(await firestore.collection(COLLECTIONS.eventControl).doc('budget').get()).data(),row=(await firestore.collection(COLLECTIONS.eventWork).doc(e.claimed.eventFingerprint).get()).data();
 await assert.rejects(e.gate.reserve(e.cap,e.gate.playDescriptor(e.cap,'play_get',e.token),e.deadline));
 assert.deepEqual(await budget(),before);assert.deepEqual((await firestore.collection(COLLECTIONS.eventControl).doc('budget').get()).data(),legacy);assert.deepEqual((await firestore.collection(COLLECTIONS.eventWork).doc(e.claimed.eventFingerprint).get()).data(),row);
 assert.equal((await firestore.collection(COLLECTIONS.eventControl).doc('capacity').get()).data()?.totalRows,1);
});

test('named Firestore reordered map keys preserve canonical legacy head; lost rolling entry rejects',async()=>{
 const a=await eventAccount();const reference=firestore.collection(COLLECTIONS.eventControl).doc('budget');const old=(await reference.get()).data()!;
 await reference.set(Object.fromEntries(Object.entries(old).reverse()));
 const ticket=await a.gate.reserve(a.cap,a.gate.playDescriptor(a.cap,'play_get',a.token),a.deadline);let calls=0;await a.gate.consume(ticket,async()=>{calls++;});assert.equal(calls,1);
 const saved=(await reference.get()).data()!;await reference.set({...saved,starts:{...saved.starts,discoveryGet:[]}});
 const gate=new DispatchGate(a.repository,config,createBillingIdentifiers(Buffer.alloc(32,9)));await assert.rejects(gate.reserve(a.cap,gate.playDescriptor(a.cap,'play_get',a.token),a.deadline));assert.equal(calls,1);
});

test('named Firestore committed result loss retains one charge and yields no dispatch ticket',async()=>{
 const a=await account(),original=database.runTransaction.bind(database);let lost=true;
 database.runTransaction=async f=>{const result=await original(f);if(lost){lost=false;throw Error('synthetic result loss');}return result;};
 try{await assert.rejects(a.gate.reserve(a.cap,a.gate.playDescriptor(a.cap,'play_get',a.token),a.deadline));}finally{database.runTransaction=original;}
 assert.equal((await budget()).totals.foreground.play_get,1);
});

test('named Firestore newer owner/retirement invalidates an already charged ticket without refund',async()=>{
 const a=await account(),ticket=await a.gate.reserve(a.cap,a.gate.playDescriptor(a.cap,'play_get',a.token),a.deadline);
 const root=(await firestore.collection(COLLECTIONS.lifecycles).doc(a.subject).get()).data()!;
 assert.equal(await a.repository.retireLifecycle(a.subject,root as never,now),true);let calls=0;
 await assert.rejects(a.gate.consume(ticket,async()=>{calls++;}));assert.equal(calls,0);assert.equal((await budget()).totals.foreground.play_get,1);
});

});}
