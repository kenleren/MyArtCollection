import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { COLLECTIONS } from '../src/constants.js';
import {
  ACTIONS, SOURCES, WINDOW_MS, DispatchError, configurationDigest,
  dispatchConfiguration, initialDispatchControls, proposeDispatch,
  proposeOpenCircuit, readDispatchControls, validateControls,
  type DispatchConfiguration, type DispatchControls,
} from '../src/dispatch_budget.js';
import type { BillingTransaction } from '../src/store.js';

const start = new Date('2031-01-01T00:00:00.000Z');
const later = (milliseconds: number): Date => new Date(+start + milliseconds);

function configuration(cap = 3): DispatchConfiguration {
  const counts = () => ({ get: cap, ack: cap, kms: cap });
  const value = {
    enabled: true,
    epoch: '1'.repeat(32),
    global: counts(),
    sources: { foreground: counts(), event: counts(), reconciliation: counts() },
  };
  return { ...value, digest: configurationDigest(value) };
}

function redigest(value: DispatchConfiguration): DispatchConfiguration {
  return { ...value, digest: configurationDigest(value) };
}

function controls(config = configuration()): DispatchControls {
  return initialDispatchControls(config, start, '2'.repeat(64), { kind: 'verified_new' });
}

function rejects(reason: DispatchError['reason']): (error: unknown) => boolean {
  return (error) => error instanceof DispatchError && error.reason === reason;
}

