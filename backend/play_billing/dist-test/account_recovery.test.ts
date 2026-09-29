import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { COLLECTIONS, CONTRACT_VERSION, DISCLOSURE_VERSION } from '../src/constants.js';
import { PlayBillingService } from '../src/verifier.js';
import { BillingDeadline } from '../src/deadline.js';
import { DisabledTokenCustody } from '../src/token_custody.js';
import { acceptDisclosure, createHarness, eligiblePurchase, purchaseToken, recordsInCollection, verifyRequest, deferred } from './test_helpers.js';
import { FakeKmsTransport, testCustody } from './fake_custody.js';
const request = (requestId: string = randomUUID()) => ({ version: CONTRACT_VERSION, requestId, billingDisclosureVersion: DISCLOSURE_VERSION });

test('fresh installation restores from encrypted server custody after process restart and renewal', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  h.clock.advance(60 * 60_000);
  h.play.setPurchase(token, eligiblePurchase(h, { expiryOffsetMs: 30 * 86400_000 }));
  const restarted = new PlayBillingService(h);
  // No token or product is supplied by the fresh client; there is no local Play facade here.
  assert.equal((await restarted.restoreEntitlement(h.identity, request())).status, 'paid');
  assert.equal(h.play.getCalls.length, 2);
  assert.equal(h.play.acknowledgeCalls.length, 0);
  assert.equal(JSON.stringify([...h.database.snapshotForTest()]).includes(token), false);
  assert.equal(recordsInCollection(h.database, COLLECTIONS.accounts).length, 1);
  assert.equal((recordsInCollection(h.database, COLLECTIONS.bindings)[0] as Record<string, unknown>).retentionExpiresAt, undefined);
});

test('crash after encrypted delivery is discoverable before acknowledgement', async () => {
  const h = createHarness({ afterDeliveryCommitted: async () => { throw new Error('synthetic crash'); } });
  await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'unavailable');
  assert.equal(h.play.acknowledgeCalls.length, 0);
  const restarted = new PlayBillingService(h);
  assert.equal((await restarted.restoreEntitlement(h.identity, request())).status, 'pending');
  assert.equal(h.play.getCalls.length, 1);
  h.clock.advance(90_000);
  assert.equal((await restarted.restoreEntitlement(h.identity, request())).status, 'paid');
  assert.equal(h.play.acknowledgeCalls.length, 1);
});

test('disabled custody cannot acknowledge or publish an account binding', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  const service = new PlayBillingService({ ...h, custody: new DisabledTokenCustody() });
  assert.equal((await service.verifySubscription(h.identity, verifyRequest(token))).status, 'unavailable');
  assert.equal(h.play.acknowledgeCalls.length, 0);
  assert.equal(recordsInCollection(h.database, COLLECTIONS.accounts).length, 0);
});

test('disclosure revoke and TTL recreation cannot revive a delayed encryption result', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  const gate = deferred(); const entered = deferred(); const kms = new FakeKmsTransport();
  kms.beforeCall = async () => { entered.resolve(); await gate.promise; };
  const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
  const pending = service.verifySubscription(h.identity, verifyRequest(token)); await entered.promise;
  const subject = h.identifiers.accountSubject(h.identity.uid);
  await h.repository.revokeDisclosure(subject, h.clock.now());
  h.database.deleteRecordForTest(COLLECTIONS.disclosures, subject);
  await acceptDisclosure(h); gate.resolve();
  assert.notEqual((await pending).status, 'paid');
  assert.equal(h.play.acknowledgeCalls.length, 0);
  assert.equal(recordsInCollection(h.database, COLLECTIONS.accounts).length, 0);
});

