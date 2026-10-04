import {EVENT_WORK_VERSION,emptyCosts} from '../src/event_records.js';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import test from 'node:test';
import { COLLECTIONS, CONTRACT_VERSION, DISCLOSURE_VERSION, DISCLOSURE_PURPOSE } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import { type AccountAuthority, type AuthorityOutbox, outboxFor } from '../src/account_authority.js';
import type { LifecycleRoot } from '../src/lifecycle.js';
import type { AttemptHandle } from '../src/store.js';
import { acceptDisclosure, createHarness, deferred, eligiblePurchase, purchaseToken, verifyRequest } from './test_helpers.js';

type Harness = ReturnType<typeof createHarness>;
const subject = (h: Harness) => h.identifiers.accountSubject(h.identity.uid);
function record<T>(h: Harness, collection: string): T {
  return accountSnapshot(h).get(`${collection}/${subject(h)}`) as T;
}
const authority = (h: Harness) => record<AccountAuthority>(h, COLLECTIONS.authorities);
const restoreRequest = () => ({ version: CONTRACT_VERSION, requestId: randomUUID(), billingDisclosureVersion: DISCLOSURE_VERSION });
// These Stage-A assertions cover account records; job fixture writes are covered
// independently by the Stage-B inbox/reclaim tests.
function accountSnapshot(h:Harness) {return new Map([...h.database.snapshotForTest()].filter(([path])=>!path.startsWith(COLLECTIONS.eventWork+'/')));}
function context(h: Harness) {
  const root = record<LifecycleRoot>(h,COLLECTIONS.lifecycles);
  const eventFingerprint=createHash('sha256').update(randomUUID()).digest('hex');
  const eventWork={eventFingerprint,generation:1,nonce:new Uint8Array(16)};
  const expiry=new Date(h.clock.now().getTime()+90_000);
  h.database.setUnsafeRecordForTest(COLLECTIONS.eventWork,eventFingerprint,{
    ...eventWork,version:EVENT_WORK_VERSION,payloadDigest:'a'.repeat(64),tokenFingerprint:'b'.repeat(64),category:'subscription',state:'working',
    receivedAt:h.clock.now(),dueAt:expiry,leaseExpiresAt:expiry,reason:'none',attemptStarts:[h.clock.now()],totalAttempts:1,dispatchTotals:emptyCosts(),
    envelope:{version:'play-event-token-custody-v1',keyVersion:'projects/synthetic-billing/locations/us-central1/keyRings/testing/cryptoKeys/tokens/cryptoKeyVersions/1',ciphertext:'AAAA'},
    resolved:{accountSubject:subject(h),lifecycleEpoch:root?.lifecycleEpoch??'a'.repeat(32),lifecycleGeneration:root?.lifecycleGeneration??1},
  });
  return { accountSubject: subject(h), work:{kind:'event' as const,fence:eventWork},
    requestFingerprint:createHash('sha256').update(`synthetic-background:${randomUUID()}`).digest('hex'),source:'background' as const };
}
async function backgroundRestore(h: Harness) {
  return h.service.processAccountObservation(context(h), { kind: 'restore', input: restoreRequest() });
}
async function acquire(h: Harness, token: string) {
  const result = await h.repository.acquireAttempt(subject(h), h.identifiers.requestFingerprint(h.identity.uid, randomUUID()),
    h.identifiers.tokenFingerprint(token), h.clock.now());
  assert.equal(result.kind, 'acquired'); if (result.kind !== 'acquired') throw new Error('synthetic acquisition failed');
  return result.attempt;
}
async function seedPaid(h: Harness) {
  await acceptDisclosure(h); const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  return token;
}
const disclosure = (accepted = true) => ({ requestId: randomUUID(), disclosureVersion: DISCLOSURE_VERSION,
  purpose: DISCLOSURE_PURPOSE, ...(accepted ? { accepted: true } : {}) });
function assertSnapshot(h: Harness) {
  const a = authority(h); const root = record<LifecycleRoot>(h, COLLECTIONS.lifecycles);
  assert.equal(root.authorityPublicationRevision, a.publicationRevision);
  assert.deepEqual(record<AuthorityOutbox>(h, COLLECTIONS.authorityOutbox), outboxFor(a.snapshot));
}

