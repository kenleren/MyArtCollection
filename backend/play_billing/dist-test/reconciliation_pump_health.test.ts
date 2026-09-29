import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { FreeReason, VerifyResponse } from '../src/contracts.js';
import { BillingDeadline } from '../src/deadline.js';
import { ReconciliationPump, emptyReconciliationSummary, type ReconciliationOutcome } from '../src/reconciliation_pump.js';
import { reconciliationHandlers, reconciliationRuntimeConfiguration, ReconciliationPumpError } from '../src/reconciliation_runtime.js';
import { UnsafeBillingRecordError } from '../src/store.js';
import { testDispatchConfig } from './dispatch_fixtures.js';
import { TEST_KEY } from './fake_custody.js';

const sensitive = 'synthetic-identifier-must-not-reach-observer';

function response(status: string, reason = 'not_verified'): VerifyResponse {
  return { version: 'play-billing-v3', status, state: 'free', reason,
    requestId: sensitive, token: sensitive, providerError: sensitive } as unknown as VerifyResponse;
}

function fixture(results: Array<(deadline: BillingDeadline) => Promise<VerifyResponse | undefined>>) {
  const now = new Date();
  const subjects = results.map((_, index) => (index + 1).toString(16).padStart(64, '0'));
  let queries = 0;
  const visited: string[] = [];
  const pump = new ReconciliationPump({
    clock: { now: () => now },
    database: { dueReconciliationWork: async (_now, limit) => {
      queries++;
      assert.equal(limit, 10);
      return subjects.map((accountSubject, index) => ({ accountSubject,
        dueAt: new Date(+now - 1000),
        ...(index % 2 ? { lastSuccessfulVerificationAt: new Date(+now - 3_600_000) } : {}),
      }));
    } },
    processor: { processOne: async (subject, deadline) => {
      assert.ok(deadline);
      visited.push(subject);
      return results[subjects.indexOf(subject)]!(deadline);
    } },
  });
  return { pump, subjects, visited, queries: () => queries };
}

function secondMustNotRun(): Promise<never> {
  return Promise.reject(new Error('second account must not be processed'));
}

for (const status of ['rejected', 'unavailable', 'none']) {
  test('pump recognizes unsafe_record before ' + status + ' counting and stops the cohort', async () => {
    const h = fixture([async () => response(status, 'unsafe_record'), secondMustNotRun]);
    const summary = await h.pump.run(new BillingDeadline());
    assert.equal(summary.outcome, 'unsafe_state');
    assert.equal(summary.selectedCount, 2);
    assert.equal(summary.startedCount, 1);
    assert.equal(summary.notStartedCount, 1);
    assert.equal(summary.errorCount, 1);
    assert.equal(summary.inactiveCount, 0);
    assert.equal(summary.noneCount, 0);
    assert.equal(summary.rejectedCount, 0);
    assert.equal(summary.unavailableCount, 0);
    assert.deepEqual(h.visited, [h.subjects[0]]);
    assert.equal(h.queries(), 1);
    assert.equal(JSON.stringify(summary).includes(sensitive), false);
  });
}

for (const typed of [true, false]) {
  test('pump stops on ' + (typed ? 'typed unsafe' : 'generic') + ' exceptions without reading messages', async () => {
    const error = typed ? new UnsafeBillingRecordError() : new Error();
    let messageReads = 0;
    Object.defineProperty(error, 'message', { get() {
      messageReads++;
      throw new Error('message getter must never be inspected');
    } });
    const h = fixture([async () => { throw error; }, secondMustNotRun]);
    const summary = await h.pump.run(new BillingDeadline());
    assert.equal(summary.outcome, typed ? 'unsafe_state' : 'partial_failure');
    assert.equal(summary.errorCount, 1);
    assert.equal(summary.startedCount, 1);
    assert.equal(summary.notStartedCount, 1);
    assert.equal(messageReads, 0);
    assert.deepEqual(h.visited, [h.subjects[0]]);
  });
}

for (const kind of ['unsafe_response', 'unsafe_error', 'generic_error', 'paid_response']) {
  test('original cancellation takes precedence over ' + kind + ' and prevents another account', async () => {
    const h = fixture([async (deadline) => {
      deadline.cancel();
      if (kind === 'unsafe_error') throw new UnsafeBillingRecordError(sensitive);
      if (kind === 'generic_error') throw new Error(sensitive);
      return response(kind === 'paid_response' ? 'paid' : 'rejected', kind === 'paid_response' ? 'not_verified' : 'unsafe_record');
    }, secondMustNotRun]);
    const deadline = new BillingDeadline();
    const summary = await h.pump.run(deadline);
    assert.equal(summary.outcome, 'partial_deadline');
    assert.equal(summary.errorCount, 0);
    assert.equal(summary.paidCount, 0);
    assert.equal(summary.rejectedCount, 0);
    assert.equal(summary.startedCount, 1);
    assert.equal(summary.notStartedCount, 1);
    assert.equal(deadline.signal.aborted, true);
    assert.deepEqual(h.visited, [h.subjects[0]]);
  });
}

