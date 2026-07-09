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
  onProviderDeadline?: (providerDeadlineAtMs: number | undefined) => void;
}): ConfiguredBrokerDependenciesResult {
  const provider = options.provider ?? new ResultProvider();
  const counters = options.counters ?? { config: 0, construction: 0, authorization: 0 };
  return {
    kind: 'ready',
    durableProtection: true,
    ownerUidAllowlist: new Set(['owner-uid']),
    protection: options.protection,
    createDependencies: (providerDeadlineAtMs) => {
      options.onProviderDeadline?.(providerDeadlineAtMs);
      return createFakeBrokerDependencies({
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
      });
    },
  };
}

test('Firebase verifier uses the SDK response.token claims after revoked Auth verification', async () => {
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
          token: {
            aud: ['123456789', 'my-art-collections'],
            iss: 'https://firebaseappcheck.googleapis.com/123456789',
            sub: 'owner-test-app',
            app_id: 'owner-test-app',
          },
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
      token: {
        aud: ['123456789', 'my-art-collections'],
        iss: 'https://firebaseappcheck.googleapis.com/123456789',
        sub: 'owner-test-app',
        app_id: 'owner-test-app',
      },
      alreadyConsumed: true,
    },
    {
      appId: 'owner-test-app',
      token: {
        aud: ['999999999', 'wrong-project'],
        iss: 'https://firebaseappcheck.googleapis.com/999999999',
        sub: 'owner-test-app',
        app_id: 'owner-test-app',
      },
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
    breakerOpen: false,
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

test('Firestore malformed and request-ledger orphan records are unsafe rather than absent', async () => {
  const current = request();
  {
    const db = new MemoryFirestore();
    const store = new FirestoreDurableBrokerStore(db);
    db.seed(store.requestRef(lifecycleInput().quota_subject, current.request_id).path, {
      payload_hash: current.payload_hash,
      state: 'completed',
    });
    assert.equal(
      (await store.createRequestLifecycle().acquire(lifecycleInput())).kind,
      'unsafe_record',
    );
  }
  {
    const db = validControlFirestore();
    const store = new FirestoreDurableBrokerStore(db);
    db.seed(store.ledgerRef(lifecycleInput().quota_subject, current.request_id).path, {
      record_version: 'broker-credit-ledger-v1',
      quota_subject: lifecycleInput().quota_subject,
      request_id: current.request_id,
      state: 'reserved',
      credit_cost: 1,
    });
    assert.equal(
      (await store.createRequestLifecycle().acquire(lifecycleInput())).kind,
      'unsafe_record',
    );
  }
  {
    const db = validControlFirestore();
    const store = new FirestoreDurableBrokerStore(db);
    const lifecycle = store.createRequestLifecycle();
    assert.equal((await lifecycle.acquire(lifecycleInput())).kind, 'reserved');
    db.documents.delete(store.ledgerRef(lifecycleInput().quota_subject, current.request_id).path);
    assert.equal((await lifecycle.acquire(lifecycleInput())).kind, 'unsafe_record');
  }
});

test('Firestore terminal settlement is atomic and idempotent', async () => {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', {
    record_version: 'broker-control-v1',
    breakerOpen: false,
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
  await lifecycle.markDispatchStarted(acquired.record, FIXED_NOW);
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

test('HTTP handler captures the provider deadline at function entry', async () => {
  let capturedDeadline: number | undefined;
  const protection = fakeProtection();
  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    nowMilliseconds: () => 1_000,
    dependenciesFactory: () => readyFactory({
      protection,
      onProviderDeadline: (value) => {
        capturedDeadline = value;
      },
    }),
  });
  const response = createHttpResponse();
  await handler(createHttpRequest({ data: request() }), response.responder);
  assert.equal(response.statusCode, 200);
  assert.equal(capturedDeadline, 56_000);
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

test('owner allowlist and consent reject before durable entitlement or breaker reads', async () => {
  const cases = [
    {
      name: 'forbidden uid',
      store: new FakeDurableBrokerStore(),
      tokenMap: new Map([
        ['owner-auth-token|owner-app-check-token', { uid: 'not-allowed', appId: 'owner-test-app' }],
      ]),
      body: request(),
      expected: 'forbidden',
    },
    {
      name: 'missing consent',
      store: new FakeDurableBrokerStore(),
      body: request({ consent_status: 'missing' }),
      expected: 'consent_required',
    },
    {
      name: 'stale consent',
      store: new FakeDurableBrokerStore(),
      body: request({ consent_copy_version: 'research-consent-v0' }),
      expected: 'consent_stale',
    },
  ];
  for (const current of cases) {
    const protection = fakeProtection(current.store, current.tokenMap);
    const handler = createResearchBrokerHttpHandler({
      env: durableEnv(),
      dependenciesFactory: () => readyFactory({ protection }),
    });
    const response = createHttpResponse();
    await handler(createHttpRequest({ data: current.body }), response.responder);
    assert.equal((response.json.error as Record<string, unknown>).code, current.expected, current.name);
    assert.equal(current.store.accessReadCount, 0, current.name);
  }
});

test('malformed request IDs are never reflected into broker-error-v1', async () => {
  const store = new FakeDurableBrokerStore();
  const protection = fakeProtection(store);
  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => readyFactory({ protection }),
  });
  const response = createHttpResponse();
  await handler(createHttpRequest({
    data: { ...request(), request_id: 'private collector notes must not echo' },
  }), response.responder);
  assert.equal(response.statusCode, 400);
  assert.equal(response.json.request_id, undefined);
  assert.equal(response.body.includes('private collector notes'), false);
  assert.equal(store.accessReadCount, 0);
});

test('same-version malformed credit controls and aggregates fail closed', async () => {
  const cases: Array<{
    name: string;
    control?: Record<string, unknown>;
    subject?: Record<string, unknown>;
    global?: Record<string, unknown>;
  }> = [
    {
      name: 'string breaker state',
      control: { breakerOpen: 'false' },
    },
    {
      name: 'string subject cap',
      control: { perSubjectCreditCap: '3' },
    },
    {
      name: 'string broker cap',
      control: { brokerCreditCap: '100' },
    },
    {
      name: 'string one-in-flight policy',
      control: { oneInFlightPerSubject: 'true' },
    },
    {
      name: 'unknown control field',
      control: { unexpected: false },
    },
    {
      name: 'string subject exposure',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: '0',
        reserved_count: 0,
      },
      global: { record_version: 'broker-credit-global-v1', exposed_credits: 0 },
    },
    {
      name: 'string subject reservation count',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: 0,
        reserved_count: '0',
      },
      global: { record_version: 'broker-credit-global-v1', exposed_credits: 0 },
    },
    {
      name: 'unknown subject aggregate field',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: 0,
        reserved_count: 0,
        unexpected: 0,
      },
      global: { record_version: 'broker-credit-global-v1', exposed_credits: 0 },
    },
    {
      name: 'string global exposure',
      global: { record_version: 'broker-credit-global-v1', exposed_credits: '0' },
    },
    {
      name: 'unknown global aggregate field',
      global: {
        record_version: 'broker-credit-global-v1',
        exposed_credits: 0,
        unexpected: 0,
      },
    },
    {
      name: 'reserved exceeds exposure',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: 0,
        reserved_count: 1,
      },
      global: { record_version: 'broker-credit-global-v1', exposed_credits: 0 },
    },
    {
      name: 'global exposure below subject exposure',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: 2,
        reserved_count: 0,
      },
      global: { record_version: 'broker-credit-global-v1', exposed_credits: 1 },
    },
    {
      name: 'subject aggregate orphaned from global aggregate',
      subject: {
        record_version: 'broker-credit-subject-v1',
        exposed_credits: 0,
        reserved_count: 0,
      },
    },
  ];
  for (const current of cases) {
    const db = new MemoryFirestore();
    const store = new FirestoreDurableBrokerStore(db);
    db.seed('brokerDurableControl/live', {
      record_version: 'broker-control-v1',
      breakerOpen: false,
      perSubjectCreditCap: 3,
      brokerCreditCap: 100,
      oneInFlightPerSubject: true,
      ...current.control,
    });
    if (current.subject !== undefined) {
      db.seed(store.subjectRef('quota_subject_v1_aaaaaaaaaaaaaaaa').path, current.subject);
    }
    if (current.global !== undefined) {
      db.seed(store.globalUsageRef().path, current.global);
    }
    const result = await store.createRequestLifecycle().acquire(lifecycleInput());
    assert.equal(result.kind, 'unsafe_record', current.name);
    assert.equal(db.find('brokerDurableIdempotency/').length, 0, current.name);
    assert.equal(db.find('brokerDurableLedger/').length, 0, current.name);
  }
});

