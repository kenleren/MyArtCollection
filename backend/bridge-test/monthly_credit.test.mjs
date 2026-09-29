/** Actual billing → identity → monthly broker. Synthetic providers, local emulator only. */
import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { setup } from './credit_identity.test.mjs';
import { MONTHLY_POLICY } from '../broker/build/dist-test/monthly_credit_fixture.js';
import { TEST_ACCOUNT_KEY } from '../broker/build/dist-test/credit_identity_fixture.js';
import { request, ResultProvider } from '../broker/build/dist-test/test_helpers.js';
import { createMonthlyBrokerSession } from '../broker/build/src/monthly_broker.js';
import { initializeMonthlyCutover } from '../broker/build/src/monthly_credit_store.js';
import { FirestoreDurableBrokerStore } from '../broker/build/src/durable_protection.js';
import { FirestoreCreditIdentityDatabase } from '../broker/build/src/credit_identity_store.js';
import { CreditIdentityDeadline } from '../broker/build/src/credit_identity_deadline.js';
import { M, fingerprint } from '../broker/build/src/monthly_credit_protocol.js';
const live = {
    record_version: 'broker-control-v1', breakerOpen: false, perSubjectCreditCap: 3, brokerCreditCap: 20, oneInFlightPerSubject: true
};
async function monthly(stores) {
    const t = await setup(stores);
    await t.enroll();
    await t.consent('accept', 0);
    await t.register();
    await t.brokerDb.transaction(async (tx) => { tx.set('brokerDurableControl', 'live', live); });
    await initializeMonthlyCutover(t.brokerDb, 'brokerDurable', MONTHLY_POLICY, 'a'.repeat(64), t.f.deadline());
    const provider = new ResultProvider();
    const options = {
        database: t.brokerDb, identityService: t.broker, accountKey: TEST_ACCOUNT_KEY, collectionPrefix: 'brokerDurable', now: t.f.clock.now, providerProvisioner: { configure: () => ({}), construct: () => provider }, authorizeProvider: () => undefined
    };
    const open = (input = request({ request_id: randomUUID() }), overrides = {}) => createMonthlyBrokerSession(MONTHLY_POLICY, () => ({ ...options, ...overrides }), t.f.tokens(), input, t.f.deadline());
    await (await open()).enroll();
    const account = () => t.brokerDb.transaction(tx => tx.get(M.accounts, t.f.accountSubject));
    return {
        ...t, provider, open, account
    };
}
test('actual synthetic billing authority supports one account-month broker spend and replay', async () => {
    const t = await monthly(), input = request();
    assert.equal((await (await t.open(input)).research()).ok, true);
    assert.equal((await t.account()).totals.finalized, 1);
    assert.equal((await (await t.open(input)).research()).ok, true);
    assert.equal(t.provider.callCount, 1);
});
const emulator = process.env.FIRESTORE_EMULATOR_HOST;
if (emulator) {
    if (!/^(127\.0\.0\.1|localhost):\d+$/.test(emulator))
        throw Error('local emulator required');
    const require = createRequire(new URL('../play_billing/package.json', import.meta.url)), { initializeApp, deleteApp } = require('firebase-admin/app'), { getFirestore } = require('firebase-admin/firestore');
    async function stores(label) { const app = initializeApp({ projectId: `demo-monthly-${label}` }, `monthly-${label}-${randomUUID()}`); after(() => deleteApp(app)); return { billing: getFirestore(app, 'archivale-play-billing'), broker: getFirestore(app) }; }
    test('default emulator actual billing→broker: concurrent last credit, replay and high-water deletion', async () => {
        const fs = await stores('last'), t = await monthly(fs);
        assert.equal((await (await t.open()).research()).ok, true);
        const a = request({ request_id: randomUUID() }), b = request({ request_id: randomUUID() });
        const sessions = await Promise.all([t.open(a), t.open(b)]);
        const results = await Promise.all(sessions.map(s => s.research()));
        assert.equal(results.filter(r => r.ok).length, 1);
        assert.equal(t.provider.callCount, 2);
        assert.equal((await t.account()).totals.exposed, 2);
        const winner = results[0].ok ? a : b;
        assert.equal((await (await t.open(winner)).research()).ok, true);
        assert.equal(t.provider.callCount, 2);
        const fp = fingerprint(TEST_ACCOUNT_KEY, t.f.accountSubject, winner.request_id);
        await fs.broker.doc(M.requests + '/' + fp).delete();
        await fs.broker.doc(M.ledger + '/' + fp).delete();
        assert.equal((await (await t.open(winner)).research()).ok, false);
        assert.equal(t.provider.callCount, 2);
        assert.equal((await t.account()).totals.exposed, 2);
    });
    test('default emulator held authorization plus consent withdrawal blocks provider and settles original month', async () => {
        const t = await monthly(await stores('withdraw'));
        let release, entered;
        const held = new Promise(r => release = r), atAuth = new Promise(r => entered = r);
        const session = await t.open(request(), { authorizeProvider: async () => { entered(); await held; } }), work = session.research();
        await atAuth;
        assert.equal((await t.consent('revoke', 1)).status, 'revoked');
        release();
        assert.equal((await work).ok, false);
        assert.equal(t.provider.callCount, 0);
        assert.equal((await t.account()).totals.refunded, 1);
        assert.equal((await t.account()).inFlight, null);
    });
    for (const prefix of ['brokerDurable', 'otherLegacy'])
        test(`default emulator v1/cutover contention uses actual ${prefix} authority`, async () => {
            const fs = (await stores(prefix.toLowerCase())).broker, legacy = new FirestoreDurableBrokerStore(fs, { collectionPrefix: prefix }), db = new FirestoreCreditIdentityDatabase(fs, legacy);
            await legacy.controlRef().set(live);
            const input = {
                quota_subject: 'quota_subject_v1_' + 'b'.repeat(64), request_id: randomUUID(), payload_hash: 'c'.repeat(64), credit_cost: 1, now: new Date()
            };
            const [cutover, reservation] = await Promise.allSettled([initializeMonthlyCutover(db, prefix, MONTHLY_POLICY, 'a'.repeat(64), new CreditIdentityDeadline()), legacy.createRequestLifecycle().acquire(input)]);
            assert.equal(reservation.status, 'fulfilled');
            if (cutover.status === 'fulfilled') {
                assert.equal(reservation.value.kind, 'migration_required');
                assert.equal((await legacy.globalUsageRef().get()).exists, false);
            }
            else {
                assert.equal(reservation.value.kind, 'reserved');
                assert.equal((await fs.doc(M.control + '/control').get()).exists, false);
                assert.equal((await legacy.controlRef().get()).data().monthlyCutover, undefined);
            }
        });
    test('default emulator lost terminal/settlement responses confirm exactly once in actual broker', async () => {
        const t = await monthly(await stores('lost'));
        let lostTerminal = false, lostSettlement = false;
        const original = t.brokerDb.transaction.bind(t.brokerDb);
        t.brokerDb.transaction = async (work) => {
            const result = await original(work);
            const a = await original(tx => tx.get(M.accounts, t.f.accountSubject));
            if (!lostTerminal && a?.inFlight?.phase === 'terminal_pending_settlement') {
                lostTerminal = true;
                throw Error('synthetic lost terminal');
            }
            if (!lostSettlement && a?.totals.finalized === 1) {
                lostSettlement = true;
                throw Error('synthetic lost settlement');
            }
            return result;
        };
        const result = await (await t.open()).research();
        assert.equal(result.ok, true);
        assert.equal(lostTerminal, true);
        assert.equal(lostSettlement, true);
        assert.equal(t.provider.callCount, 1);
        assert.equal((await t.account()).totals.finalized, 1);
    });
}
