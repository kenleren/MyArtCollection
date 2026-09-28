import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { COLLECTIONS, CONTRACT_VERSION, DISCLOSURE_PURPOSE, DISCLOSURE_VERSION } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import { BillingRepository, type BillingDatabase } from '../src/store.js';
import { validOpaqueRoute, type LifecycleRoot } from '../src/lifecycle.js';
import { PlayBillingService } from '../src/verifier.js';
import { acceptDisclosure, createHarness, deferred, eligiblePurchase, purchaseToken, recordsInCollection, verifyRequest, DeterministicNonceSource } from './test_helpers.js';
import { FakeKmsTransport, testCustody } from './fake_custody.js';

const request = (requestId: string = randomUUID()) => ({ version: CONTRACT_VERSION, requestId, billingDisclosureVersion: DISCLOSURE_VERSION });
const disclosure = (accepted = true) => ({ requestId: randomUUID(), disclosureVersion: DISCLOSURE_VERSION, purpose: DISCLOSURE_PURPOSE, ...(accepted ? { accepted: true } : {}) });
type Harness = ReturnType<typeof createHarness>;
function root(h: Harness): LifecycleRoot { return recordsInCollection(h.database, COLLECTIONS.lifecycles)[0] as LifecycleRoot; }
async function retire(h: Harness): Promise<void> {
  const current = root(h);
  assert.equal(await h.repository.retireLifecycle(current.accountSubject, current, h.clock.now()), true);
}

test('fresh disclosure/Restore leaves route absent; prepare creates one reciprocal route exactly once', async () => {
  const h = createHarness();
  assert.equal((await h.service.acceptDisclosure(h.identity, disclosure())).status, 'accepted');
  assert.equal((await h.service.restoreEntitlement(h.identity, request())).status, 'none');
  assert.equal(recordsInCollection(h.database, COLLECTIONS.lifecycles).length, 0);
  const requests = [request(), request()];
  const results = await Promise.all(requests.map((v) => h.service.preparePurchase(h.identity, v)));
  for (const [i, result] of results.entries()) {
    assert.deepEqual(Object.keys(result).sort(), ['version','requestId','status','obfuscatedAccountId','lifecycleEpoch'].sort());
    assert.equal(result.requestId, requests[i]!.requestId);
    assert.equal(result.status, 'ready');
  }
  const stored = root(h);
  assert.equal(validOpaqueRoute(stored.obfuscatedAccountId), true);
  assert.match(stored.lifecycleEpoch, /^[a-f0-9]{32}$/);
  assert.equal(recordsInCollection(h.database, COLLECTIONS.routes).length, 1);
  const retry = await new PlayBillingService(h).preparePurchase(h.identity, requests[0]);
  assert.deepEqual(retry, results[0]);
  assert.equal(h.play.getCalls.length, 0); assert.equal(h.play.acknowledgeCalls.length, 0);
});

test('prepare validates exact v3 request and disclosure without accepting client routing claims', async () => {
  const h = createHarness();
  assert.equal('reason' in (await h.service.preparePurchase(h.identity, request())), true);
  await h.service.acceptDisclosure(h.identity, disclosure());
  for (const input of [{ ...request(), version: 'play-billing-v2' }, { ...request(), lifecycleEpoch: 'a'.repeat(32) },
    { ...request(), requestId: 'not-a-uuid' }, { ...request(), billingDisclosureVersion: 'billing-verification-disclosure-v3' },
    { ...request(), uid: h.identity.uid }, { ...request(), extra: 'x'.repeat(1100) }]) {
    const result = await h.service.preparePurchase(h.identity, input);
    assert.equal('reason' in result && result.reason, 'invalid_request');
  }
  assert.equal(recordsInCollection(h.database, COLLECTIONS.lifecycles).length, 0);
});

