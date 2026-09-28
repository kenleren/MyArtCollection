import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BillingDeadline } from '../src/deadline.js';
import { GoogleKmsTokenCustody, GoogleKmsTransport, createConfiguredTokenCustody } from '../src/kms_token_custody.js';
import { crc32c } from '../src/token_custody.js';
import { FakeKmsTransport, TEST_KEY } from './fake_custody.js';
import { deferred } from './test_helpers.js';
const context = { accountSubject: 'a'.repeat(64), tokenFingerprint: 'b'.repeat(64) };

test('custody round trip binds account, token and exact same-parent key version', async () => {
  const transport = new FakeKmsTransport();
  const nextVersion = TEST_KEY.slice(0, -1) + '2';
  const custody = new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY, nextVersion], transport);
  const envelope = await custody.encrypt('synthetic-token', context, new BillingDeadline());
  assert.equal(await custody.decrypt(envelope, context, new BillingDeadline()) === 'synthetic-token', true);
  await assert.rejects(custody.decrypt({ ...envelope, keyVersion: nextVersion }, context, new BillingDeadline()));
  await assert.rejects(custody.decrypt(envelope, { ...context, accountSubject: 'c'.repeat(64) }, new BillingDeadline()));
  await assert.rejects(custody.decrypt(envelope, { ...context, tokenFingerprint: 'c'.repeat(64) }, new BillingDeadline()));
  const before = transport.calls.length;
  await assert.rejects(custody.decrypt({ ...envelope, keyVersion: TEST_KEY.slice(0, -1) + '3' }, context, new BillingDeadline()));
  assert.equal(transport.calls.length, before);
});

test('disabled or invalid configuration constructs no credential or network adapter', async () => {
  let made = 0;
  const factory = () => { made++; return new FakeKmsTransport(); };
  for (const config of [{}, { enabled: true }, { enabled: true, encryptionVersion: '../invalid', retainedVersions: [] }]) {
    const custody = createConfiguredTokenCustody({ ...config, transportFactory: factory });
    await assert.rejects(custody.encrypt('synthetic', context, new BillingDeadline()));
  }
  assert.equal(made, 0);
});

test('KMS integrity flags, ciphertext CRC, version and malformed plaintext fail closed', async () => {
  assert.equal(crc32c(Buffer.from('123456789')), '3808858755');
  for (const mutation of ['name', 'verifiedPlaintextCrc32c', 'verifiedAdditionalAuthenticatedDataCrc32c', 'ciphertextCrc32c']) {
    const underlying = new FakeKmsTransport();
    const custody = new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY], {
      request: async (...args) => ({ ...await underlying.request(args[0], args[1], args[2]) as object, [mutation]: false }),
    });
    await assert.rejects(custody.encrypt('synthetic', context, new BillingDeadline()));
  }
  const malformed = new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY], { request: async () => ({ plaintext: '%%%=', plaintextCrc32c: '0' }) });
  const good = new GoogleKmsTokenCustody(TEST_KEY, [TEST_KEY], new FakeKmsTransport());
  const envelope = await good.encrypt('synthetic', context, new BillingDeadline());
  await assert.rejects(malformed.decrypt(envelope, context, new BillingDeadline()));
});

test('transport bounds response body and rejects redirects and non-success without raw errors', async () => {
  const auth = { getClient: async () => ({ getRequestHeaders: async () => new Headers() }) };
  for (const response of [new Response('x'.repeat(32769)), new Response('synthetic failure', { status: 500 })]) {
    const transport = new GoogleKmsTransport({ auth, fetch: async (_url, init) => {
      assert.equal(init.redirect, 'error'); return response;
    } });
    await assert.rejects(transport.request(TEST_KEY, 'encrypt', {}, new BillingDeadline()), { message: 'token custody unavailable' });
  }
});

test('late auth and body completions cannot resume a timed-out custody request', async () => {
  const authGate = deferred(); let fetches = 0;
  const transport = new GoogleKmsTransport({
    auth: { getClient: async () => { await authGate.promise; return { getRequestHeaders: async () => new Headers() }; } },
    fetch: async () => { fetches++; return new Response('{}'); },
  });
  await assert.rejects(transport.request(TEST_KEY, 'encrypt', {}, new BillingDeadline(Date.now() + 10)));
  authGate.resolve(); await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fetches, 0);
  let bodyController!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start(controller) { bodyController = controller; } });
  const bodyTransport = new GoogleKmsTransport({
    auth: { getClient: async () => ({ getRequestHeaders: async () => new Headers() }) },
    fetch: async () => new Response(body),
  });
  await assert.rejects(bodyTransport.request(TEST_KEY, 'encrypt', {}, new BillingDeadline(Date.now() + 10)));
  bodyController.enqueue(Buffer.from('{}')); bodyController.close();
  await new Promise((resolve) => setImmediate(resolve));
});
