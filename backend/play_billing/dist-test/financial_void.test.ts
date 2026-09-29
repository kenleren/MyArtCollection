import assert from 'node:assert/strict';
import test, {type TestContext} from 'node:test';
import { randomUUID } from 'node:crypto';
import { financialFixture, voidNotification } from './financial_void_fixture.js';
import { COLLECTIONS } from '../src/constants.js';
import { UnsafeBillingRecordError } from '../src/store.js';
import { BillingDeadline } from '../src/deadline.js';
import { FINANCIAL_EVENT_VERSION, financialVoid } from '../src/financial_void.js';
import { validEventWork, EVENT_WORK_VERSION } from '../src/event_records.js';
import { eventDispatch } from '../src/dispatch_gate.js';
import { eventRuntimeConfiguration } from '../src/event_runtime.js';
import { eligiblePurchase, purchaseToken, verifyRequest, deferred } from './test_helpers.js';
import { configurationDigest } from '../src/dispatch_budget.js';
import { testDispatchConfig } from './dispatch_fixtures.js';
async function setup(t: TestContext, enabled=true) {
  t.mock.timers.enable({apis:['Date'],now:Date.now()});
  const h=await financialFixture({enabled});
  return {...h,database:h.memoryDatabase,advance:(ms:number)=>{h.clock.advance(ms);t.mock.timers.tick(ms);}};
}
const deadline=()=>new BillingDeadline();

test('actual factory and physical transports: full void of old renewal rechecks current paid account',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  const e=voidNotification(token,'synthetic-private-renewal-order');
  await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(row.state,'completed');assert.equal(row.verification?.outcome,'paid');assert.ok(validEventWork(row,row.eventFingerprint));
  assert.equal(h.counts.get,2);assert.equal(h.counts.ack,0);assert.equal(row.dispatchTotals.discoveryGet,0);
  assert.deepEqual(row.dispatchTotals,{discoveryGet:0,verificationGet:1,eventKms:2,accountKms:1,ack:0});
  const budget=await h.read(COLLECTIONS.dispatchControl,'budget');assert.deepEqual(budget.totals.event,{play_get:1,play_ack:0,kms_encrypt:1,kms_decrypt:2});
  const stored=JSON.stringify([...h.database.snapshotForTest()]);assert.equal(stored.includes(token),false);assert.equal(stored.includes('synthetic-private-renewal-order'),false);
});

test('superseded historical token always restores successor rather than verifying incoming token',async t=>{
  const h=await setup(t),old=await h.paid();h.advance(20_000);
  const current=purchaseToken();h.play.setPurchase(current,eligiblePurchase(h,{linkedPurchaseToken:old}));
  assert.equal((await h.service.verifySubscription(h.identity,verifyRequest(current))).status,'paid');h.advance(20_000);
  h.play.setPurchase(old,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
  const e=voidNotification(old);await h.processor.ingest(e);await h.processor.pump();
  assert.equal((await h.job(e))?.verification?.outcome,'paid');assert.equal(h.requestedTokens.at(-1),current);
});

test('current expiry publishes inactive through verifier and requires completed receipt',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_EXPIRED',expiryOffsetMs:-1}));
  const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(row.state,'completed');assert.equal(row.verification?.outcome,'inactive');assert.equal(row.verification?.reason,'expired');assert.ok(validEventWork(row,row.eventFingerprint));
});

