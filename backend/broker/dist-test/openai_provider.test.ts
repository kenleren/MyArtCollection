import assert from 'node:assert/strict';
import test from 'node:test';

import { createFakeBrokerDependencies, handleResearchRequest } from '../src/broker.js';
import type { BrokerRequest } from '../src/contracts.js';
import {
  DEFAULT_PROVIDER_TIMEOUT_MILLISECONDS,
  buildOpenAiResponsesRequest,
  createOpenAiProvider,
} from '../src/openai_provider.js';
import { authorizeProviderRequest } from '../src/provider_authorization.js';
import { InMemoryRequestLifecycle } from '../src/request_lifecycle.js';
import { FirestoreDurableBrokerStore } from '../src/durable_protection.js';
import { FIXED_NOW, baseContext, request, seededFirestore } from './test_helpers.js';

test('direct provider use without broker authorization cannot fetch', async () => {
  let fetchCalls = 0;
  const provider = createOpenAiProvider({
    apiKey: 'test-only-key',
    allowedDomains: ['museum.example'],
    fetchImpl: (async () => {
      fetchCalls += 1;
      throw new Error('must not fetch');
    }) as typeof fetch,
  });
  assert.deepEqual(await provider.research(request()), { kind: 'failure' });
  assert.equal(fetchCalls, 0);
});

test('provider maps rate limits without reading response content', async () => {
  const current = request();
  authorizeProviderRequest(current);
  const provider = createOpenAiProvider({
    apiKey: 'test-only-key',
    allowedDomains: ['museum.example'],
    fetchImpl: (async () => new Response('', {
      status: 429,
      headers: { 'Retry-After': '999' },
    })) as typeof fetch,
  });
  assert.deepEqual(await provider.research(current), {
    kind: 'rate_limited',
    retry_after_seconds: 999,
  });
});

test('provider uses only the remaining handler-wide deadline budget', async () => {
  let scheduledDelay: number | undefined;
  const current = request();
  authorizeProviderRequest(current);
  const provider = createOpenAiProvider({
    apiKey: 'test-only-key',
    allowedDomains: ['museum.example'],
    providerDeadlineAtMs: 10_000,
    nowMilliseconds: () => 9_250,
    scheduleTimeout: (_callback, delayMs) => {
      scheduledDelay = delayMs;
      return 1 as unknown as ReturnType<typeof setTimeout>;
    },
    cancelTimeout: () => {},
    fetchImpl: (async () => new Response('', { status: 429 })) as typeof fetch,
  });
  await provider.research(current);
  assert.equal(scheduledDelay, 750);
});

test('provider rejects an expired absolute deadline before timer creation or fetch', async () => {
  let timerCalls = 0;
  let fetchCalls = 0;
  const current = request();
  authorizeProviderRequest(current);
  const provider = createOpenAiProvider({
    apiKey: 'test-only-key',
    allowedDomains: ['museum.example'],
    providerDeadlineAtMs: 1_000,
    nowMilliseconds: () => 2_000,
    scheduleTimeout: () => {
      timerCalls += 1;
      return 1 as unknown as ReturnType<typeof setTimeout>;
    },
    fetchImpl: (async () => {
      fetchCalls += 1;
      return new Response('', { status: 429 });
    }) as typeof fetch,
  });

  assert.deepEqual(await provider.research(current), { kind: 'timeout' });
  assert.equal(provider.callCount, 0);
  assert.equal(timerCalls, 0);
  assert.equal(fetchCalls, 0);
});

test('provider deadline aborts before the Function timeout and persists terminal timeout refund', async () => {
  let scheduledDelay: number | undefined;
  let fireTimeout: (() => void) | undefined;
  let cancelCount = 0;
  let fetchCalls = 0;
  let capturedSignal: AbortSignal | undefined;
  const provider = createOpenAiProvider({
    apiKey: 'test-only-key',
    allowedDomains: ['museum.example'],
    scheduleTimeout: (callback, delayMs) => {
      fireTimeout = callback;
      scheduledDelay = delayMs;
      return 1 as unknown as ReturnType<typeof setTimeout>;
    },
    cancelTimeout: () => {
      cancelCount += 1;
    },
    fetchImpl: (async (_input, init) => {
      fetchCalls += 1;
      capturedSignal = init?.signal as AbortSignal;
      return new Promise<Response>((_resolve, reject) => {
        capturedSignal?.addEventListener('abort', () => {
          reject(new DOMException('aborted by fake deadline', 'AbortError'));
        }, { once: true });
      });
    }) as typeof fetch,
  });
  const lifecycle = new InMemoryRequestLifecycle();
  const dependencies = createFakeBrokerDependencies({
    requestLifecycle: lifecycle,
    providerProvisioner: {
      configure: () => ({}),
      construct: () => provider,
    },
    authorizeProvider: authorizeProviderRequest,
    now: () => FIXED_NOW,
    testProvider: provider,
  });

  const pending = handleResearchRequest(request(), baseContext, dependencies);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(scheduledDelay, DEFAULT_PROVIDER_TIMEOUT_MILLISECONDS);
  assert.equal(DEFAULT_PROVIDER_TIMEOUT_MILLISECONDS < 60_000, true);
  assert.equal(capturedSignal instanceof AbortSignal, true);
  assert.equal(capturedSignal?.aborted, false);
  fireTimeout?.();

  const result = await pending;
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.failure.condition, 'provider_timeout');
  }
  assert.equal(capturedSignal?.aborted, true);
  assert.equal(fetchCalls, 1);
  assert.equal(cancelCount, 1);
  assert.equal(lifecycle.refundCount, 1);

  const replay = await handleResearchRequest(request(), baseContext, dependencies);
  assert.equal(replay.ok, false);
  if (!replay.ok) {
    assert.equal(replay.failure.condition, 'provider_timeout');
    assert.equal(replay.failure.replayed, true);
  }
  assert.equal(fetchCalls, 1);
  assert.equal(lifecycle.refundCount, 1);
});

