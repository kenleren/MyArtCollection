import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BillingDeadline } from '../src/deadline.js';
import { createBillingIdentifiers } from '../src/crypto.js';
import { DispatchError, configurationDigest, type DispatchConfiguration } from '../src/dispatch_budget.js';
import {
  DispatchGate, accountDispatch, type DispatchCapability, type DispatchDescriptor,
  type DispatchRepository, type DispatchReservation,
} from '../src/dispatch_gate.js';
import { GoogleAndroidPublisherTransport, PlayAdapterError } from '../src/play_adapter.js';
import { GoogleKmsTransport, KmsConfigurationError } from '../src/kms_token_custody.js';
import { crc32c, custodyAad } from '../src/token_custody.js';
import type { AttemptHandle } from '../src/store.js';

const token = 'synthetic-boundary-token';
const product = 'archivale_starter_monthly' as const;
const keyVersion = 'projects/synthetic-billing/locations/us-central1/keyRings/testing/cryptoKeys/tokens/cryptoKeyVersions/1';
const identifiers = createBillingIdentifiers(Buffer.alloc(32, 7));
const flush = (): Promise<void> => new Promise((resolve) => setImmediate(resolve));
function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
function config(): DispatchConfiguration {
  const counts = () => ({ get: 3, ack: 3, kms: 3 });
  const value = { enabled: true, epoch: '1'.repeat(32), global: counts(),
    sources: { foreground: counts(), event: counts(), reconciliation: counts() } };
  return { ...value, digest: configurationDigest(value) };
}
function attempt(deadline: BillingDeadline): AttemptHandle {
  return {
    expectedPlayAccountId: Buffer.alloc(32, 5).toString('base64url'), accountSubject: 'a'.repeat(64),
    tokenFingerprint: identifiers.tokenFingerprint(token), lifecycleEpoch: 'b'.repeat(32), lifecycleGeneration: 1,
    usesReplay: false, owner: { requestFingerprint: 'c'.repeat(64), attemptGeneration: 1, attemptNonce: Buffer.alloc(16, 1) },
    fence: { assertionId: 'd'.repeat(32), indexRevision: 1, deadline, kind: 'verify',
      observationGeneration: 1, observationNonce: Buffer.alloc(16, 2), source: 'foreground', publicationRevision: 1 },
  };
}
class BoundaryRepository implements DispatchRepository {
  reservations = 0;
  validations = 0;
  circuitOpens = 0;
  expiry = Date.now() + 40_000;
  failure?: DispatchError;
  beforeFinal?: () => Promise<void>;
  onCircuit?: (deadline: BillingDeadline) => void;
  circuitFailure = false;
  configurationDigests: string[] = [];
  async dispatch(_cap: DispatchCapability, _descriptor: DispatchDescriptor, _config: DispatchConfiguration,
    _deadline: BillingDeadline, minimumRevision?: number): Promise<DispatchReservation> {
    this.configurationDigests.push(_config.digest);
    if (this.failure) throw this.failure;
    if (minimumRevision === undefined) this.reservations++;
    else { this.validations++; await this.beforeFinal?.(); }
    return { revision: this.reservations, expiresAt: this.expiry, source: 'foreground' };
  }
  async openDispatchCircuit(_config: DispatchConfiguration, deadline: BillingDeadline): Promise<void> {
    this.circuitOpens++;
    this.onCircuit?.(deadline);
    if (this.circuitFailure) throw new Error('synthetic unavailable circuit store');
  }
}
function harness(now: () => number = Date.now) {
  const repository = new BoundaryRepository();
  const gate = new DispatchGate(repository, config(), identifiers, now);
  const deadline = new BillingDeadline(Date.now() + 55_000);
  const owner = attempt(deadline);
  return { repository, gate, deadline, owner, cap: accountDispatch(owner, 'lookup_in_flight') };
}
const headers = async () => new Headers();
const auth = { getClient: async () => ({ getRequestHeaders: headers }) };
function getArgs(h: ReturnType<typeof harness>) {
  return { packageName: 'app.archivale' as const, token, timeoutMs: 10_000 as const, deadline: h.deadline, dispatch: h.cap };
}
function kmsArgs(h: ReturnType<typeof harness>) {
  const cap = accountDispatch(h.owner, 'verified_owner');
  const bytes = Buffer.from(token);
  const aad = custodyAad(h.owner, keyVersion);
  const body = { plaintext: bytes.toString('base64'), additionalAuthenticatedData: aad.toString('base64'),
    plaintextCrc32c: crc32c(bytes), additionalAuthenticatedDataCrc32c: crc32c(aad) };
  return { cap, body };
}

