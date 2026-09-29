import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CreditIdentityDeadline,
  CreditIdentityService,
  PROJECT,
  ROUTE_KEY,
  ACCOUNT_KEY,
  authorityDigest,
  routeForUid,
  type CreditIdentityConfig,
  type CreditAuthoritySnapshot,
} from '../src/credit_identity.js';
import {
  CREDIT_COLLECTIONS,
  InMemoryCreditIdentityDatabase,
} from '../src/credit_identity_store.js';
import { FirebaseAdminBrokerTokenVerifier } from '../src/durable_protection.js';

const START = Date.parse('2026-09-29T12:00:00.000Z');
const UID = 'synthetic-root-deadline-account';
const APP = 'synthetic-root-deadline-app';
const ROUTING_KEY = 'synthetic-root-routing-key-at-least-32-bytes';
const ACCOUNT_KEY_BYTES = 'synthetic-root-account-key-at-least-32-bytes';

/** Component fixture: real broker transactions, injected SDK and billing replies.
 * The separate bridge harness owns actual billing-to-broker integration evidence.
 */
async function ready(options: { ageMs?: number; validForMs?: number } = {}) {
  let now = START;
  let counter = 0;
  const database = new InMemoryCreditIdentityDatabase();
  const config: CreditIdentityConfig = {
    version: 'credit-identity-config-v1', projectId: PROJECT, enabled: true,
    routingKeyVersion: ROUTE_KEY, accountKeyVersion: ACCOUNT_KEY,
    cutoverId: '1'.repeat(32), admissionPolicyId: '2'.repeat(32),
    maxAccounts: 20, authorityMaxAgeMs: 60_000,
  };
  const snapshot: CreditAuthoritySnapshot = {
    version: 'credit-authority-v1', projectId: PROJECT,
    routingKeyVersion: ROUTE_KEY, route: routeForUid(ROUTING_KEY, UID),
    enrollmentId: '3'.repeat(32), lifecycleEpoch: '4'.repeat(32),
    lifecycleGeneration: 1, publicationRevision: 1,
    lifecycleStatus: 'active', state: 'active', planId: 'collector',
    verifiedAtMs: START - (options.ageMs ?? 0),
    playExpiresAtMs: START + 120_000,
    validUntilMs: START + (options.validForMs ?? 120_000),
  };
  const verifier = new FirebaseAdminBrokerTokenVerifier({
    config: { projectId: PROJECT, projectNumber: '123456789', allowedAppIds: new Set([APP]) },
    auth: { async verifyIdToken(_token, checkRevoked) {
      assert.equal(checkRevoked, true);
      return { uid: UID, aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`,
        firebase: { sign_in_provider: 'google.com' } };
    } },
    appCheck: { async verifyToken(_token, options) {
      assert.deepEqual(options, { consume: true });
      return { appId: APP, alreadyConsumed: false, token: {
        aud: ['123456789', PROJECT], iss: 'https://firebaseappcheck.googleapis.com/123456789', sub: APP,
      } };
    } },
  });
  let reads = 0;
  const service = new CreditIdentityService({
    config, database, verifier, routingKey: ROUTING_KEY, accountKey: ACCOUNT_KEY_BYTES,
    ownerUids: new Set([UID]), appIds: new Set([APP]), now: () => now,
    newNonce: () => (++counter).toString(16).padStart(32, '0'),
    transport: { async read(request) {
      reads += 1;
      return { version: 'credit-authority-read-result-v1', challenge: request.challenge,
        snapshot: structuredClone(snapshot), digest: authorityDigest(snapshot) };
    } },
  });
  const controls = service.initialControlsForTest();
  database.setForTest(CREDIT_COLLECTIONS.control, 'control', controls.control);
  database.setForTest(CREDIT_COLLECTIONS.control, 'initialization', controls.initialization);
  database.setOperator(UID, { entitled: true, breakerOpen: false });
  let tokenNumber = 0;
  const tokens = () => ({ authorizationHeader: 'Bearer synthetic-root-auth',
    appCheckToken: `synthetic-root-fresh-${++tokenNumber}` });
  assert.deepEqual(await service.consent(tokens(), {
    version: 'credit-consent-command-v1', requestId: '10000000-0000-4000-8000-000000000001',
    expectedConsentRevision: 0, action: 'accept',
    researchVersion: 'research-consent-v1', bridgeVersion: 'paid-ai-bridge-consent-v1',
  }), { status: 'accepted', consentRevision: 1 });
  assert.deepEqual(await service.register(tokens(), {
    version: 'credit-registration-v1', requestId: '10000000-0000-4000-8000-000000000002',
    expectedRegistrationGeneration: 0,
  }), { status: 'ready' });
  assert.equal(reads, 2);
  return { service, database, tokens, snapshot, config,
    now: () => now, setNow: (value: number) => { now = value; },
    revoke: () => service.consent(tokens(), {
      version: 'credit-consent-command-v1', requestId: '10000000-0000-4000-8000-000000000003',
      expectedConsentRevision: 1, action: 'revoke',
      researchVersion: 'research-consent-v1', bridgeVersion: 'paid-ai-bridge-consent-v1',
    }),
  };
}

type Fixture = Awaited<ReturnType<typeof ready>>;
async function heldEvaluation(f: Fixture, change: () => void | Promise<void>, deadline?: CreditIdentityDeadline) {
  let release!: () => void;
  let reached!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const arrived = new Promise<void>(resolve => { reached = resolve; });
  f.database.afterTransaction = async () => {
    f.database.afterTransaction = undefined;
    reached();
    await gate;
  };
  const pending = f.service.evaluate(f.tokens(), deadline);
  try {
    await Promise.race([arrived, pending.then(() => {
      throw new Error('Eligibility completed before the transaction-result barrier.');
    })]);
    await change();
  } finally { release(); }
  return pending;
}

test('eligible result is frozen, bounded and does not reserve a credit', async () => {
  const f = await ready({ ageMs: 20_000 });
  const before = f.database.snapshotForTest();
  const result = await f.service.evaluate(f.tokens());
  assert.equal(result.status, 'eligible');
  if (result.status !== 'eligible') assert.fail('Expected eligible fixture.');
  assert.equal(result.fence.expiresAt, START + 40_000);
  assert.equal(Object.isFrozen(result), true);
  assert.equal(Object.isFrozen(result.fence), true);
  assert.deepEqual(f.database.snapshotForTest(), before);
});

test('held eligibility cannot outlive original verification age within a live invocation', async () => {
  const f = await ready({ ageMs: 59_900 });
  const result = await heldEvaluation(f, () => f.setNow(START + 101));
  assert.equal(result.status, 'unavailable');
  assert.ok(f.now() < START + 50_000);
  assert.ok(f.now() < f.snapshot.validUntilMs!);
});

test('age-cap equality is expired without changing the original verification time', async () => {
  const f = await ready({ ageMs: 59_900 });
  assert.equal((await heldEvaluation(f, () => f.setNow(START + 100))).status, 'unavailable');
  assert.equal(f.snapshot.verifiedAtMs, START - 59_900);
});

test('held eligibility cannot outlive disclosure validity even before Play expiry and age cap', async () => {
  const f = await ready({ validForMs: 100 });
  assert.equal((await heldEvaluation(f, () => f.setNow(START + 100))).status, 'unavailable');
  assert.ok(f.now() < f.snapshot.playExpiresAtMs!);
  assert.ok(f.now() < f.snapshot.verifiedAtMs + f.config.authorityMaxAgeMs);
});

test('held eligibility cannot cross the original invocation expiry', async () => {
  const f = await ready();
  const deadline = new CreditIdentityDeadline(START + 100, f.now);
  assert.equal((await heldEvaluation(f, () => f.setNow(START + 100), deadline)).status, 'unavailable');
});

test('cancellation while a transaction result is held never returns an eligible result', async () => {
  const f = await ready();
  const deadline = new CreditIdentityDeadline(START + 50_000, f.now);
  assert.equal((await heldEvaluation(f, () => deadline.cancel(), deadline)).status, 'unavailable');
});

test('clock rollback after the transaction cannot return a future verification as eligible', async () => {
  const f = await ready();
  assert.equal((await heldEvaluation(f, () => f.setNow(START - 1))).status, 'unavailable');
});

test('slow result inside all three bounds remains eligible without refreshing its fence', async () => {
  const f = await ready({ ageMs: 59_900 });
  const result = await heldEvaluation(f, () => f.setNow(START + 99));
  assert.equal(result.status, 'eligible');
  if (result.status !== 'eligible') assert.fail('Expected eligible before all caps.');
  assert.equal(result.fence.expiresAt, START + 100);
});

test('withdrawal before an eligibility read denies access', async () => {
  const f = await ready();
  assert.deepEqual(await f.revoke(), { status: 'revoked', consentRevision: 2 });
  assert.equal((await f.service.evaluate(f.tokens())).status, 'none');
});

test('withdrawal after a completed read leaves only a stale read-only fence; the next read denies', async () => {
  const f = await ready();
  const earlier = await heldEvaluation(f, async () => {
    assert.deepEqual(await f.revoke(), { status: 'revoked', consentRevision: 2 });
  });
  assert.equal(earlier.status, 'eligible');
  if (earlier.status !== 'eligible') assert.fail('The completed read linearized before withdrawal.');
  assert.equal(earlier.fence.consentRevision, 1);
  assert.equal((await f.service.evaluate(f.tokens())).status, 'none');
  // L4-B must reread current consent/authority inside reservation and dispatch.
  assert.equal([...f.database.snapshotForTest().keys()].every(key => key.startsWith('brokerCredit')), true);
});

test('child read budget expires before deferred execution even while parent and owner are live', async () => {
  let now = START;
  let calls = 0;
  const deadline = new CreditIdentityDeadline(START + 50_000, () => now);
  const pending = deadline.run(async () => { calls += 1; return 'late'; }, 10_000, START + 90_000);
  // The microtask has not run and the timer has not had a chance to dispatch.
  now = START + 10_001;
  await assert.rejects(pending, { message: 'credit identity unavailable' });
  assert.equal(calls, 0);
  assert.ok(now < deadline.expiresAt);
});

test('child read budget is checked after completion without relying on timer delivery', async () => {
  let now = START;
  let calls = 0;
  const deadline = new CreditIdentityDeadline(START + 50_000, () => now);
  await assert.rejects(deadline.run(async () => {
    calls += 1;
    now = START + 10_001;
    return 'late';
  }, 10_000, START + 90_000), { message: 'credit identity unavailable' });
  assert.equal(calls, 1);
  assert.ok(now < deadline.expiresAt);
});
