import assert from 'node:assert/strict';
import test from 'node:test';
import type { Auth, DecodedIdToken } from 'firebase-admin/auth';
import { verifyCallableIdentity, type BillingCallableContext } from '../src/identity.js';

const appId = 'synthetic-approved-app';
const context = (): BillingCallableContext => ({
  auth: { uid: 'synthetic-user' }, app: { appId, alreadyConsumed: false },
  rawRequest: { headers: { authorization: 'Bearer synthetic-id-token' } },
});
function verifier(provider = 'google.com', uid = 'synthetic-user', fail = false) {
  const calls: unknown[][] = [];
  const auth: Pick<Auth, 'verifyIdToken'> = { verifyIdToken: async (...args) => {
    calls.push(args);
    if (fail) throw new Error('synthetic revoked token');
    return { uid, firebase: { sign_in_provider: provider } } as DecodedIdToken;
  } };
  return { auth, calls };
}

for (const consumed of [true, undefined, null, 0, 1, '', 'false', {}, []]) {
  test(`paid callable guard rejects non-fresh consumption ${JSON.stringify(consumed)} before Auth`, async () => {
    const request = context(); request.app!.alreadyConsumed = consumed;
    const { auth, calls } = verifier();
    assert.equal(await verifyCallableIdentity(request, auth, appId), undefined);
    assert.deepEqual(calls, []);
  });
}

test('paid callable guard accepts explicit fresh consumption then verifies revoked-checked Google identity', async () => {
  const { auth, calls } = verifier();
  assert.deepEqual(await verifyCallableIdentity(context(), auth, appId), { uid: 'synthetic-user' });
  assert.deepEqual(calls, [['synthetic-id-token', true]]);
});

test('paid callable guard rejects missing context, wrong app/config and authorization before Auth', async () => {
  for (const mutate of [
    (r: BillingCallableContext) => { delete r.app; },
    (r: BillingCallableContext) => { delete r.auth; },
    (r: BillingCallableContext) => { r.app!.appId = 'wrong-app'; },
    (r: BillingCallableContext) => { r.app!.appId = null; },
    (r: BillingCallableContext) => { delete r.rawRequest.headers.authorization; },
    (r: BillingCallableContext) => { r.rawRequest.headers.authorization = ['Bearer synthetic-id-token']; },
  ]) {
    const request = context(); mutate(request); const { auth, calls } = verifier();
    assert.equal(await verifyCallableIdentity(request, auth, appId), undefined);
    assert.deepEqual(calls, []);
  }
  const { auth, calls } = verifier();
  assert.equal(await verifyCallableIdentity(context(), auth, undefined), undefined);
  assert.deepEqual(calls, []);
});

test('fresh App Check does not bypass provider, UID or revocation verification', async () => {
  for (const [provider, uid, fail] of [
    ['anonymous', 'synthetic-user', false], ['google.com', 'other-user', false],
    ['google.com', 'synthetic-user', true],
  ] as const) {
    const { auth, calls } = verifier(provider, uid, fail);
    assert.equal(await verifyCallableIdentity(context(), auth, appId), undefined);
    assert.equal(calls.length, 1);
  }
});
