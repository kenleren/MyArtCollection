import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { createBillingRuntime } from '../src/billing_runtime.js';
import { COLLECTIONS } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import { accountDispatch } from '../src/dispatch_gate.js';
import { GoogleKmsTransport, KmsConfigurationError } from '../src/kms_token_custody.js';
import { crc32c, custodyAad } from '../src/token_custody.js';
import { PlayBillingService } from '../src/verifier.js';
import { seedDispatch, testDispatchConfig } from './dispatch_fixtures.js';
import { TEST_KEY } from './fake_custody.js';
import { acceptDisclosure, createHarness, deferred, DeterministicNonceSource, FakeClock, purchaseToken } from './test_helpers.js';

async function setup() {
  const h = createHarness();
  h.clock = new FakeClock(new Date());
  const configuration = testDispatchConfig();
  seedDispatch(h.database, h.clock.now(), configuration);
  const runtime = await createBillingRuntime({
    database: h.database, identifiers: h.identifiers, nonces: new DeterministicNonceSource(),
    clock: h.clock, deadline: new BillingDeadline(), providersNeeded: true,
    configuration: JSON.stringify(configuration),
  });
  assert.ok(runtime.gate);
  h.repository = runtime.repository;
  h.service = new PlayBillingService({ ...h });
  await acceptDisclosure(h);
  const token = purchaseToken();
  const acquired = await h.repository.acquireAttempt(h.identifiers.accountSubject(h.identity.uid),
    h.identifiers.requestFingerprint(h.identity.uid, randomUUID()), h.identifiers.tokenFingerprint(token),
    h.clock.now(), new BillingDeadline());
  assert.equal(acquired.kind, 'acquired');
  if (acquired.kind !== 'acquired') throw new Error('synthetic acquisition failed');
  assert.equal(await h.repository.markVerifiedOwner(acquired.attempt, 'archivale_starter_monthly', h.clock.now()), true);
  const bytes = Buffer.from(token);
  const aad = custodyAad(acquired.attempt, TEST_KEY);
  return { ...h, gate: runtime.gate, cap: accountDispatch(acquired.attempt, 'verified_owner'), body: {
    plaintext: bytes.toString('base64'), additionalAuthenticatedData: aad.toString('base64'),
    plaintextCrc32c: crc32c(bytes), additionalAuthenticatedDataCrc32c: crc32c(aad),
  } };
}

for (const status of [401, 403]) {
  for (const cleanup of ['held', 'rejected'] as const) {
    test(`KMS ${status}: ${cleanup} body cancellation cannot mask permission failure or leave dispatch open`, async () => {
      const h = await setup();
      const held = deferred();
      let cancellations = 0, authCalls = 0, fetches = 0;
      const deadline = new BillingDeadline(Date.now() + 1000);
      let circuitDeadline: BillingDeadline | undefined;
      const open = h.repository.openDispatchCircuit.bind(h.repository);
      h.repository.openDispatchCircuit = async (configuration, original) => {
        circuitDeadline = original;
        await open(configuration, original);
      };
      const transport = new GoogleKmsTransport({ gate: h.gate,
        auth: { getClient: async () => { authCalls++; return { getRequestHeaders: async () => new Headers() }; } },
        fetch: async () => {
          fetches++;
          return new Response(new ReadableStream({ cancel: () => {
            cancellations++;
            return cleanup === 'held' ? held.promise : Promise.reject(new Error('synthetic discard rejection'));
          } }), { status });
        },
      });
      try {
        await assert.rejects(transport.request(TEST_KEY, 'encrypt', h.body, deadline, h.cap), KmsConfigurationError);
        assert.equal(cancellations, 1);
        assert.equal(circuitDeadline?.expiresAt, deadline.expiresAt);
        assert.equal(circuitDeadline?.signal.aborted, false);
        const snapshot = h.database.snapshotForTest();
        const common = snapshot.get(`${COLLECTIONS.dispatchControl}/budget`) as {
          circuit: { state: string }; totals: { foreground: { kms_encrypt: number } };
        };
        assert.equal(common.circuit.state, 'open');
        assert.equal((snapshot.get(`${COLLECTIONS.eventControl}/budget`) as { circuit: boolean }).circuit, true);
        assert.equal(common.totals.foreground.kms_encrypt, 1);
        // A new invocation cannot reach authentication through the poisoned gate.
        await assert.rejects(transport.request(TEST_KEY, 'encrypt', h.body, new BillingDeadline(), h.cap));
        assert.deepEqual({ authCalls, fetches }, { authCalls: 1, fetches: 1 });
        // Allow rejected cleanup promises to surface as unhandled test failures.
        await new Promise<void>((resolve) => setImmediate(resolve));
      } finally { held.resolve(); }
    });
  }
}

test('KMS permission failure poisons immediately while circuit persistence retains the original deadline', async () => {
  const h = await setup();
  const entered = deferred(), held = deferred();
  const deadline = new BillingDeadline(Date.now() + 100);
  let circuitDeadline: BillingDeadline | undefined, fetches = 0;
  h.repository.openDispatchCircuit = async (_configuration, original) => {
    circuitDeadline = original;
    entered.resolve();
    await held.promise;
  };
  const transport = new GoogleKmsTransport({ gate: h.gate,
    auth: { getClient: async () => ({ getRequestHeaders: async () => new Headers() }) },
    fetch: async () => { fetches++; return new Response('', { status: 403 }); },
  });
  const denied = assert.rejects(transport.request(TEST_KEY, 'encrypt', h.body, deadline, h.cap), KmsConfigurationError);
  try {
    await entered.promise;
    await assert.rejects(transport.request(TEST_KEY, 'encrypt', h.body, new BillingDeadline(), h.cap));
    assert.equal(fetches, 1);
    assert.equal(circuitDeadline?.expiresAt, deadline.expiresAt);
    // The held database response is not released until the bounded request settles.
    await denied;
    assert.equal(circuitDeadline?.signal.aborted, true);
  } finally { held.resolve(); }
});
