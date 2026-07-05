import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  APPROVED_PAYLOAD_CLASS,
  CURRENT_CONSENT_COPY_VERSION,
  CURRENT_PAYLOAD_CONTRACT_VERSION,
  type BrokerRequest,
} from '../src/contracts.js';
import { createFakeBrokerDependencies, handleResearchRequest } from '../src/broker.js';

const baseContext = Object.freeze({
  uid: 'anonymous-test-uid',
  app_check_verified: true,
  auth_verified: true,
  entitled: true,
  credit_available: true,
  breaker_open: false,
});

function request(overrides: Partial<BrokerRequest> = {}): BrokerRequest {
  return {
    request_id: '11111111-1111-4111-8111-111111111111',
    consent_status: 'approved',
    consent_scope: 'image_only',
    consent_copy_version: CURRENT_CONSENT_COPY_VERSION,
    payload_contract_version: CURRENT_PAYLOAD_CONTRACT_VERSION,
    payload_hash: 'a'.repeat(64),
    approved_payload_class: APPROVED_PAYLOAD_CLASS,
    image: {
      mime_type: 'image/jpeg',
      byte_size: 120_000,
      long_edge_px: 1400,
    },
    ...overrides,
  };
}

test('fake-provider happy path validates, reserves credit, and returns fixture output', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({
    now: () => new Date('2026-07-06T12:00:00.000Z'),
    orderTrace: trace,
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'completed');
  assert.equal(response.provider, 'fake-provider');
  assert.equal(response.model, 'fake-local-model');
  assert.equal(response.sources.length, 1);
  assert.equal(response.candidate_attributions[0].source_refs[0], response.sources[0].source_id);
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.deepEqual(trace, [
    'auth',
    'consent',
    'payload_receipt',
    'entitlement',
    'breaker',
    'payload',
    'idempotency',
    'credit_reserve',
    'provider',
    'output_validation',
    'credit_finalize',
  ]);
});

test('missing consent rejects before provider call and credit reserve', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing' }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'consent_required');
  assert.equal(response.error?.stage, 'consent');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.deepEqual(trace, ['auth', 'consent']);
});

test('stale consent rejects before provider call and credit reserve', async () => {
  const deps = createFakeBrokerDependencies();

  const response = await handleResearchRequest(
    request({ consent_copy_version: 'research-consent-v0' }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'stale_consent');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
});

test('stale payload contract rejects before entitlement, credit reserve, or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ payload_contract_version: 'art-research-payload-v0' }),
    { ...baseContext, entitled: false, credit_available: false, breaker_open: true },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'payload_contract_mismatch');
  assert.equal(response.error?.stage, 'payload_receipt');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt']);
});

test('malformed payload receipt rejects before entitlement, credit reserve, or provider call', async () => {
  const cases: Array<[string, Partial<BrokerRequest>, string]> = [
    ['invalid request id', { request_id: 'not-a-uuid' }, 'invalid_request_id'],
    ['invalid payload hash', { payload_hash: 'not-a-sha-256-hex-digest' }, 'invalid_payload_hash'],
    ['invalid payload class', { approved_payload_class: 'raw_notes' }, 'payload_class_mismatch'],
  ];

  for (const [name, overrides, expectedCode] of cases) {
    await test(name, async () => {
      const trace: string[] = [];
      const deps = createFakeBrokerDependencies({ orderTrace: trace });

      const response = await handleResearchRequest(
        request(overrides),
        { ...baseContext, entitled: false, credit_available: false, breaker_open: true },
        deps,
      );

      assert.equal(response.status, 'rejected');
      assert.equal(response.error?.code, expectedCode);
      assert.equal(response.error?.stage, 'payload_receipt');
      assert.equal(deps.provider.callCount, 0);
      assert.equal(deps.creditLedger.reserveCount, 0);
      assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt']);
    });
  }
});

test('same request id with a changed payload hash returns conflict without another provider call', async () => {
  const deps = createFakeBrokerDependencies();
  const first = await handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({ payload_hash: 'b'.repeat(64) }),
    baseContext,
    deps,
  );

  assert.equal(first.status, 'completed');
  assert.equal(second.status, 'conflict');
  assert.equal(second.error?.code, 'idempotency_conflict');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
});

test('same request id and same payload hash replays without another provider call or debit', async () => {
  const deps = createFakeBrokerDependencies();
  await handleResearchRequest(request(), baseContext, deps);

  const replay = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(replay.status, 'completed');
  assert.equal(replay.replayed, true);
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
});

test('broker scaffold has no secret-value lookup requirement', async () => {
  const brokerSource = await readFile(new URL('../src/broker.js', import.meta.url), 'utf8');
  const fakeProviderSource = await readFile(new URL('../src/fake_provider.js', import.meta.url), 'utf8');
  assert.equal(brokerSource.includes('process.env'), false);
  assert.equal(fakeProviderSource.includes('process.env'), false);
  const deps = createFakeBrokerDependencies();
  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'completed');
  assert.equal(deps.provider.callCount, 1);
});
