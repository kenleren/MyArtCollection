import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { describe, test } from 'node:test';

import {
  ATTEMPT_LEASE_MS,
  COLLECTIONS,
  DISCLOSURE_PURPOSE,
  DISCLOSURE_VERSION,
  PAID_LEASE_MS,
  type ProductId,
} from '../src/constants.js';
import {
  acceptDisclosure,
  createHarness,
  eligiblePurchase,
  purchaseToken,
  recordsInCollection,
  verifyRequest,
} from './test_helpers.js';

describe('PlayBillingService verification contract', () => {
  test('requires a current billing disclosure before any Play call', async () => {
    const harness = createHarness();
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));

    const missing = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(token),
    );
    assert.equal(missing.state, 'free');
    assert.equal('reason' in missing && missing.reason, 'disclosure_required');
    assert.equal(harness.play.getCalls.length, 0);

    await acceptDisclosure(harness);
    await harness.service.revokeDisclosure(harness.identity, {
      requestId: randomUUID(),
      disclosureVersion: DISCLOSURE_VERSION,
      purpose: DISCLOSURE_PURPOSE,
    });
    const revoked = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(token),
    );
    assert.equal(revoked.state, 'free');
    assert.equal(harness.play.getCalls.length, 0);
  });

  test('rejects stale disclosure and research-shaped assertions before Play', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    harness.clock.advance(365 * 24 * 60 * 60_000);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));

    const stale = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(stale.state, 'free');
    assert.equal(harness.play.getCalls.length, 0);

    const other = createHarness();
    const subject = other.identifiers.accountSubject(other.identity.uid);
    other.database.setUnsafeRecordForTest(COLLECTIONS.disclosures, subject, {
      purpose: 'research',
    });
    const otherToken = purchaseToken();
    other.play.setPurchase(otherToken, eligiblePurchase(other));
    const wrongPurpose = await other.service.verifySubscription(
      other.identity,
      verifyRequest(otherToken),
    );
    assert.equal(wrongPurpose.state, 'free');
    assert.equal(other.play.getCalls.length, 0);
  });

  test('maps active, grace, and canceled-through-expiry to bounded paid leases', async () => {
    const cases: Array<[string, 'active' | 'grace' | 'canceled']> = [
      ['SUBSCRIPTION_STATE_ACTIVE', 'active'],
      ['SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 'grace'],
      ['SUBSCRIPTION_STATE_CANCELED', 'canceled'],
    ];
    for (const [state, expected] of cases) {
      const harness = createHarness();
      await acceptDisclosure(harness);
      const token = purchaseToken();
      harness.play.setPurchase(token, eligiblePurchase(harness, { state }));
      const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
      assert.equal(result.state, expected);
      assert.equal('leaseExpiresAt' in result, true);
      if ('leaseExpiresAt' in result) {
        assert.equal(
          new Date(result.leaseExpiresAt).getTime() - new Date(result.verifiedAt).getTime(),
          PAID_LEASE_MS,
        );
      }
    }
  });

  test('caps a paid lease at Play expiry', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness, { expiryOffsetMs: 60_000 }));
    const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(result.state, 'active');
    if ('leaseExpiresAt' in result) {
      assert.equal(result.leaseExpiresAt, result.playExpiresAt);
    }
  });

  test('fails closed for pending, paused, hold, expired, revoked, and unknown states', async () => {
    const states = [
      'SUBSCRIPTION_STATE_PENDING',
      'SUBSCRIPTION_STATE_PAUSED',
      'SUBSCRIPTION_STATE_ON_HOLD',
      'SUBSCRIPTION_STATE_EXPIRED',
      'SUBSCRIPTION_STATE_REVOKED',
      'SUBSCRIPTION_STATE_FUTURE_UNKNOWN',
    ];
    for (const state of states) {
      const harness = createHarness();
      await acceptDisclosure(harness);
      const token = purchaseToken();
      harness.play.setPurchase(token, eligiblePurchase(harness, { state }));
      const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
      assert.equal(result.state, 'free');
      assert.equal(harness.play.acknowledgeCalls.length, 0);
      assert.equal(recordsInCollection(harness.database, COLLECTIONS.bindings).length, 0);
    }
  });

  test('rejects account, offer, base-plan, prepaid, expiry, and acknowledgement mismatches', async () => {
    const cases = [
      (h: ReturnType<typeof createHarness>) =>
        eligiblePurchase(h, { accountIdentity: { uid: randomBytes(24).toString('base64url') } }),
      (h: ReturnType<typeof createHarness>) => eligiblePurchase(h, { offerId: 'offer' }),
      (h: ReturnType<typeof createHarness>) => eligiblePurchase(h, { basePlanId: 'annual' }),
      (h: ReturnType<typeof createHarness>) => eligiblePurchase(h, { autoRenewing: false }),
      (h: ReturnType<typeof createHarness>) => eligiblePurchase(h, { expiryOffsetMs: -1 }),
      (h: ReturnType<typeof createHarness>) =>
        eligiblePurchase(h, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_UNSPECIFIED' }),
    ];
    for (const makePurchase of cases) {
      const harness = createHarness();
      await acceptDisclosure(harness);
      const token = purchaseToken();
      harness.play.setPurchase(token, makePurchase(harness));
      const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
      assert.equal(result.state, 'free');
      assert.equal(harness.play.acknowledgeCalls.length, 0);
      assert.equal(recordsInCollection(harness.database, COLLECTIONS.bindings).length, 0);
    }
  });

  test('acknowledges only after delivery commit with exact fixed arguments', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }),
    );
    harness.play.beforeAcknowledge = async (args) => {
      const bindings = recordsInCollection(harness.database, COLLECTIONS.bindings) as Array<
        Record<string, unknown>
      >;
      assert.equal(bindings.length, 1);
      assert.equal(bindings[0]?.deliveryState, 'committed');
      assert.equal(args.packageName, 'app.archivale');
      assert.equal(args.subscriptionId, 'archivale_starter_monthly');
      assert.equal(Object.keys(args.body).length, 0);
      assert.equal(args.timeoutMs, 10_000);
    };

    const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(result.state, 'active');
    assert.equal(harness.play.acknowledgeCalls.length, 1);
  });

  test('acknowledgement failure cools down and re-verifies without premature access', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }),
    );
    harness.play.acknowledgeError = new Error('fixed fake failure');
    const request = verifyRequest(token);
    const first = await harness.service.verifySubscription(harness.identity, request);
    assert.equal(first.state, 'free');
    assert.equal('reason' in first && first.reason, 'verification_pending');
    assert.equal(harness.play.acknowledgeCalls.length, 1);

    const beforeBoundary = await harness.service.verifySubscription(harness.identity, request);
    assert.equal(beforeBoundary.state, 'free');
    assert.equal(harness.play.getCalls.length, 1);
    harness.clock.advance(15_000);
    harness.play.acknowledgeError = undefined;
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const recovered = await harness.service.verifySubscription(harness.identity, request);
    assert.equal(recovered.state, 'active');
    assert.equal(harness.play.acknowledgeCalls.length, 1);
    assert.equal(harness.play.getCalls.length, 2);
  });

  test('a finalized binding re-verifies without another acknowledgement call', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const first = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(first.state, 'active');
    harness.clock.advance(15_000);

    const refreshed = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(token),
    );
    assert.equal(refreshed.state, 'active');
    assert.equal(harness.play.getCalls.length, 2);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
  });

  test('returns a bounded unavailable response on a Play API error', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    harness.play.getError = new Error('fixed fake failure');
    const result = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(purchaseToken()),
    );
    assert.deepEqual(Object.keys(result).sort(), ['reason', 'requestId', 'state', 'version']);
    assert.equal('reason' in result && result.reason, 'temporarily_unavailable');
    assert.equal(harness.play.acknowledgeCalls.length, 0);
  });

  test('same request with a different token fails replay without another Play call', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const requestId = randomUUID();
    const firstToken = purchaseToken();
    harness.play.setPurchase(firstToken, eligiblePurchase(harness));
    const first = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(firstToken, 'archivale_starter_monthly', requestId),
    );
    assert.equal(first.state, 'active');

    const secondToken = purchaseToken();
    harness.play.setPurchase(secondToken, eligiblePurchase(harness));
    const second = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(secondToken, 'archivale_starter_monthly', requestId),
    );
    assert.equal('reason' in second && second.reason, 'replay_conflict');
    assert.equal(harness.play.getCalls.length, 1);
  });

  test('a durable token binding cannot move to another account subject', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const first = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(first.state, 'active');

    harness.clock.advance(15_000);
    const otherIdentity = { uid: randomBytes(24).toString('base64url') };
    const disclosure = await harness.service.acceptDisclosure(otherIdentity, {
      requestId: randomUUID(),
      disclosureVersion: DISCLOSURE_VERSION,
      purpose: DISCLOSURE_PURPOSE,
      accepted: true,
    });
    assert.equal('status' in disclosure && disclosure.status, 'accepted');
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { accountIdentity: otherIdentity }),
    );
    const second = await harness.service.verifySubscription(otherIdentity, verifyRequest(token));
    assert.equal(second.state, 'free');
    assert.equal('reason' in second && second.reason, 'not_verified');
    assert.equal(recordsInCollection(harness.database, COLLECTIONS.bindings).length, 1);
  });

  test('malformed operational state fails closed without a Play call', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    const fingerprint = harness.identifiers.tokenFingerprint(token);
    harness.database.setUnsafeRecordForTest(COLLECTIONS.operations, fingerprint, {
      contractVersion: 'unknown',
    });
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal('reason' in result && result.reason, 'unsafe_record');
    assert.equal(harness.play.getCalls.length, 0);
  });

  test('partial replay ownership fails closed instead of transferring authority', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    const request = verifyRequest(token);
    const subject = harness.identifiers.accountSubject(harness.identity.uid);
    const requestFingerprint = harness.identifiers.requestFingerprint(
      harness.identity.uid,
      request.requestId,
    );
    const tokenFingerprint = harness.identifiers.tokenFingerprint(token);
    const acquired = await harness.repository.acquireAttempt(
      subject,
      requestFingerprint,
      tokenFingerprint,
      harness.clock.now(),
    );
    assert.equal(acquired.kind, 'acquired');
    harness.database.deleteRecordForTest(COLLECTIONS.operations, tokenFingerprint);
    const result = await harness.service.verifySubscription(harness.identity, request);
    assert.equal('reason' in result && result.reason, 'unsafe_record');
    assert.equal(harness.play.getCalls.length, 0);
  });

  test('limits acknowledgement starts to three per token window', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(
      token,
      eligiblePurchase(harness, { acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING' }),
    );
    harness.play.acknowledgeError = new Error('fixed fake failure');
    const request = verifyRequest(token);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await harness.service.verifySubscription(harness.identity, request);
      assert.equal('reason' in result && result.reason, 'verification_pending');
      harness.clock.advance(15_000);
    }
    const limited = await harness.service.verifySubscription(harness.identity, request);
    assert.equal('reason' in limited && limited.reason, 'verification_pending');
    assert.equal(harness.play.acknowledgeCalls.length, 3);
    assert.equal(harness.play.getCalls.length, 4);
  });

  test('canceled-pending recovers same-product and cross-product predecessors read-only', async () => {
    const pairs: Array<[ProductId, ProductId]> = [
      ['archivale_starter_monthly', 'archivale_starter_monthly'],
      ['archivale_collector_monthly', 'archivale_starter_monthly'],
    ];
    for (const [successorProduct, predecessorProduct] of pairs) {
      const harness = createHarness();
      await acceptDisclosure(harness);
      const successorToken = purchaseToken();
      const predecessorToken = purchaseToken();
      const successor = eligiblePurchase(harness, {
        productId: successorProduct,
        state: 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
        linkedPurchaseToken: predecessorToken,
      });
      harness.play.setPurchase(successorToken, successor);
      harness.play.setPurchase(
        predecessorToken,
        eligiblePurchase(harness, { productId: predecessorProduct }),
      );
      const result = await harness.service.verifySubscription(
        harness.identity,
        verifyRequest(successorToken, successorProduct),
      );
      assert.equal(result.state, 'active');
      assert.equal('productId' in result && result.productId, predecessorProduct);
      assert.equal(harness.play.getCalls.length, 2);
      assert.equal(harness.play.acknowledgeCalls.length, 0);
      const bindings = recordsInCollection(harness.database, COLLECTIONS.bindings) as Array<
        Record<string, unknown>
      >;
      assert.equal(bindings.length, 1);
      assert.equal(bindings[0]?.productId, predecessorProduct);
      assert.equal(bindings[0]?.bindingState, 'acknowledged_delivery');
    }
  });

  test('canceled-pending never binds or acknowledges a successor when predecessor fails', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const successorToken = purchaseToken();
    const predecessorToken = purchaseToken();
    harness.play.setPurchase(
      successorToken,
      eligiblePurchase(harness, {
        state: 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED',
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
        linkedPurchaseToken: predecessorToken,
      }),
    );
    harness.play.setPurchase(
      predecessorToken,
      eligiblePurchase(harness, { state: 'SUBSCRIPTION_STATE_ON_HOLD' }),
    );
    const result = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(successorToken),
    );
    assert.equal(result.state, 'free');
    assert.equal(recordsInCollection(harness.database, COLLECTIONS.bindings).length, 0);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
  });

  test('malformed requests and unknown products make zero external calls', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    const invalid = await harness.service.verifySubscription(harness.identity, {
      ...verifyRequest(token),
      extra: true,
    });
    assert.equal('reason' in invalid && invalid.reason, 'invalid_request');
    const unknown = await harness.service.verifySubscription(
      harness.identity,
      { ...verifyRequest(token), productId: 'unconfigured' },
    );
    assert.equal(unknown.state, 'free');
    assert.equal(harness.play.getCalls.length, 1);
    assert.equal(harness.play.acknowledgeCalls.length, 0);
  });

  test('rate limits the seventh verification start in one subject window', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    for (let index = 0; index < 6; index += 1) {
      const token = purchaseToken();
      harness.play.setPurchase(token, eligiblePurchase(harness, { state: 'SUBSCRIPTION_STATE_PENDING' }));
      const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
      assert.equal(result.state, 'free');
      harness.clock.advance(15_000);
    }
    const finalToken = purchaseToken();
    harness.play.setPurchase(finalToken, eligiblePurchase(harness));
    const limited = await harness.service.verifySubscription(
      harness.identity,
      verifyRequest(finalToken),
    );
    assert.equal('reason' in limited && limited.reason, 'rate_limited');
    assert.equal(harness.play.getCalls.length, 6);
  });

  test('no durable record grants broker or client entitlement before verification', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness, { state: 'SUBSCRIPTION_STATE_PENDING' }));
    await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    const keys = [...harness.database.snapshotForTest().keys()];
    assert.equal(keys.some((key) => key.includes('brokerDurableEntitlements')), false);
    assert.equal(recordsInCollection(harness.database, COLLECTIONS.bindings).length, 0);
  });

  test('reclaim occurs at the exact lease boundary after a delivery crash', async () => {
    let shouldCrash = true;
    const harness = createHarness({
      afterDeliveryCommitted: async () => {
        if (shouldCrash) {
          shouldCrash = false;
          throw new Error('simulated boundary interruption');
        }
      },
    });
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const request = verifyRequest(token);
    const first = await harness.service.verifySubscription(harness.identity, request);
    assert.equal(first.state, 'free');
    const firstBinding = recordsInCollection(harness.database, COLLECTIONS.bindings)[0] as Record<
      string,
      unknown
    >;
    const firstGeneration = firstBinding.attemptGeneration;
    const firstNonce = firstBinding.attemptNonce as Uint8Array;

    harness.clock.advance(ATTEMPT_LEASE_MS - 1);
    const early = await harness.service.verifySubscription(harness.identity, request);
    assert.equal('reason' in early && early.reason, 'in_flight');
    assert.equal(harness.play.getCalls.length, 1);

    harness.clock.advance(1);
    const recovered = await harness.service.verifySubscription(harness.identity, request);
    assert.equal(recovered.state, 'active');
    assert.equal(harness.play.getCalls.length, 2);
    const secondBinding = recordsInCollection(harness.database, COLLECTIONS.bindings)[0] as Record<
      string,
      unknown
    >;
    assert.equal(secondBinding.attemptGeneration === Number(firstGeneration) + 1, true);
    assert.equal(bytesDiffer(firstNonce, secondBinding.attemptNonce as Uint8Array), true);
  });
});

function bytesDiffer(left: Uint8Array, right: Uint8Array): boolean {
  return left.some((value, index) => value !== right[index]);
}