test('terminal replay requires matching request, outcome, settlement, and ledger records', async () => {
  const mutations: Array<{
    name: string;
    mutate: (db: MemoryFirestore, store: FirestoreDurableBrokerStore) => void;
  }> = [
    {
      name: 'missing ledger',
      mutate: (db, store) => db.documents.delete(
        store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id).path,
      ),
    },
    {
      name: 'mismatched ledger request id',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, request_id: '22222222-2222-4222-8222-222222222222' });
      },
    },
    {
      name: 'ledger-only orphan',
      mutate: (db, store) => db.documents.delete(
        store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id).path,
      ),
    },
    {
      name: 'mismatched ledger quota subject',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, quota_subject: 'quota_subject_v1_bbbbbbbbbbbbbbbb' });
      },
    },
    {
      name: 'malformed ledger state',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, state: 'settled' });
      },
    },
    {
      name: 'malformed ledger credit cost',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, credit_cost: 2 });
      },
    },
    {
      name: 'reserved ledger has an unexpected refund reason',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, reason: 'provider_timeout' });
      },
    },
    {
      name: 'ledger has an unknown field',
      mutate: (db, store) => {
        const ref = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, unexpected: true });
      },
    },
    {
      name: 'mismatched stored quota subject',
      mutate: (db, store) => {
        const ref = store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(ref.path, { ...db.read(ref.path)!, quota_subject: 'quota_subject_v1_bbbbbbbbbbbbbbbb' });
      },
    },
    {
      name: 'mismatched terminal outcome request id',
      mutate: (db, store) => {
        const ref = store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        const record = db.read(ref.path)!;
        db.seed(ref.path, {
          ...record,
          terminal_outcome: {
            kind: 'error',
            failure: {
              request_id: '22222222-2222-4222-8222-222222222222',
              condition: 'provider_timeout',
            },
          },
        });
      },
    },
    {
      name: 'finalized failure disguised as pending refund',
      mutate: (db, store) => {
        const ref = store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        const record = db.read(ref.path)!;
        db.seed(ref.path, {
          ...record,
          settlement_state: 'pending_refund',
          terminal_outcome: {
            kind: 'error',
            failure: { request_id: request().request_id, condition: 'provider_failure' },
          },
        });
      },
    },
    {
      name: 'refunded ledger reason does not match terminal failure',
      mutate: (db, store) => {
        const requestRef = store.requestRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        const ledgerRef = store.ledgerRef('quota_subject_v1_aaaaaaaaaaaaaaaa', request().request_id);
        db.seed(requestRef.path, { ...db.read(requestRef.path)!, settlement_state: 'refunded' });
        db.seed(ledgerRef.path, {
          ...db.read(ledgerRef.path)!,
          state: 'refunded',
          reason: 'provider_rate_limited',
        });
      },
    },
  ];
  for (const current of mutations) {
    const { db, store } = await terminalTimeoutStore();
    current.mutate(db, store);
    const result = await store.createRequestLifecycle().acquire(lifecycleInput());
    assert.equal(result.kind, 'unsafe_record', current.name);
  }
});