for (const [collection, version, expected] of [
  [COLLECTIONS.bindings, 'play-billing-v2', 'recovery_required'],
  [COLLECTIONS.accounts, 'play-billing-v2', 'recovery_required'],
  [COLLECTIONS.bindings, CONTRACT_VERSION, 'unsafe_record'],
  [COLLECTIONS.accounts, CONTRACT_VERSION, 'unsafe_record'],
  [COLLECTIONS.routes, 'play-billing-route-v1', 'unsafe_record'],
] as const) {
  test(`direct prepare cannot bypass missing-root ${collection}/${version}`, async () => {
    const h = createHarness(); await h.service.acceptDisclosure(h.identity, disclosure());
    const subject = h.identifiers.accountSubject(h.identity.uid);
    h.database.setUnsafeRecordForTest(collection, collection === COLLECTIONS.accounts ? subject : 'a'.repeat(64), { contractVersion: version, accountSubject: subject });
    const before = h.database.snapshotForTest();
    const result = await h.service.preparePurchase(h.identity, request());
    assert.equal('reason' in result && result.reason, expected);
    assert.deepEqual(h.database.snapshotForTest(), before);
    assert.equal(h.play.getCalls.length, 0);
  });
}

test('disclosure pause/reaccept and TTL recreation synchronize existing route without prepare', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const original = root(h); const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  assert.equal((await h.service.revokeDisclosure(h.identity, disclosure(false))).status, 'revoked');
  assert.equal(root(h).status, 'consent_paused');
  assert.notEqual(root(h).assertionId, original.assertionId);
  const pausedAssertion = root(h).assertionId;
  h.database.deleteRecordForTest(COLLECTIONS.disclosures, original.accountSubject);
  // Explicit reacceptance alone must resume fresh-install Restore.
  const restarted = new PlayBillingService(h);
  assert.equal((await restarted.acceptDisclosure(h.identity, disclosure())).status, 'accepted');
  h.repository.preparePurchase = async () => { throw new Error('Restore must not prepare'); };
  h.clock.advance(20_000);
  assert.equal((await restarted.restoreEntitlement(h.identity, request())).status, 'paid');
  const resumed = root(h);
  assert.equal(resumed.status, 'active'); assert.notEqual(resumed.assertionId, pausedAssertion);
  assert.equal(resumed.obfuscatedAccountId, original.obfuscatedAccountId);
  assert.equal(resumed.lifecycleEpoch, original.lifecycleEpoch);
  assert.equal(resumed.lifecycleGeneration, original.lifecycleGeneration);
  const route = recordsInCollection(h.database, COLLECTIONS.routes)[0] as Record<string, unknown>;
  assert.equal(route.assertionId, resumed.assertionId); assert.equal(route.status, 'active');
});

test('revoke with absent assertion pauses existing lifecycle; retired lifecycle never revives', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  h.database.deleteRecordForTest(COLLECTIONS.disclosures, root(h).accountSubject);
  assert.equal((await h.service.revokeDisclosure(h.identity, disclosure(false))).status, 'revoked');
  assert.equal(root(h).status, 'consent_paused');
  await retire(h); const retired = root(h);
  h.database.deleteRecordForTest(COLLECTIONS.disclosures, retired.accountSubject);
  await h.service.acceptDisclosure(h.identity, disclosure());
  assert.equal(root(h).status, 'retired'); assert.equal(root(h).lifecycleGeneration, retired.lifecycleGeneration);
  assert.equal(root(h).obfuscatedAccountId, retired.obfuscatedAccountId);
  for (const result of [await h.service.preparePurchase(h.identity, request()), await h.service.restoreEntitlement(h.identity, request())]) {
    assert.equal('reason' in result && result.reason, 'recovery_required');
  }
  assert.equal(h.play.getCalls.length, 0);
});

for (const operation of ['accept', 'revoke', 'prepare', 'restore'] as const) {
  test(`malformed reciprocal route makes ${operation} fail without healing or writes`, async () => {
    const h = createHarness(); await acceptDisclosure(h);
    h.database.setUnsafeRecordForTest(COLLECTIONS.routes, root(h).routeFingerprint, { unexpected: true });
    const before = h.database.snapshotForTest();
    const result = operation === 'accept' ? await h.service.acceptDisclosure(h.identity, disclosure()) :
      operation === 'revoke' ? await h.service.revokeDisclosure(h.identity, disclosure(false)) :
      operation === 'prepare' ? await h.service.preparePurchase(h.identity, request()) : await h.service.restoreEntitlement(h.identity, request());
    assert.equal('reason' in result && result.reason, 'unsafe_record');
    assert.deepEqual(h.database.snapshotForTest(), before); assert.equal(h.play.getCalls.length, 0);
  });
}