test('aggregate distinguishes explicit inactive observations from unavailable, absent and pending results', async () => {
  const inactive: FreeReason[] = ['expired', 'on_hold', 'paused', 'revoked'];
  const results = [
    ...inactive.map((reason) => response('none', reason)),
    response('none', 'no_known_purchase'), response('unavailable', 'temporarily_unavailable'),
    response('rejected', 'not_verified'), response('pending', 'play_pending'), undefined,
    { version: 'play-billing-v3', status: 'paid', requestId: sensitive,
      planId: 'starter', productId: 'archivale_starter_monthly', state: 'active',
      verifiedAt: new Date().toISOString(), playExpiresAt: new Date(Date.now() + 60_000).toISOString(),
      leaseExpiresAt: new Date(Date.now() + 60_000).toISOString() } as VerifyResponse,
  ];
  const h = fixture(results.map((result) => async () => result));
  const summary = await h.pump.run(new BillingDeadline());
  assert.equal(summary.outcome, 'batch_finished');
  assert.equal(summary.selectedCount, 10);
  assert.equal(summary.startedCount, 10);
  assert.equal(summary.notStartedCount, 0);
  assert.equal(summary.inactiveCount, 4);
  assert.equal(summary.noneCount, 1);
  assert.equal(summary.unavailableCount, 1);
  assert.equal(summary.rejectedCount, 1);
  assert.equal(summary.pendingCount, 1);
  assert.equal(summary.unclaimedCount, 1);
  assert.equal(summary.paidCount, 1);
  assert.equal(summary.errorCount, 0);
  assert.deepEqual(h.visited, h.subjects);
  const serialized = JSON.stringify(summary);
  assert.equal(serialized.includes(sensitive), false);
  for (const subject of h.subjects) assert.equal(serialized.includes(subject), false);
  for (const value of Object.values(summary)) assert.notEqual(typeof value, 'object');
  assert.deepEqual(Object.keys(summary).sort(), [
    'version', 'outcome', 'selectedCount', 'startedCount', 'notStartedCount', 'unclaimedCount',
    'paidCount', 'inactiveCount', 'noneCount', 'pendingCount', 'unavailableCount', 'rejectedCount',
    'errorCount', 'elapsedBucket', 'selectedOldestDueLagBucket',
    'selectedOldestKnownVerificationLagBucket', 'selectedMissingSuccessCount',
  ].sort());
});

for (const reason of ['not_verified', 'play_pending', 'verification_pending', 'recovery_required']) {
  test('none with ' + reason + ' is not reported as a fresh inactive subscription', async () => {
    const h = fixture([async () => response('none', reason)]);
    const summary = await h.pump.run(new BillingDeadline());
    assert.equal(summary.outcome, 'batch_finished');
    assert.equal(summary.noneCount, 1);
    assert.equal(summary.inactiveCount, 0);
  });
}

function configuration() {
  const value = reconciliationRuntimeConfiguration({
    GCLOUD_PROJECT: 'my-art-collections',
    PLAY_BILLING_RECONCILIATION_CONFIG: JSON.stringify({
      version: 'play-billing-reconciliation-runtime-v1', enabled: true,
      policy: { activeMs: 21_600_000, retryMs: 30_000, maxRetryMs: 900_000 },
    }),
    PLAY_BILLING_ROUTING_ENABLED: 'enabled', PLAY_BILLING_RECOVERY_ENABLED: 'enabled',
    PLAY_BILLING_ANDROID_PUBLISHER_ENABLED: 'enabled', PLAY_BILLING_TOKEN_CUSTODY_ENABLED: 'enabled',
    PLAY_BILLING_DISPATCH_CONFIG: JSON.stringify(testDispatchConfig()),
    PLAY_BILLING_TOKEN_KEY_VERSION: TEST_KEY, PLAY_BILLING_TOKEN_RETAINED_VERSIONS: TEST_KEY,
  });
  assert.ok(value);
  return value;
}

