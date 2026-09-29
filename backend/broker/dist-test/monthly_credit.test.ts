import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { monthlyFixture, MONTHLY_POLICY } from './monthly_credit_fixture.js';
import { request, ResultProvider } from './test_helpers.js';
import { createMonthlyBrokerSession } from '../src/monthly_broker.js';
import { M, fingerprint, digest } from '../src/monthly_credit_protocol.js';
import { TEST_ACCOUNT_KEY, TEST_UID, deferred } from './credit_identity_fixture.js';
import { authorityDigest } from '../src/credit_identity.js';
test('disabled monthly factory constructs nothing', async () => {
    assert.equal(await createMonthlyBrokerSession({ enabled: false }, () => { throw Error('must not construct'); }, {}, request()), undefined);
});
test('actual broker monthly journey reserves, dispatches and settles then replays without a second call', async () => {
    const f = await monthlyFixture(), input = request();
    assert.equal((await (await f.open(input)).research()).ok, true);
    assert.equal(f.provider.callCount, 1);
    assert.deepEqual(f.account().totals, {
        reservationStarts: 1, dispatchStarts: 1, finalized: 1, refunded: 0, reserved: 0, exposed: 1
    });
    assert.equal(f.account().inFlight, null);
    const before = f.db.snapshotForTest();
    const replay = await (await f.open(input)).research();
    assert.equal(replay.ok, true);
    assert.equal(f.provider.callCount, 1);
    assert.deepEqual(f.db.snapshotForTest(), before);
});
test('same UUID with changed canonical content conflicts', async () => {
    const f = await monthlyFixture();
    await (await f.open(request())).research();
    const result = await (await f.open(request({ image: {
            mime_type: 'image/jpeg', byte_size: 3, long_edge_px: 900, content_base64: 'AQID'
        } }))).research();
    assert.equal(result.ok, false);
    if (!result.ok)
        assert.equal(result.failure.condition, 'idempotency_conflict');
    assert.equal(f.provider.callCount, 1);
});
test('concurrent distinct requests contend on one cross-month in-flight owner', async () => {
    const f = await monthlyFixture();
    const entered = deferred(), release = deferred();
    const first = await f.open(request({ request_id: randomUUID() }), { authorizeProvider: async () => { entered.resolve(); await release.promise; } });
    const running = first.research();
    await entered.promise;
    const second = await (await f.open()).research();
    assert.equal(second.ok, false);
    if (!second.ok)
        assert.equal(second.failure.condition, 'quota_subject_in_flight');
    release.resolve();
    assert.equal((await running).ok, true);
    assert.equal(f.provider.callCount, 1);
});
test('last monthly credit denies a third request before provider construction', async () => {
    const f = await monthlyFixture();
    for (let n = 0; n < 2; n++)
        assert.equal((await (await f.open()).research()).ok, true);
    let constructed = 0;
    const result = await (await f.open(undefined, { providerProvisioner: { configure: () => { constructed++; return {}; }, construct: () => f.provider } })).research();
    assert.equal(result.ok, false);
    if (!result.ok)
        assert.equal(result.failure.condition, 'credits_exhausted');
    assert.equal(constructed, 0);
    assert.equal(f.provider.callCount, 2);
});
for (const kind of ['timeout', 'rate_limited'] as const)
    test(`known normalized ${kind} refunds once but never dispatch budget`, async () => {
        const f = await monthlyFixture(), p = new ResultProvider({ kind });
        const input = request();
        const result = await (await f.open(input, { providerProvisioner: { configure: () => ({}), construct: () => p } })).research();
        assert.equal(result.ok, false);
        assert.equal(p.callCount, 1);
        assert.deepEqual(f.account().totals, {
            reservationStarts: 1, dispatchStarts: 1, finalized: 0, refunded: 1, reserved: 0, exposed: 0
        });
        await (await f.open(input)).research();
        assert.equal(f.account().totals.refunded, 1);
        assert.equal(f.provider.callCount, 0);
    });
