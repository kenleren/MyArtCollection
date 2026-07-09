import assert from 'node:assert/strict';
import test from 'node:test';

import {
  createFakeBrokerDependencies,
  handleResearchRequest,
  type BrokerDependencies,
} from '../src/broker.js';
import type {
  BrokerContext,
  BrokerRequest,
  ProviderClient,
  ProviderResearchResult,
} from '../src/contracts.js';
import { InMemoryRequestLifecycle } from '../src/request_lifecycle.js';
import { FIXED_NOW, ResultProvider, baseContext, request, validOutput } from './test_helpers.js';

interface DependencyCounters {
  config: number;
  construction: number;
  authorization: number;
}

function dependencies(options: {
  lifecycle?: InMemoryRequestLifecycle;
  provider?: ProviderClient;
  trace?: string[];
  now?: () => Date;
  configFailure?: boolean;
  constructionFailure?: boolean;
  authorizationFailure?: boolean;
} = {}): { deps: BrokerDependencies; counters: DependencyCounters; provider: ProviderClient } {
  const counters = { config: 0, construction: 0, authorization: 0 };
  const provider = options.provider ?? new ResultProvider();
  const deps = createFakeBrokerDependencies({
    requestLifecycle: options.lifecycle ?? new InMemoryRequestLifecycle(),
    providerProvisioner: {
      configure: () => {
        counters.config += 1;
        if (options.configFailure) {
          throw new Error('injected config failure');
        }
        return { mode: 'fake' };
      },
      construct: () => {
        counters.construction += 1;
        if (options.constructionFailure) {
          throw new Error('injected construction failure');
        }
        return provider;
      },
    },
    authorizeProvider: () => {
      counters.authorization += 1;
      if (options.authorizationFailure) {
        throw new Error('injected authorization failure');
      }
    },
    now: options.now ?? (() => FIXED_NOW),
    orderTrace: options.trace,
    testProvider: provider,
  });
  return { deps, counters, provider };
}

test('successful request follows the exact gate and provider order', async () => {
  const trace: string[] = [];
  const lifecycle = new InMemoryRequestLifecycle();
  const { deps, counters, provider } = dependencies({ lifecycle, trace });
  const result = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(result.ok, true);
  assert.equal(provider.callCount, 1);
  assert.deepEqual(counters, { config: 1, construction: 1, authorization: 1 });
  assert.equal(lifecycle.reserveCount, 1);
  assert.equal(lifecycle.finalizeCount, 1);
  assert.deepEqual(trace, [
    'auth_context',
    'consent',
    'entitlement',
    'breaker',
    'canonical_payload',
    'idempotency_replay',
    'credit_reservation',
    'provider_config',
    'provider_construction',
    'provider_authorization',
    'dispatch_persistence',
    'provider_fetch',
    'output_validation',
    'terminal_persistence',
    'credit_finalize',
  ]);
});

test('every precheck rejection performs zero provider config, construction, authorization, or fetch', async () => {
  const cases: Array<{ name: string; request: BrokerRequest; context: BrokerContext; condition: string }> = [
    {
      name: 'invalid auth',
      request: request(),
      context: { ...baseContext, auth_verified: false },
      condition: 'invalid_auth_token',
    },
    {
      name: 'missing consent',
      request: request({ consent_status: 'missing' }),
      context: baseContext,
      condition: 'consent_required',
    },
    {
      name: 'not entitled',
      request: request(),
      context: { ...baseContext, entitled: false },
      condition: 'not_entitled',
    },
    {
      name: 'breaker open',
      request: request(),
      context: { ...baseContext, breaker_open: true },
      condition: 'broker_breaker_open',
    },
    {
      name: 'hash mismatch',
      request: request({ payload_hash: 'f'.repeat(64) }),
      context: baseContext,
      condition: 'payload_hash_mismatch',
    },
  ];

  for (const current of cases) {
    await test(current.name, async () => {
      const lifecycle = new InMemoryRequestLifecycle();
      const { deps, counters, provider } = dependencies({ lifecycle });
      const result = await handleResearchRequest(current.request, current.context, deps);
      assert.equal(result.ok, false);
      if (!result.ok) {
        assert.equal(result.failure.condition, current.condition);
      }
      assert.deepEqual(counters, { config: 0, construction: 0, authorization: 0 });
      assert.equal(provider.callCount, 0);
      assert.equal(lifecycle.reserveCount, 0);
    });
  }
});