for (const [productType,refundType,reason] of [[2,1,'unsupported_one_time'],[2,2,'unsupported_one_time'],[1,2,'unsupported_partial'],[9,1,'unknown_enum'],[1,9,'unknown_enum']] as const) {
  test(`strict non-granting classification ${productType}/${refundType}`,async t=>{
    const h=await setup(t),e=voidNotification(purchaseToken(),undefined,{productType,refundType});
    await h.processor.ingest(e);await h.processor.pump();const row=(await h.job(e))!;
    assert.equal(row.reason,reason);assert.equal(row.financialRole,'quarantine');assert.equal(row.envelope,undefined);assert.deepEqual(h.counts,{get:0,ack:0,kms:0});
    assert.equal([...h.database.snapshotForTest()].some(([k])=>k.startsWith(COLLECTIONS.financialOrders+'/')),false);
  });
}
for(const [label,order,productType] of [['empty','',1],['control','a\u0000b',1],['long','a'.repeat(1025),1],['legacy-max','a'.repeat(4096),1],['negative','old-order',-1]] as const) {
  test(`legacy-first exact duplicate preserves ${label}, strict new admission rejects`,async t=>{
    const h=await setup(t,false),e=voidNotification(purchaseToken(),order,{productType});
    await h.processor.ingest(e);const before=await h.job(e);assert.equal(before?.version,EVENT_WORK_VERSION);
    const enabled=h.processorFor(await h.makeRuntime(true));const all=h.database.snapshotForTest();
    await enabled.ingest(e);assert.deepEqual(h.database.snapshotForTest(),all);
    const changed={...e,id:randomUUID(),data:{message:{...e.data.message,messageId:''}}};changed.data.message.messageId=changed.id;
    await assert.rejects(enabled.ingest(changed),/unsafe/);assert.deepEqual(h.database.snapshotForTest(),all);
  });
}

test('concurrent same-order deliveries produce one owner, one alias and exact row capacity',async t=>{
  const h=await setup(t),token=purchaseToken(),order='same-order',a=voidNotification(token,order),b=voidNotification(token,order,{eventTime:'1'});
  await Promise.all([h.processor.ingest(a),h.processor.ingest(b)]);
  const rows=[(await h.job(a))!,(await h.job(b))!];assert.deepEqual(rows.map(r=>r.financialRole).sort(),['alias','owner']);assert.equal(h.counts.kms,1);
  assert.equal((await h.read(COLLECTIONS.eventControl,'capacity')).totalRows,2);
  const before=h.database.snapshotForTest();await h.processor.ingest(a);await h.processor.ingest(b);assert.deepEqual(h.database.snapshotForTest(),before);
});

test('different orders sharing token remain distinct; partial before full does not block full owner',async t=>{
  const h=await setup(t),token=purchaseToken(),partial=voidNotification(token,'partial-to-full',{refundType:2});
  await h.processor.ingest(partial);
  const full=voidNotification(token,'partial-to-full'),renewal=voidNotification(token,'different-renewal');
  await h.processor.ingest(full);await h.processor.ingest(renewal);
  assert.equal((await h.job(full))?.financialRole,'owner');assert.equal((await h.job(renewal))?.financialRole,'owner');assert.equal(h.counts.kms,2);
});

for (const changed of ['token','product'] as const) test(`same order changed ${changed} is quarantined without custody or ownership transfer`,async t=>{
  const h=await setup(t),token=purchaseToken(),a=voidNotification(token,'conflicted-order');await h.processor.ingest(a);
  const anchor=await h.read(COLLECTIONS.financialOrders,h.identifiers.financialOrderFingerprint('conflicted-order'));
  const b=voidNotification(changed==='token'?purchaseToken():token,'conflicted-order',{productType:changed==='product'?2:1});
  await h.processor.ingest(b);const row=(await h.job(b))!;
  assert.equal(row.financialRole,'conflict');assert.equal(row.reason,'financial_conflict');assert.equal(row.financialOwnerEventFingerprint,undefined);assert.equal(row.verification,undefined);
  assert.deepEqual(await h.read(COLLECTIONS.financialOrders,anchor.orderFingerprint),anchor);assert.equal(h.counts.kms,1);
});

test('changed message payload rejects even if semantic financial identity matches',async t=>{
  const h=await setup(t),token=purchaseToken(),e=voidNotification(token,'order');await h.processor.ingest(e);const before=h.database.snapshotForTest();
  await assert.rejects(h.processor.ingest(voidNotification(token,'order',{id:e.id,eventTime:'1'})),/unsafe/);assert.deepEqual(h.database.snapshotForTest(),before);
});

for(const missing of ['anchor','owner','anchor-and-owner-with-alias'] as const) test(`surviving financial history rejects ${missing} partial loss`,async t=>{
  const h=await setup(t),token=purchaseToken(),e=voidNotification(token,'retained-order');await h.processor.ingest(e);
  if(missing==='anchor-and-owner-with-alias')await h.processor.ingest(voidNotification(token,'retained-order'));
  if(missing.includes('anchor'))h.database.deleteRecordForTest(COLLECTIONS.financialOrders,h.identifiers.financialOrderFingerprint('retained-order'));
  if(missing.includes('owner'))h.database.deleteRecordForTest(COLLECTIONS.eventWork,h.eventId(e));
  const before=h.database.snapshotForTest();await assert.rejects(h.processor.ingest(voidNotification(token,'retained-order')),/unsafe/);assert.deepEqual(h.database.snapshotForTest(),before);
});

