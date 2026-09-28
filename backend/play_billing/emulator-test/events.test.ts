import assert from 'node:assert/strict';
import test,{after} from 'node:test';
import {randomUUID,createHash} from 'node:crypto';
import {initializeApp,deleteApp} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {BILLING_DATABASE_ID,COLLECTIONS} from '../src/constants.js';
import {FirestoreBillingDatabase} from '../src/firestore_store.js';
import {EventWorkRepository} from '../src/event_work.js';
import {EVENT_CUSTODY_VERSION,BOUNDED_EVENT_LIMITS} from '../src/event_records.js';
import {BillingRepository} from '../src/store.js';
import {BillingDeadline} from '../src/deadline.js';
import {createBillingIdentifiers,CryptoNonceSource} from '../src/crypto.js';
import {TEST_KEY} from '../dist-test/fake_custody.js';
if(!process.env.FIRESTORE_EMULATOR_HOST) throw Error('FIRESTORE_EMULATOR_HOST is required');
const app=initializeApp({projectId:'demo-archivale-billing'},'events-'+randomUUID());
const firestore=getFirestore(app,BILLING_DATABASE_ID),database=new FirestoreBillingDatabase(firestore);
after(()=>deleteApp(app));
const ids=createBillingIdentifiers(Buffer.alloc(32,9));
const nonces=new CryptoNonceSource();
const repository=new BillingRepository(database,nonces,ids);
const clock={now:new Date('2033-01-01T00:00:00Z')};
const work=new EventWorkRepository(database,nonces,BOUNDED_EVENT_LIMITS,()=>0);
const hash=()=>createHash('sha256').update(randomUUID()).digest('hex');
const descriptor=()=>({eventFingerprint:hash(),payloadDigest:hash(),tokenFingerprint:hash(),category:'subscription' as const});
const envelope={version:EVENT_CUSTODY_VERSION,keyVersion:TEST_KEY,ciphertext:'AAAA'} as const;
const deadline=()=>new BillingDeadline();
async function ready(){const d=descriptor();const reserve=await work.reserve(d,clock.now,deadline());assert.equal(reserve.kind,'reserved');if(reserve.kind!=='reserved') throw Error('fixture');await work.admitCiphertext(reserve.work,envelope,clock.now,deadline());return d;}

test('named Firestore concurrent first inbox reservation consumes exactly one durable capacity slot',async()=>{
 const d=descriptor();const before=await firestore.collection(COLLECTIONS.eventControl).doc('capacity').get();
 const settled=await Promise.allSettled([1,2,3].map(()=>work.reserve(d,clock.now,deadline())));
 assert.equal(settled.filter(item=>item.status==='fulfilled').length,1);
 const winner=settled.find(item=>item.status==='fulfilled');assert.ok(winner?.status==='fulfilled'&&winner.value.kind==='reserved');
 if(winner.status==='fulfilled'&&winner.value.kind==='reserved') await work.admitCiphertext(winner.value.work,envelope,clock.now,deadline());
 const after=await firestore.collection(COLLECTIONS.eventControl).doc('capacity').get();assert.equal(after.data()?.totalRows,(before.data()?.totalRows??0)+1);
 assert.equal((await work.reserve(d,clock.now,deadline())).kind,'duplicate');
});

test('named Firestore due query reclaims crashed work once and retains charges across repository restart',async()=>{
 const d=await ready();const first=await work.claim(d.eventFingerprint,clock.now,deadline());assert.ok(first);
 await work.charge(first,'discoveryGet',clock.now,deadline());clock.now=new Date(clock.now.getTime()+90_000);
 assert.ok((await database.dueEventWork(clock.now,10)).includes(d.eventFingerprint));
 const restarted=new EventWorkRepository(new FirestoreBillingDatabase(firestore),nonces,BOUNDED_EVENT_LIMITS,()=>0);
 const claimed=await Promise.all([work.claim(d.eventFingerprint,clock.now,deadline()),restarted.claim(d.eventFingerprint,clock.now,deadline())]);
 assert.equal(claimed.filter(Boolean).length,1);const current=claimed.find(Boolean)!;assert.equal(current.generation,first.generation+1);assert.equal(current.dispatchTotals.discoveryGet,1);
 await assert.rejects(work.finish(first,'completed','none',clock.now,deadline()),/unsafe/);
 await restarted.finish(current,'completed','none',clock.now,deadline());
});

test('named Firestore two resolved event tokens contend for one account owner and retirement fences later dispatch',async()=>{
 const subject=hash();await repository.acceptDisclosure(subject,clock.now);const prepared=await repository.preparePurchase(subject,clock.now);assert.equal(prepared.kind,'ready');if(prepared.kind!=='ready') return;
 const root=(await firestore.collection(COLLECTIONS.lifecycles).doc(subject).get()).data()!;
 const resolved={accountSubject:subject,lifecycleEpoch:root.lifecycleEpoch as string,lifecycleGeneration:root.lifecycleGeneration as number};
 const descriptors=await Promise.all([ready(),ready()]);const claims=await Promise.all(descriptors.map(d=>work.claim(d.eventFingerprint,clock.now,deadline())));
 for(const claim of claims){assert.ok(claim);await work.bind(claim,resolved,clock.now,deadline());}
 const results=await Promise.all(claims.map(claim=>repository.acquireAttempt(subject,hash(),claim!.tokenFingerprint!,clock.now,deadline(),'background',{kind:'event',fence:claim!})));
 assert.equal(results.filter(result=>result.kind==='acquired').length,1);assert.equal(results.filter(result=>result.kind==='in_flight').length,1);
 assert.equal(await repository.retireLifecycle(subject,resolved,clock.now),true);
 for(const claim of claims) await assert.rejects(work.charge(claim!,'verificationGet',clock.now,deadline()),/retired/);
 const acquired=results.find(result=>result.kind==='acquired');assert.ok(acquired?.kind==='acquired');
 if(acquired.kind==='acquired') assert.equal(await repository.markVerifiedOwner(acquired.attempt,'archivale_starter_monthly',clock.now),false);
});
