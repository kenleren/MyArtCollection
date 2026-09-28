import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomUUID } from 'node:crypto';
import { BillingDeadline } from '../src/deadline.js';
import { BillingRepository, type BillingDatabase } from '../src/store.js';
import { createHarness, deferred, DeterministicNonceSource, eligiblePurchase, purchaseToken, verifyRequest } from './test_helpers.js';
import { PlayBillingService } from '../src/verifier.js';
import { COLLECTIONS } from '../src/constants.js';

test('per-operation timeout permanently invalidates original 55-second invocation', async () => {
  const deadline = new BillingDeadline(); const gate = deferred(); let writes = 0;
  await assert.rejects(deadline.run(async () => { await gate.promise; deadline.check(); writes++; }, 5));
  gate.resolve(); await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes, 0); assert.throws(() => deadline.check());
});

test('late database callback after timeout cannot acquire authority or call Play', async () => {
  const h = createHarness(); const gate = deferred(); let delay = false;
  const database: BillingDatabase = {
    databaseId: h.database.databaseId,
    runTransaction: (operation) => h.database.runTransaction(async (tx) => {
      if (delay) await gate.promise;
      return operation(tx);
    }),
  };
  const repository = new BillingRepository(database, new DeterministicNonceSource());
  await repository.acceptDisclosure(h.identifiers.accountSubject(h.identity.uid), h.clock.now());
  const token = purchaseToken(); h.play.setPurchase(token, eligiblePurchase(h));
  const service = new PlayBillingService({ ...h, repository });
  const deadline = new BillingDeadline(); delay = true;
  await assert.rejects(deadline.run(() => service.verifySubscription(h.identity, verifyRequest(token), deadline), 5));
  gate.resolve(); await new Promise((resolve) => setImmediate(resolve));
  assert.equal(h.play.getCalls.length, 0);
  assert.equal([...h.database.snapshotForTest().keys()].some((k) => k.startsWith(COLLECTIONS.accounts)), false);
});