test('failed encryption retains one anchor/slot; alias does not repair; original redelivery reclaims',async t=>{
  const h=await setup(t),token=purchaseToken(),e=voidNotification(token,'custody-crash');h.kms.fail=true;
  await assert.rejects(h.processor.ingest(e),/transient/);h.kms.fail=false;
  await h.processor.ingest(voidNotification(token,'custody-crash'));assert.equal((await h.job(e))?.state,'reserving');assert.equal(h.counts.kms,1);
  h.advance(90_000);await h.processor.ingest(e);const row=(await h.job(e))!;assert.equal(row.state,'ready');assert.equal(row.generation,2);assert.equal(row.dispatchTotals.eventKms,2);
  assert.equal((await h.read(COLLECTIONS.eventControl,'capacity')).totalRows,2);
});

test('unknown token is durable unresolved with no discovery GET',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken());await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(row.state,'blocked');assert.equal(row.reason,'unresolved');assert.equal(row.verification,undefined);assert.equal(h.counts.get,0);
});

test('generic completion bypass rejects; malformed completed owner cannot be parsed or dispatched',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken());await h.processor.ingest(e);
  const work=await h.runtime.events!.claim(h.eventId(e),h.clock.now(),deadline());assert.ok(work);
  const before=h.database.snapshotForTest();await assert.rejects(h.runtime.events!.finish(work,'completed','none',h.clock.now(),deadline()),/unsafe/);assert.deepEqual(h.database.snapshotForTest(),before);
  const bad={...work,state:'completed' as const,leaseExpiresAt:undefined};assert.equal(validEventWork(bad,bad.eventFingerprint),false);
  h.database.setUnsafeRecordForTest(COLLECTIONS.eventWork,bad.eventFingerprint,bad);
  await assert.rejects(h.processor.ingest(e),/unsafe/);assert.equal(h.counts.get,0);
});

test('disabled flag preserves completed receipt and terminal rows; pending work stops without reset',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  const completed=voidNotification(token,'completed');await h.processor.ingest(completed);await h.processor.pump();
  const alias=voidNotification(token,'completed'),conflict=voidNotification(purchaseToken(),'completed'),quarantine=voidNotification(token,'unsupported',{productType:2});
  for(const e of [alias,conflict,quarantine])await h.processor.ingest(e);
  const pending=voidNotification(token,'pending');await h.processor.ingest(pending);
  const disabled=h.processorFor(await h.makeRuntime(false));
  for(const e of [completed,alias,conflict,quarantine]) {const before=await h.job(e);await disabled.ingest(e);assert.deepEqual(await h.job(e),before);}
  const count={...h.counts},costs=(await h.job(pending))!.dispatchTotals;await disabled.pump();
  assert.equal((await h.job(pending))!.reason,'configuration');assert.deepEqual((await h.job(pending))!.dispatchTotals,costs);assert.deepEqual(h.counts,count);
});

test('retirement keeps historical job from binding a recreated account epoch or dispatching Play',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  const subject=h.identifiers.accountSubject(h.identity.uid),root=await h.read(COLLECTIONS.lifecycles,subject);
  await h.repository.retireLifecycle(subject,root,h.clock.now());const before=h.counts.get;await h.processor.pump();
  assert.equal(h.counts.get,before);assert.notEqual((await h.job(e))?.state,'completed');
});

test('consent withdrawal during deferred Play headers prevents physical GET',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  h.hooks.beforePlayHeaders=()=>h.repository.revokeDisclosure(h.identifiers.accountSubject(h.identity.uid),h.clock.now());
  const before=h.counts.get;await h.processor.pump();assert.equal(h.counts.get,before);assert.equal((await h.job(e))?.verification,undefined);
});