test('actual Google transports reject a missing gate before constructing any auth provider', () => {
  let authReads = 0;
  const options = { get auth(): typeof auth { authReads++; throw new Error('auth construction must not occur'); } };
  assert.throws(() => new GoogleAndroidPublisherTransport(options), PlayAdapterError);
  assert.throws(() => new GoogleKmsTransport(options), KmsConfigurationError);
  assert.equal(authReads, 0);
});

for (const kind of ['play', 'kms'] as const) {
  test(`${kind}: budget and stale-owner denials do not masquerade as authentication configuration faults`, async () => {
    for (const reason of ['budget', 'stale'] as const) {
      const h = harness();
      h.repository.failure = new DispatchError(reason);
      let authCalls = 0;
      let fetches = 0;
      const unavailableAuth = { getClient: async () => { authCalls++; return { getRequestHeaders: headers }; } };
      if (kind === 'play') {
        const transport = new GoogleAndroidPublisherTransport({ gate: h.gate, auth: unavailableAuth,
          fetch: async () => { fetches++; return new Response('{}'); } });
        await assert.rejects(transport.getSubscription(getArgs(h)));
      } else {
        const request = kmsArgs(h);
        const transport = new GoogleKmsTransport({ gate: h.gate, auth: unavailableAuth,
          fetch: async () => { fetches++; return new Response('{}'); } });
        await assert.rejects(transport.request(keyVersion, 'encrypt', request.body, h.deadline, request.cap));
      }
      assert.equal(authCalls, 0);
      assert.equal(fetches, 0);
      assert.equal(h.repository.circuitOpens, 0);
    }
  });

  for (const stage of ['client', 'headers'] as const) {
    test(`${kind}: cancellation during deferred ${stage} never resumes a charged request`, async () => {
      const h = harness();
      const entered = deferred();
      const release = deferred();
      let fetches = 0;
      const delayedAuth = { getClient: async () => {
        if (stage === 'client') { entered.resolve(); await release.promise; }
        return { getRequestHeaders: async () => {
          if (stage === 'headers') { entered.resolve(); await release.promise; }
          return new Headers();
        } };
      } };
      const operation = kind === 'play'
        ? new GoogleAndroidPublisherTransport({ gate: h.gate, auth: delayedAuth,
          fetch: async () => { fetches++; return new Response('{}'); } }).getSubscription(getArgs(h))
        : (() => { const request = kmsArgs(h); return new GoogleKmsTransport({ gate: h.gate, auth: delayedAuth,
          fetch: async () => { fetches++; return new Response('{}'); } })
          .request(keyVersion, 'encrypt', request.body, h.deadline, request.cap); })();
      const rejected = assert.rejects(operation);
      await entered.promise;
      h.deadline.cancel();
      release.resolve();
      await rejected;
      await flush();
      assert.equal(h.repository.reservations, 1);
      assert.equal(h.repository.validations, 0);
      assert.equal(h.repository.circuitOpens, 0);
      assert.equal(fetches, 0);
    });
  }

  test(`${kind}: auth fault classes open only the intended shared circuit`, async () => {
    for (const [error, opens] of [
      [{ response: { status: 401 } }, 1], [{ status: 403 }, 1],
      [new Error('synthetic sensitive SDK detail'), 1], [{ code: 'EACCES' }, 1],
      [{ status: 429 }, 0], [{ response: { status: 503 } }, 0], [{ code: 'ECONNRESET' }, 0],
    ] as const) {
      const h = harness();
      const failingAuth = { getClient: async (): Promise<{ getRequestHeaders: typeof headers }> => { throw error; } };
      let fetches = 0;
      const operation = kind === 'play'
        ? new GoogleAndroidPublisherTransport({ gate: h.gate, auth: failingAuth,
          fetch: async () => { fetches++; return new Response('{}'); } }).getSubscription(getArgs(h))
        : (() => { const request = kmsArgs(h); return new GoogleKmsTransport({ gate: h.gate, auth: failingAuth,
          fetch: async () => { fetches++; return new Response('{}'); } })
          .request(keyVersion, 'encrypt', request.body, h.deadline, request.cap); })();
      await assert.rejects(operation, (failure: Error) => {
        assert.doesNotMatch(failure.message, /sensitive SDK|synthetic-boundary-token|EACCES/);
        return true;
      });
      assert.equal(fetches, 0);
      assert.equal(h.repository.reservations, 1);
      assert.equal(h.repository.circuitOpens, opens);
    }
  });

  test(`${kind}: circuit persistence keeps the original transport deadline`, async () => {
    const h = harness();
    const before = Date.now();
    let circuitDeadline: number | undefined;
    h.repository.onCircuit = (deadline) => { circuitDeadline = deadline.expiresAt; };
    const failingAuth = { getClient: async (): Promise<{ getRequestHeaders: typeof headers }> => { throw { status: 401 }; } };
    const operation = kind === 'play'
      ? new GoogleAndroidPublisherTransport({ gate: h.gate, auth: failingAuth, fetch: async () => new Response('{}') }).getSubscription(getArgs(h))
      : (() => { const request = kmsArgs(h); return new GoogleKmsTransport({ gate: h.gate, auth: failingAuth, fetch: async () => new Response('{}') })
        .request(keyVersion, 'encrypt', request.body, h.deadline, request.cap); })();
    await assert.rejects(operation);
    assert.ok(circuitDeadline !== undefined);
    assert.ok(circuitDeadline <= before + 10_100, 'circuit write must not gain the remaining parent invocation time');
    assert.ok(circuitDeadline < h.deadline.expiresAt);
  });
}