test('wrong account and legacy state never provide account authority', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  const other = { uid: 'synthetic-other-account' };
  await h.repository.acceptDisclosure(h.identifiers.accountSubject(other.uid), h.clock.now());
  const count = h.play.getCalls.length;
  assert.equal((await h.service.restoreEntitlement(other, request())).status, 'none');
  assert.equal(h.play.getCalls.length, count);
  const subject = h.identifiers.accountSubject(other.uid);
  h.database.setUnsafeRecordForTest(COLLECTIONS.bindings, 'synthetic-legacy', { contractVersion: 'play-billing-v1', accountSubject: subject });
  const legacy = await h.service.restoreEntitlement(other, request());
  assert.equal('reason' in legacy && legacy.reason, 'recovery_required');
  assert.equal(h.play.getCalls.length, count);
});

test('authoritative expiry differs from failure and no request can extend stale authority', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  await h.service.verifySubscription(h.identity, verifyRequest(token)); h.clock.advance(20_000);
  h.play.getError = new Error('synthetic unavailable');
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'unavailable');
  h.play.getError = undefined; h.clock.advance(20_000);
  h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  const expired = await h.service.restoreEntitlement(h.identity, request());
  assert.equal('reason' in expired && expired.reason, 'expired');
  assert.equal(expired.status, 'none');
});

test('expired whole-call deadline performs no Play work', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const result = await h.service.restoreEntitlement(h.identity, request(), new BillingDeadline(Date.now() - 1));
  assert.equal(result.status, 'unavailable'); assert.equal(h.play.getCalls.length, 0);
});

test('same-parent KMS version relabel cannot reach Play during account restore', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const transport = new FakeKmsTransport();
  const { GoogleKmsTokenCustody } = await import('../src/kms_token_custody.js');
  const { TEST_KEY } = await import('./fake_custody.js');
  const nextVersion = TEST_KEY.slice(0, -1) + '2';
  const service = new PlayBillingService({ ...h, custody: new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY, nextVersion], transport) });
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  const binding = recordsInCollection(h.database, COLLECTIONS.bindings)[0] as Record<string, unknown>;
  h.database.setUnsafeRecordForTest(COLLECTIONS.bindings, h.identifiers.tokenFingerprint(token), {
    ...binding, tokenEnvelope: { ...binding.tokenEnvelope as object, keyVersion: nextVersion },
  });
  h.clock.advance(20_000); const before = h.play.getCalls.length;
  assert.equal((await service.restoreEntitlement(h.identity, request())).status, 'unavailable');
  assert.equal(h.play.getCalls.length, before);
});

test('unrelated active receipt cannot overwrite account; fresh expired authority permits replacement', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const first = purchaseToken(); const second = purchaseToken();
  h.play.setPurchase(first, eligiblePurchase(h));
  h.play.setPurchase(second, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(first))).status, 'paid');
  const conflict = await h.service.verifySubscription(h.identity, verifyRequest(second));
  assert.equal('reason' in conflict && conflict.reason, 'account_conflict');
  assert.equal(h.play.acknowledgeCalls.length, 0);
  h.clock.advance(90_000);
  h.play.setPurchase(first, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'none');
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(second))).status, 'paid');
  assert.equal(h.play.acknowledgeCalls.length, 1);
});

test('account revision changed during decrypt prevents any later Play request', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const kms = new FakeKmsTransport(); const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  await service.verifySubscription(h.identity, verifyRequest(token)); h.clock.advance(20_000);
  const gate = deferred(); const entered = deferred(); kms.beforeCall = async () => { entered.resolve(); await gate.promise; };
  const restoring = service.restoreEntitlement(h.identity, request()); await entered.promise;
  const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
  h.database.setUnsafeRecordForTest(COLLECTIONS.accounts, h.identifiers.accountSubject(h.identity.uid), { ...index, revision: (index.revision as number) + 1 });
  gate.resolve(); assert.notEqual((await restoring).status, 'paid'); assert.equal(h.play.getCalls.length, 1);
});

