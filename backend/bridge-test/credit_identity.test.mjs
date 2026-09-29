/** Run after both package builds. Only injected providers; optional local emulator. */
import assert from 'node:assert/strict';
import test,{after} from 'node:test';
import {randomUUID} from 'node:crypto';
import {createRequire} from 'node:module';
import {createHarness,DeterministicNonceSource,eligiblePurchase,purchaseToken,verifyRequest} from '../play_billing/build/dist-test/test_helpers.js';
import {BillingRepository} from '../play_billing/build/src/store.js';
import {PlayBillingService} from '../play_billing/build/src/verifier.js';
import {BillingBrokerBridge,initialControls,authorityDigest as billingDigest} from '../play_billing/build/src/broker_bridge.js';
import {COLLECTIONS,DISCLOSURE_VERSION,DISCLOSURE_PURPOSE,BILLING_DATABASE_ID} from '../play_billing/build/src/constants.js';
import {FirestoreBillingDatabase} from '../play_billing/build/src/firestore_store.js';
import {CreditIdentityService,authorityDigest as brokerDigest,routeForUid as brokerRoute,accountId} from '../broker/build/src/credit_identity.js';
import {FirestoreCreditIdentityDatabase,CREDIT_COLLECTIONS as C} from '../broker/build/src/credit_identity_store.js';
import {creditIdentityFixture,TEST_UID,TEST_APP,TEST_ROUTE_KEY,TEST_CONFIG} from '../broker/build/dist-test/credit_identity_fixture.js';
const req=(route)=>({version:'credit-authority-read-v1',routingKeyVersion:'entitlement-route-v1',route,challenge:'f'.repeat(32)});
export async function setup(firestores){
 const h=createHarness();h.identity={uid:TEST_UID};const db=firestores?new FirestoreBillingDatabase(firestores.billing):h.database;
 const repo=new BillingRepository(db,new DeterministicNonceSource(),h.identifiers),service=new PlayBillingService({...h,repository:repo});
 await service.acceptDisclosure(h.identity,{requestId:randomUUID(),disclosureVersion:DISCLOSURE_VERSION,purpose:DISCLOSURE_PURPOSE,accepted:true});
 const subject=h.identifiers.accountSubject(TEST_UID);await repo.preparePurchase(subject,h.clock.now());
 const root=()=>db.runTransaction(tx=>tx.get(COLLECTIONS.lifecycles,subject));
 const r=await root(),token=purchaseToken(),purchase=eligiblePurchase(h);purchase.externalAccountIdentifiers.obfuscatedExternalAccountId=r.obfuscatedAccountId;
 h.play.setPurchase(token,purchase);assert.equal((await service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
 const pair=initialControls(TEST_CONFIG,'billing');await db.runTransaction(async tx=>{tx.set(COLLECTIONS.brokerBridgeControl,'control',pair.control);tx.set(COLLECTIONS.brokerBridgeControl,'initialization',pair.initialization);});
 const bridge=new BillingBrokerBridge({database:db,repository:repo,config:TEST_CONFIG,routingKey:TEST_ROUTE_KEY,accountSubject:h.identifiers.accountSubject,approvedAppId:TEST_APP,now:()=>h.clock.now(),
  auth:{verifyIdToken:async()=>({uid:TEST_UID,firebase:{sign_in_provider:'google.com'}})}});
 const enroll=()=>bridge.enroll({auth:{uid:TEST_UID},app:{appId:TEST_APP,alreadyConsumed:false},rawRequest:{headers:{authorization:'Bearer synthetic'}}},
  {version:'credit-billing-enrollment-v1',requestId:randomUUID(),lifecycleEpoch:r.lifecycleEpoch,lifecycleGeneration:r.lifecycleGeneration});
 const f=await creditIdentityFixture({ready:false,nowMs:+h.clock.now()}),brokerDb=firestores?new FirestoreCreditIdentityDatabase(firestores.broker):f.db;
 if(firestores){await firestores.broker.doc('brokerDurableControl/live').set({record_version:'broker-control-v1',breakerOpen:false,perSubjectCreditCap:10,brokerCreditCap:20,oneInFlightPerSubject:true});
  await firestores.broker.doc(`brokerDurableEntitlements/${Buffer.from(TEST_UID).toString('base64url')}`).set({record_version:'broker-entitlement-v1',entitled:true});}
 const broker=new CreditIdentityService({...f.constructorOptions,database:brokerDb,transport:{read:(input,deadline)=>bridge.read(input,deadline)}});
 const initial=broker.initialControlsForTest();await brokerDb.transaction(async tx=>{tx.set(C.control,'control',initial.control);tx.set(C.control,'initialization',initial.initialization);});
 const consent=(action,revision)=>broker.consent(f.tokens(),{version:'credit-consent-command-v1',requestId:randomUUID(),expectedConsentRevision:revision,action,researchVersion:'research-consent-v1',bridgeVersion:'paid-ai-bridge-consent-v1'});
 const register=(generation=0)=>broker.register(f.tokens(),{version:'credit-registration-v1',requestId:randomUUID(),expectedRegistrationGeneration:generation});
 return {h,db,repo,bridge,broker,brokerDb,f,root,subject,enroll,consent,register};
}
test('actual billing projection → durable broker consent/recipient → paid eligibility, withdrawal and retirement',async()=>{
 const t=await setup();await t.enroll();assert.equal((await t.consent('accept',0)).status,'accepted');assert.equal((await t.register()).status,'ready');assert.equal((await t.broker.evaluate(t.f.tokens())).status,'eligible');
 const projection=await t.bridge.read(req(t.f.route));assert.equal(billingDigest(projection.snapshot),brokerDigest(projection.snapshot));assert.equal(projection.snapshot.route,brokerRoute(TEST_ROUTE_KEY,TEST_UID));
 assert.equal((await t.consent('revoke',1)).status,'revoked');assert.equal((await t.broker.applyAuthenticatedSnapshot(projection.snapshot,projection.digest)).status,'unavailable');
 assert.equal((await t.consent('accept',2)).status,'accepted');assert.equal((await t.broker.evaluate(t.f.tokens())).status,'none');assert.equal((await t.register(3)).status,'ready');
 const old=await t.root();await t.repo.retireLifecycle(t.subject,old,t.h.clock.now());const terminal=await t.bridge.read(req(t.f.route));assert.equal((await t.broker.applyAuthenticatedSnapshot(terminal.snapshot,terminal.digest)).status,'applied');
 assert.equal((await t.broker.evaluate(t.f.tokens())).status,'none');assert.equal((await t.broker.applyAuthenticatedSnapshot(projection.snapshot,projection.digest)).status,'ignored');
});
const emulator=process.env.FIRESTORE_EMULATOR_HOST;
if(emulator){
 if(!/^(127\.0\.0\.1|localhost):\d+$/.test(emulator))throw Error('local emulator required');
 const require=createRequire(new URL('../play_billing/package.json',import.meta.url));const {initializeApp,deleteApp}=require('firebase-admin/app'),{getFirestore}=require('firebase-admin/firestore');

 test('local emulator fixture denies anonymous access in default and named databases',async()=>{
  for(const database of ['(default)',BILLING_DATABASE_ID]){
   const response=await fetch(`http://${emulator}/v1/projects/demo-archivale-billing/databases/${encodeURIComponent(database)}/documents/brokerCreditAccounts/synthetic-probe`);
   assert.equal(response.status,403);await response.body?.cancel();
  }
 });
 async function stores(label){const app=initializeApp({projectId:`demo-credit-identity-${label}`},`credit-${label}-${randomUUID()}`);after(()=>deleteApp(app));return {billing:getFirestore(app,BILLING_DATABASE_ID),broker:getFirestore(app)};}
 test('named/default emulator: concurrent enrollment and lost-result retry remain reciprocal once',async()=>{
  const firestores=await stores('enrollment'),t=await setup(firestores);await Promise.all([t.enroll(),t.enroll()]);const results=await Promise.all([t.consent('accept',0),t.consent('accept',0)]);assert.equal(results.filter(r=>r.status==='accepted').length,1);
  let drop=true;
  const lossyDb={transaction:async(work)=>{const result=await t.brokerDb.transaction(work);
   const snapshot=(await firestores.broker.doc(C.authority+'/'+accountId(t.f.accountSubject)).get()).data();
   if(drop&&snapshot?.status==='ready'){drop=false;throw Error('synthetic committed response lost');}return result;}};
  const lossy=new CreditIdentityService({...t.f.constructorOptions,database:lossyDb,transport:{read:(input,d)=>t.bridge.read(input,d)}});
  const input={version:'credit-registration-v1',requestId:randomUUID(),expectedRegistrationGeneration:0};
  assert.equal((await lossy.register(t.f.tokens(),input)).status,'unavailable');
  const before=(await firestores.broker.doc(C.authority+'/'+accountId(t.f.accountSubject)).get()).data();
  assert.equal((await lossy.register(t.f.tokens(),input)).status,'ready');
  assert.deepEqual((await firestores.broker.doc(C.authority+'/'+accountId(t.f.accountSubject)).get()).data(),before);
  assert.equal((await t.broker.evaluate(t.f.tokens())).status,'eligible');
  assert.equal((await firestores.billing.doc(COLLECTIONS.brokerBridgeControl+'/control').get()).data().enrolledAccounts,1);assert.equal((await firestores.broker.doc(C.control+'/control').get()).data().enrolledAccounts,1);
 });
 test('named/default emulator: CAS withdrawal while second actual projection is held wins',async()=>{
  const t=await setup(await stores('withdrawal'));await t.enroll();await t.consent('accept',0);let enter,release;const entered=new Promise(r=>enter=r),held=new Promise(r=>release=r);let calls=0;
  const racing=new CreditIdentityService({...t.f.constructorOptions,database:t.brokerDb,transport:{read:async(input,d)=>{const result=await t.bridge.read(input,d);if(++calls===2){enter();await held;}return result;}}});
  const work=racing.register(t.f.tokens(),{version:'credit-registration-v1',requestId:randomUUID(),expectedRegistrationGeneration:0});await entered;
  assert.equal((await t.consent('revoke',1)).status,'revoked');release();assert.equal((await work).status,'unavailable');assert.equal((await t.broker.evaluate(t.f.tokens())).status,'none');
 });
 test('named/default emulator: terminal ordering and corrupt optional billing marker preserve core retirement',async()=>{
  const fs=await stores('terminal'),t=await setup(fs);await t.enroll();await t.consent('accept',0);await t.register();const paid=await t.bridge.read(req(t.f.route));
  await t.repo.retireLifecycle(t.subject,await t.root(),t.h.clock.now());const terminal=await t.bridge.read(req(t.f.route));await Promise.all([t.broker.applyAuthenticatedSnapshot(terminal.snapshot,terminal.digest),t.broker.applyAuthenticatedSnapshot(paid.snapshot,paid.digest)]);
  const row=(await fs.broker.doc(C.authority+'/'+accountId(t.f.accountSubject)).get()).data();assert.equal(row.snapshot.lifecycleStatus,'retired');assert.equal((await t.broker.evaluate(t.f.tokens())).status,'none');
  const second=await setup(await stores('corrupt'));await second.enroll();await second.db.runTransaction(async tx=>{const r=await tx.get(COLLECTIONS.lifecycles,second.subject);tx.set(COLLECTIONS.lifecycles,second.subject,{...r,brokerBridge:{corrupt:true}});});
  assert.equal(await second.repo.retireLifecycle(second.subject,await second.root(),second.h.clock.now()),true);
 });
}
