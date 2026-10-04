import assert from 'node:assert/strict';
import test, {type TestContext} from 'node:test';
import { randomUUID } from 'node:crypto';
import { initializeApp, deleteApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { financialFixture, voidNotification } from '../dist-test/financial_void_fixture.js';
import { FirestoreBillingDatabase } from '../src/firestore_store.js';
import { BILLING_DATABASE_ID, COLLECTIONS } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import { purchaseToken, verifyRequest } from '../dist-test/test_helpers.js';
import { configurationDigest } from '../src/dispatch_budget.js';
import { testDispatchConfig } from '../dist-test/dispatch_fixtures.js';
if (!process.env.FIRESTORE_EMULATOR_HOST) throw Error('Firestore emulator required');
let sequence=0;
async function setup(t:TestContext, config=testDispatchConfig()) {
  // Separate demo projects prevent the global ledgers/due cohorts from other workers interfering.
  t.mock.timers.enable({apis:['Date'],now:Date.now()});
  const app=initializeApp({projectId:'demo-financial-'+(++sequence)},'financial-'+randomUUID());
  t.after(()=>deleteApp(app));
  const firestore=getFirestore(app,BILLING_DATABASE_ID),database=new FirestoreBillingDatabase(firestore);
  const h=await financialFixture({database,config});
  return {...h,firestore,advance:(ms:number)=>{h.clock.advance(ms);t.mock.timers.tick(ms);}};
}
test('named financial: concurrent order owner/alias reservation uses one anchor and two message slots',async t=>{
  const h=await setup(t),token=purchaseToken(),a=voidNotification(token,'concurrent'),b=voidNotification(token,'concurrent');
  await Promise.all([h.processor.ingest(a),h.processor.ingest(b)]);
  assert.deepEqual([(await h.job(a))!.financialRole,(await h.job(b))!.financialRole].sort(),['alias','owner']);
  assert.equal((await h.firestore.collection(COLLECTIONS.financialOrders).get()).size,1);
  assert.equal((await h.read(COLLECTIONS.eventControl,'capacity')).totalRows,2);assert.equal(h.counts.kms,1);
});
test('named financial: actual gated transport journey observes current paid then records valid receipt',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  const e=voidNotification(token,'old-renewal');await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(row.state,'completed');assert.equal(row.verification?.outcome,'paid');
  assert.deepEqual((await h.read(COLLECTIONS.dispatchControl,'budget')).totals.event,{play_get:1,play_ack:0,kms_encrypt:1,kms_decrypt:2});
  const before=await h.job(e);await h.processorFor(await h.makeRuntime(false)).ingest(e);assert.deepEqual(await h.job(e),before);
});
test('named financial: bounded anchor-history query detects surviving alias after owner and anchor loss',async t=>{
  const h=await setup(t),token=purchaseToken(),a=voidNotification(token,'orphan'),b=voidNotification(token,'orphan');
  await h.processor.ingest(a);await h.processor.ingest(b);
  await h.firestore.collection(COLLECTIONS.eventWork).doc(h.eventId(a)).delete();
  await h.firestore.collection(COLLECTIONS.financialOrders).doc(h.identifiers.financialOrderFingerprint('orphan')).delete();
  const before=(await h.read(COLLECTIONS.eventControl,'capacity')).totalRows;
  await assert.rejects(h.processor.ingest(voidNotification(token,'orphan')),/unsafe/);
  assert.equal((await h.read(COLLECTIONS.eventControl,'capacity')).totalRows,before);assert.equal(h.counts.kms,1);
});
test('named financial: stale owner after real transaction reclaim cannot complete or charge',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken());await h.processor.ingest(e);
  const first=(await h.runtime.events!.claim(h.eventId(e),h.clock.now(),new BillingDeadline()))!;
  // Repository reclaim alone uses injected time; no late transport is authorized by this test.
  h.advance(90_000);
  const results=await Promise.all([1,2].map(()=>h.runtime.events!.claim(h.eventId(e),h.clock.now(),new BillingDeadline())));
  assert.equal(results.filter(Boolean).length,1);assert.equal(results.find(Boolean)!.generation,first.generation+1);
  await assert.rejects(h.runtime.events!.finish(first,'completed','none',h.clock.now(),new BillingDeadline()),/unsafe/);
  await assert.rejects(h.runtime.events!.charge(first,'verificationGet',h.clock.now(),new BillingDeadline()),/unsafe/);
});
test('named financial: retirement during deferred auth fences physical Play dispatch',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  const subject=h.identifiers.accountSubject(h.identity.uid),root=await h.read(COLLECTIONS.lifecycles,subject);
  h.hooks.beforePlayHeaders=async()=>{assert.equal(await h.repository.retireLifecycle(subject,root,h.clock.now()),true);};
  await h.processor.pump();assert.equal(h.counts.get,1);assert.equal((await h.job(e))?.verification,undefined);
});
test('named financial: foreground and void observation contend for last project GET',async t=>{
  const config=testDispatchConfig();config.global.get=2;config.digest=configurationDigest(config);
  const h=await setup(t,config),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  await Promise.allSettled([h.processor.pump(),h.service.verifySubscription(h.identity,verifyRequest(token))]);
  assert.equal(h.counts.get,2);
  const totals=(await h.read(COLLECTIONS.dispatchControl,'budget')).totals;
  assert.equal(totals.foreground.play_get+totals.event.play_get,2);
});
test('named financial: revoked current observation completes inactive receipt without financial authority',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  h.play.setPurchase(token,await h.purchase({state:'SUBSCRIPTION_STATE_REVOKED'}));
  const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  assert.equal((await h.job(e))?.verification?.reason,'revoked');assert.equal(h.counts.ack,0);
});