test('concurrent restore requests serialize before decrypt and same UUID cannot change action', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const kms = new FakeKmsTransport(); const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h)); const receipt = verifyRequest(token);
  await service.verifySubscription(h.identity, receipt); h.clock.advance(20_000);
  const reused = await service.restoreEntitlement(h.identity, request(receipt.requestId));
  assert.equal('reason' in reused && reused.reason, 'replay_conflict');
  const gate = deferred(); const entered = deferred(); kms.beforeCall = async () => { entered.resolve(); await gate.promise; };
  const first = service.restoreEntitlement(h.identity, request()); await entered.promise;
  const second = await service.restoreEntitlement(h.identity, request());
  assert.equal(second.status, 'pending'); assert.equal(kms.calls.filter((v) => v === 'decrypt').length, 1);
  gate.resolve(); assert.equal((await first).status, 'paid');
});

for (const state of ['EXPIRED', 'ON_HOLD', 'PAUSED', 'REVOKED', 'PENDING']) {
  test(`newer ${state} observation fences an older committed paid reply`, async () => {
    const h = createHarness(); await acceptDisclosure(h);
    const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
    const entered = deferred(); const release = deferred(); let first = true;
    const grant = h.repository.isCurrentGrant.bind(h.repository);
    h.repository.isCurrentGrant = async (...args) => {
      if (first) { first = false; entered.resolve(); await release.promise; }
      return grant(...args);
    };
    const older = h.service.verifySubscription(h.identity, verifyRequest(token)); await entered.promise;
    h.clock.advance(20_000);
    h.play.setPurchase(token, eligiblePurchase(h, { state: `SUBSCRIPTION_STATE_${state}`, expiryOffsetMs: -1 }));
    const newer = await h.service.restoreEntitlement(h.identity, request());
    assert.equal(newer.status, state === 'PENDING' ? 'pending' : 'none');
    release.resolve(); assert.notEqual((await older).status, 'paid');
    const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
    assert.equal(index.revision, 3);
    const operation = recordsInCollection(h.database, COLLECTIONS.operations)[0] as Record<string, unknown>;
    assert.equal(operation.phase, 'free');
    assert.equal(h.play.getCalls.length, 2);
  });
}

test('a newer failed lookup owner still fences an older committed paid reply', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  const entered = deferred(); const release = deferred(); let first = true;
  const grant = h.repository.isCurrentGrant.bind(h.repository);
  h.repository.isCurrentGrant = async (...args) => {
    if (first) { first = false; entered.resolve(); await release.promise; }
    return grant(...args);
  };
  const older = h.service.verifySubscription(h.identity, verifyRequest(token)); await entered.promise;
  h.clock.advance(20_000); h.play.getError = new Error('synthetic unavailable');
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'unavailable');
  release.resolve(); assert.notEqual((await older).status, 'paid');
});

test('a delayed inactive observation cannot overwrite a newer paid result or claim authoritative inactivity', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  await h.service.verifySubscription(h.identity, verifyRequest(token)); h.clock.advance(20_000);
  h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  const entered = deferred(); const release = deferred();
  const inactive = h.repository.recordInactive.bind(h.repository);
  h.repository.recordInactive = async (...args) => { entered.resolve(); await release.promise; return inactive(...args); };
  const older = h.service.restoreEntitlement(h.identity, request()); await entered.promise;
  h.clock.advance(90_000); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'paid');
  const before = recordsInCollection(h.database, COLLECTIONS.accounts)[0];
  release.resolve(); const stale = await older;
  assert.equal(stale.status, 'rejected'); assert.equal('reason' in stale && stale.reason, 'not_verified');
  assert.deepEqual(recordsInCollection(h.database, COLLECTIONS.accounts)[0], before);
});

