import assert from 'node:assert/strict';
import test from 'node:test';

import { handleResearchRequest, createFakeBrokerDependencies } from '../src/broker.js';
import { artResearchBroker, createFirebaseResearchBrokerDependencies } from '../src/firebase.js';
import { ConfiguredDurableBrokerProtection, FakeBrokerTokenVerifier, FirestoreDurableBrokerStore } from '../src/durable_protection.js';
import { readResearchAdmissionPolicy } from '../src/live_admission.js';
import { createConfiguredResearchBrokerDependencies, createResearchBrokerHttpHandler } from '../src/live_broker.js';
import { parseProviderDispatchBudget } from '../src/provider_budget.js';
import { baseContext, FIXED_NOW, ResultProvider, request, seededFirestore, durableEnv,
  createHttpRequest, createHttpResponse } from './test_helpers.js';

const expiry = '2026-07-10T12:00:00.000Z';
const budget = { record_version: 'broker-provider-budget-v1', dispatchLimit: 2, dispatchCount: 0, expiresAt: expiry };

function fixture(limit = 2) {
  const db = seededFirestore();
  db.seed('brokerDurableControl/providerBudget', { ...budget, dispatchLimit: limit });
  const store = new FirestoreDurableBrokerStore(db, { requireProviderBudget: true, nowMilliseconds: () => FIXED_NOW.getTime() });
  const lifecycle = store.createRequestLifecycle();
  const provider = new ResultProvider({ kind: 'timeout' });
  const deps = createFakeBrokerDependencies({ requestLifecycle: lifecycle, testProvider: provider,
    providerProvisioner: { configure: () => ({}), construct: () => provider }, now: () => FIXED_NOW });
  return { db, store, lifecycle, provider, deps };
}

test('deployed SDK manifest isolates secrets and limits the research runtime', () => {
  const endpoint = artResearchBroker.__endpoint;
  assert.equal(endpoint.platform, 'gcfv2');
  assert.equal(endpoint.minInstances, 0);
  assert.equal(endpoint.maxInstances, 1);
  assert.equal(endpoint.concurrency, 1);
  assert.equal(endpoint.serviceAccountEmail, 'archivale-research-broker@my-art-collections.iam.gserviceaccount.com');
  assert.deepEqual(endpoint.secretEnvironmentVariables?.map(secret => secret.key).sort(),
    ['BROKER_QUOTA_HMAC_SECRET', 'OPENAI_API_KEY']);
});

test('admission remains owner-only unless an exact finite internal-test window is configured', () => {
  assert.deepEqual(readResearchAdmissionPolicy({}), { mode: 'owner_only' });
  for (const env of [
    { BROKER_ADMISSION_MODE: 'all' },
    { BROKER_ADMISSION_MODE: 'verified_internal_app' },
    { BROKER_ADMISSION_MODE: 'verified_internal_app', BROKER_INTERNAL_TEST_EXPIRES_AT: 'never' },
    { BROKER_ADMISSION_MODE: 'verified_internal_app', BROKER_INTERNAL_TEST_EXPIRES_AT: '2026-02-30T00:00:00.000Z' },
  ]) assert.equal(readResearchAdmissionPolicy(env), undefined);
  assert.equal(createConfiguredResearchBrokerDependencies(durableEnv({ BROKER_OWNER_UID_ALLOWLIST: '' })).kind, 'misconfigured');
});

test('provider budget requires an existing strict head and never admits more than thirty attempts', () => {
  assert.deepEqual(parseProviderDispatchBudget(budget), budget);
  for (const invalid of [undefined, {}, { ...budget, record_version: 'old' },
    { ...budget, dispatchCount: -1 }, { ...budget, dispatchLimit: 31 },
    { ...budget, dispatchCount: 3 }, { ...budget, extra: true },
    { ...budget, expiresAt: '2026-02-30T00:00:00.000Z' }]) {
    assert.equal(parseProviderDispatchBudget(invalid), undefined);
  }
});

test('repeated provider timeouts refund collector credits but exhaust the immutable attempt budget', async () => {
  const { db, provider, deps } = fixture();
  for (const id of ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222']) {
    const result = await handleResearchRequest(request({ request_id: id }), baseContext, deps);
    assert.equal(result.ok, false);
    assert.equal(db.read('brokerDurableControl/globalUsage')?.exposed_credits, 0);
  }
  const denied = await handleResearchRequest(request({ request_id: '33333333-3333-4333-8333-333333333333' }), baseContext, deps);
  assert.equal(denied.ok, false);
  if (!denied.ok) assert.equal(denied.failure.condition, 'credits_exhausted');
  assert.equal(provider.callCount, 2);
  assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 2);
  await handleResearchRequest(request(), baseContext, deps);
  assert.equal(provider.callCount, 2);
  assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 2);
});