for (const change of ['consent', 'operator', 'authority'] as const)
    test(`fresh ${change} loss during awaited authorization prevents provider dispatch`, async () => {
        const f = await monthlyFixture();
        const result = await (await f.open(request(), { authorizeProvider: async () => {
                if (change === 'consent')
                    await f.consent('revoke');
                if (change === 'operator')
                    f.db.setOperator(TEST_UID, { entitled: false, breakerOpen: false });
                if (change === 'authority') {
                    const s = {
                        ...f.getSnapshot(), state: 'none' as const, reason: 'expired' as const, publicationRevision: 2
                    };
                    delete s.planId;
                    delete s.playExpiresAtMs;
                    delete s.validUntilMs;
                    assert.equal((await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s))).status, 'applied');
                }
            } })).research();
        assert.equal(result.ok, false);
        assert.equal(f.provider.callCount, 0);
        assert.equal(f.account().totals.refunded, 1);
        assert.equal(f.account().inFlight, null);
    });
test('retained replay receipt detects both request and ledger removal', async () => {
    const f = await monthlyFixture(), input = request();
    await (await f.open(input)).research();
    const fp = fingerprint(TEST_ACCOUNT_KEY, f.accountSubject, input.request_id);
    f.db.deleteForTest(M.requests, fp);
    f.db.deleteForTest(M.ledger, fp);
    const before = f.db.snapshotForTest(), result = await (await f.open(input)).research();
    assert.equal(result.ok, false);
    assert.equal(f.provider.callCount, 1);
    assert.deepEqual(f.db.snapshotForTest(), before);
});
test('immutable original month survives midnight dispatch and late settlement', async () => {
    const f = await monthlyFixture({ nowMs: Date.parse('2031-01-31T23:59:59.900Z') });
    const result = await (await f.open(request(), { authorizeProvider: () => { f.clock.advance(200); } })).research();
    assert.equal(result.ok, true);
    assert.equal(f.account().latestMonth, '2031-01');
    assert.equal(f.account().months['2031-01'].totals.finalized, 1);
    const s = {
        ...f.getSnapshot(), verifiedAtMs: f.clock.now(), publicationRevision: 2
    };
    await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s));
    assert.equal((await (await f.open()).research()).ok, true);
    assert.equal(f.account().latestMonth, '2031-02');
    assert.equal(f.account().months['2031-02'].totals.finalized, 1);
});
test('paid upgrade raises ceiling and downgrade preserves usage and that month ceiling', async () => {
    const f = await monthlyFixture();
    await (await f.open()).research();
    let s = {
        ...f.getSnapshot(), planId: 'collector' as const, publicationRevision: 2
    };
    await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s));
    await (await f.open()).research();
    const m = f.account().latestMonth;
    assert.equal(f.row(M.months, `${f.accountSubject}_${m}`).allowanceCeiling, 4);
    assert.equal(f.account().totals.exposed, 2);
    await f.service.applyAuthenticatedSnapshot({
        ...s, planId: 'starter', publicationRevision: 3
    }, authorityDigest({
        ...s, planId: 'starter', publicationRevision: 3
    }));
    await (await f.open()).research();
    assert.equal(f.row(M.months, `${f.accountSubject}_${m}`).allowanceCeiling, 4);
    assert.equal(f.account().totals.exposed, 3);
});
test('monthly marker revision is independent from consent and identity revisions', async () => {
    const f = await monthlyFixture();
    const c = 'brokerCreditAccounts', id = `broker-account-v1_${f.accountSubject}`;
    const before = f.row(c, id);
    await (await f.open()).research();
    const after = f.row(c, id);
    assert.equal(after.revision, before.revision);
    assert.deepEqual(after.consent, before.consent);
    assert.equal(after.registrationGeneration, before.registrationGeneration);
    assert.ok(after.monthly.monthlyRevision > before.monthly.monthlyRevision);
});
for (const action of ['accept', 'revoke'] as const)
    test(`consent ${action} preserves a malformed monthly marker without reading accounting`, async () => {
        const f = await monthlyFixture();
        const id = `broker-account-v1_${f.accountSubject}`, a = f.row('brokerCreditAccounts', id), marker = { corrupt: 'preserve' };
        f.db.setForTest('brokerCreditAccounts', id, { ...a, monthly: marker });
        const original = f.db.transaction.bind(f.db);
        f.db.transaction = work => original(tx => work({ ...tx, get: async (c, id) => {
                if (c.startsWith('brokerMonthly'))
                    throw Error('must not read monthly');
                return tx.get(c, id);
            } }));
        assert.equal((await f.consent(action)).status, action === 'accept' ? 'accepted' : 'revoked');
        assert.deepEqual(f.row('brokerCreditAccounts', id).monthly, marker);
        f.db.transaction = original;
        if (action === 'accept') {
            const result = await (await f.open()).research();
            assert.equal(result.ok, false);
            assert.equal(f.provider.callCount, 0);
        }
    });
