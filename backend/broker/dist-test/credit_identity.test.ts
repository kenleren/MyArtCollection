import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { creditIdentityFixture, deferred, TEST_UID, TEST_APP, TEST_CONFIG, TEST_ACCOUNT_KEY, TEST_ROUTE_KEY } from './credit_identity_fixture.js';
import { CreditIdentityService, createCreditIdentity, accountId, routeId, accountForUid, routeForUid, authorityDigest, admissionDigest, PROJECT, type CreditAuthoritySnapshot } from '../src/credit_identity.js';
import { FirestoreCreditIdentityDatabase, CREDIT_COLLECTIONS as C } from '../src/credit_identity_store.js';
import { FirebaseAdminBrokerTokenVerifier } from '../src/durable_protection.js';
const command = (generation = 0, id = randomUUID()) => ({ version: 'credit-registration-v1', requestId: id, expectedRegistrationGeneration: generation });
function none(s: CreditAuthoritySnapshot, reason: 'revoked' | 'retired' | 'requires_verification', revision: number): CreditAuthoritySnapshot {
    const { planId, playExpiresAtMs, validUntilMs, ...base } = s;
    return { ...base, state: 'none', reason, publicationRevision: revision, lifecycleStatus: reason === 'retired' ? 'retired' : reason === 'revoked' ? 'consent_paused' : 'active', lifecycleGeneration: s.lifecycleGeneration + (reason === 'retired' ? 1 : 0) };
}
test('stable account domains are independent of app/install and private from shared route', () => {
    assert.equal(accountForUid(TEST_ACCOUNT_KEY, TEST_UID), accountForUid(TEST_ACCOUNT_KEY, TEST_UID));
    assert.notEqual(accountForUid(TEST_ACCOUNT_KEY, TEST_UID), routeForUid(TEST_ROUTE_KEY, TEST_UID));
    assert.notEqual(accountForUid(TEST_ACCOUNT_KEY, TEST_UID), accountForUid(TEST_ACCOUNT_KEY, TEST_UID + '2'));
    assert.equal(admissionDigest(TEST_CONFIG, TEST_ACCOUNT_KEY, new Set(['b', 'a']), new Set(['z', 'a'])), admissionDigest(TEST_CONFIG, TEST_ACCOUNT_KEY, new Set(['a', 'b']), new Set(['a', 'z'])));
});
test('disabled factory never evaluates any dependencies', () => { for (const c of [undefined, {}, { enabled: false }])
    assert.equal(createCreditIdentity(c, () => { throw Error('unexpected'); }), undefined); assert.throws(() => createCreditIdentity({ enabled: true }, () => { throw Error('unexpected'); })); });
