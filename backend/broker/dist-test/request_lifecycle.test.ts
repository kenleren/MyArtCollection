import assert from 'node:assert/strict';
import test from 'node:test';

import { InMemoryRequestLifecycle } from '../src/request_lifecycle.js';
import { FIXED_NOW, baseContext, request } from './test_helpers.js';

function input(now: Date) {
  const current = request();
  return {
    quota_subject: baseContext.quota_subject,
    request_id: current.request_id,
    payload_hash: current.payload_hash,
    credit_cost: 1 as const,
    now,
  };
}

test('reservation lease is active before 60 seconds and expires exactly at the boundary', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const first = await lifecycle.acquire(input(FIXED_NOW));
  assert.equal(first.kind, 'reserved');
  assert.equal(
    (await lifecycle.acquire(input(new Date(FIXED_NOW.getTime() + 59_999)))).kind,
    'in_flight',
  );

  const boundary = await lifecycle.acquire(input(new Date(FIXED_NOW.getTime() + 60_000)));
  assert.equal(boundary.kind, 'replay');
  if (boundary.kind === 'replay') {
    assert.equal(boundary.outcome.kind, 'error');
    await lifecycle.settle(boundary.record);
  }
  assert.equal(lifecycle.refundCount, 1);
});

test('dispatch_started remains ambiguous after lease expiry and is never redriven', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const acquired = await lifecycle.acquire(input(FIXED_NOW));
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    return;
  }
  await lifecycle.markDispatchStarted(acquired.record, FIXED_NOW);
  assert.equal(
    (await lifecycle.acquire(input(new Date(FIXED_NOW.getTime() + 59_999)))).kind,
    'in_flight',
  );
  assert.equal(
    (await lifecycle.acquire(input(new Date(FIXED_NOW.getTime() + 60_000)))).kind,
    'outcome_unknown',
  );
  assert.equal(lifecycle.reserveCount, 1);
  assert.equal(lifecycle.refundCount, 0);
});

test('dispatch compare-and-set rejects the exact lease boundary and refunds', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const acquired = await lifecycle.acquire(input(FIXED_NOW));
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    return;
  }
  const dispatch = await lifecycle.markDispatchStarted(
    acquired.record,
    new Date(FIXED_NOW.getTime() + 60_000),
  );
  assert.equal(dispatch.kind, 'lease_expired');
  if (dispatch.kind === 'lease_expired') {
    await lifecycle.settle(dispatch.record);
  }
  assert.equal(lifecycle.refundCount, 1);
});

test('retention expiry is a deletion signal only and never changes replay behavior', async () => {
  const lifecycle = new InMemoryRequestLifecycle();
  const acquired = await lifecycle.acquire(input(FIXED_NOW));
  assert.equal(acquired.kind, 'reserved');
  if (acquired.kind !== 'reserved') {
    return;
  }
  await lifecycle.persistTerminal(acquired.record, {
    kind: 'error',
    failure: { request_id: request().request_id, condition: 'provider_timeout' },
  }, 'refund');
  await lifecycle.settle(acquired.record);

  const replay = await lifecycle.acquire(input(new Date(FIXED_NOW.getTime() + 86_400_001)));
  assert.equal(replay.kind, 'replay');
});