test('same account request replay crosses approved app identities without moving accounting', async () => {
    const apps = ['1:123456789:android:creditidentity', '1:123456789:android:second'];
    const f = await monthlyFixture({ appIds: apps }), input = request();
    await (await f.open(input)).research();
    const before = f.db.snapshotForTest();
    const other = await createMonthlyBrokerSession(f.policy, () => f.deps, f.tokens(apps[1]), input, f.deadline());
    assert.ok(other);
    assert.equal((await other.research()).ok, true);
    assert.equal(f.provider.callCount, 1);
    assert.deepEqual(f.db.snapshotForTest(), before);
});
test('new reservation cannot keep an old month when admission reads cross midnight', async () => {
    const f = await monthlyFixture({ nowMs: Date.parse('2031-01-31T23:59:59.900Z') });
    const session = await f.open();
    const before = f.db.snapshotForTest(), original = f.db.transaction.bind(f.db);
    let advance = true;
    f.db.transaction = work => original(tx => work({ ...tx, readOperator: async (uid) => {
            const result = await tx.readOperator(uid);
            if (advance) {
                advance = false;
                f.clock.advance(200);
            }
            return result;
        } }));
    assert.equal((await session.research()).ok, false);
    assert.equal(f.provider.callCount, 0);
    assert.deepEqual(f.db.snapshotForTest(), before);
});
for (const boundary of ['age', 'lease', 'rollback'] as const)
    test(`late dispatch transaction result ${boundary} prevents invocation and permits exact-owner cleanup`, async () => {
        const start = 1900000000000;
        const f = await monthlyFixture({ nowMs: start });
        if (boundary === 'age') {
            const s = {
                ...f.getSnapshot(), verifiedAtMs: start - 59900, publicationRevision: 2
            };
            await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s));
        }
        const original = f.db.transaction.bind(f.db);
        let held = false;
        f.db.transaction = async (work) => {
            const result = await original(work);
            if (!held && [...f.db.snapshotForTest()].some(([k, v]) => k.startsWith(M.requests + '/') && (v as any).state === 'dispatch_intent')) {
                held = true;
                f.clock.advance(boundary === 'rollback' ? -1 : boundary === 'age' ? 101 : 50001);
            }
            return result;
        };
        const result = await (await f.open()).research();
        assert.equal(result.ok, false);
        assert.equal(f.provider.callCount, 0);
        assert.equal(f.account().totals.refunded, 1);
        assert.equal(f.account().totals.dispatchStarts, 1);
    });
for (const phase of ['terminal', 'settlement'] as const)
    test(`one cleanup readback confirms lost committed ${phase} response`, async () => {
        const f = await monthlyFixture();
        let lost = false;
        const original = f.db.transaction.bind(f.db);
        f.db.transaction = async (work) => {
            const result = await original(work);
            const rows = [...f.db.snapshotForTest()].filter(([k]) => k.startsWith(M.requests + '/')).map(([, v]) => v as any);
            if (!lost && rows.some(r => phase === 'terminal' ? r.state === 'terminal' : r.settlement_state === 'finalized')) {
                lost = true;
                throw Error('synthetic lost response');
            }
            return result;
        };
        const result = await (await f.open()).research();
        assert.equal(result.ok, true);
        assert.equal(f.provider.callCount, 1);
        assert.equal(f.account().totals.finalized, 1);
        assert.equal(f.account().inFlight, null);
        assert.equal(lost, true);
    });
