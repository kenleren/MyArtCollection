import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { getFirestore } from 'firebase-admin/firestore';
import { deleteApp, initializeApp } from 'firebase-admin/app';

import {
  artResearchBroker,
  createFirebaseResearchBrokerDependencies,
} from '../src/index.js';
import type { FirebaseAdminAppCheckLike } from '../src/durable_protection.js';
import { FirestoreDurableBrokerStore } from '../src/durable_protection.js';
import { request } from './test_helpers.js';

const projectId = 'demo-art-research-broker';
const projectNumber = '123456789';
const appId = '1:123456789:android:demoartresearchbroker';
async function main(): Promise<void> {
  requireEmulator('FIREBASE_AUTH_EMULATOR_HOST');
  requireEmulator('FIRESTORE_EMULATOR_HOST');

  const app = initializeApp({ projectId }, 'issue-188-emulator-harness');
  try {
    const identityToken = await createAnonymousEmulatorToken();
    const appCheck = new EmulatorAppCheckVerifier();
    const dependencies = createFirebaseResearchBrokerDependencies(emulatorEnv(identityToken.uid), {
      app,
      appCheck,
    });
    assert.equal(dependencies.kind, 'ready');
    if (dependencies.kind !== 'ready') {
      return;
    }

    const identity = await dependencies.protection.verifyIdentity({
      authorizationHeader: `Bearer ${identityToken.token}`,
      appCheckToken: 'emulator-app-check-token',
    });
    assert.equal(identity.ok, true, JSON.stringify(identity));
    assert.equal(appCheck.calls, 1);

    const marker = getFirestore(app).collection('issue188Harness').doc('marker');
    await marker.set({ expected: true });
    assert.deepEqual((await marker.get()).data(), { expected: true });
    await assertDispatchBudgetIsAtomic(getFirestore(app));

    // The deployed export is a fixed onRequest handler, not the adapter-taking
    // factory used only by this local harness.
    assert.equal(typeof artResearchBroker, 'function');
    assert.equal(
      Object.hasOwn(artResearchBroker, 'createWithAdapters'),
      false,
    );
    await assertProductionFunctionStaysNonInjectable();
  } finally {
    await deleteApp(app);
  }
}

async function assertDispatchBudgetIsAtomic(firestore: ReturnType<typeof getFirestore>): Promise<void> {
  const store = new FirestoreDurableBrokerStore(firestore, {
    collectionPrefix: 'internalResearchBudgetHarness', requireProviderBudget: true,
  });
  const now = new Date();
  await store.controlRef().set({ record_version: 'broker-control-v1', breakerOpen: false,
    perSubjectCreditCap: 3, brokerCreditCap: 6, oneInFlightPerSubject: true });
  await store.providerBudgetRef().set({ record_version: 'broker-provider-budget-v1',
    dispatchLimit: 1, dispatchCount: 0, expiresAt: new Date(now.getTime() + 60_000).toISOString() });
  const lifecycle = store.createRequestLifecycle();
  const reservations = await Promise.all(['a', 'b'].map(subject => lifecycle.acquire({
    quota_subject: `quota_subject_v1_${subject.repeat(64)}`, request_id: randomUUID(),
    payload_hash: request().payload_hash, credit_cost: 1, now,
  })));
  assert.ok(reservations.every(result => result.kind === 'reserved'));
  const starts = await Promise.all(reservations.map(result => {
    if (result.kind !== 'reserved') throw new Error('Synthetic reservation failed');
    return lifecycle.markDispatchStarted(result.record, new Date());
  }));
  assert.deepEqual(starts.map(result => result.kind).sort(), ['budget_denied', 'started']);
  assert.equal((await store.providerBudgetRef().get()).data()?.dispatchCount, 1);
  for (const reservation of reservations) {
    if (reservation.kind !== 'reserved') continue;
    const replay = await lifecycle.acquire({ quota_subject: reservation.record.quota_subject,
      request_id: reservation.record.request_id, payload_hash: reservation.record.payload_hash,
      credit_cost: 1, now: new Date() });
    assert.ok(replay.kind === 'in_flight' || replay.kind === 'replay');
  }
  assert.equal((await store.providerBudgetRef().get()).data()?.dispatchCount, 1);
  console.log('Synthetic Firestore dispatch budget: concurrent reservation and replay passed.');
}

function emulatorEnv(ownerUid: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    BROKER_HTTP_ENABLED: 'true',
    BROKER_PROVIDER_MODE: 'openai',
    BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
    BROKER_OWNER_UID_ALLOWLIST: ownerUid,
    BROKER_FIREBASE_PROJECT_ID: projectId,
    BROKER_FIREBASE_PROJECT_NUMBER: projectNumber,
    BROKER_APP_ID_ALLOWLIST: appId,
    BROKER_DURABLE_STORE_CONFIGURED: 'true',
    BROKER_QUOTA_HMAC_SECRET: 'emulator-only-not-a-secret',
  };
}

class EmulatorAppCheckVerifier implements FirebaseAdminAppCheckLike {
  calls = 0;

  async verifyToken(token: string, options: { consume: boolean }) {
    assert.equal(token, 'emulator-app-check-token');
    assert.equal(options.consume, true);
    this.calls += 1;
    return {
      alreadyConsumed: false,
      appId,
      token: {
        aud: [projectId, projectNumber],
        iss: `https://firebaseappcheck.googleapis.com/${projectNumber}`,
        sub: appId,
        app_id: appId,
      },
    };
  }
}

async function createAnonymousEmulatorToken(): Promise<{ token: string; uid: string }> {
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST!;
  const response = await fetch(
    `http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator-only`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const rawBody = await response.text();
  assert.equal(response.ok, true, rawBody);
  const body = JSON.parse(rawBody) as { idToken?: unknown; localId?: unknown };
  if (typeof body.idToken !== 'string' || typeof body.localId !== 'string') {
    assert.fail('Auth emulator did not return an ID token.');
  }
  return { token: body.idToken, uid: body.localId };
}

async function assertProductionFunctionStaysNonInjectable(): Promise<void> {
  const functionsHost = process.env.FUNCTIONS_EMULATOR_HOST ?? '127.0.0.1:5001';
  const functionIds = ['broker-artResearchBroker', 'artResearchBroker'];
  for (const functionId of functionIds) {
    const response = await fetch(
      `http://${functionsHost}/${projectId}/us-central1/${functionId}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ data: {} }),
      },
    );
    if (response.status === 404) {
      continue;
    }
    assert.equal(response.status, 503);
    const body = await response.json() as Record<string, unknown>;
    assert.equal(body.error_contract_version, 'broker-error-v1');
    assert.deepEqual(body.error, {
      code: 'temporarily_unavailable',
      message: 'Research is temporarily unavailable.',
      retryable: true,
      retry_after_seconds: 30,
    });
    return;
  }
  assert.fail('Functions emulator did not expose artResearchBroker.');
}

function requireEmulator(name: string): void {
  assert.ok(process.env[name], `${name} must be set by firebase emulators:exec.`);
}

await main();