function latch() {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const transportFailures: Array<[ReconciliationOutcome, string]> = [
  ['configuration_unavailable', 'billing reconciliation configuration unavailable'],
  ['partial_failure', 'billing reconciliation partial failure'],
  ['unsafe_state', 'billing reconciliation unsafe state'],
  ['partial_deadline', 'billing reconciliation deadline unavailable'],
];
for (const [outcome, message] of transportFailures) {
  test('scheduler exposes only fixed ' + outcome + ' error after one frozen aggregate', async () => {
    let runs = 0, observations = 0;
    const summary = emptyReconciliationSummary(outcome);
    const handlers = reconciliationHandlers(configuration, () => ({ run: async () => {
      runs++;
      return summary;
    } }), (observed) => {
      observations++;
      assert.ok(Object.isFrozen(observed));
      assert.deepEqual(observed, summary);
    });
    await assert.rejects(handlers.pump(), (error: unknown) => {
      assert.ok(error instanceof ReconciliationPumpError);
      assert.equal(error.outcome, outcome);
      assert.equal(error.message, message);
      return true;
    });
    assert.deepEqual({ runs, observations }, { runs: 1, observations: 1 });
  });
}

test('scheduler construction never reads a hostile error message or reports its contents', async () => {
  const hostile = new Error();
  let reads = 0, creates = 0, output = '';
  Object.defineProperty(hostile, 'message', { get() {
    reads++;
    throw new Error(sensitive);
  } });
  const handlers = reconciliationHandlers(() => { throw hostile; }, () => {
    creates++;
    throw new Error(sensitive);
  }, (summary) => { output = JSON.stringify(summary); });
  await assert.rejects(handlers.pump(), /^Error: billing reconciliation configuration unavailable$/);
  assert.equal(reads, 0);
  assert.equal(creates, 0);
  assert.equal(output.includes(sensitive), false);
  assert.equal(JSON.parse(output).outcome, 'configuration_unavailable');
});

for (const kind of ['throw', 'reject']) {
  test('observer ' + kind + ' cannot change a completed batch or trigger another job', async () => {
    let runs = 0, observations = 0;
    const handlers = reconciliationHandlers(configuration, () => ({ run: async () => {
      runs++;
      return emptyReconciliationSummary('batch_finished');
    } }), () => {
      observations++;
      if (kind === 'throw') throw new Error(sensitive);
      return Promise.reject(new Error(sensitive));
    });
    const deadline = new BillingDeadline();
    const summary = await handlers.pump(deadline);
    assert.equal(summary.outcome, 'batch_finished');
    assert.equal(deadline.signal.aborted, false);
    assert.deepEqual({ runs, observations }, { runs: 1, observations: 1 });
    await new Promise<void>((resolve) => setImmediate(resolve));
  });
}

test('held observer stops being awaited without canceling the original deadline; late rejection is contained', async () => {
  const held = latch();
  let runs = 0, observations = 0;
  const deadline = new BillingDeadline(Date.now() + 2000);
  const handlers = reconciliationHandlers(configuration, () => ({ run: async () => {
    runs++;
    return emptyReconciliationSummary('batch_finished');
  } }), () => { observations++; return held.promise; });
  try {
    const summary = await handlers.pump(deadline);
    assert.equal(summary.outcome, 'batch_finished');
    assert.equal(deadline.signal.aborted, false);
    assert.ok(Date.now() < deadline.expiresAt);
    assert.deepEqual({ runs, observations }, { runs: 1, observations: 1 });
    held.reject(new Error(sensitive));
    await new Promise<void>((resolve) => setImmediate(resolve));
  } finally { held.resolve(); }
});

test('original expiry during reporting overrides a completed batch without waiting for the observer', async () => {
  const held = latch();
  let runs = 0, observations = 0;
  const deadline = new BillingDeadline(Date.now() + 100);
  const handlers = reconciliationHandlers(configuration, () => ({ run: async () => {
    runs++;
    return emptyReconciliationSummary('batch_finished');
  } }), () => { observations++; return held.promise; });
  try {
    await assert.rejects(handlers.pump(deadline), /^Error: billing reconciliation deadline unavailable$/);
    assert.deepEqual({ runs, observations }, { runs: 1, observations: 1 });
  } finally { held.resolve(); }
});

test('explicit cancellation releases a held observer and never launches additional work', { timeout: 1500 }, async () => {
  const held = latch(), entered = latch();
  let runs = 0, observations = 0;
  const deadline = new BillingDeadline(Date.now() + 20_000);
  const handlers = reconciliationHandlers(configuration, () => ({ run: async () => {
    runs++;
    return emptyReconciliationSummary('batch_finished');
  } }), () => { observations++; entered.resolve(); return held.promise; });
  const rejection = assert.rejects(handlers.pump(deadline), /^Error: billing reconciliation deadline unavailable$/);
  try {
    await entered.promise;
    deadline.cancel();
    await rejection;
    assert.deepEqual({ runs, observations }, { runs: 1, observations: 1 });
  } finally { held.resolve(); }
});

test('already expired or disabled callbacks produce no reporting or dependency work', async () => {
  let configurations = 0, creates = 0, observations = 0;
  const handlers = reconciliationHandlers(() => { configurations++; return undefined; }, () => {
    creates++;
    throw new Error(sensitive);
  }, () => { observations++; });
  await assert.rejects(handlers.pump(new BillingDeadline(Date.now() - 1)), /^Error: billing reconciliation deadline unavailable$/);
  assert.equal(configurations, 0);
  assert.equal((await handlers.pump()).outcome, 'disabled');
  assert.deepEqual({ configurations, creates, observations }, { configurations: 1, creates: 0, observations: 0 });
});

for (const value of [null, false, { status: 'invented', token: sensitive }]) {
  test('unsupported processor result ' + JSON.stringify(value) + ' stops without leaking payload', async () => {
    const h = fixture([async () => value as unknown as VerifyResponse, secondMustNotRun]);
    const summary = await h.pump.run(new BillingDeadline());
    assert.equal(summary.outcome, 'partial_failure');
    assert.equal(summary.errorCount, 1);
    assert.equal(summary.startedCount, 1);
    assert.equal(summary.notStartedCount, 1);
    assert.deepEqual(h.visited, [h.subjects[0]]);
    assert.equal(JSON.stringify(summary).includes(sensitive), false);
  });
}
