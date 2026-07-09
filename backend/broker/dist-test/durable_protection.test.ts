import assert from 'node:assert/strict';
import test from 'node:test';

import { createFakeBrokerDependencies } from '../src/broker.js';
import type { ProviderClient } from '../src/contracts.js';
import {
  ConfiguredDurableBrokerProtection,
  FakeBrokerTokenVerifier,
  FakeDurableBrokerStore,
  FirebaseAdminBrokerTokenVerifier,
  FirestoreDurableBrokerStore,
  deriveQuotaSubject,
  type DurableBrokerProtection,
} from '../src/durable_protection.js';
import {
  createResearchBrokerHttpHandler,
  type ConfiguredBrokerDependenciesResult,
} from '../src/live_broker.js';
import {
  FIXED_NOW,
  MemoryFirestore,
  ResultProvider,
  createHttpRequest,
  createHttpResponse,
  durableEnv,
  request,
} from './test_helpers.js';

const protectionConfig = {
  projectId: 'my-art-collections',
  projectNumber: '123456789',
  allowedAppIds: new Set(['owner-test-app']),
  quotaHmacSecret: 'test-only-quota-hmac-secret',
};

function fakeProtection(
  store = new FakeDurableBrokerStore(),
  tokenMap?: ReadonlyMap<string, { uid: string; appId: string }>,
): DurableBrokerProtection {
  return new ConfiguredDurableBrokerProtection(
    new FakeBrokerTokenVerifier(protectionConfig, tokenMap),
    store,
    store.lifecycle,
    protectionConfig,
  );
}

function readyFactory(options: {
  protection: DurableBrokerProtection;
  provider?: ProviderClient;
  counters?: { config: number; construction: number; authorization: number };
}): ConfiguredBrokerDependenciesResult {
  const provider = options.provider ?? new ResultProvider();
  const counters = options.counters ?? { config: 0, construction: 0, authorization: 0 };
  return {
    kind: 'ready',
    durableProtection: true,
    ownerUidAllowlist: new Set(['owner-uid']),
    protection: options.protection,
    createDependencies: () => createFakeBrokerDependencies({
      requestLifecycle: options.protection.createRequestLifecycle(),
      providerProvisioner: {
        configure: () => {
          counters.config += 1;
          return {};
        },
        construct: () => {
          counters.construction += 1;
          return provider;
        },
      },
      authorizeProvider: () => {
        counters.authorization += 1;
      },
      now: () => FIXED_NOW,
      testProvider: provider,
    }),
  };
}

test('Firebase verifier checks revoked Auth and project before consuming App Check', async () => {
  const order: string[] = [];
  const verifier = new FirebaseAdminBrokerTokenVerifier({
    auth: {
      async verifyIdToken(_token, checkRevoked) {
        order.push('auth');
        assert.equal(checkRevoked, true);
        return {
          uid: 'owner-uid',
          aud: 'my-art-collections',
          iss: 'https://securetoken.google.com/my-art-collections',
          firebase: { sign_in_provider: 'anonymous' },
        };
      },
    },
    appCheck: {
      async verifyToken(_token, options) {
        order.push('app_check_consume');
        assert.deepEqual(options, { consume: true });
        return {
          appId: 'owner-test-app',
          aud: ['123456789', 'my-art-collections'],
          iss: 'https://firebaseappcheck.googleapis.com/123456789',
          alreadyConsumed: false,
        };
      },
    },
    config: protectionConfig,
  });
  const result = await verifier.verify({
    authorizationHeader: 'Bearer owner-auth-token',
    appCheckToken: 'limited-use-token',
  });
  assert.equal(result.ok, true);
  assert.deepEqual(order, ['auth', 'app_check_consume']);
});

test('wrong-project Auth rejects before App Check consumption', async () => {
  let appCheckCalls = 0;
  const verifier = new FirebaseAdminBrokerTokenVerifier({
    auth: {
      async verifyIdToken() {
        return {
          uid: 'owner-uid',
          aud: 'wrong-project',
          iss: 'https://securetoken.google.com/wrong-project',
          firebase: { sign_in_provider: 'anonymous' },
        };
      },
    },
    appCheck: {
      async verifyToken() {
        appCheckCalls += 1;
        throw new Error('must not be reached');
      },
    },
    config: protectionConfig,
  });
  assert.deepEqual(await verifier.verify({
    authorizationHeader: 'Bearer owner-auth-token',
    appCheckToken: 'limited-use-token',
  }), { ok: false, code: 'wrong_project_auth' });
  assert.equal(appCheckCalls, 0);
});

