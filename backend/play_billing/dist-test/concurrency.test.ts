import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { describe, test } from 'node:test';

import { ATTEMPT_LEASE_MS, COLLECTIONS } from '../src/constants.js';
import type { AttemptHandle } from '../src/store.js';
import {
  acceptDisclosure,
  createHarness,
  deferred,
  eligiblePurchase,
  purchaseToken,
  recordsInCollection,
  verifyRequest,
  type Harness,
} from './test_helpers.js';

describe('billing request and token concurrency', () => {
  test('distinct request IDs share one token single-flight', async () => {
    const gate = deferred();
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    harness.play.beforeGet = async () => gate.promise;

    const first = harness.service.verifySubscription(harness.identity, verifyRequest(token));
    await waitUntil(() => harness.play.getCalls.length === 1);
    const second = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal('reason' in second && second.reason, 'in_flight');
    assert.equal(harness.play.getCalls.length, 1);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
    gate.resolve();
    assert.equal((await first).state, 'active');
  });

  test('identical request arrival after delivery commit cannot adopt ownership', async () => {
    const gate = deferred();
    const harness = createHarness({ afterDeliveryCommitted: async () => gate.promise });
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }),
    );
    const request = verifyRequest(token);

    const first = harness.service.verifySubscription(harness.identity, request);
    await waitUntil(
      () => recordsInCollection(harness.database, COLLECTIONS.bindings).length === 1,
    );
    const getCount = harness.play.getCalls.length;
    const duplicate = await harness.service.verifySubscription(harness.identity, request);
    assert.equal('reason' in duplicate && duplicate.reason, 'in_flight');
    assert.equal(harness.play.getCalls.length, getCount);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
    gate.resolve();
    assert.equal((await first).state, 'active');
    assert.equal(harness.play.acknowledgeCalls.length, 1);
  });

  test('duplicate arrival while acknowledgement runs starts no calls', async () => {
    const gate = deferred();
    const harness = createHarness({ afterAcknowledgementStarted: async () => gate.promise });
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }),
    );
    const first = harness.service.verifySubscription(harness.identity, verifyRequest(token));
    await waitUntil(() => operationPhase(harness) === 'ack_in_progress');
    const duplicate = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal('reason' in duplicate && duplicate.reason, 'in_flight');
    assert.equal(harness.play.getCalls.length, 1);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
    gate.resolve();
    assert.equal((await first).state, 'active');
    assert.equal(harness.play.acknowledgeCalls.length, 1);
  });

  test('two workers can authorize exactly one acknowledgement start', async () => {
    const harness = createHarness();
    const attempt = await stageDelivery(harness);
    const results = await Promise.all([
      harness.repository.beginAcknowledgement(attempt, harness.clock.now()),
      harness.repository.beginAcknowledgement(attempt, harness.clock.now()),
    ]);
    assert.equal(results.filter(Boolean).length, 1);
    const operation = recordsInCollection(harness.database, COLLECTIONS.operations)[0] as Record<
      string,
      unknown
    >;
    assert.equal((operation.acknowledgementStartedAt as unknown[]).length, 1);
  });

  test('paid finalization wins a competing ambiguous callback and cannot regress', async () => {
    const harness = createHarness();
    const attempt = await stageAcknowledgement(harness);
    const [commit, unknownCommitted] = await Promise.all([
      harness.repository.finalizePaid(attempt, harness.clock.now(), 'ack_in_progress'),
      harness.repository.markAcknowledgementUnknown(attempt, harness.clock.now()),
    ]);
    assert.equal(commit !== undefined, true);
    assert.equal(unknownCommitted, false);
    assertFinalized(harness);

    const staleCallback = await harness.repository.markAcknowledgementUnknown(
      attempt,
      harness.clock.now(),
    );
    assert.equal(staleCallback, false);
    assertFinalized(harness);
  });

  test('an ambiguous callback that wins forces cooldown and fresh verification', async () => {
    const harness = createHarness();
    const attempt = await stageAcknowledgement(harness);
    const unknownCommitted = await harness.repository.markAcknowledgementUnknown(
      attempt,
      harness.clock.now(),
    );
    const staleSuccess = await harness.repository.finalizePaid(
      attempt,
      harness.clock.now(),
      'ack_in_progress',
    );
    assert.equal(unknownCommitted, true);
    assert.equal(staleSuccess, undefined);

    const early = await harness.repository.acquireAttempt(
      attempt.accountSubject,
      attempt.owner.requestFingerprint,
      attempt.tokenFingerprint,
      harness.clock.now(),
    );
    assert.equal(early.kind, 'verification_pending');
    harness.clock.advance(15_000);
    const reclaimed = await harness.repository.acquireAttempt(
      attempt.accountSubject,
      attempt.owner.requestFingerprint,
      attempt.tokenFingerprint,
      harness.clock.now(),
    );
    assert.equal(reclaimed.kind, 'acquired');
  });

  test('stale owner writes fail after generation-advancing reclaim', async () => {
    const harness = createHarness();
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
      reclaimed.attempt.owner.attemptGeneration === oldAttempt.owner.attemptGeneration + 1,
      true,
    );
    assert.equal(
      bytesDiffer(reclaimed.attempt.owner.attemptNonce, oldAttempt.owner.attemptNonce),
      true,
    );

    const staleUnknown = await harness.repository.markAcknowledgementUnknown(
      oldAttempt,
      harness.clock.now(),
    );
    const staleFinal = await harness.repository.finalizePaid(
      oldAttempt,
      harness.clock.now(),
      'ack_in_progress',
    );
    assert.equal(staleUnknown, false);
    assert.equal(staleFinal, undefined);
    assert.equal(operationPhase(harness), 'lookup_in_flight');
  });

  test('linked successor supersedes predecessor only in acknowledged finalization', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const predecessorToken = purchaseToken();
    harness.play.setPurchase(predecessorToken, eligiblePurchase(harness));
    const predecessor = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(predecessorToken),
    );
    assert.equal(predecessor.state, 'active');

    const successorToken = purchaseToken();
    harness.play.setPurchase(
      successorToken,
      eligiblePurchase(harness, {
        productId: 'archivale_collector_monthly',
        linkedPurchaseToken: predecessorToken,
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
      }),
    );
    const successor = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(successorToken, 'archivale_collector_monthly'),
    );
    assert.equal(successor.state, 'active');
    const bindings = recordsInCollection(harness.database, COLLECTIONS.bindings) as Array<
      Record<string, unknown>
    >;
    assert.equal(bindings.length, 2);
    assert.equal(bindings.filter((record) => record.bindingState === 'superseded').length, 1);
    assert.equal(
      bindings.filter((record) => record.bindingState === 'acknowledged_delivery').length,
      1,
    );

    harness.clock.advance(15_000);
    const stalePredecessor = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(predecessorToken),
    );
    assert.equal(stalePredecessor.state, 'free');
    const afterRetry = recordsInCollection(harness.database, COLLECTIONS.bindings) as Array<
      Record<string, unknown>
    >;
    assert.equal(afterRetry.filter((record) => record.bindingState === 'superseded').length, 1);
  });
});

