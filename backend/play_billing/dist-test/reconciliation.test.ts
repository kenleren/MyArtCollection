import { seedDispatch,testDispatchConfig,meteredPlay,meteredCustody } from './dispatch_fixtures.js';
import { DispatchGate } from '../src/dispatch_gate.js';
import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {COLLECTIONS,CONTRACT_VERSION,DISCLOSURE_VERSION,DISCLOSURE_PURPOSE} from '../src/constants.js';
import {BillingDeadline} from '../src/deadline.js';
import {BillingRepository, type AttemptHandle} from '../src/store.js';
import {PlayBillingService} from '../src/verifier.js';
import {ReconciliationProcessor} from '../src/reconciliation_processor.js';
import {type ReconcileWork,type ReconcileFence,marked,validWork,selection} from '../src/reconciliation_work.js';
import type {LifecycleRoot} from '../src/lifecycle.js';
import type {AccountAuthority} from '../src/account_authority.js';
import {createHarness,acceptDisclosure,eligiblePurchase,purchaseToken,verifyRequest,DeterministicNonceSource,deferred} from './test_helpers.js';
const policy={activeMs:60_000,retryMs:30_000,maxRetryMs:900_000}; // Synthetic only.
function setup(){const h=createHarness();h.repository=new BillingRepository(h.database,new DeterministicNonceSource(),h.identifiers,policy,undefined,()=>h.clock.now());h.service=new PlayBillingService(h);
 const config=testDispatchConfig();seedDispatch(h.database,h.clock.now(),config);const gate=new DispatchGate(h.repository,config,h.identifiers);
 const processor=new ReconciliationProcessor({repository:h.repository,identifiers:h.identifiers,clock:h.clock,play:meteredPlay(gate,h.play),custody:meteredCustody(gate,h.custody)});return {...h,processor};}
type H=ReturnType<typeof setup>;
const subject=(h:H)=>h.identifiers.accountSubject(h.identity.uid);
const row=<T>(h:H,c:string)=>h.database.snapshotForTest().get(c+'/'+subject(h)) as T;
const work=(h:H)=>row<ReconcileWork>(h,COLLECTIONS.reconcileWork);
const restore=()=>({version:CONTRACT_VERSION,requestId:randomUUID(),billingDisclosureVersion:DISCLOSURE_VERSION});
async function seed(h:H){await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');return token;}
function unmark(h:H){const root=row<LifecycleRoot>(h,COLLECTIONS.lifecycles);const {reconcileVersion:_v,reconcileScheduleRevision:_r,reconcileOwnerGeneration:_g,...old}=root;h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles,subject(h),old);h.database.deleteRecordForTest(COLLECTIONS.reconcileWork,subject(h));return old;}