test('Publisher serializes ACK URL/body before auth and ignores later caller mutation', async () => {
  const h = harness();
  const entered = deferred();
  const release = deferred();
  const body = { externalAccountIds: { obfuscatedAccountId: Buffer.alloc(32, 5).toString('base64url') } };
  const original = JSON.stringify(body);
  let sent = '';
  let url = '';
  const transport = new GoogleAndroidPublisherTransport({ gate: h.gate,
    auth: { getClient: async () => { entered.resolve(); await release.promise; return { getRequestHeaders: headers }; } },
    fetch: async (target, init) => { url = target; sent = init.body!; return new Response(null, { status: 204 }); },
  });
  const args = { ...getArgs(h), subscriptionId: product, body, dispatch: accountDispatch(h.owner, 'ack_in_progress') };
  const operation = transport.acknowledgeSubscription(args);
  await entered.promise;
  body.externalAccountIds.obfuscatedAccountId = 'changed-after-admission';
  args.token = 'changed-token';
  release.resolve();
  await operation;
  assert.equal(sent, original);
  assert.ok(url.includes(encodeURIComponent(token)));
  assert.equal(h.repository.reservations, 1);
  assert.equal(h.repository.validations, 1);
});

test('KMS uses exact serialized bytes captured before deferred headers', async () => {
  const h = harness();
  const request = kmsArgs(h);
  const original = JSON.stringify(request.body);
  const entered = deferred();
  const release = deferred();
  let sent = '';
  const transport = new GoogleKmsTransport({ gate: h.gate,
    auth: { getClient: async () => ({ getRequestHeaders: async () => { entered.resolve(); await release.promise; return new Headers(); } }) },
    fetch: async (_url, init) => { sent = init.body as string; return new Response('{}'); },
  });
  const operation = transport.request(keyVersion, 'encrypt', request.body, h.deadline, request.cap);
  await entered.promise;
  request.body.plaintext = Buffer.from('changed-token').toString('base64');
  request.body.additionalAuthenticatedData = Buffer.from('changed-aad').toString('base64');
  release.resolve();
  await operation;
  assert.equal(sent, original);
  assert.equal(h.repository.reservations, 1);
  assert.equal(h.repository.validations, 1);
});

test('final validation returning after the ticket lease expires cannot fetch while the parent remains active', async () => {
  let now = Date.now();
  const h = harness(() => now);
  h.repository.expiry = now + 100;
  const capturedExpiry = h.repository.expiry;
  const entered = deferred();
  const release = deferred();
  h.repository.beforeFinal = async () => { entered.resolve(); await release.promise; };
  let fetches = 0;
  const transport = new GoogleAndroidPublisherTransport({ gate: h.gate, auth, now: () => now,
    fetch: async () => { fetches++; return new Response('{}'); } });
  const operation = transport.getSubscription(getArgs(h));
  const rejected = assert.rejects(operation);
  await entered.promise;
  now = capturedExpiry;
  h.repository.expiry = now + 30_000; // A later extension cannot renew the existing ticket.
  release.resolve();
  await rejected;
  assert.ok(Date.now() < h.deadline.expiresAt);
  assert.equal(fetches, 0);
  assert.equal(h.repository.circuitOpens, 0);
});