async function stageDelivery(harness: Harness): Promise<AttemptHandle> {
  const accountSubject = harness.identifiers.accountSubject(harness.identity.uid);
  const tokenFingerprint = harness.identifiers.tokenFingerprint(purchaseToken());
  const requestFingerprint = harness.identifiers.requestFingerprint(
    harness.identity.uid,
    randomUUID(),
  );
  const acquired = await harness.repository.acquireAttempt(
    accountSubject,
    requestFingerprint,
    tokenFingerprint,
    harness.clock.now(),
  );
  if (acquired.kind !== 'acquired') {
    throw new Error('attempt setup failed');
  }
  const verified = await harness.repository.markVerifiedOwner(
    acquired.attempt,
    'archivale_starter_monthly',
    harness.clock.now(),
  );
  const delivered = await harness.repository.commitDelivery(acquired.attempt, {
    planId: 'starter',
    productId: 'archivale_starter_monthly',
    normalizedState: 'active',
    playExpiresAt: new Date(harness.clock.now().getTime() + 60 * 60_000),
    verifiedAt: harness.clock.now(),
    playAcknowledged: false,
  });
  if (!verified || !delivered) {
    throw new Error('delivery setup failed');
  }
  return acquired.attempt;
}

async function stageAcknowledgement(harness: Harness): Promise<AttemptHandle> {
  const attempt = await stageDelivery(harness);
  const started = await harness.repository.beginAcknowledgement(attempt, harness.clock.now());
  if (!started) {
    throw new Error('acknowledgement setup failed');
  }
  return attempt;
}

function operationPhase(harness: Harness): unknown {
  const operation = recordsInCollection(harness.database, COLLECTIONS.operations)[0] as
    | Record<string, unknown>
    | undefined;
  return operation?.phase;
}

function assertFinalized(harness: Harness): void {
  const binding = recordsInCollection(harness.database, COLLECTIONS.bindings)[0] as Record<
    string,
    unknown
  >;
  const operation = recordsInCollection(harness.database, COLLECTIONS.operations)[0] as Record<
    string,
    unknown
  >;
  assert.equal(binding.ackState, 'acknowledged');
  assert.equal(binding.bindingState, 'acknowledged_delivery');
  assert.equal(operation.outcomeCode, 'paid');
}

function bytesDiffer(left: Uint8Array, right: Uint8Array): boolean {
  return left.some((value, index) => value !== right[index]);
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) {
      return;
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
  throw new Error('test barrier was not reached');
}