test('refund rejects malformed or orphan credit aggregates without partial settlement', async () => {
  const mutations: Array<{
    name: string;
    mutate: (db: MemoryFirestore, store: FirestoreDurableBrokerStore) => void;
  }> = [
    {
      name: 'missing subject aggregate',
      mutate: (db, store) => db.documents.delete(store.subjectRef(lifecycleInput().quota_subject).path),
    },
    {
      name: 'missing global aggregate',
      mutate: (db, store) => db.documents.delete(store.globalUsageRef().path),
    },
    {
      name: 'malformed subject exposure',
      mutate: (db, store) => {
        const ref = store.subjectRef(lifecycleInput().quota_subject);
        db.seed(ref.path, { ...db.read(ref.path)!, exposed_credits: '1' });
      },
    },
    {
      name: 'malformed subject reservation count',
      mutate: (db, store) => {
        const ref = store.subjectRef(lifecycleInput().quota_subject);
        db.seed(ref.path, { ...db.read(ref.path)!, reserved_count: '1' });
      },
    },
    {
      name: 'malformed global exposure',
      mutate: (db, store) => {
        const ref = store.globalUsageRef();
        db.seed(ref.path, { ...db.read(ref.path)!, exposed_credits: '1' });
      },
    },
    {
      name: 'subject reservation aggregate is empty',
      mutate: (db, store) => {
        const ref = store.subjectRef(lifecycleInput().quota_subject);
        db.seed(ref.path, { ...db.read(ref.path)!, reserved_count: 0 });
      },
    },
    {
      name: 'global exposure is below subject exposure',
      mutate: (db, store) => {
        const ref = store.globalUsageRef();
        db.seed(ref.path, { ...db.read(ref.path)!, exposed_credits: 0 });
      },
    },
  ];
  for (const current of mutations) {
    const { db, store } = await terminalTimeoutStore();
    const lifecycle = store.createRequestLifecycle();
    const replay = await lifecycle.acquire(lifecycleInput());
    assert.equal(replay.kind, 'replay', current.name);
    if (replay.kind !== 'replay') {
      continue;
    }
    current.mutate(db, store);
    await assert.rejects(lifecycle.settle(replay.record), /unsafe_credit_aggregate/, current.name);
    assert.equal(
      db.read(store.requestRef(lifecycleInput().quota_subject, request().request_id).path)?.settlement_state,
      'pending_refund',
      current.name,
    );
    assert.equal(
      db.read(store.ledgerRef(lifecycleInput().quota_subject, request().request_id).path)?.state,
      'reserved',
      current.name,
    );
  }
});