for (const invalidPointer of ['current', 'candidate'] as const) {
  for (const damage of ['missing', 'cross-account', 'malformed'] as const) {
    test(`both index pointers are checked before custody: ${invalidPointer} is ${damage}`, async () => {
      const h = createHarness(); await acceptDisclosure(h);
      const kms = new FakeKmsTransport(); const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
      const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
      await service.verifySubscription(h.identity, verifyRequest(token)); h.clock.advance(20_000);
      const subject = h.identifiers.accountSubject(h.identity.uid);
      const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
      const binding = recordsInCollection(h.database, COLLECTIONS.bindings)[0] as Record<string, unknown>;
      const bad = 'a'.repeat(64);
      if (damage !== 'missing') h.database.setUnsafeRecordForTest(COLLECTIONS.bindings, bad, {
        ...binding, tokenFingerprint: bad,
        ...(damage === 'cross-account' ? { accountSubject: h.identifiers.accountSubject('different-account') } : { ackState: 'invalid' }),
      });
      h.database.setUnsafeRecordForTest(COLLECTIONS.accounts, subject, {
        ...index, current: h.identifiers.tokenFingerprint(token), candidate: h.identifiers.tokenFingerprint(token), [invalidPointer]: bad,
      });
      const playCount = h.play.getCalls.length; const custodyCount = kms.calls.length;
      for (const result of [await service.restoreEntitlement(h.identity, request()),
        await service.verifySubscription(h.identity, verifyRequest(token))]) {
        assert.equal(result.status, 'rejected'); assert.equal('reason' in result && result.reason, 'unsafe_record');
      }
      assert.equal(h.play.getCalls.length, playCount); assert.equal(kms.calls.length, custodyCount);
    });
  }
}

test('a late committed inactive result cannot reply inactive after newer paid authority', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  await h.service.verifySubscription(h.identity, verifyRequest(token)); h.clock.advance(20_000);
  h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  const entered = deferred(); const release = deferred();
  const inactive = h.repository.recordInactive.bind(h.repository);
  h.repository.recordInactive = async (...args) => { const result = await inactive(...args); entered.resolve(); await release.promise; return result; };
  const older = h.service.restoreEntitlement(h.identity, request()); await entered.promise;
  h.clock.advance(90_000); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'paid');
  release.resolve(); const stale = await older;
  assert.equal(stale.status, 'rejected'); assert.equal('reason' in stale && stale.reason, 'not_verified');
});

test('genuine unrelated same-account custody cannot form a dual-pointer replacement chain', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const kms = new FakeKmsTransport(); const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
  const first = purchaseToken(); const second = purchaseToken();
  h.play.setPurchase(first, eligiblePurchase(h)); await service.verifySubscription(h.identity, verifyRequest(first));
  h.clock.advance(20_000);
  h.play.setPurchase(first, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  await service.restoreEntitlement(h.identity, request());
  h.play.setPurchase(second, eligiblePurchase(h)); await service.verifySubscription(h.identity, verifyRequest(second));
  h.clock.advance(20_000);
  const subject = h.identifiers.accountSubject(h.identity.uid);
  const firstFingerprint = h.identifiers.tokenFingerprint(first); const secondFingerprint = h.identifiers.tokenFingerprint(second);
  const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
  const binding = recordsInCollection(h.database, COLLECTIONS.bindings).find((v) => (v as Record<string, unknown>).tokenFingerprint === secondFingerprint) as Record<string, unknown>;
  h.database.setUnsafeRecordForTest(COLLECTIONS.bindings, secondFingerprint, { ...binding, attemptPhase: 'delivery_committed' });
  h.database.setUnsafeRecordForTest(COLLECTIONS.accounts, subject, { ...index, current: firstFingerprint, candidate: secondFingerprint });
  h.play.setPurchase(first, eligiblePurchase(h));
  const beforePlay = h.play.getCalls.length; const beforeCustody = kms.calls.length;
  const result = await service.restoreEntitlement(h.identity, request());
  assert.equal('reason' in result && result.reason, 'unsafe_record');
  assert.equal(h.play.getCalls.length, beforePlay); assert.equal(kms.calls.length, beforeCustody);
  assert.equal((recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>).current, firstFingerprint);
});

