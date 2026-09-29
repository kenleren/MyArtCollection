import assert from 'node:assert/strict';
import test from 'node:test';
import { monthlyFixture, MONTHLY_POLICY } from './monthly_credit_fixture.js';
import { request } from './test_helpers.js';
import { M, digest, parsePolicy, parseControlPair, initialMonthlyControls, parseRequest, parseLedger, validTotals } from '../src/monthly_credit_protocol.js';
for (const field of ['starter', 'collector', 'archive'] as const)
    for (const value of [-1, 1.1, 1001, Number.MAX_SAFE_INTEGER])
        test(`policy rejects ${field} invalid bounded allowance ${value}`, () => {
            assert.throws(() => parsePolicy({ ...MONTHLY_POLICY, allowances: { ...MONTHLY_POLICY.allowances, [field]: value } }));
        });
test('strict controls reject surplus keys, partial pair, reordered map keys remain canonical', () => {
    const p = initialMonthlyControls(MONTHLY_POLICY, 'a'.repeat(64));
    assert.throws(() => parseControlPair({ ...p.control, extra: true }, p.initialization, p.witness));
    assert.throws(() => parseControlPair(p.control, undefined, p.witness));
    const reverse = Object.fromEntries(Object.entries(p.control).reverse());
    assert.deepEqual(parseControlPair(reverse, p.initialization, p.witness).control, p.control);
    assert.equal(digest(reverse), digest(p.control));
});
test('closed v2 terminal and ledger bindings reject inconsistent settlement or altered month', async () => {
    const f = await monthlyFixture();
    await (await f.open(request())).research();
    const rows = [...f.db.snapshotForTest()], r = rows.find(([k]) => k.startsWith(M.requests + '/'))![1] as any, l = rows.find(([k]) => k.startsWith(M.ledger + '/'))![1] as any;
    for (const bad of [{ ...r, extra: true }, { ...r, originalMonth: '2020-01' }, { ...r, settlement_state: 'refunded' }, { ...r, leaseExpiresAtMs: r.reservedAtMs + 60001 }, { ...r, authority: { ...r.authority, verifiedAtMs: r.reservedAtMs + 1 } }])
        assert.throws(() => parseRequest(bad));
    assert.throws(() => parseLedger({
        ...l, state: 'refunded', refundReason: 'injected'
    }, r));
});
test('counter equations reject underflow, overflow and finalized-without-dispatch', () => {
    for (const v of [{
            reservationStarts: 1, dispatchStarts: 0, finalized: 1, refunded: 0, reserved: 0, exposed: 1
        }, {
            reservationStarts: 1, dispatchStarts: 1, finalized: 0, refunded: 2, reserved: 0, exposed: 0
        }, {
            reservationStarts: Number.MAX_SAFE_INTEGER + 1, dispatchStarts: 0, finalized: 0, refunded: 0, reserved: 0, exposed: 0
        }])
        assert.equal(validTotals(v), false);
});

test('encoded document limit is enforced before a write proposal', async () => {
    const { bounded } = await import('../src/monthly_credit_protocol.js');
    assert.throws(() => bounded({ oversized: 'x'.repeat(256 * 1024) }));
    assert.deepEqual(bounded({ safe: 1 }), { safe: 1 });
});
