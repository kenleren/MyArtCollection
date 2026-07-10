import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { describe, test } from 'node:test';

import type { Firestore } from 'firebase-admin/firestore';

import {
  BILLING_DATABASE_ID,
  BILLING_VERIFIER_SERVICE_ACCOUNT,
  COLLECTIONS,
} from '../src/constants.js';
import { FirestoreBillingDatabase } from '../src/firestore_store.js';
import {
  acceptDisclosure,
  createHarness,
  eligiblePurchase,
  purchaseToken,
  recordsInCollection,
  verifyRequest,
} from './test_helpers.js';

const repositoryRoot = resolve(process.cwd(), '../..');

describe('billing isolation and redaction', () => {
  test('firebase targets the dedicated codebase and named database', async () => {
    const firebase = JSON.parse(
      await readFile(resolve(repositoryRoot, 'firebase.json'), 'utf8'),
    ) as Record<string, unknown>;
    const functions = firebase.functions as Array<Record<string, unknown>>;
    const firestore = firebase.firestore as Array<Record<string, unknown>>;
    const billingCodebases = functions.filter((entry) => entry.codebase === 'play-billing');
    assert.equal(billingCodebases.length, 1);
    assert.equal(billingCodebases[0]?.source, 'backend/play_billing');
    assert.equal(firestore.length, 1);
    assert.equal(firestore[0]?.database, BILLING_DATABASE_ID);
    assert.equal(firestore[0]?.rules, 'firestore.play-billing.rules');
  });

  test('client rules deny every read and write without exceptions', async () => {
    const rules = await readFile(resolve(repositoryRoot, 'firestore.play-billing.rules'), 'utf8');
    assert.equal(rules.includes('match /{document=**}'), true);
    assert.equal(rules.includes('allow read, write: if false;'), true);
    assert.equal(/allow\s+(read|write)[^;]*if\s+true/.test(rules), false);
    assert.equal(rules.match(/\ballow\b/g)?.length, 1);
  });

  test('Firestore adapter rejects any non-billing database', () => {
    const wrongDatabase = { databaseId: '(default)' } as unknown as Firestore;
    assert.throws(() => new FirestoreBillingDatabase(wrongDatabase), /database mismatch/);
  });

  test('raw request identity material never enters durable records', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    const result = await harness.service.verifySubscription(harness.identity, verifyRequest(token));
    assert.equal(result.state, 'active');
    const stored = [...harness.database.snapshotForTest().values()];
    assert.equal(containsValue(stored, token), false);
    assert.equal(containsValue(stored, harness.identity.uid), false);
    assert.equal(
      containsValue(stored, harness.identifiers.obfuscatedAccountId(harness.identity.uid)),
      false,
    );
  });

  test('opaque attempt fields exist only in the three server-only collections', async () => {
    const harness = createHarness();
    await acceptDisclosure(harness);
    const token = purchaseToken();
    harness.play.setPurchase(token, eligiblePurchase(harness));
    await harness.service.verifySubscription(harness.identity, verifyRequest(token));

    const permitted = new Set<string>([
      COLLECTIONS.bindings,
      COLLECTIONS.replays,
      COLLECTIONS.operations,
    ]);
    const ownerFieldNames = new Set([
      'attemptGeneration',
      'attemptNonce',
      'attemptRequestFingerprint',
    ]);
    let ownerBearingCollectionCount = 0;
    for (const [key, record] of harness.database.snapshotForTest()) {
      const collection = key.slice(0, key.indexOf('/'));
      const fields = new Set(Object.keys(record as Record<string, unknown>));
      const hasOwnerField = [...ownerFieldNames].some((field) => fields.has(field));
      if (hasOwnerField) {
        ownerBearingCollectionCount += 1;
        assert.equal(permitted.has(collection), true);
      }
    }
    assert.equal(ownerBearingCollectionCount, 3);
    assert.equal(recordsInCollection(harness.database, COLLECTIONS.rateLimits).length, 1);
  });

  test('billing source has no logging or AI entitlement writes', async () => {
    const sourceFiles = [
      'src/constants.ts',
      'src/contracts.ts',
      'src/crypto.ts',
      'src/firebase.ts',
      'src/firestore_store.ts',
      'src/in_memory_store.ts',
      'src/play_adapter.ts',
      'src/store.ts',
      'src/verifier.ts',
    ];
    const sources = await Promise.all(
      sourceFiles.map((file) =>
        readFile(resolve(repositoryRoot, 'backend/play_billing', file), 'utf8'),
      ),
    );
    const combined = sources.join('\n');
    assert.equal(/\bconsole\./.test(combined), false);
    assert.equal(/\blogger\./.test(combined), false);
    assert.equal(combined.includes('brokerDurableEntitlements'), false);
    assert.equal(combined.includes("getFirestore(app, BILLING_DATABASE_ID)"), true);
  });

  test('callables consume App Check and enforce the fixed runtime envelope', async () => {
    const source = await readFile(
      resolve(repositoryRoot, 'backend/play_billing/src/firebase.ts'),
      'utf8',
    );
    assert.equal(source.includes('enforceAppCheck: true'), true);
    assert.equal(source.includes('consumeAppCheckToken: true'), true);
    assert.equal(source.includes("region: 'us-central1'"), true);
    assert.equal(source.includes('timeoutSeconds: 60'), true);
    assert.equal(source.includes('serviceAccount: BILLING_VERIFIER_SERVICE_ACCOUNT'), true);
    assert.equal(
      BILLING_VERIFIER_SERVICE_ACCOUNT,
      'archivale-play-billing-verifier@my-art-collections.iam.gserviceaccount.com',
    );
    assert.equal(source.includes("verifyIdToken(authorization.slice('Bearer '.length), true)"), true);
    assert.equal(source.includes("sign_in_provider !== 'anonymous'"), true);
    assert.equal(source.includes('request.app.appId !== approvedAppId'), true);
  });

  test('rollback fixture excludes destructive and broker targets', async () => {
    const fixture = JSON.parse(
      await readFile(
        resolve(repositoryRoot, 'backend/play_billing/fixtures/rollback-boundaries.json'),
        'utf8',
      ),
    ) as Record<string, unknown>;
    assert.equal(fixture.database, BILLING_DATABASE_ID);
    assert.equal(
      (fixture.forbiddenRollbackTargets as string[]).includes('delete_billing_database'),
      true,
    );
    assert.equal(
      (fixture.forbiddenRollbackTargets as string[]).includes('write_broker_entitlements'),
      true,
    );
  });
});

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