for (const corruption of ['none', 'wrong-predecessor', 'current-successor', 'candidate-successor'] as const) {
  test(`linked pending delivery recovery validates reciprocal chain: ${corruption}`, async () => {
    const h = createHarness(); await acceptDisclosure(h);
    const first = purchaseToken(); const second = purchaseToken();
    h.play.setPurchase(first, eligiblePurchase(h)); await h.service.verifySubscription(h.identity, verifyRequest(first));
    h.play.setPurchase(second, eligiblePurchase(h, { linkedPurchaseToken: first, acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
    const crashing = new PlayBillingService({ ...h, hooks: { afterDeliveryCommitted: async () => { throw new Error('synthetic crash'); } } });
    assert.equal((await crashing.verifySubscription(h.identity, verifyRequest(second))).status, 'unavailable');
    h.clock.advance(90_000);
    const firstFingerprint = h.identifiers.tokenFingerprint(first); const secondFingerprint = h.identifiers.tokenFingerprint(second);
    const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
    assert.equal(index.current, firstFingerprint); assert.equal(index.candidate, secondFingerprint);
    if (corruption !== 'none') {
      const fingerprint = corruption === 'current-successor' ? firstFingerprint : secondFingerprint;
      const binding = recordsInCollection(h.database, COLLECTIONS.bindings).find((v) => (v as Record<string, unknown>).tokenFingerprint === fingerprint) as Record<string, unknown>;
      h.database.setUnsafeRecordForTest(COLLECTIONS.bindings, fingerprint, { ...binding,
        ...(corruption === 'wrong-predecessor' ? { stagedPredecessorFingerprint: 'a'.repeat(64) } : { successorFingerprint: 'a'.repeat(64) }),
      });
    }
    const before = h.play.getCalls.length;
    const result = await new PlayBillingService(h).restoreEntitlement(h.identity, request());
    if (corruption === 'none') {
      assert.equal(result.status, 'paid'); assert.equal(h.play.acknowledgeCalls.length, 1);
      const old = recordsInCollection(h.database, COLLECTIONS.bindings).find((v) => (v as Record<string, unknown>).tokenFingerprint === firstFingerprint) as Record<string, unknown>;
      assert.equal(old.successorFingerprint, secondFingerprint); assert.equal(old.bindingState, 'superseded');
    } else {
      assert.equal('reason' in result && result.reason, 'unsafe_record');
      assert.equal(h.play.getCalls.length, before); assert.equal(h.play.acknowledgeCalls.length, 0);
    }
  });
}

test('freshly expired unrelated replacement survives crash before acknowledgement without an obsolete current pointer', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const first = purchaseToken(); const second = purchaseToken();
  h.play.setPurchase(first, eligiblePurchase(h)); await h.service.verifySubscription(h.identity, verifyRequest(first));
  h.clock.advance(20_000);
  h.play.setPurchase(first, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'none');
  h.play.setPurchase(second, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  const crashing = new PlayBillingService({ ...h, hooks: { afterDeliveryCommitted: async () => { throw new Error('synthetic crash'); } } });
  assert.equal((await crashing.verifySubscription(h.identity, verifyRequest(second))).status, 'unavailable');
  const index = recordsInCollection(h.database, COLLECTIONS.accounts)[0] as Record<string, unknown>;
  assert.equal(index.current, undefined); assert.equal(index.candidate, h.identifiers.tokenFingerprint(second));
  assert.equal(recordsInCollection(h.database, COLLECTIONS.bindings).length, 2);
  assert.equal(h.play.acknowledgeCalls.length, 0);
  h.clock.advance(90_000);
  assert.equal((await new PlayBillingService(h).restoreEntitlement(h.identity, request())).status, 'paid');
  assert.equal(h.play.acknowledgeCalls.length, 1);
});