test('consumed and wrong-project App Check tokens fail closed', async () => {
  for (const body of [
    {
      appId: 'owner-test-app',
      aud: ['123456789', 'my-art-collections'],
      iss: 'https://firebaseappcheck.googleapis.com/123456789',
      alreadyConsumed: true,
    },
    {
      appId: 'owner-test-app',
      aud: ['999999999', 'wrong-project'],
      iss: 'https://firebaseappcheck.googleapis.com/999999999',
      alreadyConsumed: false,
    },
  ]) {
    const verifier = new FirebaseAdminBrokerTokenVerifier({
      auth: {
        async verifyIdToken() {
          return {
            uid: 'owner-uid',
            aud: 'my-art-collections',
            iss: 'https://securetoken.google.com/my-art-collections',
            firebase: { sign_in_provider: 'anonymous' },
          };
        },
      },
      appCheck: { async verifyToken() { return body; } },
      config: protectionConfig,
    });
    const result = await verifier.verify({
      authorizationHeader: 'Bearer owner-auth-token',
      appCheckToken: 'limited-use-token',
    });
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(
        result.code,
        body.alreadyConsumed ? 'app_check_replayed' : 'wrong_project_app_check',
      );
    }
  }
});

test('fake limited-use App Check tokens reject replay', async () => {
  const verifier = new FakeBrokerTokenVerifier(protectionConfig);
  const input = {
    authorizationHeader: 'Bearer owner-auth-token',
    appCheckToken: 'owner-app-check-token',
  };
  assert.equal((await verifier.verify(input)).ok, true);
  assert.deepEqual(await verifier.verify(input), { ok: false, code: 'app_check_replayed' });
});

test('Firestore acquire transaction creates one request and one credit under concurrency', async () => {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', {
    record_version: 'broker-control-v1',
    perSubjectCreditCap: 3,
    brokerCreditCap: 100,
    oneInFlightPerSubject: true,
  });
  const store = new FirestoreDurableBrokerStore(db);
  const lifecycle = store.createRequestLifecycle();
  const current = request();
  const input = {
    quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    request_id: current.request_id,
    payload_hash: current.payload_hash,
    credit_cost: 1 as const,
    now: FIXED_NOW,
  };
  const [first, second] = await Promise.all([lifecycle.acquire(input), lifecycle.acquire(input)]);
  assert.deepEqual([first.kind, second.kind].sort(), ['in_flight', 'reserved']);
  assert.equal(db.find('brokerDurableIdempotency/').length, 1);
  assert.equal(db.find('brokerDurableLedger/').length, 1);
  assert.deepEqual(db.read('brokerDurableControl/globalUsage'), {
    record_version: 'broker-credit-global-v1',
    exposed_credits: 1,
  });
});

test('Firestore malformed and orphan records are unsafe rather than absent', async () => {
  const db = new MemoryFirestore();
  const store = new FirestoreDurableBrokerStore(db);
  const lifecycle = store.createRequestLifecycle();
  const current = request();
  const requestRef = store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', current.request_id);
  db.seed(requestRef.path, { payload_hash: current.payload_hash, state: 'completed' });
  const result = await lifecycle.acquire({
    quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    request_id: current.request_id,
    payload_hash: current.payload_hash,
    credit_cost: 1,
    now: FIXED_NOW,
  });
  assert.equal(result.kind, 'unsafe_record');
});

