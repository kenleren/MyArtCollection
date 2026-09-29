import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { createHarness, acceptDisclosure, eligiblePurchase, purchaseToken, verifyRequest } from './test_helpers.js';
import { BillingBrokerBridge, createBillingBridge, initialControls, routeForUid, bridgeRouteId, ROUTE_KEY, ACCOUNT_KEY, PROJECT, type CreditIdentityConfig } from '../src/broker_bridge.js';
import { COLLECTIONS } from '../src/constants.js';
import { BillingDeadline } from '../src/deadline.js';
import type { DisclosureRecord } from '../src/store.js';
import type { LifecycleRoot } from '../src/lifecycle.js';
const key = 'synthetic-shared-route-key-000000000';
const config: CreditIdentityConfig = { version: 'credit-identity-config-v1', projectId: PROJECT, enabled: true, routingKeyVersion: ROUTE_KEY, accountKeyVersion: ACCOUNT_KEY, cutoverId: 'a'.repeat(32), admissionPolicyId: 'b'.repeat(32), maxAccounts: 20, authorityMaxAgeMs: 60000 };
async function setup(paid = false) {
    const h = createHarness();
    await acceptDisclosure(h);
    if (paid) {
        const token = purchaseToken();
        h.play.setPurchase(token, eligiblePurchase(h));
        assert.equal((await h.service.verifySubscription(h.identity, verifyRequest(token))).status, 'paid');
    }
    const subject = h.identifiers.accountSubject(h.identity.uid), route = routeForUid(key, h.identity.uid), pair = initialControls(config, 'billing');
    h.database.setUnsafeRecordForTest(COLLECTIONS.brokerBridgeControl, 'control', pair.control);
    h.database.setUnsafeRecordForTest(COLLECTIONS.brokerBridgeControl, 'initialization', pair.initialization);
    const bridge = new BillingBrokerBridge({ database: h.database, repository: h.repository, config, routingKey: key, accountSubject: h.identifiers.accountSubject, approvedAppId: 'synthetic-approved-app', now: () => h.clock.now(),
        auth: { verifyIdToken: async () => ({ uid: h.identity.uid, firebase: { sign_in_provider: 'google.com' } } as any) } });
    const root = () => h.database.snapshotForTest().get(COLLECTIONS.lifecycles + '/' + subject) as LifecycleRoot;
    const context = { auth: { uid: h.identity.uid }, app: { appId: 'synthetic-approved-app', alreadyConsumed: false }, rawRequest: { headers: { authorization: 'Bearer synthetic' } } };
    const request = () => ({ version: 'credit-billing-enrollment-v1', requestId: randomUUID(), lifecycleEpoch: root().lifecycleEpoch, lifecycleGeneration: root().lifecycleGeneration });
    const read = () => bridge.read({ version: 'credit-authority-read-v1', routingKeyVersion: ROUTE_KEY, route, challenge: 'c'.repeat(32) });
    return { ...h, bridge, subject, route, root, context, request, read };
}
test('disabled billing bridge does not construct dependencies', () => { assert.equal(createBillingBridge({ enabled: false }, () => { throw Error('unexpected'); }), undefined); });
test('verified Google enrollment is reciprocal, concurrent-idempotent and privacy projected', async () => {
    const h = await setup(true);
    await Promise.all([h.bridge.enroll(h.context, h.request()), h.bridge.enroll(h.context, h.request())]);
    const response = await h.read();
    assert.equal(response.snapshot.state, 'active');
    assert.equal(response.snapshot.planId, 'starter');
    assert.equal((h.database.snapshotForTest().get(COLLECTIONS.brokerBridgeControl + '/control') as any).enrolledAccounts, 1);
    const text = JSON.stringify(response);
    for (const x of [h.identity.uid, h.subject, h.root().obfuscatedAccountId, 'tokenFingerprint', 'productId'])
        assert.equal(text.includes(x), false);
    assert.ok(Buffer.byteLength(text) < 4096);
});
for (const app of [true, undefined, 'false'])
    test(`billing enrollment fresh-consumption guard rejects ${String(app)}`, async () => { const h = await setup(); await assert.rejects(h.bridge.enroll({ ...h.context, app: { ...h.context.app, alreadyConsumed: app } }, h.request())); assert.equal(h.database.snapshotForTest().has(COLLECTIONS.brokerBindings + '/' + h.subject), false); });