test('newer authority before financial completion cannot be replaced by old receipt',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  const original=h.repository.finishFinancialObservation.bind(h.repository);
  h.repository.finishFinancialObservation=async(f,d)=>{await h.repository.revokeDisclosure(h.identifiers.accountSubject(h.identity.uid),h.clock.now());return original(f,d);};
  await h.processor.pump();assert.equal((await h.job(e))?.verification,undefined);
  assert.equal((await h.read(COLLECTIONS.authorities,h.identifiers.accountSubject(h.identity.uid))).snapshot.reason,'revoked');
});

test('financial reciprocal loss after ticket reservation prevents physical action',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken(),'ticket-anchor');await h.processor.ingest(e);
  const w=(await h.runtime.events!.claim(h.eventId(e),h.clock.now(),deadline()))!,cap=eventDispatch(w,'working');
  const gate=h.runtime.gate!,d=gate.playDescriptor(cap,'play_get',JSON.parse(Buffer.from(e.data.message.data,'base64').toString()).voidedPurchaseNotification.purchaseToken);
  const ticket=await gate.reserve(cap,d,deadline());h.database.deleteRecordForTest(COLLECTIONS.financialOrders,w.financial!.orderFingerprint);
  let sent=0;await assert.rejects(gate.consume(ticket,async()=>{sent++;}));assert.equal(sent,0);
});

test('full void flag configuration has exact closed values',()=>{
  assert.throws(()=>eventRuntimeConfiguration({PLAY_BILLING_EVENTS_ENABLED:'enabled',PLAY_BILLING_FULL_VOID_ENABLED:'true'}),/configuration/);
});

test('lost committed admission response preserves one anchor and original cost history',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken(),'response-loss');
  const run=h.database.runTransaction.bind(h.database);let lose=true;
  h.database.runTransaction=async operation=>{const result=await run(operation);if(lose){lose=false;throw Error('synthetic result lost');}return result;};
  await assert.rejects(h.processor.ingest(e),/transient/);assert.equal(h.counts.kms,0);
  h.database.runTransaction=run;const first=(await h.job(e))!;assert.equal(first.state,'reserving');
  h.advance(90_000);await h.processor.ingest(e);assert.equal((await h.job(e))?.state,'ready');
  assert.equal((await h.read(COLLECTIONS.eventControl,'capacity')).totalRows,1);assert.equal((await h.job(e))?.generation,2);
});

test('malformed receipt/state combinations are rejected before duplicate handling',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  const valid=(await h.job(e))!;assert.ok(valid.verification);
  for(const bad of [
    {...valid,verification:undefined},
    {...valid,verification:{...valid.verification!,publicationRevision:0}},
    {...valid,state:'blocked' as const,reason:'unsafe' as const},
    {...valid,financialRole:'alias' as const,financialOwnerEventFingerprint:'a'.repeat(64),state:'blocked' as const,reason:'duplicate_order' as const},
  ]) {
    assert.equal(validEventWork(bad,bad.eventFingerprint),false);h.database.setUnsafeRecordForTest(COLLECTIONS.eventWork,bad.eventFingerprint,bad);
    const before={...h.counts};await assert.rejects(h.processor.ingest(e),/unsafe/);assert.deepEqual(h.counts,before);
  }
});

test('stale working nonce cannot complete or charge after reclaim',async t=>{
  const h=await setup(t),e=voidNotification(purchaseToken());await h.processor.ingest(e);
  const first=(await h.runtime.events!.claim(h.eventId(e),h.clock.now(),deadline()))!;h.advance(90_000);
  const second=(await h.runtime.events!.claim(h.eventId(e),h.clock.now(),deadline()))!;
  assert.equal(second.generation,first.generation+1);assert.deepEqual(second.dispatchTotals,first.dispatchTotals);
  await assert.rejects(h.repository.finishFinancialObservation(first,deadline()),UnsafeBillingRecordError);
  await assert.rejects(h.runtime.events!.charge(first,'eventKms',h.clock.now(),deadline()),/unsafe/);
  assert.equal((await h.job(e))?.generation,second.generation);
});