test('new root idle; actual paid custody schedules atomically and remains private',async()=>{
 const h=setup();await acceptDisclosure(h);assert.equal(work(h).state,'idle');assert.equal(validWork(work(h),row(h,COLLECTIONS.lifecycles)),true);
 const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');
 assert.equal(work(h).currentDemand?.tokenFingerprint,h.identifiers.tokenFingerprint(token));assert.equal(+work(h).dueAt,+h.clock.now()+policy.activeMs);
 assert.equal(work(h).candidateDemand,undefined);assert.equal(validWork(work(h),row(h,COLLECTIONS.lifecycles)),true);
 const text=JSON.stringify(work(h));assert.equal(text.includes(h.identity.uid),false);assert.equal(text.includes(token),false);
});
test('missed RTDN rechecks actual retained custody and atomically publishes expired authority',async()=>{
 const h=setup();const token=await seed(h);h.clock.advance(61_000);h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 const result=await h.processor.processOne(subject(h));assert.equal(result?.status,'none');assert.equal(result&&'reason'in result&&result.reason,'expired');
 const a=row<AccountAuthority>(h,COLLECTIONS.authorities);assert.equal(a.snapshot.state,'none');assert.equal(a.snapshot.reason,'expired');assert.equal(a.owner?.phase,'complete');
 assert.equal(work(h).state,'policy_blocked');assert.equal(work(h).completedObservation?.outcome,'inactive');assert.deepEqual(work(h).dispatchTotals,{get:1,ack:0,kms:1});
 assert.equal([...h.database.snapshotForTest().keys()].some(k=>k.startsWith(COLLECTIONS.eventWork+'/')),false);
});
test('paid current refresh completes final response without staging, ACK or encrypt',async()=>{
 const h=setup();const token=await seed(h);h.clock.advance(61_000);h.play.setPurchase(token,eligiblePurchase(h));
 const before=work(h);const result=await h.processor.processOne(subject(h));assert.equal(result?.status,'paid');assert.equal(work(h).completedObservation?.outcome,'paid');
 assert.equal(work(h).ownerGeneration,before.ownerGeneration+1);assert.equal(work(h).dispatchTotals.ack,0);assert.equal(work(h).dispatchTotals.kms,1);assert.equal(+work(h).dueAt,+h.clock.now()+policy.activeMs);
});
for(const loss of ['work','marker','revision','orphan'] as const)test(`lost ${loss} fails closed before provider or reset`,async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);
 if(loss==='work')h.database.deleteRecordForTest(COLLECTIONS.reconcileWork,subject(h));
 if(loss==='marker'){const root=row<LifecycleRoot>(h,COLLECTIONS.lifecycles);delete root.reconcileVersion;delete root.reconcileOwnerGeneration;delete root.reconcileScheduleRevision;h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles,subject(h),root);}
 if(loss==='revision')h.database.setUnsafeRecordForTest(COLLECTIONS.reconcileWork,subject(h),{...work(h),scheduleRevision:work(h).scheduleRevision+1});
 if(loss==='orphan')h.database.deleteRecordForTest(COLLECTIONS.lifecycles,subject(h));
 const before=h.database.snapshotForTest(),calls=h.play.getCalls.length;const result=await h.service.restoreEntitlement(h.identity,restore());assert.equal('reason'in result&&result.reason,'unsafe_record');assert.deepEqual(h.database.snapshotForTest(),before);assert.equal(h.play.getCalls.length,calls);
});
for(const action of ['prepare','restore','verify','accept'] as const)test(`unmarked ${action} is migration-required without mutation or dispatch`,async()=>{
 const h=setup();const token=await seed(h);unmark(h);h.clock.advance(61_000);const before=h.database.snapshotForTest(),calls=h.play.getCalls.length;
 const result=action==='prepare'?await h.service.preparePurchase(h.identity,restore()):action==='restore'?await h.service.restoreEntitlement(h.identity,restore()):action==='verify'?await h.service.verifySubscription(h.identity,verifyRequest(token)):await h.service.acceptDisclosure(h.identity,{requestId:randomUUID(),disclosureVersion:DISCLOSURE_VERSION,purpose:DISCLOSURE_PURPOSE,accepted:true});
 assert.equal('reason'in result&&result.reason,'recovery_required');assert.deepEqual(h.database.snapshotForTest(),before);assert.equal(h.play.getCalls.length,calls);
});
for(const action of ['revoke','retire'] as const)test(`unmarked ${action} publishes fail-safe exception without schedule adoption`,async()=>{
 const h=setup();await seed(h);const root=unmark(h);if(action==='revoke')await h.repository.revokeDisclosure(subject(h),h.clock.now());else assert.equal(await h.repository.retireLifecycle(subject(h),root,h.clock.now()),true);
 assert.equal(work(h),undefined);assert.equal(row<LifecycleRoot>(h,COLLECTIONS.lifecycles).reconcileVersion,undefined);assert.equal(row<AccountAuthority>(h,COLLECTIONS.authorities).snapshot.state,'none');
 assert.equal(row<{reason:string}>(h,COLLECTIONS.reconcileExceptions).reason,'unmarked_'+(action==='revoke'?'revoked':'retired'));
 const result=await h.service.preparePurchase(h.identity,restore());assert.notEqual(result.status,'ready');
});
test('closed default policy cannot claim or dispatch',async()=>{const h=createHarness();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));await h.service.verifySubscription(h.identity,verifyRequest(token));h.clock.advance(86_400_000);assert.equal(await h.repository.claimReconciliation(h.identifiers.accountSubject(h.identity.uid),h.clock.now(),new BillingDeadline()),undefined);});