test('simultaneous subjects cannot spend the last dispatch slot twice', async () => {
  const { db, lifecycle } = fixture(1);
  const inputs = ['a', 'b'].map((subject, index) => ({ quota_subject: `quota_${subject}`,
    request_id: index === 0 ? request().request_id : '22222222-2222-4222-8222-222222222222',
    payload_hash: request().payload_hash, credit_cost: 1 as const, now: FIXED_NOW }));
  const acquired = await Promise.all(inputs.map(input => lifecycle.acquire(input)));
  assert.ok(acquired.every(result => result.kind === 'reserved'));
  const starts = await Promise.all(acquired.map(result => {
    if (result.kind !== 'reserved') throw new Error('fixture');
    return lifecycle.markDispatchStarted(result.record, FIXED_NOW);
  }));
  assert.deepEqual(starts.map(result => result.kind).sort(), ['budget_denied', 'started']);
  assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 1);
});

test('breaker changes, missing heads and expiry during dispatch reject without fetching or resetting counts', async () => {
  for (const change of ['breaker', 'missing', 'expired'] as const) {
    const { db, lifecycle, provider, deps } = fixture();
    const original = lifecycle.markDispatchStarted.bind(lifecycle);
    lifecycle.markDispatchStarted = async (record, now) => {
      if (change === 'breaker') await db.doc('brokerDurableControl/live').update({ breakerOpen: true });
      if (change === 'missing') await db.doc('brokerDurableControl/providerBudget').delete();
      if (change === 'expired') await db.doc('brokerDurableControl/providerBudget').update({ expiresAt: FIXED_NOW.toISOString() });
      return original(record, now);
    };
    assert.equal((await handleResearchRequest(request(), baseContext, deps)).ok, false);
    assert.equal(provider.callCount, 0);
    assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, change === 'missing' ? undefined : 0);
    assert.equal(db.read('brokerDurableControl/globalUsage')?.exposed_credits, 0);
    const replay = await handleResearchRequest(request(), baseContext, deps);
    assert.equal(replay.ok, false);
    if (!replay.ok) assert.equal(replay.failure.replayed, true);
  }
});

test('expiry immediately after dispatch commit retains its count and makes zero provider calls', async () => {
  const { db, lifecycle, provider, deps } = fixture();
  let now = FIXED_NOW;
  const original = lifecycle.markDispatchStarted.bind(lifecycle);
  lifecycle.markDispatchStarted = async (record, timestamp) => {
    const result = await original(record, timestamp);
    now = new Date(expiry);
    return result;
  };
  deps.now = () => now;
  assert.equal((await handleResearchRequest(request(), baseContext, deps)).ok, false);
  assert.equal(provider.callCount, 0);
  assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 1);
  assert.equal(db.read('brokerDurableControl/globalUsage')?.exposed_credits, 0);
});

test('uncertain dispatch commit never fetches or redrives and retains the possible attempt charge', async () => {
  const { db, lifecycle, provider, deps } = fixture();
  const original = lifecycle.markDispatchStarted.bind(lifecycle);
  lifecycle.markDispatchStarted = async (record, now) => {
    await original(record, now);
    throw new Error('synthetic ambiguous commit acknowledgement');
  };
  await handleResearchRequest(request(), baseContext, deps);
  await handleResearchRequest(request(), baseContext, deps);
  assert.equal(provider.callCount, 0);
  assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 1);
});