test('Firestore dispatch CAS prevents exact-boundary and cross-instance double dispatch', async () => {
  const db = validControlFirestore();
  const store = new FirestoreDurableBrokerStore(db);
  const lifecycleA = store.createRequestLifecycle();
  const lifecycleB = store.createRequestLifecycle();
  const acquired = await lifecycleA.acquire(lifecycleInput());
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    return;
  }
  const boundary = new Date(FIXED_NOW.getTime() + 60_000);
  const [expiry, dispatch] = await Promise.all([
    lifecycleB.acquire(lifecycleInput(boundary)),
    lifecycleA.markDispatchStarted(acquired.record, boundary),
  ]);
  assert.equal(expiry.kind, 'replay');
  assert.equal(dispatch.kind, 'lease_expired');

  const secondDb = validControlFirestore();
  const secondStore = new FirestoreDurableBrokerStore(secondDb);
  const firstInstance = secondStore.createRequestLifecycle();
  const secondInstance = secondStore.createRequestLifecycle();
  const secondAcquired = await firstInstance.acquire(lifecycleInput());
  assert.equal(secondAcquired.kind, 'reserved');
  if (secondAcquired.kind !== 'reserved') {
    return;
  }
  const attempts = await Promise.allSettled([
    firstInstance.markDispatchStarted(secondAcquired.record, FIXED_NOW),
    secondInstance.markDispatchStarted({ ...secondAcquired.record }, FIXED_NOW),
  ]);
  assert.equal(attempts.filter((entry) => entry.status === 'fulfilled').length, 1);
  assert.equal(attempts.filter((entry) => entry.status === 'rejected').length, 1);
});

function lifecycleInput(now: Date = FIXED_NOW) {
  const current = request();
  return {
    quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    request_id: current.request_id,
    payload_hash: current.payload_hash,
    credit_cost: 1 as const,
    now,
  };
}

function validControlFirestore(): MemoryFirestore {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', {
    record_version: 'broker-control-v1',
    breakerOpen: false,
    perSubjectCreditCap: 3,
    brokerCreditCap: 100,
    oneInFlightPerSubject: true,
  });
  return db;
}

async function terminalTimeoutStore(): Promise<{
  db: MemoryFirestore;
  store: FirestoreDurableBrokerStore;
}> {
  const db = validControlFirestore();
  const store = new FirestoreDurableBrokerStore(db);
  const lifecycle = store.createRequestLifecycle();
  const acquired = await lifecycle.acquire(lifecycleInput());
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    throw new Error('fixture reservation failed');
  }
  await lifecycle.markDispatchStarted(acquired.record, FIXED_NOW);
  await lifecycle.persistTerminal(acquired.record, {
    kind: 'error',
    failure: { request_id: request().request_id, condition: 'provider_timeout' },
  }, 'refund');
  return { db, store };
}