test('first admission atomically marks root and initializes bounded authority/outbox, then publishes fresh paid state', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  assert.equal(authority(h), undefined);
  const token = purchaseToken(); const attempt = await acquire(h, token);
  assert.equal(authority(h).observationGeneration, 1); assert.equal(authority(h).publicationRevision, 0);
  assert.equal(authority(h).snapshot.state, 'none'); assertSnapshot(h);
  assert.equal(await h.repository.closeAttempt(attempt, h.clock.now()), true);
  h.clock.advance(20_000); h.play.setPurchase(token, eligiblePurchase(h));
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
  assert.equal(authority(h).publicationRevision, 1); assert.equal(authority(h).observationGeneration, 2);
  assert.equal(authority(h).snapshot.state, 'active'); assertSnapshot(h);
});

for (const missing of ['authority', 'outbox', 'both'] as const) {
  test(`loss of initialized ${missing} fails without resetting high-water or dispatching Play`, async () => {
    const h = createHarness(); await seedPaid(h);
    if (missing !== 'outbox') h.database.deleteRecordForTest(COLLECTIONS.authorities, subject(h));
    if (missing !== 'authority') h.database.deleteRecordForTest(COLLECTIONS.authorityOutbox, subject(h));
    const before = accountSnapshot(h); const calls = h.play.getCalls.length;
    for (const result of [await backgroundRestore(h), await h.service.preparePurchase(h.identity, restoreRequest()),
      await h.service.acceptDisclosure(h.identity, disclosure())]) {
      assert.equal('reason' in result && result.reason, 'unsafe_record');
    }
    assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, calls);
  });
}

test('old valid L1 account requires fresh verification when authority is first initialized', async () => {
  const h = createHarness(); const token = await seedPaid(h);
  // Exact synthetic old-L1 preimage: root lacked markers and no authority/outbox existed.
  const root = record<LifecycleRoot>(h, COLLECTIONS.lifecycles);
  const { authorityVersion: _version, authorityPublicationRevision: _revision, ...oldRoot } = root;
  h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, subject(h), oldRoot);
  h.database.deleteRecordForTest(COLLECTIONS.authorities, subject(h));
  h.database.deleteRecordForTest(COLLECTIONS.authorityOutbox, subject(h));
  h.clock.advance(20_000); h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  const result = await backgroundRestore(h);
  assert.equal('reason' in result && result.reason, 'expired');
  assert.equal(authority(h).snapshot.state, 'none'); assertSnapshot(h);
});

test('shared opaque-subject background engine recovers same-account custody with no raw UID context', async () => {
  const h = createHarness(); await seedPaid(h); h.clock.advance(20_000);
  assert.equal((await backgroundRestore(h)).status, 'paid');
  assert.equal(authority(h).owner?.source, 'background'); assertSnapshot(h);
  const serialized = JSON.stringify([...accountSnapshot(h).values()]);
  assert.equal(serialized.includes(h.identity.uid), false);
  const calls = h.play.getCalls.length;
  for (const invalid of [{ ...context(h), accountSubject: h.identity.uid }, { ...context(h), uid: h.identity.uid }]) {
    assert.equal((await h.service.processAccountObservation(invalid, { kind: 'restore', input: restoreRequest() })).status, 'rejected');
  }
  assert.equal(h.play.getCalls.length, calls);
});

test('different tokens share exclusive admission; denied token acquisition writes no owner, counters or replay', async () => {
  const h = createHarness(); await acceptDisclosure(h);
  const first = await acquire(h, purchaseToken()); const before = accountSnapshot(h);
  const secondToken = purchaseToken(); h.play.setPurchase(secondToken, eligiblePurchase(h));
  const result = await h.service.processAccountObservation(context(h), { kind: 'verify', input: verifyRequest(secondToken) });
  assert.equal('reason' in result && result.reason, 'in_flight');
  assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, 0);
  h.clock.advance(90_000);
  assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(secondToken))).status, 'paid');
  assert.equal(authority(h).observationGeneration, 2);
  const current = accountSnapshot(h);
  assert.equal(await h.repository.markVerifiedOwner(first, 'archivale_starter_monthly', h.clock.now()), false);
  assert.equal(await h.repository.closeAttempt(first, h.clock.now()), false);
  assert.deepEqual(accountSnapshot(h), current);
});

