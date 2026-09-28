import { syntheticEnvelopeForRepositoryTests } from '../dist-test/fake_custody.js';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, describe, test } from 'node:test';

import { deleteApp, initializeApp, type App } from 'firebase-admin/app';
import { getFirestore, type Firestore } from 'firebase-admin/firestore';

import { ATTEMPT_LEASE_MS, BILLING_DATABASE_ID, COLLECTIONS } from '../src/constants.js';
import { FirestoreBillingDatabase } from '../src/firestore_store.js';
import { BillingRepository, type AttemptHandle } from '../src/store.js';
import { PlayBillingService } from '../src/verifier.js';
import { CryptoNonceSource, createBillingIdentifiers, type BillingIdentifiers } from '../src/crypto.js';
import { CONTRACT_VERSION, DISCLOSURE_VERSION } from '../src/constants.js';
import { createHarness, eligiblePurchase, purchaseToken, verifyRequest, DeterministicNonceSource, FakeClock } from '../dist-test/test_helpers.js';

if (process.env.FIRESTORE_EMULATOR_HOST === undefined) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required');
}

const apps: App[] = [];

after(async () => {
  await Promise.all(apps.map((app) => deleteApp(app)));
});

describe('named billing database persistence', () => {
  test('encrypted account restore survives a repository/service restart on named Firestore', async () => {
    const h = createHarness();
    const persisted = createFirestoreHarness(h.identifiers);
    const subject = h.identifiers.accountSubject(h.identity.uid);
    await persisted.repository.acceptDisclosure(subject, h.clock.now());
    const prepared = await persisted.repository.preparePurchase(subject, h.clock.now());
    assert.equal(prepared.kind, 'ready');
    if (prepared.kind !== 'ready') throw new Error('routing setup failed');
    const service = new PlayBillingService({ ...h, repository: persisted.repository });
    const token = purchaseToken(); h.play.setPurchase(token, { ...eligiblePurchase(h), externalAccountIdentifiers: { obfuscatedExternalAccountId: prepared.obfuscatedAccountId } });
    assert.equal((await service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
    const stored = await readRecord(persisted.firestore, COLLECTIONS.bindings, h.identifiers.tokenFingerprint(token));
    assert.equal(JSON.stringify(stored).includes(token), false);
    assert.equal(stored.retentionExpiresAt, undefined);
    h.clock.advance(20_000);
    const restarted = new PlayBillingService({ ...h,
      repository: new BillingRepository(new FirestoreBillingDatabase(persisted.firestore), new CryptoNonceSource(), h.identifiers),
    });
    await restarted.acceptDisclosure(h.identity, { requestId: randomUUID(), disclosureVersion: DISCLOSURE_VERSION,
      purpose: 'play_subscription_verification', accepted: true });
    const restored = await restarted.restoreEntitlement(h.identity, {
      version: CONTRACT_VERSION, requestId: randomUUID(), billingDisclosureVersion: DISCLOSURE_VERSION,
    });
    assert.equal(restored.status, 'paid');
    assert.equal(h.play.getCalls.length, 2);
    const index = await readRecord(persisted.firestore, COLLECTIONS.accounts, subject);
    assert.equal(index.current === h.identifiers.tokenFingerprint(token), true);
  });

  test('concurrent first registration and lost response preserve one reciprocal Firestore route', async () => {
    const h = createFirestoreHarness(); const subject = opaque(`route-account-${randomUUID()}`);
    await h.repository.acceptDisclosure(subject, h.clock.now());
    const prepared = await Promise.all([1,2,3].map(() => h.repository.preparePurchase(subject, h.clock.now())));
    assert.equal(prepared.every((value) => value.kind === 'ready'), true);
    assert.deepEqual(prepared[0], prepared[1]); assert.deepEqual(prepared[1], prepared[2]);
    const root = await readRecord(h.firestore, COLLECTIONS.lifecycles, subject);
    const route = await readRecord(h.firestore, COLLECTIONS.routes, root.routeFingerprint as string);
    assert.equal(route.lifecycleEpoch, root.lifecycleEpoch); assert.equal(route.assertionId, root.assertionId);
    const routes = await h.firestore.collection(COLLECTIONS.routes).where('accountSubject', '==', subject).get();
    assert.equal(routes.size, 1);
    // A failed response after the transaction is durable cannot rotate identity.
    const original = h.repository.preparePurchase.bind(h.repository);
    h.repository.preparePurchase = async (...args) => { await original(...args); throw new Error('synthetic lost response'); };
    await assert.rejects(h.repository.preparePurchase(subject, h.clock.now()));
    assert.deepEqual(await original(subject, h.clock.now()), prepared[0]);
  });

  test('Firestore disclosure synchronization and retirement remain atomic across restart', async () => {
    const h = createFirestoreHarness(); const subject = opaque(`retire-account-${randomUUID()}`);
    await h.repository.acceptDisclosure(subject, h.clock.now());
    await h.repository.preparePurchase(subject, h.clock.now());
    const first = await readRecord(h.firestore, COLLECTIONS.lifecycles, subject);
    await h.repository.revokeDisclosure(subject, h.clock.now());
    const paused = await readRecord(h.firestore, COLLECTIONS.lifecycles, subject);
    assert.equal(paused.status, 'consent_paused'); assert.notEqual(paused.assertionId, first.assertionId);
    await h.firestore.collection(COLLECTIONS.disclosures).doc(subject).delete();
    await h.repository.acceptDisclosure(subject, h.clock.now());
    const resumed = await readRecord(h.firestore, COLLECTIONS.lifecycles, subject);
    assert.equal(resumed.lifecycleEpoch, first.lifecycleEpoch); assert.equal(resumed.obfuscatedAccountId, first.obfuscatedAccountId);
    assert.equal((await readRecord(h.firestore, COLLECTIONS.routes, resumed.routeFingerprint as string)).assertionId, resumed.assertionId);
    assert.equal(await h.repository.retireLifecycle(subject, { lifecycleEpoch: resumed.lifecycleEpoch as string,
      lifecycleGeneration: resumed.lifecycleGeneration as number }, h.clock.now()), true);
    await h.repository.acceptDisclosure(subject, h.clock.now());
    assert.equal((await h.repository.preparePurchase(subject, h.clock.now())).kind, 'recovery_required');
    const retired = await readRecord(h.firestore, COLLECTIONS.lifecycles, subject);
    assert.equal(retired.status, 'retired'); assert.equal(retired.lifecycleGeneration, 2);
  });

  test('Firestore direct prepare refuses legacy and orphan route records without creating root', async () => {
    for (const collection of [COLLECTIONS.bindings, COLLECTIONS.accounts, COLLECTIONS.routes]) {
      const h = createFirestoreHarness(); const subject = opaque(`orphan-account-${randomUUID()}`);
      await h.repository.acceptDisclosure(subject, h.clock.now());
      await h.firestore.collection(collection).doc(collection === COLLECTIONS.accounts ? subject : randomUUID())
        .set({ contractVersion: 'play-billing-v2', accountSubject: subject });
      if (collection === COLLECTIONS.routes) await assert.rejects(h.repository.preparePurchase(subject, h.clock.now()));
      else assert.equal((await h.repository.preparePurchase(subject, h.clock.now())).kind, 'recovery_required');
      assert.equal((await h.firestore.collection(COLLECTIONS.lifecycles).doc(subject).get()).exists, false);
    }
  });

  test('persists opaque owner fields in only the three approved records', async () => {
    const harness = createFirestoreHarness();
    const rawAccountId = `raw-account-${randomUUID()}`;
    const rawPurchaseToken = `raw-token-${randomUUID()}`;
    const rawRequestId = `raw-request-${randomUUID()}`;
    const accountSubject = opaque(rawAccountId);
    const tokenFingerprint = opaque(rawPurchaseToken);
    const requestFingerprint = opaque(rawRequestId);
    const attempt = await acquire(harness, accountSubject, requestFingerprint, tokenFingerprint);

    assert.equal(
      await harness.repository.markVerifiedOwner(
        attempt,
        'archivale_starter_monthly',
        harness.clock.now(),
      ),
      true,
    );
    assert.equal(await commitDelivery(harness, attempt), true);

    const records = await loadRecords(harness.firestore, [
      [COLLECTIONS.bindings, tokenFingerprint],
      [COLLECTIONS.replays, requestFingerprint],
      [COLLECTIONS.operations, tokenFingerprint],
      [COLLECTIONS.rateLimits, accountSubject],
    ]);
    assert.equal(records.length, 4);

    const ownerBearing = records
      .filter(({ value }) => hasOwnerFields(value))
      .map(({ collection }) => collection)
      .sort();
    assert.deepEqual(ownerBearing, [
      COLLECTIONS.bindings,
      COLLECTIONS.operations,
      COLLECTIONS.replays,
    ].sort());

    for (const record of records) {
      assert.equal(record.id === rawAccountId, false);
      assert.equal(record.id === rawPurchaseToken, false);
      assert.equal(record.id === rawRequestId, false);
      assert.equal(containsValue(record.value, rawAccountId), false);
      assert.equal(containsValue(record.value, rawPurchaseToken), false);
      assert.equal(containsValue(record.value, rawRequestId), false);
    }
  });

  test('uses Firestore transactions as a single acknowledgement CAS boundary', async () => {
    const harness = createFirestoreHarness();
    const attempt = await stageDelivery(harness);

    const results = await Promise.all([
      harness.repository.beginAcknowledgement(attempt, harness.clock.now()),
      harness.repository.beginAcknowledgement(attempt, harness.clock.now()),
    ]);
    assert.equal(results.filter(Boolean).length, 1);

    const operation = await readRecord(
      harness.firestore,
      COLLECTIONS.operations,
      attempt.tokenFingerprint,
    );
    assert.equal((operation.acknowledgementStartedAt as unknown[]).length, 1);
    assert.equal(operation.phase, 'ack_in_progress');
  });

  test('rejects stale owner writes after the Firestore-backed attempt is reclaimed', async () => {
    const harness = createFirestoreHarness();
    const oldAttempt = await stageAcknowledgement(harness);
    harness.clock.advance(ATTEMPT_LEASE_MS);
    const reclaimed = await harness.repository.acquireAttempt(
      oldAttempt.accountSubject,
      oldAttempt.owner.requestFingerprint,
      oldAttempt.tokenFingerprint,
      harness.clock.now(),
    );
    assert.equal(reclaimed.kind, 'acquired');
    if (reclaimed.kind !== 'acquired') {
      throw new Error('reclaim setup failed');
    }
    assert.equal(
      reclaimed.attempt.owner.attemptGeneration,
      oldAttempt.owner.attemptGeneration + 1,
    );

    assert.equal(
      await harness.repository.markVerifiedOwner(
        reclaimed.attempt,
        'archivale_starter_monthly',
        harness.clock.now(),
      ),
      true,
    );
    assert.equal(await commitDelivery(harness, reclaimed.attempt), true);

    assert.equal(
      await harness.repository.markAcknowledgementUnknown(oldAttempt, harness.clock.now()),
      false,
    );
    assert.equal(
      await harness.repository.finalizePaid(
        oldAttempt,
        harness.clock.now(),
        'ack_in_progress',
      ),
      undefined,
    );

    const binding = await readRecord(
      harness.firestore,
      COLLECTIONS.bindings,
      oldAttempt.tokenFingerprint,
    );
    assert.equal(binding.attemptGeneration, reclaimed.attempt.owner.attemptGeneration);
    assert.equal(binding.attemptRequestFingerprint, reclaimed.attempt.owner.requestFingerprint);
  });
});

function createFirestoreHarness(identifiers: BillingIdentifiers = createBillingIdentifiers(Buffer.alloc(32, 7))): {
  clock: FakeClock;
  firestore: Firestore;
  repository: BillingRepository;
} {
  const app = initializeApp({ projectId: 'demo-archivale-billing' }, randomUUID());
  apps.push(app);
  const firestore = getFirestore(app, BILLING_DATABASE_ID);
  assert.equal(firestore.databaseId, BILLING_DATABASE_ID);
  return {
    clock: new FakeClock(),
    firestore,
    repository: new BillingRepository(
      new FirestoreBillingDatabase(firestore),
      new CryptoNonceSource(),
      identifiers,
    ),
  };
}

async function stageAcknowledgement(
  harness: ReturnType<typeof createFirestoreHarness>,
): Promise<AttemptHandle> {
  const attempt = await stageDelivery(harness);
  assert.equal(await harness.repository.beginAcknowledgement(attempt, harness.clock.now()), true);
  return attempt;
}

async function stageDelivery(
  harness: ReturnType<typeof createFirestoreHarness>,
): Promise<AttemptHandle> {
  const attempt = await acquire(
    harness,
    opaque(`account-${randomUUID()}`),
    opaque(`request-${randomUUID()}`),
    opaque(`token-${randomUUID()}`),
  );
  assert.equal(
    await harness.repository.markVerifiedOwner(
      attempt,
      'archivale_starter_monthly',
      harness.clock.now(),
    ),
    true,
  );
  assert.equal(await commitDelivery(harness, attempt), true);
  return attempt;
}

async function acquire(
  harness: ReturnType<typeof createFirestoreHarness>,
  accountSubject: string,
  requestFingerprint: string,
  tokenFingerprint: string,
): Promise<AttemptHandle> {
  if (!await harness.repository.hasCurrentDisclosure(accountSubject, harness.clock.now())) await harness.repository.acceptDisclosure(accountSubject, harness.clock.now());
  await harness.repository.preparePurchase(accountSubject, harness.clock.now());
  const result = await harness.repository.acquireAttempt(
    accountSubject,
    requestFingerprint,
    tokenFingerprint,
    harness.clock.now(),
  );
  assert.equal(result.kind, 'acquired');
  if (result.kind !== 'acquired') {
    throw new Error('attempt setup failed');
  }
  return result.attempt;
}

function commitDelivery(
  harness: ReturnType<typeof createFirestoreHarness>,
  attempt: AttemptHandle,
): Promise<boolean> {
  const now = harness.clock.now();
  return harness.repository.commitDelivery(attempt, {
    tokenEnvelope: syntheticEnvelopeForRepositoryTests,
    planId: 'starter',
    productId: 'archivale_starter_monthly',
    normalizedState: 'active',
    playExpiresAt: new Date(now.getTime() + 60 * 60_000),
    verifiedAt: now,
    playAcknowledged: false,
  });
}

async function loadRecords(
  firestore: Firestore,
  paths: Array<[string, string]>,
): Promise<Array<{ collection: string; id: string; value: Record<string, unknown> }>> {
  return Promise.all(
    paths.map(async ([collection, id]) => ({
      collection,
      id,
      value: await readRecord(firestore, collection, id),
    })),
  );
}

async function readRecord(
  firestore: Firestore,
  collection: string,
  id: string,
): Promise<Record<string, unknown>> {
  const snapshot = await firestore.collection(collection).doc(id).get();
  assert.equal(snapshot.exists, true);
  return snapshot.data() as Record<string, unknown>;
}

function hasOwnerFields(value: Record<string, unknown>): boolean {
  return [
    'requestFingerprint',
    'attemptRequestFingerprint',
    'attemptGeneration',
    'attemptNonce',
  ].some((field) => field in value);
}

function opaque(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

function containsValue(value: unknown, target: string): boolean {
  if (value === target) {
    return true;
  }
  if (Array.isArray(value)) {
    return value.some((nested) => containsValue(nested, target));
  }
  if (value !== null && typeof value === 'object') {
    return Object.values(value).some((nested) => containsValue(nested, target));
  }
  return false;
}