for (const side of ['marker', 'binding', 'reverse'])
    test(`initialized ${side} loss cannot repair itself`, async () => {
        const h = await setup();
        await h.bridge.enroll(h.context, h.request());
        if (side === 'marker') {
            const r = h.root();
            delete r.brokerBridge;
            h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, h.subject, r);
        }
        else
            h.database.deleteRecordForTest(side === 'binding' ? COLLECTIONS.brokerBindings : COLLECTIONS.brokerRoutes, side === 'binding' ? h.subject : bridgeRouteId(h.route));
        const before = h.database.snapshotForTest();
        await assert.rejects(h.bridge.enroll(h.context, h.request()));
        await assert.rejects(h.read());
        assert.deepEqual(h.database.snapshotForTest(), before);
    });
for (const action of ['revoke', 'retire'])
    test(`core ${action} ignores malformed optional bridge and unavailable controls`, async () => {
        const h = await setup(true);
        await h.bridge.enroll(h.context, h.request());
        h.database.setUnsafeRecordForTest(COLLECTIONS.lifecycles, h.subject, { ...h.root(), brokerBridge: { invalid: 'preserved' } });
        h.database.deleteRecordForTest(COLLECTIONS.brokerBridgeControl, 'control');
        const original = h.database.runTransaction.bind(h.database);
        h.database.runTransaction = work => original(tx => work({ ...tx, get: async (c, id) => { if (c === COLLECTIONS.brokerBridgeControl)
                throw Error('must not read'); return tx.get(c, id); } }));
        if (action === 'revoke')
            await h.repository.revokeDisclosure(h.subject, h.clock.now());
        else
            assert.equal(await h.repository.retireLifecycle(h.subject, h.root(), h.clock.now()), true);
        assert.equal((h.database.snapshotForTest().get(COLLECTIONS.authorities + '/' + h.subject) as any).snapshot.state, 'none');
        assert.deepEqual(h.root().brokerBridge, { invalid: 'preserved' });
    });
test('bridge survivor prevents new lifecycle after partial core loss', async () => {
    const h = await setup();
    await h.bridge.enroll(h.context, h.request());
    for (const c of [COLLECTIONS.lifecycles, COLLECTIONS.authorities, COLLECTIONS.authorityOutbox, COLLECTIONS.reconcileWork])
        h.database.deleteRecordForTest(c, h.subject);
    for (const [path] of h.database.snapshotForTest())
        if (path.startsWith(COLLECTIONS.routes + '/'))
            h.database.deleteRecordForTest(COLLECTIONS.routes, path.slice(COLLECTIONS.routes.length + 1));
    await assert.rejects(h.repository.preparePurchase(h.subject, h.clock.now()));
    assert.equal(h.database.snapshotForTest().has(COLLECTIONS.lifecycles + '/' + h.subject), false);
});
for (const loss of ['expired', 'missing'])
    test(`active none authority requires current disclosure: ${loss}`, async () => {
        const h = await setup();
        await h.bridge.enroll(h.context, h.request());
        if (loss === 'missing')
            h.database.deleteRecordForTest(COLLECTIONS.disclosures, h.subject);
        else
            h.clock.advance(366 * 86400000);
        await assert.rejects(h.read());
    });
test('revoke/reaccept and terminal generation use existing authority publications', async () => {
    const h = await setup(true);
    await h.bridge.enroll(h.context, h.request());
    const paid = await h.read();
    await h.repository.revokeDisclosure(h.subject, h.clock.now());
    assert.equal((await h.read()).snapshot.reason, 'revoked');
    await acceptDisclosure(h);
    const after = await h.read();
    assert.equal(after.snapshot.reason, 'requires_verification');
    assert.ok(after.snapshot.publicationRevision > paid.snapshot.publicationRevision);
    const root = h.root();
    await h.repository.retireLifecycle(h.subject, root, h.clock.now());
    const retired = await h.read();
    assert.equal(retired.snapshot.reason, 'retired');
    assert.equal(retired.snapshot.lifecycleGeneration, root.lifecycleGeneration + 1);
    await assert.rejects(h.bridge.enroll(h.context, h.request()));
});


test('enrollment cannot commit when retained disclosure expires during its final orphan query', async () => {
    const h = await setup();
    const disclosure = h.database.snapshotForTest().get(COLLECTIONS.disclosures + '/' + h.subject) as DisclosureRecord;
    disclosure.retentionExpiresAt = new Date(+h.clock.now() + 100);
    h.database.setUnsafeRecordForTest(COLLECTIONS.disclosures, h.subject, disclosure);
    const before = h.database.snapshotForTest();
    const original = h.database.runTransaction.bind(h.database);
    h.database.runTransaction = work => original(tx => work({
        ...tx,
        findSubjectBrokerRoute: async subject => {
            const result = await tx.findSubjectBrokerRoute(subject);
            h.clock.advance(101);
            return result;
        },
    }));
    await assert.rejects(h.bridge.enroll(h.context, h.request()));
    // Includes root marker, both reciprocal records, and both control counters.
    assert.deepEqual(h.database.snapshotForTest(), before);
});

