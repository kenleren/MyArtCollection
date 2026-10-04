import { randomUUID } from 'node:crypto';
import { FirebaseAdminBrokerTokenVerifier } from '../src/durable_protection.js';
import { CreditIdentityService, CreditIdentityDeadline, type CreditIdentityOptions, type CreditIdentityConfig, type CreditAuthoritySnapshot, accountForUid, routeForUid, authorityDigest, ACCOUNT_KEY, ROUTE_KEY, PROJECT } from '../src/credit_identity.js';
import { InMemoryCreditIdentityDatabase, CREDIT_COLLECTIONS as C } from '../src/credit_identity_store.js';
export const TEST_UID = 'synthetic-credit-owner';
export const TEST_APP = '1:123456789:android:creditidentity';
export const TEST_ROUTE_KEY = 'synthetic-route-key-00000000000000';
export const TEST_ACCOUNT_KEY = 'synthetic-account-key-000000000000';
export const TEST_CONFIG: CreditIdentityConfig = { version: 'credit-identity-config-v1', projectId: PROJECT, enabled: true, routingKeyVersion: ROUTE_KEY, accountKeyVersion: ACCOUNT_KEY,
    cutoverId: 'a'.repeat(32), maxAccounts: 20, authorityMaxAgeMs: 60000, admissionPolicyId: 'b'.repeat(32) };
export async function creditIdentityFixture(options: {
    nowMs?: number;
    verifiedAtMs?: number;
    validUntilMs?: number;
    ready?: boolean;
    collectionPrefix?: string;
    appIds?: string[];
    uid?: string;
    ownerUids?: string[];
    database?: InMemoryCreditIdentityDatabase;
} = {}) {
    const uid = options.uid ?? TEST_UID;
    let now = options.nowMs ?? 1900000000000;
    let sequence = 0, tokenSequence = 0, consentRevision = 0;
    const consumed = new Set<string>();
    const tokenApps = new Map<string,string>();
    const clock = { now: () => now, set: (value: number) => { now = value; }, advance: (ms: number) => { now += ms; } };
    const db = options.database ?? new InMemoryCreditIdentityDatabase(options.collectionPrefix);
    db.setOperator(uid, { entitled: true, breakerOpen: false });
    const verifier = new FirebaseAdminBrokerTokenVerifier({ config: { projectId: PROJECT, projectNumber: '123456789', allowedAppIds: new Set(options.appIds ?? [TEST_APP]) }, auth: { verifyIdToken: async (token, revoked) => {
                if (token !== 'synthetic-auth' || !revoked)
                    throw Error('fixed');
                return { uid, aud: PROJECT, iss: `https://securetoken.google.com/${PROJECT}`, firebase: { sign_in_provider: 'google.com' } };
            } }, appCheck: { verifyToken: async (token, options) => {
                if (!options.consume)
                    throw Error('fixed');
                const alreadyConsumed = consumed.has(token);
                consumed.add(token);
                const app = tokenApps.get(token) ?? TEST_APP;
                return { appId: app, alreadyConsumed,
                    token: { aud: [PROJECT, '123456789'], iss: 'https://firebaseappcheck.googleapis.com/123456789', sub: app, app_id: app } };
            } } });
    const tokens = (app=TEST_APP) => { const token=`fresh-app-${++tokenSequence}`; tokenApps.set(token,app); return {authorizationHeader:'Bearer synthetic-auth',appCheckToken:token}; };
    let snapshot: CreditAuthoritySnapshot = { version: 'credit-authority-v1', projectId: PROJECT, routingKeyVersion: ROUTE_KEY, route: routeForUid(TEST_ROUTE_KEY, uid), enrollmentId: 'c'.repeat(32),
        lifecycleEpoch: 'd'.repeat(32), lifecycleGeneration: 1, publicationRevision: 1, lifecycleStatus: 'active', state: 'active', verifiedAtMs: options.verifiedAtMs ?? now, planId: 'starter',
        playExpiresAtMs: now + 3600000, validUntilMs: options.validUntilMs ?? now + 300000 };
    let reads = 0;
    const transport = { read: async (request: any) => { reads++; return { version: 'credit-authority-read-result-v1', challenge: request.challenge, snapshot: { ...snapshot }, digest: authorityDigest(snapshot) }; } };
    const constructorOptions: CreditIdentityOptions = { config: TEST_CONFIG, database: db, verifier, transport, routingKey: TEST_ROUTE_KEY, accountKey: TEST_ACCOUNT_KEY,
        ownerUids: new Set(options.ownerUids ?? [uid]), appIds: new Set(options.appIds ?? [TEST_APP]), now: clock.now, newNonce: () => (++sequence).toString(16).padStart(32, '0') };
    const service = new CreditIdentityService(constructorOptions);
    const pair = service.initialControlsForTest();
    if (!db.snapshotForTest().has(C.control + '/control')) {
        db.setForTest(C.control, 'control', pair.control);
        db.setForTest(C.control, 'initialization', pair.initialization);
    }
    const consent = async (action: 'accept' | 'revoke') => { const r = await service.consent(tokens(), { version: 'credit-consent-command-v1', requestId: randomUUID(), expectedConsentRevision: consentRevision, action, researchVersion: 'research-consent-v1', bridgeVersion: 'paid-ai-bridge-consent-v1' }); if (r.consentRevision !== undefined)
        consentRevision = r.consentRevision; return r; };
    const register = async (expectedRegistrationGeneration = 0, requestId = randomUUID()) => service.register(tokens(), { version: 'credit-registration-v1', requestId, expectedRegistrationGeneration });
    if (options.ready !== false) {
        if ((await consent('accept')).status !== 'accepted' || (await register()).status !== 'ready')
            throw Error('fixture setup failed');
    }
    return { service, db, clock, tokens, consent, register, constructorOptions, transport, accountSubject: accountForUid(TEST_ACCOUNT_KEY, uid), route: snapshot.route,
        evaluate: (deadline?: CreditIdentityDeadline) => service.evaluate(tokens(), deadline), deadline: (durationMs = 50000) => new CreditIdentityDeadline(clock.now() + durationMs, clock.now),
        getSnapshot: () => ({ ...snapshot }), setSnapshot: (value: CreditAuthoritySnapshot) => { snapshot = { ...value }; }, readCount: () => reads };
}
export function deferred<T = void>() { let resolve!: (value: T | PromiseLike<T>) => void; let reject!: (reason?: unknown) => void; const promise = new Promise<T>((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