test('lost intent response never reaches the legacy automatic refund catch or invokes a provider', async () => {
    const f = await monthlyFixture();
    let lost = false;
    const original = f.db.transaction.bind(f.db);
    f.db.transaction = async (work) => {
        const result = await original(work);
        if (!lost && [...f.db.snapshotForTest()].some(([k, v]) => k.startsWith(M.requests + '/') && (v as any).state === 'dispatch_intent')) {
            lost = true;
            throw Error('lost intent');
        }
        return result;
    };
    const result = await (await f.open()).research();
    assert.equal(result.ok, false);
    assert.equal(f.provider.callCount, 0);
    assert.equal(lost, true);
    assert.equal(f.account().totals.refunded, 1);
    assert.equal(f.account().totals.dispatchStarts, 1);
});
test('zero injected caps deny before provider preparation', async () => {
    const f = await monthlyFixture({ policy: { ...MONTHLY_POLICY, globalMonthlyExposure: 0 } });
    let configs = 0;
    const r = await (await f.open(undefined, { providerProvisioner: { configure: () => { configs++; return {}; }, construct: () => f.provider } })).research();
    assert.equal(r.ok, false);
    assert.equal(configs, 0);
});
test('unknown provider outcome holds cross-month in-flight exposure; a late known result settles without new dispatch', async () => {
    const f = await monthlyFixture(), provider = new ResultProvider().makeSlow(), parent = f.deadline(), entered = deferred();
    const originalResearch = provider.research.bind(provider);
    provider.research = async (r) => { entered.resolve(); return originalResearch(r); };
    const session = await createMonthlyBrokerSession(f.policy, () => ({ ...f.deps, providerProvisioner: { configure: () => ({}), construct: () => provider } }), f.tokens(), request(), parent);
    assert.ok(session);
    const work = session.research();
    await entered.promise;
    parent.cancel();
    const result = await work;
    assert.equal(result.ok, false);
    if (!result.ok)
        assert.equal(result.failure.condition, 'dispatch_outcome_unknown');
    assert.equal(f.account().totals.reserved, 1);
    assert.equal(f.account().totals.refunded, 0);
    assert.equal(f.account().inFlight.phase, 'dispatch_intent');
    assert.equal((await (await f.open()).research()).ok, false);
    assert.equal(provider.callCount, 1);
    const settled = deferred();
    const original = f.db.transaction.bind(f.db);
    f.db.transaction = async (action) => {
        const r = await original(action);
        if (f.account().totals.finalized === 1)
            settled.resolve();
        return r;
    };
    await f.consent('revoke');
    provider.release();
    await settled.promise;
    assert.equal(f.account().totals.finalized, 1);
    assert.equal(f.account().inFlight, null);
    assert.equal(provider.callCount, 1);
});
test('global last exposure credit is shared across two durable accounts', async () => {
    const { creditIdentityFixture } = await import('./credit_identity_fixture.js');
    const other = 'synthetic-other-owner', owners = [TEST_UID, other];
    const f = await monthlyFixture({ ownerUids: owners, policy: { ...MONTHLY_POLICY, globalMonthlyExposure: 1 } });
    const second = await creditIdentityFixture({
        uid: other, ownerUids: owners, database: f.db, nowMs: f.clock.now()
    });
    const provider = new ResultProvider();
    const secondSession = await createMonthlyBrokerSession(f.policy, () => ({
        ...f.deps, identityService: second.service, providerProvisioner: { configure: () => ({}), construct: () => provider }
    }), second.tokens(), request({ request_id: randomUUID() }), second.deadline());
    assert.ok(secondSession);
    await secondSession.enroll();
    const first = await f.open();
    const results = await Promise.all([first.research(), secondSession.research()]);
    assert.equal(results.filter(r => r.ok).length, 1);
    assert.equal(f.provider.callCount + provider.callCount, 1);
    assert.equal(f.control().totals.exposed, 1);
    assert.equal(f.control().enrolledAccounts, 2);
});
for (const boundary of ['control', 'initialization', 'account', 'marker', 'month', 'global_month', 'shard'] as const)
    test(`retained high-water rejects missing ${boundary} without resetting usage`, async () => {
        const f = await monthlyFixture(), input = request();
        await (await f.open(input)).research();
        const fp = fingerprint(TEST_ACCOUNT_KEY, f.accountSubject, input.request_id), m = f.account().latestMonth;
        if (boundary === 'control' || boundary === 'initialization')
            f.db.deleteForTest(M.control, boundary);
        if (boundary === 'account')
            f.db.deleteForTest(M.accounts, f.accountSubject);
        if (boundary === 'marker') {
            const id = `broker-account-v1_${f.accountSubject}`, row = f.row('brokerCreditAccounts', id);
            delete row.monthly;
            f.db.setForTest('brokerCreditAccounts', id, row);
        }
        if (boundary === 'month')
            f.db.deleteForTest(M.months, `${f.accountSubject}_${m}`);
        if (boundary === 'global_month')
            f.db.deleteForTest(M.globalMonths, m);
        if (boundary === 'shard')
            f.db.deleteForTest(M.replay, `${f.accountSubject}_${fp[0]}`);
        const before = f.db.snapshotForTest();
        assert.equal((await (await f.open(input)).research()).ok, false);
        assert.equal(f.provider.callCount, 1);
        assert.deepEqual(f.db.snapshotForTest(), before);
    });