test('Firestore terminal settlement is atomic and idempotent', async () => {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', {
    record_version: 'broker-control-v1',
    perSubjectCreditCap: 3,
    brokerCreditCap: 100,
    oneInFlightPerSubject: true,
  });
  const store = new FirestoreDurableBrokerStore(db);
  const lifecycle = store.createRequestLifecycle();
  const current = request();
  const acquired = await lifecycle.acquire({
    quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    request_id: current.request_id,
    payload_hash: current.payload_hash,
    credit_cost: 1,
    now: FIXED_NOW,
  });
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    return;
  }
  await lifecycle.markDispatchStarted(acquired.record);
  await lifecycle.persistTerminal(acquired.record, {
    kind: 'error',
    failure: { request_id: current.request_id, condition: 'provider_timeout' },
  }, 'refund');
  await lifecycle.settle(acquired.record);
  await lifecycle.settle(acquired.record);

  assert.deepEqual(db.find('brokerDurableLedger/').map((entry) => entry.state), ['refunded']);
  assert.deepEqual(db.read('brokerDurableControl/globalUsage'), {
    record_version: 'broker-credit-global-v1',
    exposed_credits: 0,
  });
});

test('unversioned control records fail closed', async () => {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', { breakerOpen: false });
  const store = new FirestoreDurableBrokerStore(db);
  await assert.rejects(
    store.readAccess({ uid: 'owner-uid', appId: 'owner-test-app', quotaSubject: 'quota' }),
    /unsafe_control_record/,
  );
});

test('HTTP protocol and kill-switch errors always use broker-error-v1', async () => {
  const env = durableEnv({ BROKER_HTTP_ENABLED: 'false' });
  const handler = createResearchBrokerHttpHandler({ env });
  const response = createHttpResponse();
  await handler(createHttpRequest({ data: request() }), response.responder);
  assert.equal(response.statusCode, 503);
  assert.equal(response.json.error_contract_version, 'broker-error-v1');
  assert.equal((response.json.error as Record<string, unknown>).code, 'temporarily_unavailable');
});

test('live prechecks cause zero provider setup or fetch and split entitlement from credits', async () => {
  const cases = [
    { name: 'not entitled', store: new FakeDurableBrokerStore({ entitledUids: [] }), expected: 'not_entitled' },
    { name: 'hash mismatch', store: new FakeDurableBrokerStore(), body: request({ payload_hash: 'f'.repeat(64) }), expected: 'payload_invalid' },
    { name: 'credits exhausted', store: new FakeDurableBrokerStore({ perSubjectCreditCap: 0 }), expected: 'credits_exhausted' },
  ];
  for (const current of cases) {
    const counters = { config: 0, construction: 0, authorization: 0 };
    const provider = new ResultProvider();
    const protection = fakeProtection(current.store);
    const handler = createResearchBrokerHttpHandler({
      env: durableEnv(),
      dependenciesFactory: () => readyFactory({ protection, provider, counters }),
    });
    const response = createHttpResponse();
    await handler(createHttpRequest({ data: current.body ?? request() }), response.responder);
    assert.equal((response.json.error as Record<string, unknown>).code, current.expected, current.name);
    assert.deepEqual(counters, { config: 0, construction: 0, authorization: 0 }, current.name);
    assert.equal(provider.callCount, 0, current.name);
  }
});

test('fresh App Check token can replay completed result without another credit or dispatch', async () => {
  const tokenMap = new Map([
    ['owner-auth-token|app-token-1', { uid: 'owner-uid', appId: 'owner-test-app' }],
    ['owner-auth-token|app-token-2', { uid: 'owner-uid', appId: 'owner-test-app' }],
  ]);
  const store = new FakeDurableBrokerStore({ perSubjectCreditCap: 1 });
  const protection = fakeProtection(store, tokenMap);
  const provider = new ResultProvider();
  const counters = { config: 0, construction: 0, authorization: 0 };
  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => readyFactory({ protection, provider, counters }),
  });

  const first = createHttpResponse();
  await handler(createHttpRequest({ data: request() }, { 'x-firebase-appcheck': 'app-token-1' }), first.responder);
  const replay = createHttpResponse();
  await handler(createHttpRequest({ data: request() }, { 'x-firebase-appcheck': 'app-token-2' }), replay.responder);
  assert.equal(first.statusCode, 200);
  assert.equal(replay.statusCode, 200);
  assert.equal(replay.json.replayed, true);
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
});

test('quota subject is one-way derived from the single approved project identity', () => {
  const value = deriveQuotaSubject({
    uid: 'owner-uid',
    appId: 'owner-test-app',
    projectId: 'my-art-collections',
    secret: 'test-only-secret',
  });
  assert.match(value, /^quota_subject_v1_[a-f0-9]{64}$/);
  assert.equal(value.includes('owner-uid'), false);
});