test('completed replay is free even when no additional credits are available', async () => {
  const lifecycle = new InMemoryRequestLifecycle({ perSubjectCreditCap: 1 });
  const { deps, counters, provider } = dependencies({ lifecycle });
  const first = await handleResearchRequest(request(), baseContext, deps);
  const replay = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(first.ok, true);
  assert.equal(replay.ok, true);
  if (replay.ok) {
    assert.equal(replay.response.replayed, true);
  }
  assert.equal(provider.callCount, 1);
  assert.equal(counters.config, 1);
  assert.equal(lifecycle.reserveCount, 1);
  assert.equal(lifecycle.finalizeCount, 1);
});

test('entitlement and breaker are rechecked before completed replay', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const { deps, provider } = dependencies({ lifecycle });
  assert.equal((await handleResearchRequest(request(), baseContext, deps)).ok, true);

  const notEntitled = await handleResearchRequest(
    request(),
    { ...baseContext, entitled: false },
    deps,
  );
  const breakerOpen = await handleResearchRequest(
    request(),
    { ...baseContext, breaker_open: true },
    deps,
  );
  assert.equal(notEntitled.ok, false);
  assert.equal(breakerOpen.ok, false);
  if (!notEntitled.ok) {
    assert.equal(notEntitled.failure.condition, 'not_entitled');
  }
  if (!breakerOpen.ok) {
    assert.equal(breakerOpen.failure.condition, 'broker_breaker_open');
  }
  assert.equal(provider.callCount, 1);
});

test('same request ID with a different canonical payload conflicts before provider setup', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const { deps, counters, provider } = dependencies({ lifecycle });
  await handleResearchRequest(request(), baseContext, deps);
  const changed = request({
    image: { mime_type: 'image/jpeg', byte_size: 3, long_edge_px: 1600, content_base64: 'BAUG' },
  });
  const conflict = await handleResearchRequest(changed, baseContext, deps);

  assert.equal(conflict.ok, false);
  if (!conflict.ok) {
    assert.equal(conflict.failure.condition, 'idempotency_conflict');
  }
  assert.equal(provider.callCount, 1);
  assert.equal(counters.config, 1);
});

test('concurrent duplicate and distinct requests cannot double dispatch', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const provider = new ResultProvider().makeSlow();
  const { deps } = dependencies({ lifecycle, provider });
  const first = handleResearchRequest(request(), baseContext, deps);
  await new Promise<void>((resolve) => setImmediate(resolve));

  const duplicate = await handleResearchRequest(request(), baseContext, deps);
  const distinct = await handleResearchRequest(
    request({ request_id: '22222222-2222-4222-8222-222222222222' }),
    baseContext,
    deps,
  );
  assert.equal(duplicate.ok, false);
  assert.equal(distinct.ok, false);
  if (!duplicate.ok) {
    assert.equal(duplicate.failure.condition, 'quota_subject_in_flight');
  }
  if (!distinct.ok) {
    assert.equal(distinct.failure.condition, 'quota_subject_in_flight');
  }
  assert.equal(provider.callCount, 1);
  assert.equal(lifecycle.reserveCount, 1);
  provider.release();
  assert.equal((await first).ok, true);
});

test('provider outcome table applies terminal refund/finalize semantics', async () => {
  const cases: Array<{
    result: ProviderResearchResult;
    condition?: string;
    settlement: 'refunded' | 'finalized';
  }> = [
    { result: { kind: 'rate_limited', retry_after_seconds: 999 }, condition: 'provider_rate_limited', settlement: 'refunded' },
    { result: { kind: 'refusal' }, condition: 'provider_refusal', settlement: 'finalized' },
    { result: { kind: 'timeout' }, condition: 'provider_timeout', settlement: 'refunded' },
    { result: { kind: 'failure' }, condition: 'provider_failure', settlement: 'finalized' },
    { result: { kind: 'invalid_output' }, condition: 'provider_invalid_output', settlement: 'finalized' },
    { result: { kind: 'success', output: validOutput() }, settlement: 'finalized' },
  ];

  for (const current of cases) {
    const lifecycle = new InMemoryRequestLifecycle();
    const { deps } = dependencies({ lifecycle, provider: new ResultProvider(current.result) });
    const result = await handleResearchRequest(request(), baseContext, deps);
    if (current.condition === undefined) {
      assert.equal(result.ok, true);
    } else {
      assert.equal(result.ok, false);
      if (!result.ok) {
        assert.equal(result.failure.condition, current.condition);
      }
    }
    assert.equal(lifecycle.finalizeCount, current.settlement === 'finalized' ? 1 : 0);
    assert.equal(lifecycle.refundCount, current.settlement === 'refunded' ? 1 : 0);
  }
});