test('caller request mutation while identity awaits cannot change captured provider bytes', async () => {
    const f = await monthlyFixture(), input = request();
    let seen = '';
    const provider = new ResultProvider(), original = provider.research.bind(provider);
    provider.research = async (r) => { seen = r.image.content_base64; return original(r); };
    const pending = createMonthlyBrokerSession(f.policy, () => ({ ...f.deps, providerProvisioner: { configure: () => ({}), construct: () => provider } }), f.tokens(), input, f.deadline());
    input.image.content_base64 = 'BAUG';
    const session = await pending;
    assert.ok(session);
    assert.equal((await session.research()).ok, true);
    assert.equal(seen, 'AQID');
});
test('cleanup keeps one absolute budget across terminal commit and settlement', async () => {
    const f = await monthlyFixture(), input = request();
    let delayed = false;
    const original = f.db.transaction.bind(f.db);
    f.db.transaction = async (work) => {
        const result = await original(work);
        if (!delayed && [...f.db.snapshotForTest()].some(([k, v]) => k.startsWith(M.requests + '/') && (v as any).state === 'terminal')) {
            delayed = true;
            f.clock.advance(20001);
        }
        return result;
    };
    const r = await (await f.open(input)).research();
    assert.equal(r.ok, false);
    assert.equal(f.provider.callCount, 1);
    assert.equal(f.account().totals.reserved, 1);
    assert.equal(f.account().inFlight.phase, 'terminal_pending_settlement');
    f.db.transaction = original;
    // A fresh authenticated replay has a new cleanup cap, not a new dispatch grant.
    const replay = await (await f.open(input)).research();
    assert.equal(replay.ok, true);
    assert.equal(f.account().totals.finalized, 1);
    assert.equal(f.provider.callCount, 1);
});
test('unknown intent plus unavailable exact-owner cleanup retains exposure and cannot redrive', async () => {
    const f = await monthlyFixture(), input = request();
    let intentLost = false;
    const original = f.db.transaction.bind(f.db);
    f.db.transaction = async (work) => {
        if (intentLost)
            throw Error('synthetic store unavailable');
        const result = await original(work);
        if ([...f.db.snapshotForTest()].some(([k, v]) => k.startsWith(M.requests + '/') && (v as any).state === 'dispatch_intent')) {
            intentLost = true;
            throw Error('synthetic intent response lost');
        }
        return result;
    };
    const session = await f.open(input), r = await session.research();
    assert.equal(r.ok, false);
    if (!r.ok)
        assert.equal(r.failure.condition, 'dispatch_outcome_unknown');
    assert.equal(f.account().totals.refunded, 0);
    assert.equal(f.account().totals.reserved, 1);
    assert.equal(f.provider.callCount, 0);
    f.db.transaction = original;
    const replay = await (await f.open(input)).research();
    assert.equal(replay.ok, false);
    if (!replay.ok)
        assert.equal(replay.failure.condition, 'dispatch_outcome_unknown');
    assert.equal(f.provider.callCount, 0);
});
test('malformed optional monthly marker does not alter current identity eligibility but blocks spend', async () => {
    const f = await monthlyFixture(), id = `broker-account-v1_${f.accountSubject}`, a = f.row('brokerCreditAccounts', id);
    f.db.setForTest('brokerCreditAccounts', id, { ...a, monthly: { bad: true } });
    assert.equal((await f.evaluate()).status, 'eligible');
    assert.equal((await (await f.open()).research()).ok, false);
    assert.equal(f.provider.callCount, 0);
});
test('terminal and settlement response losses share one total cleanup confirmation read', async () => {
    const f = await monthlyFixture();
    const original = f.db.transaction.bind(f.db);
    let terminalLost = false, settlementLost = false, confirmations = 0;
    f.db.transaction = async (work) => {
        let writes = 0;
        const result = await original(tx => work({ ...tx, set: (c, id, value) => { writes++; tx.set(c, id, value); } }));
        const r = [...f.db.snapshotForTest()].find(([k]) => k.startsWith(M.requests + '/'))?.[1] as any;
        if (r?.state === 'terminal' && writes === 0)
            confirmations++;
        if (!terminalLost && r?.settlement_state === 'pending_finalize' && writes > 0) {
            terminalLost = true;
            throw Error('synthetic lost terminal');
        }
        if (!settlementLost && r?.settlement_state === 'finalized' && writes > 0) {
            settlementLost = true;
            throw Error('synthetic lost settlement');
        }
        return result;
    };
    await (await f.open()).research();
    assert.equal(terminalLost, true);
    assert.equal(settlementLost, true);
    assert.equal(confirmations, 1);
    assert.equal(f.account().totals.finalized, 1);
    assert.equal(f.provider.callCount, 1);
});
test('unexpected v2 hook exception never enters legacy terminal refund and never reads its message', async (t) => {
    const { MonthlyCreditStore } = await import('../src/monthly_credit_store.js');
    const f = await monthlyFixture();
    let reads = 0;
    const hostile = { get message() { reads++; throw Error('message must not be read'); } };
    t.mock.method(MonthlyCreditStore.prototype, 'dispatch', async () => { throw hostile; });
    const result = await (await f.open()).research();
    assert.equal(result.ok, false);
    if (!result.ok)
        assert.equal(result.failure.condition, 'dispatch_outcome_unknown');
    assert.equal(reads, 0);
    assert.equal(f.provider.callCount, 0);
    assert.equal(f.account().totals.refunded, 0);
    assert.equal(f.account().totals.reserved, 1);
});
test('concurrent and repeated same-owner dispatch consumption invokes only once', async (t) => {
    const { MonthlyCreditStore } = await import('../src/monthly_credit_store.js');
    const f = await monthlyFixture(), original = MonthlyCreditStore.prototype.dispatch;
    t.mock.method(MonthlyCreditStore.prototype, 'dispatch', async function (this: InstanceType<typeof MonthlyCreditStore>, ...args: Parameters<typeof original>) {
        const results = await Promise.all([original.apply(this, args), original.apply(this, args)]);
        assert.equal(results[1].kind, 'outcome_unknown');
        assert.equal((await original.apply(this, args)).kind, 'outcome_unknown');
        return results[0];
    });
    assert.equal((await (await f.open()).research()).ok, true);
    assert.equal(f.provider.callCount, 1);
    assert.equal(f.account().totals.dispatchStarts, 1);
});
test('synchronous provider rejection is a known failure and leaves irreversible dispatch spent', async () => {
    const f = await monthlyFixture();
    f.provider.research = () => { f.provider.callCount++; throw Error('synthetic provider rejection'); };
    const result = await (await f.open()).research();
    assert.equal(result.ok, false);
    if (!result.ok)
        assert.equal(result.failure.condition, 'provider_failure');
    assert.equal(f.provider.callCount, 1);
    assert.equal(f.account().totals.finalized, 1);
    assert.equal(f.account().totals.dispatchStarts, 1);
});
test('a self-consistent account digest cannot hide a pointer that conflicts with its retained request', async () => {
    const { markerFor } = await import('../src/monthly_credit_protocol.js');
    const f = await monthlyFixture(), entered = deferred(), release = deferred();
    const work = (await f.open(request(), { authorizeProvider: async () => { entered.resolve(); await release.promise; } })).research();
    await entered.promise;
    const a = f.account();
    a.inFlight.ownerNonce = 'f'.repeat(32);
    const id = `broker-account-v1_${f.accountSubject}`, credit = f.row('brokerCreditAccounts', id);
    f.db.setForTest(M.accounts, f.accountSubject, a);
    f.db.setForTest('brokerCreditAccounts', id, { ...credit, monthly: markerFor(a) });
    const before = f.db.snapshotForTest();
    release.resolve();
    assert.equal((await work).ok, false);
    assert.equal(f.provider.callCount, 0);
    assert.deepEqual(f.db.snapshotForTest(), before);
});

