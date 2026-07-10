import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, describe, test } from 'node:test';

import { deleteApp, initializeApp, type App } from 'firebase-admin/app';
import { getFirestore, type Firestore } from 'firebase-admin/firestore';

import { ATTEMPT_LEASE_MS, BILLING_DATABASE_ID, COLLECTIONS } from '../src/constants.js';
import { FirestoreBillingDatabase } from '../src/firestore_store.js';
import { BillingRepository, type AttemptHandle } from '../src/store.js';
import { DeterministicNonceSource, FakeClock } from '../dist-test/test_helpers.js';

if (process.env.FIRESTORE_EMULATOR_HOST === undefined) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required');
}

const apps: App[] = [];

after(async () => {
  await Promise.all(apps.map((app) => deleteApp(app)));
});

describe('named billing database persistence', () => {
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
    const attempt = await stageAcknowledgement(harness);

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
    assert.equal(operation.acknowledgementStartCount, 1);
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

function createFirestoreHarness(): {
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
      new DeterministicNonceSource(),
    ),
  };
}

async function stageAcknowledgement(
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
  assert.equal(await harness.repository.beginAcknowledgement(attempt, harness.clock.now()), true);
  return attempt;
}

async function acquire(
  harness: ReturnType<typeof createFirestoreHarness>,
  accountSubject: string,
  requestFingerprint: string,
  tokenFingerprint: string,
): Promise<AttemptHandle> {
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