for (const consumed of [true, undefined, null, 'false', 0])
    test(`real guard rejects non-fresh consumption ${String(consumed)}`, async () => {
        let calls = 0;
        const verifier = new FirebaseAdminBrokerTokenVerifier({ config: { projectId: PROJECT, projectNumber: '123', allowedAppIds: new Set([TEST_APP]) }, auth: { verifyIdToken: async () => ({ uid: TEST_UID, aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`, firebase: { sign_in_provider: 'google.com' } }) }, appCheck: { verifyToken: async () => { calls++; return { appId: TEST_APP, alreadyConsumed: consumed as any, token: { aud: [PROJECT, '123'], iss: 'https://firebaseappcheck.googleapis.com/123', sub: TEST_APP } }; } } });
        const result = await verifier.verify({ authorizationHeader: 'Bearer synthetic', appCheckToken: 'synthetic' });
        assert.equal(result.ok, false);
        assert.equal(calls, 1);
    });
test('actual guard consumes a fresh token once; replay cannot register', async () => { const f = await creditIdentityFixture({ ready: false }), tokens = f.tokens(); assert.equal((await f.constructorOptions.verifier.verify(tokens)).ok, true); assert.equal((await f.constructorOptions.verifier.verify(tokens)).ok, false); assert.equal((await f.service.register(tokens, command())).status, 'unavailable'); assert.equal(f.readCount(), 0); });
test('two-read registration has durable lost-result receipt and never extends verification', async () => {
    const f = await creditIdentityFixture({ ready: false });
    await f.consent('accept');
    const input = command();
    assert.equal((await f.service.register(f.tokens(), input)).status, 'ready');
    const before = f.db.snapshotForTest();
    assert.equal((await f.service.register(f.tokens(), input)).status, 'ready');
    assert.equal(f.readCount(), 2);
    assert.deepEqual(f.db.snapshotForTest(), before);
    assert.equal((await f.evaluate()).status, 'eligible');
    const all = JSON.stringify([...before]);
    for (const forbidden of [TEST_UID, Buffer.from(TEST_UID).toString('base64url'), 'synthetic-auth', 'purchaseToken', 'tokenFingerprint', 'obfuscatedAccountId'])
        assert.equal(all.includes(forbidden), false);
});
for (const c of [C.accounts, C.routes, C.authority])
    test(`lost reciprocal ${c} cannot recreate enrollment`, async () => {
        const f = await creditIdentityFixture();
        f.db.deleteForTest(c, c === C.routes ? routeId(f.route) : accountId(f.accountSubject));
        const before = f.db.snapshotForTest();
        assert.equal((await f.consent('accept')).status, 'unavailable');
        assert.equal((await f.evaluate()).status, 'unavailable');
        assert.deepEqual(f.db.snapshotForTest(), before);
    });
test('old acceptance cannot undo consent withdrawal; reaccept needs fresh registration', async () => {
    const f = await creditIdentityFixture({ ready: false }), accept = { version: 'credit-consent-command-v1', requestId: randomUUID(), expectedConsentRevision: 0, action: 'accept', researchVersion: 'research-consent-v1', bridgeVersion: 'paid-ai-bridge-consent-v1' };
    assert.equal((await f.service.consent(f.tokens(), accept)).status, 'accepted');
    assert.equal((await f.register()).status, 'ready');
    const revoke = { ...accept, requestId: randomUUID(), expectedConsentRevision: 1, action: 'revoke' };
    assert.equal((await f.service.consent(f.tokens(), revoke)).status, 'revoked');
    assert.equal((await f.service.consent(f.tokens(), accept)).status, 'unavailable');
    assert.equal((await f.evaluate()).status, 'none');
    assert.equal((await f.service.consent(f.tokens(), { ...accept, requestId: randomUUID(), expectedConsentRevision: 2 })).status, 'accepted');
    assert.equal((await f.evaluate()).status, 'none');
    assert.equal((await f.register(3)).status, 'ready');
});
test('optional corrupt snapshot and absent controls do not prevent broker withdrawal', async () => {
    const f = await creditIdentityFixture(), id = accountId(f.accountSubject), record = f.db.snapshotForTest().get(C.authority + '/' + id) as any;
    f.db.setForTest(C.authority, id, { ...record, snapshot: { malformed: true } });
    f.db.deleteForTest(C.control, 'control');
    assert.equal((await f.consent('revoke')).status, 'revoked');
    assert.equal((await f.evaluate()).status, 'unavailable');
    assert.deepEqual((f.db.snapshotForTest().get(C.authority + '/' + id) as any).snapshot, { malformed: true });
});
test('new policy control/config blocks old completed receipt until fresh registration', async () => {
    const f = await creditIdentityFixture(), service = new CreditIdentityService({ ...f.constructorOptions, config: { ...TEST_CONFIG, admissionPolicyId: 'e'.repeat(32) } }), pair = service.initialControlsForTest();
    for (const [name, value] of Object.entries(pair))
        f.db.setForTest(C.control, name, { ...value, revision: 1, enrolledAccounts: 1 });
    assert.equal((await service.evaluate(f.tokens())).status, 'unavailable');
    const s = { ...f.getSnapshot(), publicationRevision: 2 };
    assert.equal((await service.applyAuthenticatedSnapshot(s, authorityDigest(s))).status, 'unavailable');
    assert.equal((await service.register(f.tokens(), command(1))).status, 'ready');
    assert.equal((await service.evaluate(f.tokens())).status, 'eligible');
});
test('terminal G+1 supersedes paid G; conflicting equal digest and unknown epoch are rejected', async () => {
    const f = await creditIdentityFixture(), old = f.getSnapshot(), terminal = none(old, 'retired', 2);
    assert.equal((await f.service.applyAuthenticatedSnapshot(terminal, authorityDigest(terminal))).status, 'applied');
    assert.equal((await f.service.applyAuthenticatedSnapshot(old, authorityDigest(old))).status, 'ignored');
    assert.equal((await f.evaluate()).status, 'none');
    const foreign = { ...terminal, lifecycleEpoch: 'e'.repeat(32) };
    assert.equal((await f.service.applyAuthenticatedSnapshot(foreign, authorityDigest(foreign))).status, 'unavailable');
    const conflict = { ...terminal, verifiedAtMs: terminal.verifiedAtMs - 1 };
    assert.equal((await f.service.applyAuthenticatedSnapshot(conflict, authorityDigest(conflict))).status, 'unavailable');
    assert.equal((await f.register(1)).status, 'unavailable');
});
for (const gap of [1, 2])
    test(`withdrawal during read ${gap} fences all late results`, async () => {
        const f = await creditIdentityFixture({ ready: false });
        await f.consent('accept');
        const entered = deferred(), release = deferred();
        let calls = 0;
        const original = f.transport.read;
        f.transport.read = async (req) => { if (++calls === gap) {
            entered.resolve();
            await release.promise;
        } return original(req); };
        const pending = f.register();
        await entered.promise;
        assert.equal((await f.consent('revoke')).status, 'revoked');
        release.resolve();
        assert.equal((await pending).status, 'unavailable');
        assert.equal((await f.evaluate()).status, 'none');
    });
test('higher pending delivery defeats older second read without resetting high-water', async () => {
    const f = await creditIdentityFixture({ ready: false });
    await f.consent('accept');
    const entered = deferred(), release = deferred();
    let calls = 0;
    const original = f.transport.read;
    f.transport.read = async (req) => { const response = await original(req); if (++calls === 2) {
        entered.resolve();
        await release.promise;
    } return response; };
    const pending = f.register();
    await entered.promise;
    const s = none(f.getSnapshot(), 'revoked', 2);
    assert.equal((await f.service.applyAuthenticatedSnapshot(s, authorityDigest(s))).status, 'applied');
    release.resolve();
    assert.equal((await pending).status, 'unavailable');
    const record = f.db.snapshotForTest().get(C.authority + '/' + accountId(f.accountSubject)) as any;
    assert.equal(record.snapshot.publicationRevision, 2);
    assert.equal(record.status, 'blocked');
});
test('same-owner resumed read-one failure cannot clean up advanced read-two', async () => {
    const f = await creditIdentityFixture({ ready: false });
    await f.consent('accept');
    const first = deferred(), second = deferred(), releaseFirst = deferred(), releaseSecond = deferred();
    let calls = 0;
    const original = f.transport.read;
    f.transport.read = async (req) => { calls++; if (calls === 1) {
        first.resolve();
        await releaseFirst.promise;
        throw Error('synthetic');
    } if (calls === 3) {
        second.resolve();
        await releaseSecond.promise;
    } return original(req); };
    const input = command(), a = f.service.register(f.tokens(), input);
    await first.promise;
    const b = f.service.register(f.tokens(), input);
    await second.promise;
    releaseFirst.resolve();
    assert.equal((await a).status, 'unavailable');
    assert.equal((f.db.snapshotForTest().get(C.authority + '/' + accountId(f.accountSubject)) as any).owner.stage, 'read_two');
    releaseSecond.resolve();
    assert.equal((await b).status, 'ready');
});
test('expired owner reclaim preserves high-water and late old owner loses', async () => {
    const f = await creditIdentityFixture({ ready: false });
    await f.consent('accept');
    const entered = deferred(), release = deferred();
    let calls = 0;
    const original = f.transport.read;
    f.transport.read = async (req) => { if (++calls === 1) {
        entered.resolve();
        await release.promise;
    } return original(req); };
    const old = f.register();
    await entered.promise;
    f.clock.advance(90001);
    f.setSnapshot({ ...f.getSnapshot(), verifiedAtMs: f.clock.now(), validUntilMs: f.clock.now() + 300000 });
    assert.equal((await f.register(1)).status, 'ready');
    release.resolve();
    assert.equal((await old).status, 'unavailable');
    assert.equal((await f.evaluate()).status, 'eligible');
});
test('client-chosen identity, extra payload and malformed authority cannot enter durable records', async () => {
    const f = await creditIdentityFixture({ ready: false });
    assert.equal((await f.service.register(f.tokens(), { ...command(), route: 'a'.repeat(64) })).status, 'unavailable');
    assert.equal(f.readCount(), 0);
    await f.consent('accept');
    f.transport.read = async (req) => ({ version: 'credit-authority-read-result-v1', challenge: req.challenge, snapshot: { ...f.getSnapshot(), uid: 'extra' }, digest: 'a'.repeat(64) });
    assert.equal((await f.register()).status, 'unavailable');
});
test('blocked completion receipt cannot authorize a mixed ready row with old paid snapshot', async () => {
    const f = await creditIdentityFixture(), id = accountId(f.accountSubject), record = f.db.snapshotForTest().get(C.authority + '/' + id) as any;
    f.db.setForTest(C.authority, id, { ...record, lastRegistrationCommand: { ...record.lastRegistrationCommand, outcome: 'blocked' } });
    assert.equal((await f.evaluate()).status, 'unavailable');
});
test('remote absolute ten-second cap rejects fulfilled late result before its timer fires', async () => {
    const f = await creditIdentityFixture({ ready: false });
    await f.consent('accept');
    const original = f.transport.read;
    f.transport.read = async (req) => { f.clock.advance(10001); return original(req); };
    assert.equal((await f.register()).status, 'unavailable');
    assert.equal((await f.evaluate()).status, 'none');
});
test('retirement must advance exactly one generation; malformed same-generation terminal is rejected', async () => {
    const f = await creditIdentityFixture();
    const terminal = none(f.getSnapshot(), 'retired', 2);
    terminal.lifecycleGeneration = 1;
    assert.equal((await f.service.applyAuthenticatedSnapshot(terminal, authorityDigest(terminal))).status, 'unavailable');
    assert.equal((await f.evaluate()).status, 'eligible');
});

test('Firestore bridge adapter requires the explicit default database', () => {
    for (const databaseId of [undefined, 'archivale-play-billing', 'other']) {
        assert.throws(() => new FirestoreCreditIdentityDatabase({ databaseId } as any));
    }
});

test('wider parent cannot extend the fifty-second admission deadline before a transaction callback', async () => {
    const f = await creditIdentityFixture({ready:false});
    f.db.beforeTransaction = async () => { f.db.beforeTransaction = undefined; f.clock.advance(50001); };
    const result = await f.service.consent(f.tokens(), {version:'credit-consent-command-v1', requestId:randomUUID(), expectedConsentRevision:0, action:'accept', researchVersion:'research-consent-v1', bridgeVersion:'paid-ai-bridge-consent-v1'}, f.deadline(3600000));
    assert.equal(result.status,'unavailable');
    assert.equal([...f.db.snapshotForTest().keys()].some(key=>key.startsWith(C.accounts+'/')),false);
});