test('invalid normalized output finalizes spend', async () => {
  const output = validOutput();
  output.sources[0].source_url = 'http://not-https.example';
  const lifecycle = new InMemoryRequestLifecycle();
  const { deps } = dependencies({ lifecycle, provider: new ResultProvider({ kind: 'success', output }) });
  const result = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(result.ok, false);
  assert.equal(lifecycle.finalizeCount, 1);
});

test('config, construction, and authorization failures terminalize then refund without fetch', async () => {
  for (const point of ['configFailure', 'constructionFailure', 'authorizationFailure'] as const) {
    const lifecycle = new InMemoryRequestLifecycle();
    const setup = dependencies({ lifecycle, [point]: true });
    const result = await handleResearchRequest(request(), baseContext, setup.deps);
    assert.equal(result.ok, false, point);
    assert.equal(setup.provider.callCount, 0, point);
    assert.equal(lifecycle.refundCount, 1, point);
  }
});

test('failed dispatch persistence forbids fetch and replays the terminal failure', async () => {
  const lifecycle = new InMemoryRequestLifecycle({
    faults: { dispatch_persistence: () => { throw new Error('injected'); } },
  });
  const { deps, provider, counters } = dependencies({ lifecycle });
  const first = await handleResearchRequest(request(), baseContext, deps);
  const replay = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(first.ok, false);
  assert.equal(replay.ok, false);
  if (!replay.ok) {
    assert.equal(replay.failure.condition, 'dispatch_persistence_failure');
    assert.equal(replay.failure.replayed, true);
  }
  assert.equal(provider.callCount, 0);
  assert.equal(counters.config, 1);
  assert.equal(lifecycle.refundCount, 1);
});

test('failed terminal persistence after dispatch never refunds, deletes, or redrives', async () => {
  let now = FIXED_NOW;
  const lifecycle = new InMemoryRequestLifecycle({
    faults: { terminal_persistence: () => { throw new Error('injected'); } },
  });
  const { deps, provider, counters } = dependencies({ lifecycle, now: () => now });
  const first = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(first.ok, false);
  assert.equal(provider.callCount, 1);
  assert.equal(lifecycle.refundCount, 0);
  assert.equal(lifecycle.finalizeCount, 0);

  now = new Date(FIXED_NOW.getTime() + 60_000);
  const replay = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(replay.ok, false);
  if (!replay.ok) {
    assert.equal(replay.failure.condition, 'dispatch_outcome_unknown');
  }
  assert.equal(provider.callCount, 1);
  assert.equal(counters.config, 1);
});

test('pending finalize is recovered idempotently on replay', async () => {
  let failOnce = true;
  const lifecycle = new InMemoryRequestLifecycle({
    faults: {
      finalize: () => {
        if (failOnce) {
          failOnce = false;
          throw new Error('injected finalize fault');
        }
      },
    },
  });
  const { deps, provider } = dependencies({ lifecycle });
  const first = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(first.ok, true);
  assert.equal(lifecycle.finalizeCount, 0);

  const replay = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(replay.ok, true);
  assert.equal(lifecycle.finalizeCount, 1);
  assert.equal(provider.callCount, 1);

  await handleResearchRequest(request(), baseContext, deps);
  assert.equal(lifecycle.finalizeCount, 1);
});

test('pending refund is recovered idempotently on replay', async () => {
  let failOnce = true;
  const lifecycle = new InMemoryRequestLifecycle({
    faults: {
      refund: () => {
        if (failOnce) {
          failOnce = false;
          throw new Error('injected refund fault');
        }
      },
    },
  });
  const { deps, provider } = dependencies({
    lifecycle,
    provider: new ResultProvider({ kind: 'timeout' }),
  });
  const first = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(first.ok, false);
  assert.equal(lifecycle.refundCount, 0);

  const replay = await handleResearchRequest(request(), baseContext, deps);
  assert.equal(replay.ok, false);
  assert.equal(lifecycle.refundCount, 1);
  assert.equal(provider.callCount, 1);

  await handleResearchRequest(request(), baseContext, deps);
  assert.equal(lifecycle.refundCount, 1);
});

test('legacy and malformed durable records fail closed before provider setup', async () => {
  for (const raw of [
    { payload_hash: request().payload_hash, state: 'completed' },
    { record_version: 'unknown-v2', state: 'terminal' },
    { record_version: 'broker-request-lifecycle-v1', state: 'mystery' },
  ]) {
    const lifecycle = new InMemoryRequestLifecycle();
    lifecycle.seedRaw(baseContext.quota_subject, request().request_id, raw);
    const { deps, counters, provider } = dependencies({ lifecycle });
    const result = await handleResearchRequest(request(), baseContext, deps);
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(result.failure.condition, 'malformed_durable_record');
    }
    assert.equal(counters.config, 0);
    assert.equal(provider.callCount, 0);
  }
});