test('historical UID hash is not a valid v3 Play identity', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, { ...eligiblePurchase(h), externalAccountIdentifiers: {
    obfuscatedExternalAccountId: createHash('sha256').update(`archivale-play-account-v1\n${h.identity.uid}`).digest('base64url'),
  } });
  const result = await h.service.verifySubscription(h.identity, verifyRequest(token));
  assert.equal('reason' in result && result.reason, 'not_verified');
  assert.equal(recordsInCollection(h.database, COLLECTIONS.bindings).length, 0);
});

for (const boundary of ['acquireAttempt','markVerifiedOwner','commitDelivery','beginAcknowledgement','finalizePaid'] as const) {
  test(`retirement after ${boundary} commit fences later provider work and paid response`, async () => {
    const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
    h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
    const entered = deferred(); const release = deferred();
    const original = h.repository[boundary].bind(h.repository);
    let gated = false;
    // Each concrete method retains its production signature; only its returned
    // committed result is delayed to model the reviewed late-result boundary.
    (h.repository as unknown as Record<string, (...args: any[]) => Promise<unknown>>)[boundary] = async (...args: any[]) => {
      const result = await (original as (...args: any[]) => Promise<unknown>)(...args);
      if (!gated && result) { gated = true; entered.resolve(); await release.promise; }
      return result;
    };
    const pending = h.service.verifySubscription(h.identity, verifyRequest(token));
    await entered.promise; await retire(h); const gets = h.play.getCalls.length; const acks = h.play.acknowledgeCalls.length;
    release.resolve(); assert.notEqual((await pending).status, 'paid');
    assert.equal(h.play.getCalls.length, gets); assert.equal(h.play.acknowledgeCalls.length, acks);
    assert.equal(root(h).status, 'retired');
  });
}

test('retirement during encryption prevents encrypted delivery and acknowledgement', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
  h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
  const kms = new FakeKmsTransport(); const entered = deferred(); const release = deferred();
  kms.beforeCall = async () => { entered.resolve(); await release.promise; };
  const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
  const pending = service.verifySubscription(h.identity, verifyRequest(token)); await entered.promise;
  await retire(h); release.resolve(); assert.notEqual((await pending).status, 'paid');
  assert.equal(recordsInCollection(h.database, COLLECTIONS.bindings).length, 0); assert.equal(h.play.acknowledgeCalls.length, 0);
});

test('canceled late prepare transaction cannot create a route', async () => {
  const h = createHarness(); await h.service.acceptDisclosure(h.identity, disclosure());
  const entered = deferred(); const release = deferred();
  const database: BillingDatabase = { databaseId: h.database.databaseId, runTransaction: (action) => h.database.runTransaction(async (tx) => {
    entered.resolve(); await release.promise; return action(tx);
  }) };
  const repo = new BillingRepository(database, new DeterministicNonceSource(), h.identifiers);
  const service = new PlayBillingService({ ...h, repository: repo }); const deadline = new BillingDeadline();
  const pending = service.preparePurchase(h.identity, request(), deadline); await entered.promise;
  deadline.cancel(); release.resolve(); assert.equal((await pending).status, 'unavailable');
  assert.equal(recordsInCollection(h.database, COLLECTIONS.lifecycles).length, 0);
});