describe('common billing dispatch control boundaries', () => {
  test('missing, disabled and all-zero configuration cannot enable dispatch', () => {
    assert.equal(dispatchConfiguration(undefined), undefined);
    assert.equal(dispatchConfiguration(JSON.stringify(redigest({ ...configuration(), enabled: false }))), undefined);
    assert.equal(dispatchConfiguration(JSON.stringify(configuration(0))), undefined);
    assert.deepEqual(dispatchConfiguration(JSON.stringify(configuration(1))), configuration(1));
  });

  test('configuration rejects tampering, unknown dimensions and oversized limits', () => {
    const cases: unknown[] = [
      null,
      [],
      { ...configuration(), digest: '0'.repeat(64) },
      { ...configuration(), extra: true },
      redigest({ ...configuration(), global: { get: 121, ack: 1, kms: 1 } }),
      redigest({ ...configuration(), global: { get: -1, ack: 1, kms: 1 } }),
      redigest({ ...configuration(), global: { get: 0.5, ack: 1, kms: 1 } }),
      { ...configuration(), sources: { ...configuration().sources, financial: { get: 1, ack: 1, kms: 1 } } },
    ];
    const overAllocation = configuration(1);
    overAllocation.sources.event.get = 2;
    cases.push(redigest(overAllocation));
    for (const value of cases) {
      assert.throws(() => dispatchConfiguration(JSON.stringify(value)), rejects('configuration'));
    }
    assert.throws(() => dispatchConfiguration('{'), rejects('configuration'));
    assert.throws(() => dispatchConfiguration(' '.repeat(4097)), rejects('configuration'));
  });

  test('a shared last unit can be spent by only one source', () => {
    for (const winner of SOURCES) {
      const config = configuration(1);
      const original = controls(config);
      const before = structuredClone(original);
      const charged = proposeDispatch(original, config, winner, 'play_get', start);
      assert.deepEqual(original, before);
      assert.equal(charged.budget.totals[winner].play_get, 1);
      assert.equal(charged.budget.revision, 1);
      assert.equal(charged.marker.revision, 1);
      const spent = structuredClone(charged);
      for (const contender of SOURCES) {
        assert.throws(() => proposeDispatch(charged, config, contender, 'play_get', start), rejects('budget'));
        assert.deepEqual(charged, spent);
      }
    }
  });

  test('source allocation is an additional cap, and KMS encrypt/decrypt share one group', () => {
    let config = configuration(2);
    config.sources.foreground.get = 0;
    config.sources.event.kms = 1;
    config = redigest(config);
    const initial = controls(config);
    assert.throws(() => proposeDispatch(initial, config, 'foreground', 'play_get', start), rejects('budget'));
    const encrypted = proposeDispatch(initial, config, 'event', 'kms_encrypt', start);
    assert.throws(() => proposeDispatch(encrypted, config, 'event', 'kms_decrypt', start), rejects('budget'));
    const decrypted = proposeDispatch(encrypted, config, 'reconciliation', 'kms_decrypt', start);
    assert.equal(decrypted.budget.starts.kms.length, 2);
    assert.throws(() => proposeDispatch(decrypted, config, 'foreground', 'kms_encrypt', start), rejects('budget'));
    assert.equal(decrypted.budget.totals.event.kms_encrypt, 1);
    assert.equal(decrypted.budget.totals.reconciliation.kms_decrypt, 1);
    assert.equal(decrypted.budget.starts.get.length, 0);
  });

  test('a window boundary preserves its charge until strictly outside the window', () => {
    const config = configuration(1);
    const first = proposeDispatch(controls(config), config, 'foreground', 'play_get', start);
    assert.throws(() => proposeDispatch(first, config, 'event', 'play_get', later(WINDOW_MS)), rejects('budget'));
    const second = proposeDispatch(first, config, 'event', 'play_get', later(WINDOW_MS + 1));
    assert.equal(second.budget.starts.get.length, 1);
    assert.equal(second.budget.totals.foreground.play_get, 1);
    assert.equal(second.budget.totals.event.play_get, 1);
    assert.equal(second.budget.revision, 2);
    assert.deepEqual(first.budget.starts.get[0].at, start);
  });

  test('backward time cannot prune, restore allowance or change counters', () => {
    const config = configuration(2);
    const charged = proposeDispatch(controls(config), config, 'event', 'play_ack', later(1));
    const before = structuredClone(charged);
    assert.throws(() => proposeDispatch(charged, config, 'foreground', 'play_ack', start), rejects('unsafe'));
    assert.throws(() => validateControls(charged, config, start), rejects('unsafe'));
    assert.deepEqual(charged, before);
  });

  test('strict paired controls reject partial loss, mismatched identity and impossible history', () => {
    const config = configuration();
    const charged = proposeDispatch(controls(config), config, 'foreground', 'play_get', later(2));
    const mutations: Array<(value: DispatchControls) => void> = [
      (v) => { v.marker = undefined as unknown as DispatchControls['marker']; },
      (v) => { v.budget = undefined as unknown as DispatchControls['budget']; },
      (v) => { v.marker.revision++; },
      (v) => { v.budget.epoch = '3'.repeat(32); },
      (v) => { v.marker.cutoverDigest = '3'.repeat(64); },
      (v) => { v.budget.project = 'other' as typeof v.budget.project; },
      (v) => { v.budget.totals.event.play_get = 1; },
      (v) => { v.budget.starts.get[0].at = later(3); },
      (v) => { v.budget.starts.get[0].at = new Date(NaN); },
      (v) => { v.budget.starts.get[0].action = 'play_ack'; },
      (v) => { v.budget.starts.get[0].source = 'invented' as 'foreground'; },
      (v) => { Object.assign(v.budget, { token: 'synthetic-unexpected-field' }); },
      (v) => { Object.assign(v.budget.totals, { financial: {} }); },
      (v) => { v.budget.circuit.generation = 2; },
      (v) => { v.budget.circuit = { state: 'closed', generation: 0, reason: 'configuration' }; },
    ];
    for (const mutate of mutations) {
      const corrupted = structuredClone(charged);
      mutate(corrupted);
      assert.throws(() => validateControls(corrupted, config, later(2)), rejects('unsafe'));
    }
    const two = proposeDispatch(charged, config, 'event', 'play_get', later(4));
    two.budget.starts.get.reverse();
    assert.throws(() => validateControls(two, config, later(4)), rejects('unsafe'));
  });

  test('equal timestamps are valid, but row limits and retained-count evidence remain bounded', () => {
    const config = configuration();
    const one = proposeDispatch(controls(config), config, 'foreground', 'play_get', start);
    const two = proposeDispatch(one, config, 'event', 'play_get', start);
    validateControls(two, config, start);
    const countMismatch = structuredClone(two);
    countMismatch.budget.starts.get[1].source = 'foreground';
    assert.throws(() => validateControls(countMismatch, config, start), rejects('unsafe'));
    const oversized = structuredClone(one);
    oversized.budget.starts.get = Array.from({ length: 121 }, () => structuredClone(one.budget.starts.get[0]));
    oversized.budget.totals.foreground.play_get = 121;
    oversized.budget.revision = oversized.marker.revision = 121;
    assert.throws(() => validateControls(oversized, config, start), rejects('unsafe'));
  });

  test('safe-integer exhaustion fails closed without resetting high-water', () => {
    const config = configuration();
    const maxed = controls(config);
    maxed.budget.totals.foreground.play_get = Number.MAX_SAFE_INTEGER;
    maxed.marker.revision = maxed.budget.revision = Number.MAX_SAFE_INTEGER;
    validateControls(maxed, config, start);
    const before = structuredClone(maxed);
    assert.throws(() => proposeDispatch(maxed, config, 'foreground', 'play_get', start), rejects('unsafe'));
    assert.throws(() => proposeOpenCircuit(maxed, start), rejects('unsafe'));
    assert.deepEqual(maxed, before);
    const impossible = structuredClone(maxed);
    impossible.budget.totals.event.play_ack = 1;
    assert.throws(() => validateControls(impossible, config, start), rejects('unsafe'));
  });

  test('opening the common circuit preserves history and blocks every source and action', () => {
    const config = configuration();
    const charged = proposeDispatch(controls(config), config, 'event', 'kms_encrypt', start);
    const opened = proposeOpenCircuit(charged, later(1));
    validateControls(opened, config, later(1));
    assert.deepEqual(opened.budget.totals, charged.budget.totals);
    assert.deepEqual(opened.budget.starts, charged.budget.starts);
    assert.equal(opened.budget.revision, charged.budget.revision + 1);
    assert.equal(opened.budget.circuit.generation, 1);
    for (const source of SOURCES) for (const action of ACTIONS) {
      assert.throws(() => proposeDispatch(opened, config, source, action, later(1)), rejects('configuration'));
    }
  });

  test('retained legacy totals survive window aging and circuit changes without becoming fresh allowance', () => {
    const config = configuration(1);
    const legacy = {
      kind: 'retained' as const, digest: '4'.repeat(64), revision: 500,
      totals: { discoveryGet: 20, verificationGet: 200, eventKms: 30, accountKms: 80, ack: 10 },
    };
    const original = initialDispatchControls(config, start, '2'.repeat(64), legacy);
    assert.equal(original.budget.totals.event.play_get, 0);
    const first = proposeDispatch(original, config, 'event', 'play_get', start);
    const next = proposeDispatch(first, config, 'event', 'play_get', later(WINDOW_MS + 1));
    const opened = proposeOpenCircuit(next, later(WINDOW_MS + 2));
    validateControls(opened, config, later(WINDOW_MS + 2));
    assert.deepEqual(opened.budget.legacy, legacy);
    assert.equal(opened.budget.totals.event.play_get, 2);
    assert.equal(opened.budget.starts.get.length, 1);
    const malformed = structuredClone(opened);
    Object.assign(malformed.budget.legacy, { rawToken: 'not-permitted' });
    assert.throws(() => validateControls(malformed, config, later(WINDOW_MS + 2)), rejects('unsafe'));
  });

  test('different configuration or epoch cannot adopt initialized controls to gain headroom', () => {
    const config = configuration(1);
    const charged = proposeDispatch(controls(config), config, 'foreground', 'play_get', start);
    for (const changed of [configuration(2), redigest({ ...config, epoch: '3'.repeat(32) })]) {
      assert.throws(() => proposeDispatch(charged, changed, 'foreground', 'play_get', start), rejects('unsafe'));
    }
    assert.equal(charged.budget.totals.foreground.play_get, 1);
  });

  test('read-only control admission never initializes absent or partial records', async () => {
    const config = configuration();
    const present = controls(config);
    for (const mode of ['absent', 'marker-only', 'budget-only', 'both'] as const) {
      const reads: string[] = [];
      let writes = 0;
      const tx: BillingTransaction = {
        async get<T>(collection: string, id: string): Promise<T | undefined> {
          assert.equal(collection, COLLECTIONS.dispatchControl);
          reads.push(id);
          return (id === 'marker' && (mode === 'marker-only' || mode === 'both') ? present.marker
            : id === 'budget' && (mode === 'budget-only' || mode === 'both') ? present.budget : undefined) as T | undefined;
        },
        async findSubjectBinding() { throw new Error('unexpected query'); },
        async findSubjectRoute() { throw new Error('unexpected query'); },
        async findAnyEventWork() { throw new Error('unexpected query'); },
        set() { writes++; },
      };
      if (mode === 'both') assert.deepEqual(await readDispatchControls(tx, config, start), present);
      else await assert.rejects(readDispatchControls(tx, config, start), rejects('unsafe'));
      assert.deepEqual(reads, ['marker', 'budget']);
      assert.equal(writes, 0);
    }
  });
});