async function candidate(h:H,old:string,ackBarrier=false){
 const token=purchaseToken();h.clock.advance(20_000);h.play.setPurchase(token,eligiblePurchase(h,{linkedPurchaseToken:old,acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 const hooks=ackBarrier?{afterAcknowledgementStarted:async()=>{throw new Error('synthetic crash');}}:{afterDeliveryCommitted:async()=>{throw new Error('synthetic crash');}};
 const service=new PlayBillingService({...h,hooks});await service.verifySubscription(h.identity,verifyRequest(token));h.clock.advance(91_000);return token;
}
for(const active of [true,false])test(`non-granting candidate yields overdue current; active=${active} preserves both pointers`,async()=>{
 const h=setup();const old=await seed(h),next=await candidate(h,old);h.play.setPurchase(next,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_PENDING',linkedPurchaseToken:old,acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 const currentDue=+work(h).currentDemand!.dueAt;
 const first=await h.processor.processOne(subject(h));assert.equal(first&&'reason'in first&&first.reason,'play_pending');
 assert.equal(work(h).candidateDemand!.lastObservedDemandRevision,work(h).candidateDemand!.demandRevision);assert.equal(+work(h).currentDemand!.dueAt,currentDue);
 h.play.setPurchase(old,eligiblePurchase(h,active?{}:{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 const calls=h.play.getCalls.length;const second=await h.processor.processOne(subject(h));assert.equal(second?.status,active?'paid':'none');assert.equal(h.play.getCalls.length,calls+1);
 const index=row<{current:string;candidate:string}>(h,COLLECTIONS.accounts);assert.equal(index.current,h.identifiers.tokenFingerprint(old));assert.equal(index.candidate,h.identifiers.tokenFingerprint(next));assert.equal(work(h).dispatchTotals.ack,0);
});
test('durable ACK barrier never yields overdue current until fresh confirmation clears it',async()=>{
 const h=setup();const old=await seed(h),next=await candidate(h,old,true);
 h.play.setPurchase(next,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_PENDING',linkedPurchaseToken:old,acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
 const age=+work(h).currentDemand!.dueAt;const pending=await h.processor.processOne(subject(h));assert.equal(pending&&'reason'in pending&&pending.reason,'play_pending');const calls=h.play.getCalls.length;
 assert.equal(await h.processor.processOne(subject(h)),undefined);assert.equal(h.play.getCalls.length,calls);assert.equal(+work(h).currentDemand!.dueAt,age);
 h.clock.advance(31_000);h.play.setPurchase(next,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_PENDING',linkedPurchaseToken:old,acknowledgementState:'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'}));
 await h.processor.processOne(subject(h));assert.equal(row<AccountAuthority>(h,COLLECTIONS.authorities).acknowledgementRecoveryToken,undefined);
 assert.equal((await h.processor.processOne(subject(h)))?.status,'paid');assert.equal(+work(h).candidateDemand!.dueAt>+h.clock.now(),true);
});
test('reclaim preserves costs and rejects every old owner reservation/completion',async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const first=await h.repository.claimReconciliation(subject(h),h.clock.now(),new BillingDeadline());assert.ok(first);
 h.clock.advance(91_000);const second=await h.repository.claimReconciliation(subject(h),h.clock.now(),new BillingDeadline());assert.ok(second);assert.equal(second.ownerGeneration,first.ownerGeneration+1);assert.notDeepEqual(second.nonce,first.nonce);assert.equal(work(h).attemptStarts.length,2);
 const before=h.database.snapshotForTest();assert.equal(await h.repository.retryReconciliation(first,h.clock.now(),new BillingDeadline()),false);await assert.rejects(h.repository.reserveReconciliation(first,'get',h.clock.now(),new BillingDeadline(),'a'.repeat(64)));assert.deepEqual(h.database.snapshotForTest(),before);
});
for(const action of ['revoke','retire','expiry'] as const)test(`${action} during retained-token decrypt prevents GET and paid publication`,async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const entered=deferred(),release=deferred();
 const processor=new ReconciliationProcessor({...h,custody:{...h.custody,encrypt:h.custody.encrypt.bind(h.custody),decrypt:async(...args)=>{entered.resolve();await release.promise;return h.custody.decrypt(...args);}}});
 const before=h.play.getCalls.length;const run=processor.processOne(subject(h));await entered.promise;
 if(action==='revoke')await h.repository.revokeDisclosure(subject(h),h.clock.now());else if(action==='retire')await h.repository.retireLifecycle(subject(h),row(h,COLLECTIONS.lifecycles),h.clock.now());else h.clock.advance(366*86_400_000);
 release.resolve();assert.notEqual((await run)?.status,'paid');assert.equal(h.play.getCalls.length,before);
});
for(const outcome of ['paid','inactive'] as const)test(`completed ${outcome} receipt is read-only and newer claim invalidates final response`,async()=>{
 const h=setup();const token=await seed(h);h.clock.advance(61_000);if(outcome==='inactive')h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
 let captured:AttemptHandle|undefined;const validate=outcome==='paid'?'isCurrentGrant':'isCurrentResponse';const original=h.repository[validate].bind(h.repository);
 h.repository[validate]=async(attempt,now)=>{captured=attempt;assert.equal(await original(attempt,now),true);assert.equal(await h.repository.closeAttempt(attempt,now),false);
  await h.repository.acceptDisclosure(subject(h),now);return original(attempt,now);};
 const result=await h.processor.processOne(subject(h));assert.notEqual(result?.status,'paid');assert.equal(result&&'reason'in result&&result.reason,'not_verified');assert.ok(captured?.completedObservation);assert.equal(work(h).completedObservation,undefined);
});
test('two concurrent claims admit exactly one and query limit is bounded',async()=>{const h=setup();await seed(h);h.clock.advance(61_000);assert.deepEqual((await h.database.dueReconciliationWork(h.clock.now(),10)).map(r=>r.accountSubject),[subject(h)]);await assert.rejects(h.database.dueReconciliationWork(h.clock.now(),11));const claims=await Promise.all([0,1].map(()=>h.repository.claimReconciliation(subject(h),h.clock.now(),new BillingDeadline())));assert.equal(claims.filter(Boolean).length,1);});

test('canceled pending successor can refresh only its indexed predecessor under the same job',async()=>{
 const h=setup();const old=await seed(h),next=await candidate(h,old);h.play.setPurchase(next,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',linkedPurchaseToken:old}));
 const result=await h.processor.processOne(subject(h));assert.equal(result?.status,'paid');assert.equal(work(h).dispatchTotals.get,2);assert.equal(work(h).completedObservation?.selectedDemand.kind,'current');
 const index=row<{current:string;candidate:string}>(h,COLLECTIONS.accounts);assert.equal(index.current,h.identifiers.tokenFingerprint(old));assert.equal(index.candidate,h.identifiers.tokenFingerprint(next));
});
test('inactive current demand stays quiescent across later candidate retries',async()=>{
 const h=setup();const old=await seed(h),next=await candidate(h,old);h.play.setPurchase(next,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_PENDING',linkedPurchaseToken:old}));await h.processor.processOne(subject(h));h.play.setPurchase(old,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));await h.processor.processOne(subject(h));assert.equal(work(h).currentDemand,undefined);
 h.clock.advance(31_000);await h.processor.processOne(subject(h));assert.equal(work(h).currentDemand,undefined);
 await h.repository.acceptDisclosure(subject(h),h.clock.now());assert.equal(work(h).currentDemand?.tokenFingerprint,h.identifiers.tokenFingerprint(old));
});
for(const field of ['kind','token','demand','index'] as const)test(`selected ${field} corruption fences admission before decrypt`,async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const fence=await h.repository.claimReconciliation(subject(h),h.clock.now(),new BillingDeadline());assert.ok(fence);
 const corrupted=structuredClone(fence);if(field==='kind')corrupted.selectedDemand.kind='candidate';if(field==='token')corrupted.selectedDemand.tokenFingerprint='a'.repeat(64);if(field==='demand')corrupted.selectedDemand.demandRevision++;if(field==='index')corrupted.selectedDemand.indexRevision++;
 const calls=h.play.getCalls.length;const result=await h.service.processAccountObservation({accountSubject:subject(h),requestFingerprint:'b'.repeat(64),source:'background',work:{kind:'reconciliation',fence:corrupted}},{kind:'restore',input:restore()});assert.notEqual(result.status,'paid');assert.equal(h.play.getCalls.length,calls);
});
test('contradictory current acknowledgement cannot use no-ACK refresh branch',async()=>{const h=setup();const token=await seed(h);h.clock.advance(61_000);h.play.setPurchase(token,eligiblePurchase(h,{acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));assert.notEqual((await h.processor.processOne(subject(h)))?.status,'paid');assert.equal(work(h).dispatchTotals.ack,0);assert.equal(work(h).state,'retry');});

for(const reason of ['SUBSCRIPTION_STATE_EXPIRED','SUBSCRIPTION_STATE_ON_HOLD','SUBSCRIPTION_STATE_PAUSED','SUBSCRIPTION_STATE_PENDING'] as const)test(`inactive ${reason} stops current polling without erasing custody; reaccept demands fresh observation`,async()=>{
 const h=setup();const token=await seed(h);h.clock.advance(61_000);h.play.setPurchase(token,eligiblePurchase(h,{state:reason,expiryOffsetMs:reason==='SUBSCRIPTION_STATE_EXPIRED'?-1:60_000}));await h.processor.processOne(subject(h));
 assert.equal(work(h).currentDemand,undefined);assert.equal(work(h).state,'policy_blocked');assert.ok(h.database.snapshotForTest().get(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)));assert.equal(row<{current:string}>(h,COLLECTIONS.accounts).current,h.identifiers.tokenFingerprint(token));
 h.clock.advance(86_400_000);assert.equal(await h.processor.processOne(subject(h)),undefined);await h.repository.acceptDisclosure(subject(h),h.clock.now());assert.equal(work(h).currentDemand?.tokenFingerprint,h.identifiers.tokenFingerprint(token));
});
test('explicit paid Restore restores demand after inactive quiescence',async()=>{const h=setup();const token=await seed(h);h.clock.advance(61_000);h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_ON_HOLD'}));await h.processor.processOne(subject(h));assert.equal(work(h).currentDemand,undefined);h.clock.advance(20_000);h.play.setPurchase(token,eligiblePurchase(h));assert.equal((await h.service.restoreEntitlement(h.identity,restore())).status,'paid');assert.ok(work(h).currentDemand);});
test('failed terminal transaction never advances handle; retried callback applies winning receipt once',async()=>{
 const h=setup();const token=await seed(h);h.clock.advance(61_000);
 let captured:AttemptHandle|undefined,abort=true,inside=false;const original=h.database.runTransaction.bind(h.database);
 const finalize=h.repository.finalizeReconciliationCurrent.bind(h.repository);
 h.repository.finalizeReconciliationCurrent=async(attempt,...args)=>{captured=attempt;inside=true;try{return await finalize(attempt,...args);}finally{inside=false;}};
 h.database.runTransaction=async operation=>{
   if(!inside)return original(operation);
   const before=structuredClone({fence:captured!.fence!.work,completed:captured!.completedObservation});
   if(abort){abort=false;await assert.rejects(original(async tx=>{await operation(tx);assert.deepEqual({fence:captured!.fence!.work,completed:captured!.completedObservation},before);throw new Error('synthetic callback retry');}));}
   return original(async tx=>{const result=await operation(tx);assert.deepEqual({fence:captured!.fence!.work,completed:captured!.completedObservation},before);return result;});
 };
 const result=await h.processor.processOne(subject(h));assert.equal(result?.status,'paid');assert.ok(captured?.completedObservation);assert.equal(work(h).completedObservation?.scheduleRevision,captured!.completedObservation!.scheduleRevision);
});
test('custody staging transaction rollback preserves binding, index, marker and work together',async()=>{
 const h=setup();await acceptDisclosure(h);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(h));const original=h.database.runTransaction.bind(h.database);
 h.database.runTransaction=operation=>original(async tx=>{
  let staging=false;const result=await operation({...tx,set:(collection,id,value)=>{if(collection===COLLECTIONS.bindings)staging=true;tx.set(collection,id,value);}});
  if(staging)throw new Error('synthetic staging failure');return result;
 });
 assert.notEqual((await h.service.verifySubscription(h.identity,verifyRequest(token))).status,'paid');assert.equal(work(h).state,'idle');assert.equal(work(h).scheduleRevision,0);
 assert.equal(row(h,COLLECTIONS.accounts),undefined);assert.equal(h.database.snapshotForTest().get(COLLECTIONS.bindings+'/'+h.identifiers.tokenFingerprint(token)),undefined);assert.equal(validWork(work(h),row(h,COLLECTIONS.lifecycles)),true);
});

test('unmarked retirement exception survives partial core loss and forbids new lifecycle or acceptance',async()=>{
 const h=setup();await acceptDisclosure(h);const root=unmark(h);assert.equal(await h.repository.retireLifecycle(subject(h),root,h.clock.now()),true);
 for(const collection of [COLLECTIONS.lifecycles,COLLECTIONS.authorities,COLLECTIONS.authorityOutbox])h.database.deleteRecordForTest(collection,subject(h));h.database.deleteRecordForTest(COLLECTIONS.routes,root.routeFingerprint);
 const before=h.database.snapshotForTest();const prepared=await h.service.preparePurchase(h.identity,restore());assert.equal('reason'in prepared&&prepared.reason,'unsafe_record');
 const accepted=await h.service.acceptDisclosure(h.identity,{requestId:randomUUID(),disclosureVersion:DISCLOSURE_VERSION,purpose:DISCLOSURE_PURPOSE,accepted:true});assert.equal('reason'in accepted&&accepted.reason,'unsafe_record');
 assert.deepEqual(h.database.snapshotForTest(),before);assert.equal(h.play.getCalls.length,0);
});

test('expired oldest consent is atomically blocked so bounded query reaches healthy account',async()=>{
 const h=setup();await seed(h);h.clock.advance(366*86_400_000);const other={...h,identity:{uid:'synthetic-second'}};await acceptDisclosure(other);const token=purchaseToken();h.play.setPurchase(token,eligiblePurchase(other));await h.service.verifySubscription(other.identity,verifyRequest(token));h.clock.advance(61_000);
 assert.deepEqual((await h.database.dueReconciliationWork(h.clock.now(),1)).map(r=>r.accountSubject),[subject(h)]);const before=work(h);assert.equal(await h.processor.processOne(subject(h)),undefined);
 assert.equal(work(h).state,'blocked');assert.equal(work(h).reason,'consent');assert.deepEqual(work(h).dispatchTotals,before.dispatchTotals);assert.deepEqual(work(h).attemptStarts,before.attemptStarts);assert.equal(work(h).ownerGeneration,before.ownerGeneration+1);
 assert.deepEqual((await h.database.dueReconciliationWork(h.clock.now(),1)).map(r=>r.accountSubject),[h.identifiers.accountSubject(other.identity.uid)]);
});
test('exhausted rolling-day attempts move due head to finite window boundary without resetting counts',async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const old=work(h);old.attemptStarts=Array.from({length:12},()=>h.clock.now());h.database.setUnsafeRecordForTest(COLLECTIONS.reconcileWork,subject(h),old);
 assert.equal(await h.processor.processOne(subject(h)),undefined);assert.equal(work(h).state,'retry');assert.equal(work(h).reason,'budget');assert.equal(work(h).attemptStarts.length,12);assert.equal(+work(h).dueAt,+h.clock.now()+86_400_001);assert.deepEqual((await h.database.dueReconciliationWork(h.clock.now(),10)).map(r=>r.accountSubject),[]);
});
test('one-job deadline bounds delayed admission and fences late GET without renewing cleanup deadline',async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const entered=deferred(),release=deferred();const acquire=h.repository.acquireAccountAttempt.bind(h.repository);
 h.repository.acquireAccountAttempt=async(...args)=>{entered.resolve();await release.promise;return acquire(...args);};
 const calls=h.play.getCalls.length;const deadline=new BillingDeadline(Date.now()+25);const pending=h.processor.processOne(subject(h),deadline);const rejected=assert.rejects(pending);await entered.promise;await rejected;assert.throws(()=>deadline.check());release.resolve();await new Promise(r=>setImmediate(r));assert.equal(h.play.getCalls.length,calls);assert.equal(work(h).state,'working');
});

test('expired invocation does not wait on cleanup behind an already-held database transaction',async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const entered=deferred(),release=deferred();const original=h.database.runTransaction.bind(h.database);let hold=false;
 const acquire=h.repository.acquireAccountAttempt.bind(h.repository);h.repository.acquireAccountAttempt=(...args)=>{hold=true;return acquire(...args);};
 h.database.runTransaction=operation=>original(async tx=>{if(hold){hold=false;entered.resolve();await release.promise;}return operation(tx);});
 const deadline=new BillingDeadline(Date.now()+25),calls=h.play.getCalls.length;const run=h.processor.processOne(subject(h),deadline);const rejected=assert.rejects(run);await entered.promise;await rejected;release.resolve();await new Promise(r=>setImmediate(r));assert.equal(h.play.getCalls.length,calls);
});
test('already-emitted paid v3 result remains immutable after later server revocation',async()=>{const h=setup();await seed(h);h.clock.advance(61_000);const emitted=await h.processor.processOne(subject(h));assert.equal(emitted?.status,'paid');await h.repository.revokeDisclosure(subject(h),h.clock.now());assert.equal(row<AccountAuthority>(h,COLLECTIONS.authorities).snapshot.state,'none');assert.equal(emitted?.status,'paid');assert.equal(work(h).completedObservation,undefined);});

test('a newer same-token claim between terminal commit and final read rejects the old paid response',async()=>{
 const h=setup();await seed(h);h.clock.advance(61_000);const original=h.repository.isCurrentGrant.bind(h.repository);let newer:ReconcileFence|undefined;
 h.repository.isCurrentGrant=async(attempt,now)=>{assert.equal(await original(attempt,now),true);h.clock.advance(61_000);newer=await h.repository.claimReconciliation(subject(h),h.clock.now(),new BillingDeadline());assert.ok(newer);return original(attempt,h.clock.now());};
 const result=await h.processor.processOne(subject(h));assert.equal(result&&'reason'in result&&result.reason,'not_verified');assert.equal(work(h).ownerGeneration,newer!.ownerGeneration);assert.equal(work(h).state,'working');assert.equal(work(h).completedObservation,undefined);
});
