import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  APPROVED_PAYLOAD_CLASS,
  CURRENT_CONSENT_COPY_VERSION,
  CURRENT_PAYLOAD_CONTRACT_VERSION,
  type BrokerContext,
  type BrokerRequest,
  type BrokerResearchOutput,
  type ProviderClient,
} from '../src/contracts.js';
import { createFakeBrokerDependencies, handleResearchRequest } from '../src/broker.js';
import { PlaceholderCreditLedger } from '../src/credit_ledger.js';

const baseContext = Object.freeze({
  app_check_verified: true,
  auth_verified: true,
  auth_identity: {
    uid: 'anonymous-test-uid',
    project_id: 'local-broker-project',
    sign_in_provider: 'anonymous',
  },
  app_identity: {
    app_id: 'local-ios-app',
    project_id: 'local-broker-project',
  },
  quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
  entitled: true,
  credit_available: true,
  breaker_open: false,
} satisfies BrokerContext);

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

function invalidOutput(): BrokerResearchOutput {
  return {
    sources: [
      {
        source_id: 'src_bad_url',
        source_name: 'Invalid Fixture',
        source_type: 'museum',
        source_url: 'http://example.invalid/not-https',
        title: 'Invalid source URL fixture',
        accessed_at: new Date('2026-07-06T00:00:00.000Z').toISOString(),
        citation_excerpt: 'Fixture excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  };
}

class StaticProvider implements ProviderClient {
  callCount = 0;

  constructor(private readonly output: BrokerResearchOutput) {}

  async research(_request: BrokerRequest): Promise<BrokerResearchOutput> {
    this.callCount += 1;
    return this.output;
  }
}

class ThrowingProvider implements ProviderClient {
  callCount = 0;

  async research(_request: BrokerRequest): Promise<BrokerResearchOutput> {
    this.callCount += 1;
    throw new Error('fake provider failure');
  }
}

class SlowProvider implements ProviderClient {
  callCount = 0;
  private releaseProvider!: () => void;
  readonly release = new Promise<void>((resolve) => {
    this.releaseProvider = resolve;
  });

  async research(_request: BrokerRequest): Promise<BrokerResearchOutput> {
    this.callCount += 1;
    await this.release;
    return {
      sources: [
        {
          source_id: 'src_slow',
          source_name: 'Slow Fixture',
          source_type: 'museum',
          source_url: 'https://museum.example/research/slow',
          title: 'Slow collection record',
          accessed_at: new Date('2026-07-06T00:00:00.000Z').toISOString(),
          citation_excerpt: 'Slow fixture excerpt.',
          matched_fields: ['title'],
        },
      ],
      candidate_attributions: [
        {
          candidate_id: 'candidate_slow',
          confidence: 'possible',
          match_reason: 'Slow fixture result.',
          field_sources: { title: 'ai_suggested' },
          source_refs: ['src_slow'],
        },
      ],
      comparable_value_signals: [],
      warnings: [],
    };
  }

  resolve(): void {
    this.releaseProvider();
  }
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
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['finalized']);
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

test('unauthenticated request rejects before consent, payload, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing', payload_contract_version: 'old' }),
    { ...baseContext, app_check_verified: false },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'unauthorized');
  assert.equal(response.error?.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth']);
});

test('missing quota subject rejects before consent, payload, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing', payload_contract_version: 'old' }),
    { ...baseContext, quota_subject: '' },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_quota_subject');
  assert.equal(response.error?.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth']);
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
  assert.equal(deps.creditLedger.records.length, 0);
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
  assert.equal(deps.creditLedger.records.length, 0);
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
  assert.equal(deps.creditLedger.records.length, 0);
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
      assert.equal(deps.creditLedger.records.length, 0);
      assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt']);
    });
  }
});

test('malformed payload body rejects before credit reserve or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ image: { mime_type: 'image/jpeg', byte_size: 1_500_001, long_edge_px: 1400 } }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_image_size');
  assert.equal(response.error?.stage, 'payload');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement', 'breaker', 'payload']);
});

test('unsupported image MIME type rejects before credit reserve or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({
      image: {
        mime_type: 'image/png' as BrokerRequest['image']['mime_type'],
        byte_size: 120_000,
        long_edge_px: 1400,
      },
    }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'unsupported_image_mime_type');
  assert.equal(response.error?.stage, 'payload');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement', 'breaker', 'payload']);
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
  assert.equal(deps.creditLedger.finalizeCount, 1);
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
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('concurrent same request id and payload hash shares one in-flight provider call and debit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({ provider });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = handleResearchRequest(request(), baseContext, deps);
  provider.resolve();

  const [firstResponse, secondResponse] = await Promise.all([first, second]);

  assert.equal(firstResponse.status, 'completed');
  assert.equal(secondResponse.status, 'completed');
  assert.equal(secondResponse.replayed, true);
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('concurrent distinct requests under subject cap reserve only one in-flight credit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({
    provider,
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 1, brokerMonthlyCap: 100 }),
  });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({
      request_id: '22222222-2222-4222-8222-222222222222',
      payload_hash: 'b'.repeat(64),
    }),
    baseContext,
    deps,
  );
  provider.resolve();
  const firstResponse = await first;

  assert.equal(firstResponse.status, 'completed');
  assert.equal(second.status, 'rejected');
  assert.equal(second.error?.code, 'quota_subject_monthly_cap_exceeded');
  assert.equal(second.error?.stage, 'credit_reserve');
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.exposedCreditsFor(baseContext.quota_subject), 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), [
    'finalized',
    'rejected-before-reserve',
  ]);
});

test('concurrent distinct requests under broker cap reserve only one in-flight credit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({
    provider,
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 100, brokerMonthlyCap: 1 }),
  });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({
      request_id: '22222222-2222-4222-8222-222222222222',
      payload_hash: 'b'.repeat(64),
    }),
    { ...baseContext, quota_subject: 'quota_subject_v1_bbbbbbbbbbbbbbbb' },
    deps,
  );
  provider.resolve();
  const firstResponse = await first;

  assert.equal(firstResponse.status, 'completed');
  assert.equal(second.status, 'rejected');
  assert.equal(second.error?.code, 'broker_monthly_cap_exceeded');
  assert.equal(second.error?.stage, 'credit_reserve');
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.exposedCredits, 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), [
    'finalized',
    'rejected-before-reserve',
  ]);
});

test('provider output validation failure finalizes the reservation and counts spend', async () => {
  const deps = createFakeBrokerDependencies({
    provider: new StaticProvider(invalidOutput()),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_source_url');
  assert.equal(response.error?.stage, 'output_validation');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.refundCount, 0);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['finalized']);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('provider exception refunds the reserved credit and does not count spend', async () => {
  const deps = createFakeBrokerDependencies({
    provider: new ThrowingProvider(),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'provider_failure');
  assert.equal(response.error?.stage, 'provider');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 0);
  assert.equal(deps.creditLedger.refundCount, 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['refunded']);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 0);
});

test('per-user monthly cap placeholder fails closed before provider call', async () => {
  const deps = createFakeBrokerDependencies({
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 0 }),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'quota_subject_monthly_cap_exceeded');
  assert.equal(response.error?.stage, 'credit_reserve');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records[0].state, 'rejected-before-reserve');
});

test('broker monthly cap placeholder fails closed before provider call', async () => {
  const deps = createFakeBrokerDependencies({
    creditLedger: new PlaceholderCreditLedger({ brokerMonthlyCap: 0 }),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'broker_monthly_cap_exceeded');
  assert.equal(response.error?.stage, 'credit_reserve');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records[0].state, 'rejected-before-reserve');
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
