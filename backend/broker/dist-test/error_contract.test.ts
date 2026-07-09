import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import {
  BROKER_ERROR_DEFINITIONS,
  brokerErrorEnvelope,
  clampRetryAfterSeconds,
  type BrokerErrorCondition,
} from '../src/error_contract.js';

interface ErrorFixture {
  contract_version: string;
  cases: Array<{
    condition: BrokerErrorCondition;
    http_status: number;
    code: string;
    message: string;
    retryable: boolean;
    retry_after_seconds?: number;
  }>;
}

test('broker-error-v1 fixture exhaustively matches every internal condition', async () => {
  const fixture = JSON.parse(
    await readFile(new URL('../../fixtures/broker-error-v1.json', import.meta.url), 'utf8'),
  ) as ErrorFixture;
  assert.equal(fixture.contract_version, 'broker-error-v1');
  assert.deepEqual(
    fixture.cases.map((entry) => entry.condition).sort(),
    Object.keys(BROKER_ERROR_DEFINITIONS).sort(),
  );
  for (const entry of fixture.cases) {
    assert.deepEqual(BROKER_ERROR_DEFINITIONS[entry.condition], {
      http_status: entry.http_status,
      code: entry.code,
      message: entry.message,
      retryable: entry.retryable,
      ...(entry.retry_after_seconds === undefined
        ? {}
        : { retry_after_seconds: entry.retry_after_seconds }),
    });
  }
});

test('error envelopes are versioned, fixed-shape, and sanitized', () => {
  const envelope = brokerErrorEnvelope('wrong_project_auth', '11111111-1111-4111-8111-111111111111');
  assert.deepEqual(envelope, {
    status: 401,
    body: {
      ok: false,
      error_contract_version: 'broker-error-v1',
      request_id: '11111111-1111-4111-8111-111111111111',
      status: 'rejected',
      error: {
        code: 'unauthorized',
        message: 'Authentication could not be verified.',
        retryable: false,
      },
    },
  });
  assert.equal(JSON.stringify(envelope).includes('project'), false);
});

test('rate-limit retry delay defaults and clamps to 5-300 seconds', () => {
  assert.equal(clampRetryAfterSeconds(undefined), 30);
  assert.equal(clampRetryAfterSeconds(Number.NaN), 30);
  assert.equal(clampRetryAfterSeconds(1), 5);
  assert.equal(clampRetryAfterSeconds(5.1), 6);
  assert.equal(clampRetryAfterSeconds(301), 300);
  assert.equal(brokerErrorEnvelope('provider_rate_limited', undefined, 2).body.error.retry_after_seconds, 5);
  assert.equal(brokerErrorEnvelope('provider_rate_limited', undefined, 500).body.error.retry_after_seconds, 300);
});