test('final completion read checks fresh disclosure time and leaves newer state untouched',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);
  const finish=h.repository.finishFinancialObservation.bind(h.repository),run=h.database.runTransaction.bind(h.database);
  h.repository.finishFinancialObservation=async(f,d)=>{
    const subject=h.identifiers.accountSubject(h.identity.uid),disclosure=await h.read(COLLECTIONS.disclosures,subject);
    h.database.setUnsafeRecordForTest(COLLECTIONS.disclosures,subject,{...disclosure,retentionExpiresAt:new Date(+h.clock.now()+100)});
    h.database.runTransaction=op=>run(tx=>op({...tx,get:async<T>(c:Parameters<typeof tx.get>[0],id:string)=>{
      const value=await tx.get<T>(c,id);if(c===COLLECTIONS.authorityOutbox)h.advance(101);return value;
    }}));
    try{return await finish(f,d);}finally{h.database.runTransaction=run;}
  };
  await h.processor.pump();assert.equal((await h.job(e))?.verification,undefined);assert.notEqual((await h.job(e))?.state,'completed');
});

test('foreground and financial Restore contend for last common GET unit',async t=>{
  t.mock.timers.enable({apis:['Date'],now:Date.now()});
  const config=testDispatchConfig();config.global.get=2;config.digest=configurationDigest(config);
  const h=await financialFixture({config}),token=await h.paid();h.clock.advance(20_000);t.mock.timers.tick(20_000);
  const e=voidNotification(token);await h.processor.ingest(e);
  const result=await Promise.allSettled([h.processor.pump(),h.service.restoreEntitlement(h.identity,{version:'play-billing-v3',requestId:randomUUID(),billingDisclosureVersion:'billing-verification-disclosure-v4'})]);
  assert.equal(result.length,2);assert.equal(h.counts.get,2);
  const budget=await h.read(COLLECTIONS.dispatchControl,'budget');assert.equal(budget.totals.foreground.play_get+budget.totals.event.play_get,2);
});

test('revoked current authority completes the financial receipt instead of retrying',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  h.play.setPurchase(token,eligiblePurchase(h,{state:'SUBSCRIPTION_STATE_REVOKED',expiryOffsetMs:60_000}));
  const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(row.state,'completed');assert.equal(row.verification?.outcome,'inactive');assert.equal(row.verification?.reason,'revoked');assert.equal(h.counts.get,2);
});

test('cross-account binding with incompatible lifecycle blocks historical routing before Play',async t=>{
  const h=await setup(t),token=await h.paid();h.advance(20_000);
  const other=h.identifiers.accountSubject('synthetic-second-user');await h.repository.acceptDisclosure(other,h.clock.now());await h.repository.preparePurchase(other,h.clock.now());
  const id=h.identifiers.tokenFingerprint(token),binding=await h.read(COLLECTIONS.bindings,id);
  h.database.setUnsafeRecordForTest(COLLECTIONS.bindings,id,{...binding,accountSubject:other});
  const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  assert.equal(h.counts.get,1);assert.equal((await h.job(e))?.reason,'unsafe');assert.equal((await h.job(e))?.verification,undefined);
});

test('historical void respects current candidate ACK ambiguity instead of selecting old receipt',async t=>{
  const h=await setup(t),old=await h.paid();h.advance(20_000);
  const candidate=purchaseToken();h.play.setPurchase(candidate,eligiblePurchase(h,{linkedPurchaseToken:old,acknowledgementState:'ACKNOWLEDGEMENT_STATE_PENDING'}));
  h.hooks.ackStatus=500;assert.notEqual((await h.service.verifySubscription(h.identity,verifyRequest(candidate))).status,'paid');h.advance(20_000);
  const e=voidNotification(old);await h.processor.ingest(e);await h.processor.pump();
  assert.equal(h.requestedTokens.at(-1),candidate);assert.equal((await h.job(e))?.verification,undefined);
  const authority=await h.read(COLLECTIONS.authorities,h.identifiers.accountSubject(h.identity.uid));assert.equal(authority.acknowledgementRecoveryToken,h.identifiers.tokenFingerprint(candidate));
});

test('malformed null records and null resolved receipt reject without throwing',async t=>{
  for(const value of [null,undefined,[],3,'invalid'])assert.equal(validEventWork(value as never,'a'.repeat(64)),false);
  const h=await setup(t),token=await h.paid();h.advance(20_000);const e=voidNotification(token);await h.processor.ingest(e);await h.processor.pump();
  const row=(await h.job(e))!;assert.equal(validEventWork({...row,resolved:null as never},row.eventFingerprint),false);
  assert.equal(validEventWork({...row,verification:null as never},row.eventFingerprint),false);
});