test('failed global token admission does not initialize or strand the other account authority', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken(); await acquire(h, token);
  const other = { uid: 'synthetic-other' };
  await h.service.acceptDisclosure(other, disclosure()); await h.service.preparePurchase(other, restoreRequest());
  const before = accountSnapshot(h);
  assert.equal('reason' in (await h.service.verifySubscription(other, verifyRequest(token))), true);
  assert.deepEqual(accountSnapshot(h), before);
  assert.equal(accountSnapshot(h).has(`${COLLECTIONS.authorities}/${h.identifiers.accountSubject(other.uid)}`), false);
});

test('forged account generation, nonce, source or subject cannot mutate a valid token owner', async () => {
  const h = createHarness(); await acceptDisclosure(h); const attempt = await acquire(h, purchaseToken());
  const before = accountSnapshot(h);
  const forgeries: AttemptHandle[] = [
    { ...attempt, fence: { ...attempt.fence!, observationGeneration: attempt.fence!.observationGeneration + 1 } },
    { ...attempt, fence: { ...attempt.fence!, observationNonce: new Uint8Array(16) } },
    { ...attempt, fence: { ...attempt.fence!, source: 'background' } },
    { ...attempt, accountSubject: 'f'.repeat(64) },
  ];
  for (const forged of forgeries) {
    assert.equal(await h.repository.markVerifiedOwner(forged, 'archivale_starter_monthly', h.clock.now()), false);
  }
  assert.deepEqual(accountSnapshot(h), before);
});

for (const kind of ['live', 'crashed', 'ambiguous'] as const) {
  test(`${kind} acknowledgement blocks different-token admission until same-token fresh recovery`, async () => {
    const entered = deferred(); const release = deferred();
    const h = createHarness({ afterAcknowledgementStarted: async () => { entered.resolve(); await release.promise; } });
    await acceptDisclosure(h); const token = purchaseToken();
    h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
    if (kind === 'ambiguous') h.play.acknowledgeError = new Error('synthetic ambiguous ack');
    const pending = h.service.verifySubscription(h.identity, verifyRequest(token)); await entered.promise;
    if (kind === 'ambiguous') { release.resolve(); await pending; }
    if (kind !== 'live') h.clock.advance(90_000);
    const successor = purchaseToken(); h.play.setPurchase(successor, eligiblePurchase(h, { linkedPurchaseToken: token }));
    const before = accountSnapshot(h); const calls = h.play.getCalls.length;
    const denied = await h.service.verifySubscription(h.identity, verifyRequest(successor));
    assert.equal('reason' in denied && denied.reason, 'verification_pending');
    assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, calls);
    if (kind === 'live') { release.resolve(); assert.equal((await pending).status, 'paid'); }
    else {
      h.play.setPurchase(token, eligiblePurchase(h));
      assert.equal((await backgroundRestore(h)).status, 'paid');
      if (kind === 'crashed') { release.resolve(); assert.notEqual((await pending).status, 'paid'); }
    }
    assert.equal(authority(h).acknowledgementRecoveryToken, undefined);
    assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(successor))).status, 'paid');
    assertSnapshot(h);
  });
}

for (const [oldState, newState] of [['active', 'expired'], ['expired', 'active']] as const) {
  test(`late final server validation cannot return ${oldState} after newer ${newState} authority`, async () => {
    const h = createHarness(); const token = await seedPaid(h); h.clock.advance(20_000);
    const entered = deferred(); const release = deferred();
    if (oldState === 'expired') h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
    const method = oldState === 'active' ? 'isCurrentGrant' : 'isCurrentResponse';
    const original = h.repository[method].bind(h.repository); let paused = false;
    h.repository[method] = async (...args) => { if (!paused) { paused = true; entered.resolve(); await release.promise; } return original(...args); };
    const old = h.service.restoreEntitlement(h.identity, restoreRequest()); await entered.promise;
    h.clock.advance(20_000);
    h.play.setPurchase(token, eligiblePurchase(h, newState === 'expired' ? { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 } : {}));
    const newer = await backgroundRestore(h);
    assert.equal(newer.status, newState === 'active' ? 'paid' : 'none');
    const before = accountSnapshot(h); release.resolve();
    assert.equal((await old).status, 'rejected'); assert.deepEqual(accountSnapshot(h), before); assertSnapshot(h);
  });
}