test('actual Firebase factory requires a budget and can grant internal test access without billing records', async () => {
  const db = seededFirestore();
  const futureExpiry = '2035-01-01T00:00:00.000Z';
  const env = durableEnv({ BROKER_ADMISSION_MODE: 'verified_internal_app',
    BROKER_INTERNAL_TEST_EXPIRES_AT: futureExpiry, BROKER_OWNER_UID_ALLOWLIST: '' });
  const configured = createFirebaseResearchBrokerDependencies(env, {
    firestore: db,
    auth: { verifyIdToken: async () => { throw new Error('unused'); } },
    appCheck: { verifyToken: async () => { throw new Error('unused'); } },
  });
  assert.equal(configured.kind, 'ready');
  if (configured.kind !== 'ready') throw new Error('fixture');
  const identity = { auth: { authVerified: true, appCheckVerified: true, uid: 'new-test-user' },
    app: { appId: 'owner-test-app' }, quotaSubject: 'new-test-subject' };
  await assert.rejects(configured.protection.readAccess(identity), /unsafe_provider_budget/);
  db.seed('brokerDurableControl/providerBudget', { ...budget, expiresAt: futureExpiry });
  assert.deepEqual(await configured.protection.readAccess(identity), { entitled: true, breakerOpen: false });
  await db.doc('brokerDurableControl/providerBudget').update({ expiresAt: '2036-01-01T00:00:00.000Z' });
  await assert.rejects(configured.protection.readAccess(identity), /internal_test_budget_mismatch/);
});

test('expired internal mode denies at HTTP entry before identity or provider setup', async () => {
  let calls = 0;
  const configured = { kind: 'ready' as const, durableProtection: true as const,
    ownerUidAllowlist: new Set<string>(),
    admission: { mode: 'verified_internal_app' as const, expiresAt: expiry, expiresAtMs: Date.parse(expiry) },
    protection: { verifyIdentity: async () => { calls++; throw new Error('must not verify'); },
      readAccess: async () => { throw new Error('must not read'); },
      createRequestLifecycle: () => { throw new Error('must not create'); } },
    createDependencies: () => { throw new Error('must not construct'); } };
  const response = createHttpResponse();
  await createResearchBrokerHttpHandler({ env: durableEnv(), dependenciesFactory: () => configured,
    nowMilliseconds: () => Date.parse(expiry) })(createHttpRequest({ data: request() }), response.responder);
  assert.equal(response.statusCode, 503);
  assert.equal(calls, 0);
});

test('active internal admission accepts a new verified identity while retaining Auth, app and consent gates', async () => {
  for (const scenario of ['valid', 'wrong-app', 'bad-auth', 'no-consent'] as const) {
    const db = seededFirestore();
    db.seed('brokerDurableControl/providerBudget', budget);
    const store = new FirestoreDurableBrokerStore(db, { requireProviderBudget: true,
      internalTestExpiresAt: expiry, nowMilliseconds: () => FIXED_NOW.getTime() });
    const config = { projectId: 'my-art-collections', projectNumber: '123456789',
      allowedAppIds: new Set(['owner-test-app']), quotaHmacSecret: 'synthetic-quota-key' };
    const verifier = new FakeBrokerTokenVerifier(config, new Map([
      ['test-auth|test-app-token', { uid: 'new-internal-user', appId: scenario === 'wrong-app' ? 'unapproved-app' : 'owner-test-app' }],
    ]));
    const protection = new ConfiguredDurableBrokerProtection(verifier, store, store.createRequestLifecycle(), config);
    let fetches = 0;
    const env = durableEnv({ BROKER_ADMISSION_MODE: 'verified_internal_app',
      BROKER_INTERNAL_TEST_EXPIRES_AT: expiry, BROKER_OWNER_UID_ALLOWLIST: '' });
    const configured = createConfiguredResearchBrokerDependencies(env, {
      fetchImpl: (async () => { fetches++; return new Response('', { status: 429 }); }) as typeof fetch,
      nowMilliseconds: () => FIXED_NOW.getTime(),
    }, undefined, protection);
    assert.equal(configured.kind, 'ready');
    if (configured.kind !== 'ready') throw new Error('fixture');
    const original = configured.createDependencies;
    configured.createDependencies = deadline => ({ ...original(deadline), now: () => FIXED_NOW });
    const response = createHttpResponse();
    await createResearchBrokerHttpHandler({ env, dependenciesFactory: () => configured,
      nowMilliseconds: () => FIXED_NOW.getTime() })(createHttpRequest({ data: request({
        consent_status: scenario === 'no-consent' ? 'missing' : 'approved',
      }) }, { authorization: scenario === 'bad-auth' ? 'Bearer unknown-auth' : 'Bearer test-auth',
        'x-firebase-appcheck': 'test-app-token' }), response.responder);
    assert.equal(fetches, scenario === 'valid' ? 1 : 0, scenario);
    assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, scenario === 'valid' ? 1 : 0, scenario);
    assert.equal(db.find('brokerDurableEntitlements/').length, 1, 'no test purchase/entitlement record was created');
  }
});