for (const boundary of ['deferred_callback', 'final_read', 'committed_result'] as const)
    test(`enrollment enforces its absolute 50-second child cap at ${boundary}`, async t => {
        const h = await setup();
        const before = h.database.snapshotForTest();
        const start = Date.now();
        let wallTime = start;
        t.mock.method(Date, 'now', () => wallTime);
        const parent = new BillingDeadline(start + 120000);
        const original = h.database.runTransaction.bind(h.database);
        h.database.runTransaction = async work => {
            if (boundary === 'deferred_callback')
                wallTime = start + 50001;
            const result = await original(tx => work({
                ...tx,
                findSubjectBrokerRoute: async subject => {
                    const value = await tx.findSubjectBrokerRoute(subject);
                    if (boundary === 'final_read')
                        wallTime = start + 50001;
                    return value;
                },
            }));
            if (boundary === 'committed_result')
                wallTime = start + 50001;
            return result;
        };
        await assert.rejects(h.bridge.enroll(h.context, h.request(), parent), /billing deadline elapsed/);
        assert.ok(wallTime < parent.expiresAt, 'the child cap, not parent expiry, caused rejection');
        assert.equal(parent.signal.aborted, true, 'late work inherits cancellation');
        if (boundary !== 'committed_result') {
            assert.deepEqual(h.database.snapshotForTest(), before);
        }
        else {
            // A valid callback already committed. Response timeout cannot undo
            // enrollment; a fresh invocation must replay without a second count.
            assert.ok(h.root().brokerBridge);
            const committed = h.database.snapshotForTest();
            h.database.runTransaction = original;
            await h.bridge.enroll(h.context, h.request());
            assert.deepEqual(h.database.snapshotForTest(), committed);
        }
    });

for (const boundary of ['deferred_callback', 'transaction_result'] as const)
    test(`projection enforces its absolute 10-second child cap at ${boundary}`, async t => {
        const h = await setup(true);
        await h.bridge.enroll(h.context, h.request());
        const before = h.database.snapshotForTest();
        const start = Date.now();
        let wallTime = start;
        t.mock.method(Date, 'now', () => wallTime);
        const parent = new BillingDeadline(start + 50000);
        const original = h.database.runTransaction.bind(h.database);
        h.database.runTransaction = async work => {
            if (boundary === 'deferred_callback')
                wallTime = start + 10001;
            const result = await original(work);
            if (boundary === 'transaction_result')
                wallTime = start + 10001;
            return result;
        };
        await assert.rejects(h.bridge.read({ version: 'credit-authority-read-v1', routingKeyVersion: ROUTE_KEY, route: h.route, challenge: 'd'.repeat(32) }, parent), /billing deadline elapsed/);
        assert.ok(wallTime < parent.expiresAt);
        assert.equal(parent.signal.aborted, true);
        assert.deepEqual(h.database.snapshotForTest(), before);
    });

test('bridge checks child expiry before deferred work begins', async t => {
    const h = await setup();
    const before = h.database.snapshotForTest();
    const start = Date.now();
    let wallTime = start;
    t.mock.method(Date, 'now', () => wallTime);
    let transactions = 0;
    const original = h.database.runTransaction.bind(h.database);
    h.database.runTransaction = work => { transactions++; return original(work); };
    const result = h.bridge.enroll(h.context, h.request(), new BillingDeadline(start + 120000));
    wallTime = start + 50001;
    await assert.rejects(result, /billing deadline elapsed/);
    assert.equal(transactions, 0);
    assert.deepEqual(h.database.snapshotForTest(), before);
});

test('bridge promptly inherits parent cancellation and fences a late final read', async () => {
    const h = await setup();
    const before = h.database.snapshotForTest();
    const parent = new BillingDeadline(Date.now() + 120000);
    let entered!: () => void;
    const atRead = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    let finished!: () => void;
    const transactionFinished = new Promise<void>(resolve => { finished = resolve; });
    const original = h.database.runTransaction.bind(h.database);
    h.database.runTransaction = async work => {
        try {
            return await original(tx => work({
                ...tx,
                findSubjectBrokerRoute: async subject => {
                    const result = await tx.findSubjectBrokerRoute(subject);
                    entered();
                    await held;
                    return result;
                },
            }));
        }
        finally { finished(); }
    };
    const result = h.bridge.enroll(h.context, h.request(), parent);
    await atRead;
    parent.cancel();
    try { await assert.rejects(result, /billing deadline elapsed/); }
    finally { release(); }
    await transactionFinished;
    assert.deepEqual(h.database.snapshotForTest(), before);
});