for (const stage of ['configure', 'construct'] as const) test(`consent withdrawal during awaited ${stage} blocks the later provider boundary`, async () => {
    const f = await monthlyFixture();
    const provisioner = {
        configure: async () => { if (stage === 'configure') await f.consent('revoke'); return {}; },
        construct: async () => { if (stage === 'construct') await f.consent('revoke'); return f.provider; },
    };
    const result = await (await f.open(undefined, { providerProvisioner: provisioner })).research();
    assert.equal(result.ok, false); assert.equal(f.provider.callCount, 0); assert.equal(f.account().totals.refunded, 1);
});

test('paid validUntil expiry during final result wait is independent of verification age and parent deadline', async () => {
    const f = await monthlyFixture(), start = f.clock.now();
    const s = { ...f.getSnapshot(), verifiedAtMs: start, validUntilMs: start + 100, publicationRevision: 2 };
    await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s));
    const original = f.db.transaction.bind(f.db); let held = false;
    f.db.transaction = async action => {
        const result = await original(action);
        if (!held && [...f.db.snapshotForTest()].some(([k, v]) => k.startsWith(M.requests + '/') && (v as any).state === 'dispatch_intent')) { held = true; f.clock.advance(101); }
        return result;
    };
    assert.equal((await (await f.open()).research()).ok, false);
    assert.equal(f.clock.now() - start, 101); assert.equal(f.provider.callCount, 0); assert.equal(f.account().totals.refunded, 1);
});