test('already-emitted v3 reply remains a bounded client lease after later server revocation', async () => {
  const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  const emitted = await h.service.verifySubscription(h.identity, verifyRequest(token)); assert.equal(emitted.status, 'paid');
  await h.service.revokeDisclosure(h.identity, disclosure(false));
  assert.equal(authority(h).snapshot.state, 'none'); assert.equal(authority(h).snapshot.reason, 'revoked');
  // Stage A cannot rewrite a response already sent or invalidate an installed v3 memory lease.
  assert.equal(emitted.status, 'paid'); assert.equal('publicationRevision' in emitted, false);
  if (emitted.status === 'paid') assert.equal(new Date(emitted.leaseExpiresAt).getTime() - new Date(emitted.verifiedAt).getTime(), 15 * 60_000);
});

test('disclosure invalidates observation and publishes no authority; reaccept never republishes cached paid', async () => {
  const h = createHarness(); const token = await seedPaid(h); h.clock.advance(20_000);
  const attempt = await acquire(h, token); const previous = authority(h);
  await h.service.revokeDisclosure(h.identity, disclosure(false));
  assert.equal(authority(h).publicationRevision, previous.publicationRevision + 1);
  assert.equal(await h.repository.markVerifiedOwner(attempt, 'archivale_starter_monthly', h.clock.now()), false);
  await h.service.acceptDisclosure(h.identity, disclosure());
  assert.equal(authority(h).snapshot.state, 'none'); assert.equal(authority(h).snapshot.reason, 'requires_verification');
  assert.equal(authority(h).publicationRevision, previous.publicationRevision + 2); assertSnapshot(h);
});

test('revoke before first purchase initializes marker/outbox; retirement and reaccept cannot reset them', async () => {
  const h = createHarness(); await acceptDisclosure(h); assert.equal(authority(h), undefined);
  await h.service.revokeDisclosure(h.identity, disclosure(false)); assert.equal(authority(h).publicationRevision, 1); assertSnapshot(h);
  const root = record<LifecycleRoot>(h, COLLECTIONS.lifecycles);
  assert.equal(await h.repository.retireLifecycle(subject(h), root, h.clock.now()), true);
  assert.equal(authority(h).snapshot.reason, 'retired'); assert.equal(authority(h).lifecycleGeneration, root.lifecycleGeneration + 1);
  await h.service.acceptDisclosure(h.identity, disclosure());
  assert.equal(authority(h).snapshot.reason, 'retired'); assert.equal(authority(h).publicationRevision, 3); assertSnapshot(h);
  assert.equal('reason' in (await backgroundRestore(h)), true); assert.equal(h.play.getCalls.length, 0);
});

for (const corruption of ['revision', 'digest', 'owner', 'observation_overflow', 'publication_overflow'] as const) {
  test(`authority ${corruption} is rejected without high-water reset or paid grant`, async () => {
    const h = createHarness(); await seedPaid(h); h.clock.advance(20_000);
    const a = authority(h);
    if (corruption === 'revision') a.publicationRevision++;
    if (corruption === 'owner') a.owner = { ...a.owner!, source: 'other' as 'foreground' };
    if (corruption === 'observation_overflow') a.observationGeneration = Number.MAX_SAFE_INTEGER;
    if (corruption === 'publication_overflow') {
      a.publicationRevision = Number.MAX_SAFE_INTEGER; a.snapshot.publicationRevision = Number.MAX_SAFE_INTEGER;
      h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, subject(h), { ...record<LifecycleRoot>(h, COLLECTIONS.lifecycles), authorityPublicationRevision: a.publicationRevision });
      h.database.setUnsafeRecordForTest(COLLECTIONS.authorityOutbox, subject(h), outboxFor(a.snapshot));
    }
    h.database.setUnsafeRecordForTest(COLLECTIONS.authorities, subject(h), a);
    if (corruption === 'digest') h.database.setUnsafeRecordForTest(COLLECTIONS.authorityOutbox, subject(h), { ...outboxFor(a.snapshot), digest: 'f'.repeat(64) });
    const before = accountSnapshot(h); const result = await backgroundRestore(h);
    assert.notEqual(result.status, 'paid');
    // Publication overflow must also reject before admission/provider work, not strand a new lease.
    assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, 1);
  });
}

