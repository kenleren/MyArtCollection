import assert from 'node:assert/strict';
import test from 'node:test';
import { isPaidGoogleIdentity } from '../src/identity.js';

test('paid identity requires Google from verified claims and matching callable UID', () => {
  for (const provider of ['anonymous', 'password', 'apple.com', undefined]) {
    assert.equal(isPaidGoogleIdentity({ uid: 'synthetic-user', firebase: { sign_in_provider: provider } }, 'synthetic-user'), false);
  }
  const google = { uid: 'synthetic-user', firebase: { sign_in_provider: 'google.com' } };
  assert.equal(isPaidGoogleIdentity(google, 'synthetic-user'), true);
  assert.equal(isPaidGoogleIdentity(google, 'other-user'), false);
  assert.equal(isPaidGoogleIdentity({ ...google, uid: '' }, ''), false);
});