test('tickets snapshot mutable caller input and can be consumed only once, including concurrent use', async () => {
  const h = harness();
  const cap = { ...h.cap };
  const descriptor = { ...h.gate.playDescriptor(cap, 'play_get', token) };
  const ticket = await h.gate.reserve(cap, descriptor, h.deadline);
  const capturedAttempt = 'attempt' in ticket.capability ? ticket.capability.attempt : '';
  if ('attempt' in cap) cap.attempt = 'changed';
  descriptor.tokenFingerprint = 'f'.repeat(64);
  assert.equal('attempt' in ticket.capability && ticket.capability.attempt, capturedAttempt);
  assert.equal(ticket.descriptor.tokenFingerprint, identifiers.tokenFingerprint(token));
  assert.ok(Object.isFrozen(ticket) && Object.isFrozen(ticket.capability) && Object.isFrozen(ticket.descriptor));
  const entered = deferred();
  const release = deferred();
  h.repository.beforeFinal = async () => { entered.resolve(); await release.promise; };
  let fetches = 0;
  const first = h.gate.consume(ticket, async () => { fetches++; return 'ok'; });
  await entered.promise;
  await assert.rejects(h.gate.consume(ticket, async () => { fetches++; return 'replayed'; }));
  release.resolve();
  assert.equal(await first, 'ok');
  await assert.rejects(h.gate.consume(ticket, async () => { fetches++; return 'replayed'; }));
  assert.equal(fetches, 1);
  assert.equal(h.repository.reservations, 1);
});

test('a synchronous fetch failure spends its ticket and an uncertain reservation creates no ticket', async () => {
  const h = harness();
  const descriptor = h.gate.playDescriptor(h.cap, 'play_get', token);
  const ticket = await h.gate.reserve(h.cap, descriptor, h.deadline);
  let attempts = 0;
  await assert.rejects(h.gate.consume(ticket, () => { attempts++; throw new Error('synthetic fetch failure'); }));
  await assert.rejects(h.gate.consume(ticket, async () => { attempts++; }));
  assert.equal(attempts, 1);
  const uncertain: DispatchRepository = {
    async dispatch() { attempts++; throw new Error('committed reservation response lost'); },
    async openDispatchCircuit() {},
  };
  const gate = new DispatchGate(uncertain, config(), identifiers);
  await assert.rejects(gate.reserve(h.cap, descriptor, h.deadline));
  assert.equal(attempts, 2);
});

test('configuration failure poisons the shared gate even if persisting the circuit fails', async () => {
  const h = harness();
  const descriptor = h.gate.playDescriptor(h.cap, 'play_get', token);
  const existing = await h.gate.reserve(h.cap, descriptor, h.deadline);
  h.repository.circuitFailure = true;
  await h.gate.configurationFailure(h.deadline);
  await assert.rejects(h.gate.reserve(h.cap, descriptor, h.deadline));
  let fetches = 0;
  await assert.rejects(h.gate.consume(existing, async () => { fetches++; }));
  assert.equal(fetches, 0);
  assert.equal(h.repository.reservations, 1);
  assert.equal(h.repository.circuitOpens, 1);
});

test('caller configuration mutation cannot rebind a reserved ticket to a different epoch or allocation', async () => {
  const h = harness();
  const callerConfig = config();
  const originalDigest = callerConfig.digest;
  const originalEpoch = callerConfig.epoch;
  const gate = new DispatchGate(h.repository, callerConfig, identifiers);
  const descriptor = gate.playDescriptor(h.cap, 'play_get', token);
  const ticket = await gate.reserve(h.cap, descriptor, h.deadline);
  callerConfig.epoch = 'e'.repeat(32);
  callerConfig.global.get = 1;
  callerConfig.sources.foreground.get = 1;
  callerConfig.digest = configurationDigest(callerConfig);
  let fetches = 0;
  await gate.consume(ticket, async () => { fetches++; });
  assert.equal(fetches, 1);
  assert.equal(ticket.epoch, originalEpoch);
  assert.equal(ticket.configDigest, originalDigest);
  assert.equal(gate.config.epoch, originalEpoch);
  assert.equal(gate.config.digest, originalDigest);
  assert.deepEqual(h.repository.configurationDigests, [originalDigest, originalDigest]);
  assert.ok(Object.isFrozen(gate.config) && Object.isFrozen(gate.config.global)
    && Object.isFrozen(gate.config.sources.foreground));
});