test('cancellation after an admission callback cannot undo its commit but fences subsequent authority', async () => {
  const h = createHarness(); await acceptDisclosure(h); const original = h.database.runTransaction.bind(h.database);
  const entered = deferred(); const release = deferred();
  h.database.runTransaction = action => original(async tx => { const result = await action(tx); entered.resolve(); await release.promise; return result; });
  const deadline = new BillingDeadline(); const before = accountSnapshot(h);
  const pending = h.repository.acquireAttempt(subject(h), context(h).requestFingerprint, h.identifiers.tokenFingerprint(purchaseToken()), h.clock.now(), deadline);
  await entered.promise; deadline.cancel(); release.resolve();
  // In-flight database commit cannot be canceled after callback return; service dispatch/final validation still must fence it.
  const result = await pending; assert.equal(result.kind, 'acquired');
  if (result.kind === 'acquired') await assert.rejects(h.repository.isCurrentAttempt(result.attempt, h.clock.now()));
  assert.notDeepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, 0);
});

for (const firstUse of ['admission', 'disclosure'] as const) {
  test(`L1 cutover ${firstUse} retains an existing ambiguous acknowledgement barrier`, async () => {
    const h = createHarness(); await acceptDisclosure(h); const token = purchaseToken();
    h.play.setPurchase(token, eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }));
    h.play.acknowledgeError = new Error('synthetic uncertain response');
    assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'pending');
    const { authorityVersion: _v, authorityPublicationRevision: _r, ...oldRoot } = record<LifecycleRoot>(h, COLLECTIONS.lifecycles);
    h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, subject(h), oldRoot);
    h.database.deleteRecordForTest(COLLECTIONS.authorities, subject(h));
    h.database.deleteRecordForTest(COLLECTIONS.authorityOutbox, subject(h));
    h.clock.advance(90_000);
    if (firstUse === 'disclosure') await h.service.acceptDisclosure(h.identity, disclosure());
    const successor = purchaseToken(); h.play.setPurchase(successor, eligiblePurchase(h, { linkedPurchaseToken: token }));
    const calls = h.play.getCalls.length;
    const denied = await h.service.verifySubscription(h.identity, verifyRequest(successor));
    assert.equal('reason' in denied && denied.reason, 'verification_pending'); assert.equal(h.play.getCalls.length, calls);
    h.play.setPurchase(token, eligiblePurchase(h));
    assert.equal((await backgroundRestore(h)).status, 'paid'); assertSnapshot(h);
    assert.equal(authority(h).acknowledgementRecoveryToken, undefined);
  });
}

test('root or initialization-marker loss cannot adopt surviving authority as a first use', async () => {
  for (const missing of ['root', 'marker'] as const) {
    const h = createHarness(); await seedPaid(h);
    if (missing === 'root') h.database.deleteRecordForTest(COLLECTIONS.lifecycles, subject(h));
    else {
      const { authorityVersion: _v, authorityPublicationRevision: _r, ...withoutMarker } = record<LifecycleRoot>(h, COLLECTIONS.lifecycles);
      h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, subject(h), withoutMarker);
    }
    const before = accountSnapshot(h);
    const result = await h.service.preparePurchase(h.identity, restoreRequest());
    assert.equal('reason' in result && result.reason, 'unsafe_record');
    assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, 1);
  }
});

test('a later commit cannot retroactively change an already final-validated v3 paid reply', async () => {
  const h = createHarness(); const token = await seedPaid(h); h.clock.advance(20_000);
  const entered = deferred(); const release = deferred(); const original = h.repository.isCurrentGrant.bind(h.repository); let paused = false;
  h.repository.isCurrentGrant = async (...args) => {
    const valid = await original(...args);
    if (!paused) { paused = true; entered.resolve(); await release.promise; }
    return valid;
  };
  const reply = h.service.restoreEntitlement(h.identity, restoreRequest()); await entered.promise;
  h.clock.advance(20_000); h.play.setPurchase(token, eligiblePurchase(h, { state: 'SUBSCRIPTION_STATE_EXPIRED', expiryOffsetMs: -1 }));
  assert.equal((await backgroundRestore(h)).status, 'none');
  release.resolve(); assert.equal((await reply).status, 'paid');
  assert.equal(authority(h).snapshot.state, 'none'); assertSnapshot(h);
});

test('orphaned acknowledgement recovery pointer cannot authorize a new token or be silently healed', async () => {
  const h = createHarness(); await seedPaid(h);
  h.database.setUnsafeRecordForTest(COLLECTIONS.authorities, subject(h), {
    ...authority(h), acknowledgementRecoveryToken: 'b'.repeat(64),
  });
  const before = accountSnapshot(h);
  const result = await backgroundRestore(h);
  assert.equal('reason' in result && result.reason, 'unsafe_record');
  assert.deepEqual(accountSnapshot(h), before); assert.equal(h.play.getCalls.length, 1);
});
