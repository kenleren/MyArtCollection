import assert from 'node:assert/strict';
import test from 'node:test';

import type { BrokerRequest } from '../src/contracts.js';
import {
  buildOpenAiResponsesRequest,
  createOpenAiProvider,
} from '../src/openai_provider.js';
import { authorizeProviderRequest } from '../src/provider_authorization.js';
import { request } from './test_helpers.js';

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
  assert.equal(serialized.includes('museum.example'), true);
  assert.equal(serialized.includes('previous_response_id'), false);
  assert.equal(serialized.includes('request_id'), false);
  assert.equal(serialized.includes('payload_hash'), false);
});