test('newer authority cannot extend a reservation original short lease', async () => {
    const f = await monthlyFixture(), start = f.clock.now();
    const old = { ...f.getSnapshot(), verifiedAtMs: start - 59900, publicationRevision: 2 };
    await f.service.applyAuthenticatedSnapshot(old, authorityDigest(old));
    const result = await (await f.open(undefined, { authorizeProvider: async () => {
        const fresh = { ...f.getSnapshot(), verifiedAtMs: start, publicationRevision: 3 };
        await f.service.applyAuthenticatedSnapshot(fresh, authorityDigest(fresh));
        f.clock.advance(101);
    } })).research();
    assert.equal(result.ok, false); assert.equal(f.provider.callCount, 0); assert.equal(f.account().totals.refunded, 1);
});

test('actual broker provider order reaches durable intent before the one invocation', async () => {
    const f = await monthlyFixture(), order: string[] = [], original = f.provider.research.bind(f.provider);
    f.provider.research = async r => { order.push('provider'); assert.equal(f.account().inFlight.phase, 'dispatch_intent'); assert.equal(f.account().totals.dispatchStarts, 1); return original(r); };
    const session = await f.open(undefined, {
        providerProvisioner: { configure: () => { order.push('configure'); return {}; }, construct: () => { order.push('construct'); return f.provider; } },
        authorizeProvider: () => { order.push('authorize'); },
    });
    assert.equal((await session.research()).ok, true); assert.deepEqual(order, ['configure', 'construct', 'authorize', 'provider']);
});