test('OpenAI request remains minimized, stateless, and allowlisted', () => {
  const current: BrokerRequest = request({
    consent_scope: 'image_plus_draft_hints',
    draft_hints: { title_hint: 'Fixture', search_terms: ['fixture'] },
  });
  const body = buildOpenAiResponsesRequest(current, {
    allowedDomains: ['museum.example'],
    externalWebAccess: false,
    modelName: 'test-model',
    reasoningEffort: 'high',
    searchContextSize: 'medium',
  });
  const serialized = JSON.stringify(body);
  assert.equal(body.store, false);
  assert.equal(body.prompt_cache_retention, 'in_memory');
  assert.equal(body.max_output_tokens, 8192);
  assert.equal(body.max_tool_calls, 4);
  assert.equal(serialized.includes('museum.example'), true);
  assert.equal(serialized.includes('previous_response_id'), false);
  assert.equal(serialized.includes('request_id'), false);
  assert.equal(serialized.includes('payload_hash'), false);
});

test('authorized dispatch refuses redirects and sends bounded retention settings without retries', async () => {
  let calls = 0;
  const current = request();
  authorizeProviderRequest(current);
  const provider = createOpenAiProvider({ apiKey: 'test-only-key', allowedDomains: ['museum.example'],
    fetchImpl: (async (_url, init) => {
      calls++;
      assert.equal(init?.redirect, 'error');
      const body = JSON.parse(init?.body as string);
      assert.equal(body.store, false);
      assert.equal(body.prompt_cache_retention, 'in_memory');
      assert.equal(body.max_output_tokens, 8192);
      assert.equal(body.max_tool_calls, 4);
      return new Response('', { status: 302, headers: { location: 'https://unapproved.invalid' } });
    }) as typeof fetch });
  assert.deepEqual(await provider.research(current), { kind: 'failure' });
  assert.deepEqual(await provider.research(current), { kind: 'failure' });
  assert.equal(calls, 1);
});

test('only completed provider runs become completed research; truncated, failed and refused runs stay charged', async () => {
  const structured = JSON.stringify({ sources: [], candidate_attributions: [], comparable_value_signals: [], warnings: [] });
  const message = { type: 'message', status: 'completed', content: [{ type: 'output_text', text: structured }] };
  const completed = { status: 'completed', output: [message] };
  const cases = [
    { name: 'completed', body: completed, success: true },
    { name: 'token limit', body: { ...completed, status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } }, success: false },
    { name: 'incomplete message', body: { ...completed, output: [{ ...message, status: 'incomplete' }] }, success: false },
    { name: 'failed search', body: { ...completed, output: [{ type: 'web_search_call', status: 'failed' }, message] }, success: false },
    { name: 'provider error', body: { ...completed, error: { message: 'synthetic-private-provider-detail' } }, success: false },
    { name: 'missing completion status', body: { output: [message] }, success: false },
    { name: 'refusal', body: { ...completed, output: [{ ...message, content: [{ type: 'refusal' }] }] }, success: false },
  ];
  for (const scenario of cases) {
    const db = seededFirestore();
    db.seed('brokerDurableControl/providerBudget', { record_version: 'broker-provider-budget-v1',
      dispatchLimit: 1, dispatchCount: 0, expiresAt: '2026-07-10T12:00:00.000Z' });
    const store = new FirestoreDurableBrokerStore(db, { requireProviderBudget: true });
    let calls = 0;
    const provider = createOpenAiProvider({ apiKey: 'test-only-key', allowedDomains: ['museum.example'],
      fetchImpl: (async () => { calls++; return new Response(JSON.stringify(scenario.body), { status: 200 }); }) as typeof fetch });
    const deps = createFakeBrokerDependencies({ requestLifecycle: store.createRequestLifecycle(),
      providerProvisioner: { configure: () => ({}), construct: () => provider },
      authorizeProvider: authorizeProviderRequest, now: () => FIXED_NOW });
    const result = await handleResearchRequest(request(), baseContext, deps);
    assert.equal(result.ok, scenario.success, scenario.name);
    assert.equal(JSON.stringify(result).includes('synthetic-private-provider-detail'), false);
    assert.equal(db.read('brokerDurableControl/providerBudget')?.dispatchCount, 1);
    await handleResearchRequest(request(), baseContext, deps);
    assert.equal(calls, 1, 'same request never repeats the paid dispatch');
  }
});