test('retirement rejects stale epoch and generation without writes', async () => {
  const h = createHarness(); await acceptDisclosure(h); const initial = root(h); const before = h.database.snapshotForTest();
  assert.equal(await h.repository.retireLifecycle(initial.accountSubject, { ...initial, lifecycleEpoch: 'a'.repeat(32) }, h.clock.now()), false);
  assert.equal(await h.repository.retireLifecycle(initial.accountSubject, { ...initial, lifecycleGeneration: 2 }, h.clock.now()), false);
  assert.deepEqual(h.database.snapshotForTest(), before);
  await retire(h);
  assert.equal(await h.repository.retireLifecycle(initial.accountSubject, initial, h.clock.now()), false);
});

for (const boundary of ['acquire', 'decrypt'] as const) {
  test(`retirement at restore ${boundary} boundary prevents later Play work`, async () => {
    const h = createHarness(); await acceptDisclosure(h);
    const kms = new FakeKmsTransport(); const service = new PlayBillingService({ ...h, custody: testCustody(kms) });
    const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
    assert.equal((await service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
    h.clock.advance(20_000); const entered = deferred(); const release = deferred();
    if (boundary === 'acquire') {
      const original = h.repository.acquireAccountAttempt.bind(h.repository);
      h.repository.acquireAccountAttempt = async (...args) => { const result = await original(...args); entered.resolve(); await release.promise; return result; };
    } else {
      kms.beforeCall = async () => { entered.resolve(); await release.promise; };
    }
    const pending = service.restoreEntitlement(h.identity, request()); await entered.promise;
    await retire(h); const before = kms.calls.length; release.resolve();
    assert.notEqual((await pending).status, 'paid'); assert.equal(h.play.getCalls.length, 1);
    if (boundary === 'acquire') assert.equal(kms.calls.length, before);
  });
}

async function prepareOtherAccount(h: Harness) {
  const identity = { uid: 'synthetic-other-google-account' };
  assert.equal((await h.service.acceptDisclosure(identity, disclosure())).status, 'accepted');
  assert.equal((await h.service.preparePurchase(identity, request())).status, 'ready');
  return identity;
}

test('unverified wrong-account attempt cannot poison an unbound token or reset its cooldown/counters', async () => {
  const h = createHarness(); await acceptDisclosure(h); const other = await prepareOtherAccount(h);
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  const wrongRequest = verifyRequest(token);
  const wrong = await h.service.verifySubscription(other, wrongRequest);
  assert.equal('reason' in wrong && wrong.reason, 'not_verified');
  const old = recordsInCollection(h.database, COLLECTIONS.operations)[0] as Record<string, unknown>;
  assert.equal(old.accountSubject, undefined); assert.equal(recordsInCollection(h.database, COLLECTIONS.bindings).length, 0);
  const early = await h.service.verifySubscription(h.identity, verifyRequest(token));
  assert.equal('reason' in early && early.reason, 'rate_limited'); assert.equal(h.play.getCalls.length, 1);
  h.clock.advance(90_000);
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  const current = recordsInCollection(h.database, COLLECTIONS.operations)[0] as Record<string, unknown>;
  assert.equal(current.attemptGeneration, Number(old.attemptGeneration) + 1);
  assert.notDeepEqual(current.attemptNonce, old.attemptNonce);
  assert.equal(h.play.getCalls.length, 2);
  assert.equal(recordsInCollection(h.database, COLLECTIONS.rateLimits).length, 2);
  const before = h.database.snapshotForTest();
  assert.notEqual((await h.service.verifySubscription(other, wrongRequest)).status, 'paid');
  assert.deepEqual(h.database.snapshotForTest(), before); assert.equal(h.play.getCalls.length, 2);
});

test('unverified cross-account lease remains protected; reclaimed attempt fences every late old mutation', async () => {
  const h = createHarness(); await acceptDisclosure(h); const other = await prepareOtherAccount(h);
  const token = purchaseToken(); const fingerprint = h.identifiers.tokenFingerprint(token);
  const prior = await h.repository.acquireAttempt(h.identifiers.accountSubject(other.uid),
    h.identifiers.requestFingerprint(other.uid, randomUUID()), fingerprint, h.clock.now());
  assert.equal(prior.kind, 'acquired'); if (prior.kind !== 'acquired') return;
  h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'pending');
  assert.equal(h.play.getCalls.length, 0);
  h.clock.advance(90_000);
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  const before = h.database.snapshotForTest();
  assert.equal(await h.repository.markVerifiedOwner(prior.attempt, 'archivale_starter_monthly', h.clock.now()), false);
  assert.equal(await h.repository.closeAttempt(prior.attempt, h.clock.now()), false);
  assert.equal(await h.repository.isCurrentAttempt(prior.attempt, h.clock.now()), false);
  assert.deepEqual(h.database.snapshotForTest(), before);
});

for (const boundary of ['verified_owner', 'delivery_committed', 'ack_in_progress', 'paid'] as const) {
  test(`cross-account reacquisition cannot transfer ${boundary} ownership`, async () => {
    const h = createHarness(); await acceptDisclosure(h); const other = await prepareOtherAccount(h);
    const token = purchaseToken(); const fingerprint = h.identifiers.tokenFingerprint(token);
    if (boundary === 'verified_owner') {
      const acquired = await h.repository.acquireAttempt(h.identifiers.accountSubject(h.identity.uid),
        h.identifiers.requestFingerprint(h.identity.uid, randomUUID()), fingerprint, h.clock.now());
      assert.equal(acquired.kind, 'acquired'); if (acquired.kind !== 'acquired') return;
      assert.equal(await h.repository.markVerifiedOwner(acquired.attempt, 'archivale_starter_monthly', h.clock.now()), true);
    } else {
      h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
      const service = boundary === 'paid' ? h.service : new PlayBillingService({ ...h, hooks: {
        ...(boundary === 'delivery_committed' ? { afterDeliveryCommitted: async () => { throw new Error('synthetic crash'); } } :
          { afterAcknowledgementStarted: async () => { throw new Error('synthetic crash'); } }),
      } });
      await service.verifySubscription(h.identity, verifyRequest(token));
    }
    const operation = recordsInCollection(h.database, COLLECTIONS.operations)[0] as Record<string, unknown>;
    assert.equal(operation.phase, boundary);
    h.clock.advance(90_000);
    const before = h.database.snapshotForTest(); const calls = h.play.getCalls.length;
    const result = await h.service.verifySubscription(other, verifyRequest(token));
    assert.equal('reason' in result && result.reason, 'unsafe_record');
    assert.deepEqual(h.database.snapshotForTest(), before); assert.equal(h.play.getCalls.length, calls);
  });
}

test('same-account retry cannot erase a verified-owner claim before interrupted custody', async () => {
  const h = createHarness(); await acceptDisclosure(h); const other = await prepareOtherAccount(h);
  const token = purchaseToken(); const fingerprint = h.identifiers.tokenFingerprint(token);
  const subject = h.identifiers.accountSubject(h.identity.uid);
  const acquired = await h.repository.acquireAttempt(subject,
    h.identifiers.requestFingerprint(h.identity.uid, randomUUID()), fingerprint, h.clock.now());
  assert.equal(acquired.kind, 'acquired'); if (acquired.kind !== 'acquired') return;
  assert.equal(await h.repository.markVerifiedOwner(acquired.attempt, 'archivale_starter_monthly', h.clock.now()), true);
  h.clock.advance(90_000);
  const retry = await h.repository.acquireAttempt(subject,
    h.identifiers.requestFingerprint(h.identity.uid, randomUUID()), fingerprint, h.clock.now());
  assert.equal(retry.kind, 'acquired'); if (retry.kind !== 'acquired') return;
  assert.equal(await h.repository.closeAttempt(retry.attempt, h.clock.now()), true);
  assert.equal((recordsInCollection(h.database, COLLECTIONS.operations)[0] as Record<string, unknown>).accountSubject, subject);
  h.clock.advance(90_000);
  const before = h.database.snapshotForTest();
  const result = await h.service.verifySubscription(other, verifyRequest(token));
  assert.equal('reason' in result && result.reason, 'unsafe_record');
  assert.deepEqual(h.database.snapshotForTest(), before); assert.equal(h.play.getCalls.length, 0);
});
