import { randomBytes } from 'node:crypto';
import { admittedOwner } from './credit_admission.js';
import type { BrokerTokenVerifier, VerifyBrokerTokensInput } from './durable_protection.js';
import { CreditIdentityDeadline } from './credit_identity_deadline.js';
import { CREDIT_COLLECTIONS as C, type CreditIdentityDatabase, type CreditTransaction } from './credit_identity_store.js';
import { ACCOUNT_KEY, ROUTE_KEY, PROJECT, accountForUid, routeForUid, authorityDigest, controls, enrollControls, initialControls, parseConfig, parseReply, validSnapshot, fail, shape, hex, nonce, count, positive, increment, uuid, hash, date, type CreditIdentityConfig, type CreditAuthoritySnapshot, type AuthorityRead, type AuthorityReply, type CreditPlan } from './credit_identity_protocol.js';
export * from './credit_identity_protocol.js';
export { CreditIdentityDeadline } from './credit_identity_deadline.js';
export interface CreditIdentityTransport {
    read(request: AuthorityRead, deadline: CreditIdentityDeadline): Promise<unknown>;
}
export interface CreditIdentityOptions {
    config: CreditIdentityConfig;
    database: CreditIdentityDatabase;
    verifier: BrokerTokenVerifier;
    transport: CreditIdentityTransport;
    routingKey: string;
    accountKey: string;
    ownerUids: ReadonlySet<string>;
    appIds: ReadonlySet<string>;
    now?: () => number;
    newNonce?: () => string;
}
interface Identity {
    uid: string;
    accountSubject: string;
    route: string;
}
interface Consent {
    status: 'accepted' | 'revoked';
    revision: number;
    assertionId: string;
    researchVersion: 'research-consent-v1';
    bridgeVersion: 'paid-ai-bridge-consent-v1';
}
export interface CreditAccount {
    version: 'broker-credit-account-v1';
    accountKeyVersion: typeof ACCOUNT_KEY;
    accountSubject: string;
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    cutoverId: string;
    createdAt: Date;
    updatedAt: Date;
    revision: number;
    consent: Consent;
    lastConsentCommand: {
        requestId: string;
        expectedRevision: number;
        digest: string;
    };
    registrationGeneration: number;
    receiverInitialized: true;
}
interface Route {
    version: 'broker-credit-route-v1';
    accountKeyVersion: typeof ACCOUNT_KEY;
    accountSubject: string;
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    cutoverId: string;
}
export interface RegistrationOwner {
    requestId: string;
    expectedGeneration: number;
    generation: number;
    nonce: string;
    assertionId: string;
    consentRevision: number;
    admissionPolicyId: string;
    leaseExpiresAt: Date;
    stage: 'read_one' | 'read_two';
}
interface Receipt {
    requestId: string;
    digest: string;
    expectedGeneration: number;
    committedGeneration: number;
    assertionId: string;
    consentRevision: number;
    admissionPolicyId: string;
    outcome: 'ready' | 'retired' | 'blocked';
}
export interface CreditReceiver {
    version: 'broker-credit-authority-v1';
    accountKeyVersion: typeof ACCOUNT_KEY;
    accountSubject: string;
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    cutoverId: string;
    status: 'unregistered' | 'pending' | 'ready' | 'blocked' | 'retired';
    registrationGeneration: number;
    boundConsentRevision?: number;
    boundAssertionId?: string;
    owner?: RegistrationOwner;
    lastRegistrationCommand?: Receipt;
    snapshot?: CreditAuthoritySnapshot;
    digest?: string;
}
interface Pair {
    account: CreditAccount;
    receiver: CreditReceiver;
    route: Route;
}
export type EligibilityResult = {
    status: 'eligible';
    planId: CreditPlan;
    fence: Readonly<{
        accountSubject: string;
        consentRevision: number;
        assertionId: string;
        registrationGeneration: number;
        lifecycleEpoch: string;
        lifecycleGeneration: number;
        publicationRevision: number;
        digest: string;
        verifiedAtMs: number;
        expiresAt: number;
    }>;
} | {
    status: 'none' | 'unavailable';
};
export type RegistrationResult = {
    status: 'ready' | 'retired' | 'blocked' | 'unavailable';
};
export const accountId = (subject: string) => `${ACCOUNT_KEY}_${subject}`;
export const routeId = (route: string) => `${ROUTE_KEY}_${route}`;
const versions = (v: any) => v.accountKeyVersion === ACCOUNT_KEY && v.routingKeyVersion === ROUTE_KEY && hex(v.accountSubject) && hex(v.route) && nonce(v.cutoverId);
function validConsent(v: unknown): v is Consent { return shape(v, ['status', 'revision', 'assertionId', 'researchVersion', 'bridgeVersion']) && ['accepted', 'revoked'].includes(v.status) && positive(v.revision) && nonce(v.assertionId) && v.researchVersion === 'research-consent-v1' && v.bridgeVersion === 'paid-ai-bridge-consent-v1'; }
function validAccount(v: unknown): v is CreditAccount {
    return shape(v, ['version', 'accountKeyVersion', 'accountSubject', 'routingKeyVersion', 'route', 'cutoverId', 'createdAt', 'updatedAt', 'revision', 'consent', 'lastConsentCommand', 'registrationGeneration', 'receiverInitialized']) &&
        v.version === 'broker-credit-account-v1' && versions(v) && date(v.createdAt) && date(v.updatedAt) && positive(v.revision) && validConsent(v.consent) && count(v.registrationGeneration) && v.receiverInitialized === true &&
        shape(v.lastConsentCommand, ['requestId', 'expectedRevision', 'digest']) && uuid(v.lastConsentCommand.requestId) && count(v.lastConsentCommand.expectedRevision) && hex(v.lastConsentCommand.digest) && v.lastConsentCommand.expectedRevision + 1 === v.consent.revision;
}
function validRoute(v: unknown): v is Route { return shape(v, ['version', 'accountKeyVersion', 'accountSubject', 'routingKeyVersion', 'route', 'cutoverId']) && v.version === 'broker-credit-route-v1' && versions(v); }
function validOwner(v: unknown): v is RegistrationOwner {
    return shape(v, ['requestId', 'expectedGeneration', 'generation', 'nonce', 'assertionId', 'consentRevision', 'admissionPolicyId', 'leaseExpiresAt', 'stage']) &&
        uuid(v.requestId) && count(v.expectedGeneration) && positive(v.generation) && v.generation === v.expectedGeneration + 1 && nonce(v.nonce) && nonce(v.assertionId) && positive(v.consentRevision) && nonce(v.admissionPolicyId) && date(v.leaseExpiresAt) && ['read_one', 'read_two'].includes(v.stage);
}
function validReceipt(v: unknown): v is Receipt {
    return shape(v, ['requestId', 'digest', 'expectedGeneration', 'committedGeneration', 'assertionId', 'consentRevision', 'admissionPolicyId', 'outcome']) &&
        uuid(v.requestId) && hex(v.digest) && count(v.expectedGeneration) && positive(v.committedGeneration) && v.committedGeneration === v.expectedGeneration + 1 && nonce(v.assertionId) && positive(v.consentRevision) && nonce(v.admissionPolicyId) && ['ready', 'retired', 'blocked'].includes(v.outcome);
}
function receiverCore(v: unknown): v is CreditReceiver {
    return shape(v, ['version', 'accountKeyVersion', 'accountSubject', 'routingKeyVersion', 'route', 'cutoverId', 'status', 'registrationGeneration'], ['boundConsentRevision', 'boundAssertionId', 'owner', 'lastRegistrationCommand', 'snapshot', 'digest']) &&
        v.version === 'broker-credit-authority-v1' && versions(v) && ['unregistered', 'pending', 'ready', 'blocked', 'retired'].includes(v.status) && count(v.registrationGeneration);
}
function validReceiver(v: unknown): v is CreditReceiver {
    if (!receiverCore(v))
        return false;
    if ((v.boundConsentRevision === undefined) !== (v.boundAssertionId === undefined) || v.boundConsentRevision !== undefined && (!positive(v.boundConsentRevision) || !nonce(v.boundAssertionId)))
        return false;
    if (['pending', 'ready', 'retired'].includes(v.status) && v.boundConsentRevision === undefined)
        return false;
    if (v.owner !== undefined && (!validOwner(v.owner) || v.owner.generation !== v.registrationGeneration || v.owner.assertionId !== v.boundAssertionId || v.owner.consentRevision !== v.boundConsentRevision))
        return false;
    if ((v.status === 'pending') !== (v.owner !== undefined))
        return false;
    if (v.lastRegistrationCommand !== undefined && (!validReceipt(v.lastRegistrationCommand) || v.lastRegistrationCommand.committedGeneration > v.registrationGeneration))
        return false;
    if ((v.snapshot === undefined) !== (v.digest === undefined) || v.snapshot !== undefined && (!validSnapshot(v.snapshot) || authorityDigest(v.snapshot) !== v.digest || v.snapshot.route !== v.route))
        return false;
    if (['ready', 'retired'].includes(v.status) && (v.snapshot === undefined || v.lastRegistrationCommand === undefined || v.lastRegistrationCommand.outcome === 'blocked'))
        return false;
    if (v.status === 'ready' && v.lastRegistrationCommand?.outcome !== 'ready')
        return false;
    return v.status !== 'retired' || v.snapshot?.lifecycleStatus === 'retired';
}
function related(a: {
    accountSubject: string;
    route: string;
    cutoverId: string;
}, b: {
    accountSubject: string;
    route: string;
    cutoverId: string;
}): boolean { return a.accountSubject === b.accountSubject && a.route === b.route && a.cutoverId === b.cutoverId; }
function sorted(values: Iterable<string>): string[] { return [...new Set(values)].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))); }
export function admissionDigest(config: CreditIdentityConfig, accountKey: string, ownerUids: ReadonlySet<string>, appIds: ReadonlySet<string>): string {
    if (!ownerUids.size || !appIds.size || [...appIds].some(v => typeof v !== 'string' || !v.trim() || v.length > 256))
        fail();
    return hash(['archivale-credit-admission-policy-v1', PROJECT, config.admissionPolicyId, sorted(appIds), sorted([...ownerUids].map(uid => accountForUid(accountKey, uid)))]);
}
export function createCreditIdentity(config: unknown, dependencies: () => Omit<CreditIdentityOptions, 'config'>): CreditIdentityService | undefined {
    if (!config || typeof config !== 'object' || !('enabled' in config) || config.enabled !== true)
        return undefined;
    const parsed = parseConfig(config);
    return new CreditIdentityService({
        ...dependencies(), config: parsed
    });
}
/** No exported network entrypoint uses this disabled source foundation. */
export class CreditIdentityService {
    private readonly config: Readonly<CreditIdentityConfig>;
    private readonly now: () => number;
    private readonly newNonce: () => string;
    private readonly owners: ReadonlySet<string>;
    private readonly apps: ReadonlySet<string>;
    readonly policyDigest: string;
    private readonly routingKey: string;
    private readonly accountKey: string;
    constructor(private readonly options: CreditIdentityOptions) {
        this.config = parseConfig(options.config);
        this.now = options.now ?? Date.now;
        this.newNonce = options.newNonce ?? (() => randomBytes(16).toString('hex'));
        this.owners = new Set(options.ownerUids);
        this.apps = new Set(options.appIds);
        this.routingKey = options.routingKey;
        this.accountKey = options.accountKey;
        this.policyDigest = admissionDigest(this.config, this.accountKey, this.owners, this.apps);
        routeForUid(this.routingKey, 'validate-key');
    }
    initialControlsForTest() { return initialControls(this.config, 'broker', this.policyDigest); }
    private deadline(): CreditIdentityDeadline { return new CreditIdentityDeadline(this.now() + 50000, this.now); }
    private freshNonce(): string {
        const n = this.newNonce();
        if (!nonce(n))
            fail();
        return n;
    }
    private async identity(tokens: VerifyBrokerTokensInput, d: CreditIdentityDeadline, requireAdmission = true): Promise<Identity> {
        const v = await d.run(() => this.options.verifier.verify(tokens));
        if (!v.ok || v.auth.projectId !== PROJECT || v.app.projectId !== PROJECT || !this.apps.has(v.app.appId) ||
            !['anonymous', 'google.com'].includes(v.auth.signInProvider) || requireAdmission && !admittedOwner(this.owners, v.auth.uid))
            fail();
        return {
            uid: v.auth.uid, accountSubject: accountForUid(this.accountKey, v.auth.uid), route: routeForUid(this.routingKey, v.auth.uid)
        };
    }
    private async pair(tx: CreditTransaction, i: Pick<Identity, 'accountSubject' | 'route'>, safety = false): Promise<Pair | undefined> {
        const a = await tx.get(C.accounts, accountId(i.accountSubject)), r = await tx.get(C.routes, routeId(i.route)), v = await tx.get(C.authority, accountId(i.accountSubject));
        if (a === undefined) {
            if (r !== undefined || v !== undefined || await tx.findAccountRoute(i.accountSubject) !== undefined)
                fail();
            return undefined;
        }
        if (!validAccount(a) || !validRoute(r) || !receiverCore(v) || (!safety && !validReceiver(v)) || !related(a, r) || !related(a, v) || !related(a, {
            ...i, cutoverId: this.config.cutoverId
        }) || v.registrationGeneration !== a.registrationGeneration)
            fail();
        return {
            account: a, receiver: v, route: r
        };
    }
    private async control(tx: CreditTransaction) { return controls(await tx.get(C.control, 'control'), await tx.get(C.control, 'initialization'), this.config, 'broker', this.policyDigest); }
    private accepted(p: Pair): void {
        if (p.account.consent.status !== 'accepted')
            fail();
    }
    private bound(p: Pair): void {
        this.accepted(p);
        if (p.receiver.boundAssertionId !== p.account.consent.assertionId || p.receiver.boundConsentRevision !== p.account.consent.revision)
            fail();
        const r = p.receiver.lastRegistrationCommand;
        if (['ready', 'retired'].includes(p.receiver.status) && (!r || r.admissionPolicyId !== this.config.admissionPolicyId || r.committedGeneration !== p.account.registrationGeneration || r.assertionId !== p.account.consent.assertionId || r.consentRevision !== p.account.consent.revision))
            fail();
    }
    async consent(tokens: VerifyBrokerTokensInput, input: unknown, d = this.deadline()): Promise<{
        status: 'accepted' | 'revoked' | 'no_account' | 'unavailable';
        consentRevision?: number;
    }> {
        d = d.bounded(50000);
        try {
            return await d.run(async () => {
                if (!shape(input, ['version', 'requestId', 'expectedConsentRevision', 'action', 'researchVersion', 'bridgeVersion']) || input.version !== 'credit-consent-command-v1' || !uuid(input.requestId) || !count(input.expectedConsentRevision) ||
                    !['accept', 'revoke'].includes(input.action) || input.researchVersion !== 'research-consent-v1' || input.bridgeVersion !== 'paid-ai-bridge-consent-v1')
                    fail();
                const command = Object.freeze({
                    ...input
                }), i = await this.identity(tokens, d, command.action === 'accept');
                const digest = hash([command.version, command.requestId, command.expectedConsentRevision, command.action, command.researchVersion, command.bridgeVersion]);
                return this.options.database.transaction(async (tx) => {
                    d.check();
                    const p = await this.pair(tx, i, command.action === 'revoke');
                    const control = command.action === 'accept' ? await this.control(tx) : undefined;
                    if (!p && command.action === 'revoke')
                        return {
                            status: 'no_account'
                        };
                    if (p && p.account.lastConsentCommand.requestId === command.requestId) {
                        if (p.account.lastConsentCommand.digest !== digest || p.account.lastConsentCommand.expectedRevision !== command.expectedConsentRevision)
                            fail();
                        d.check();
                        return {
                            status: p.account.consent.status, consentRevision: p.account.consent.revision
                        };
                    }
                    if (command.expectedConsentRevision !== (p?.account.consent.revision ?? 0))
                        fail();
                    const current = p?.account, now = new Date(this.now()), consent: Consent = {
                        status: command.action === 'accept' ? 'accepted' : 'revoked', revision: increment(command.expectedConsentRevision), assertionId: this.freshNonce(), researchVersion: 'research-consent-v1', bridgeVersion: 'paid-ai-bridge-consent-v1'
                    };
                    const a: CreditAccount = {
                        version: 'broker-credit-account-v1', accountKeyVersion: ACCOUNT_KEY, accountSubject: i.accountSubject, routingKeyVersion: ROUTE_KEY, route: i.route, cutoverId: this.config.cutoverId,
                        createdAt: current?.createdAt ?? now, updatedAt: now, revision: increment(current?.revision ?? 0), consent, lastConsentCommand: {
                            requestId: command.requestId, expectedRevision: command.expectedConsentRevision, digest
                        },
                        registrationGeneration: current ? increment(current.registrationGeneration) : 0, receiverInitialized: true
                    };
                    const route: Route = {
                        version: 'broker-credit-route-v1', accountKeyVersion: ACCOUNT_KEY, accountSubject: i.accountSubject, routingKeyVersion: ROUTE_KEY, route: i.route, cutoverId: this.config.cutoverId
                    };
                    const v: CreditReceiver = p ? {
                        ...p.receiver, status: p.receiver.status === 'retired' ? 'retired' : 'blocked', registrationGeneration: a.registrationGeneration
                    } : {
                        ...route, version: 'broker-credit-authority-v1', status: 'unregistered', registrationGeneration: 0
                    };
                    delete v.owner;
                    const next = !p ? enrollControls(control!) : undefined;
                    d.check();
                    tx.set(C.accounts, accountId(i.accountSubject), a);
                    tx.set(C.routes, routeId(i.route), route);
                    tx.set(C.authority, accountId(i.accountSubject), v);
                    if (next) {
                        tx.set(C.control, 'control', next.control);
                        tx.set(C.control, 'initialization', next.initialization);
                    }
                    return {
                        status: consent.status, consentRevision: consent.revision
                    };
                });
            });
        }
        catch {
            return {
                status: 'unavailable'
            };
        }
    }
    async register(tokens: VerifyBrokerTokensInput, input: unknown, d = this.deadline()): Promise<RegistrationResult> {
        d = d.bounded(50000);
        let i: Identity | undefined, owner: RegistrationOwner | undefined;
        try {
            return await d.run(async () => {
                if (!shape(input, ['version', 'requestId', 'expectedRegistrationGeneration']) || input.version !== 'credit-registration-v1' || !uuid(input.requestId) || !count(input.expectedRegistrationGeneration))
                    fail();
                const command = Object.freeze({
                    ...input
                });
                const digest = hash([command.version, command.requestId, command.expectedRegistrationGeneration]);
                i = await this.identity(tokens, d);
                const start = await this.options.database.transaction(async (tx) => {
                    d.check();
                    await this.control(tx);
                    const p = await this.pair(tx, i!);
                    if (!p)
                        fail();
                    this.accepted(p);
                    const receipt = p.receiver.lastRegistrationCommand;
                    if (receipt && receipt.requestId === command.requestId) {
                        if (receipt.digest !== digest || receipt.expectedGeneration !== command.expectedRegistrationGeneration || receipt.committedGeneration !== p.account.registrationGeneration || receipt.assertionId !== p.account.consent.assertionId || receipt.consentRevision !== p.account.consent.revision || receipt.admissionPolicyId !== this.config.admissionPolicyId)
                            fail();
                        d.check();
                        return {
                            result: {
                                status: receipt.outcome
                            } as RegistrationResult
                        };
                    }
                    if (p.receiver.status === 'retired')
                        fail();
                    if (p.receiver.owner && p.receiver.owner.requestId === command.requestId) {
                        const o = p.receiver.owner;
                        this.bound(p);
                        if (o.expectedGeneration !== command.expectedRegistrationGeneration || o.admissionPolicyId !== this.config.admissionPolicyId || +o.leaseExpiresAt <= this.now())
                            fail();
                        d.check();
                        return {
                            owner: o
                        };
                    }
                    if (command.expectedRegistrationGeneration !== p.account.registrationGeneration || p.receiver.owner && +p.receiver.owner.leaseExpiresAt > this.now())
                        fail();
                    const generation = increment(p.account.registrationGeneration), o: RegistrationOwner = {
                        requestId: command.requestId, expectedGeneration: command.expectedRegistrationGeneration, generation, nonce: this.freshNonce(), assertionId: p.account.consent.assertionId, consentRevision: p.account.consent.revision, admissionPolicyId: this.config.admissionPolicyId, leaseExpiresAt: new Date(this.now() + 90000), stage: 'read_one'
                    };
                    const a = {
                        ...p.account, registrationGeneration: generation, revision: increment(p.account.revision), updatedAt: new Date(this.now())
                    };
                    const v: CreditReceiver = {
                        ...p.receiver, status: 'pending', registrationGeneration: generation, boundAssertionId: o.assertionId, boundConsentRevision: o.consentRevision, owner: o
                    };
                    d.check();
                    tx.set(C.accounts, accountId(i!.accountSubject), a);
                    tx.set(C.authority, accountId(i!.accountSubject), v);
                    return {
                        owner: o
                    };
                });
                if (start.result)
                    return start.result;
                owner = start.owner!;
                for (const stage of ['read_one', 'read_two'] as const) {
                    if (owner.stage !== stage)
                        continue;
                    d.check(+owner.leaseExpiresAt);
                    const request: AuthorityRead = Object.freeze({
                        version: 'credit-authority-read-v1', routingKeyVersion: ROUTE_KEY, route: i.route, challenge: this.freshNonce()
                    });
                    const callDeadline = d.bounded(10000, +owner.leaseExpiresAt);
                    const reply = parseReply(await d.run(() => this.options.transport.read(request, callDeadline), 10000, callDeadline.expiresAt), request);
                    const changed = await this.options.database.transaction(async (tx) => {
                        d.check(+owner!.leaseExpiresAt);
                        await this.control(tx);
                        const p = await this.pair(tx, i!);
                        if (!p)
                            fail();
                        this.bound(p);
                        if (!this.owns(p, owner!, stage))
                            return undefined;
                        const v = this.advance(p.receiver, reply.snapshot, reply.digest, false);
                        if (!v)
                            return undefined;
                        if (v.snapshot!.publicationRevision > reply.snapshot.publicationRevision)
                            fail();
                        if (stage === 'read_one') {
                            const next: RegistrationOwner = {
                                ...owner!, stage: 'read_two'
                            };
                            v.owner = next;
                            d.check(+next.leaseExpiresAt);
                            tx.set(C.authority, accountId(i!.accountSubject), v);
                            return {
                                owner: next
                            };
                        }
                        v.status = v.snapshot!.lifecycleStatus === 'retired' ? 'retired' : 'ready';
                        delete v.owner;
                        v.lastRegistrationCommand = this.receipt(owner!, digest, v.status);
                        d.check(+owner!.leaseExpiresAt);
                        tx.set(C.authority, accountId(i!.accountSubject), v);
                        return {
                            result: {
                                status: v.status
                            } as RegistrationResult
                        };
                    });
                    if (!changed)
                        fail();
                    if (changed.result)
                        return changed.result;
                    owner = changed.owner!;
                }
                fail();
            });
        }
        catch {
            if (i && owner && !d.signal.aborted) {
                try {
                    await d.run(() => this.options.database.transaction(async (tx) => {
                        const p = await this.pair(tx, i!);
                        if (!p || !this.owns(p, owner!, owner!.stage))
                            return;
                        this.bound(p);
                        const v = {
                            ...p.receiver, status: 'blocked' as const, lastRegistrationCommand: this.receipt(owner!, hash(['credit-registration-v1', owner!.requestId, owner!.expectedGeneration]), 'blocked')
                        };
                        delete v.owner;
                        d.check(+owner!.leaseExpiresAt);
                        tx.set(C.authority, accountId(i!.accountSubject), v);
                    }));
                }
                catch { /* An expired invocation cannot clean up another owner or extend itself. */ }
            }
            return {
                status: 'unavailable'
            };
        }
    }
    private receipt(o: RegistrationOwner, digest: string, outcome: Receipt['outcome']): Receipt { return {
        requestId: o.requestId, digest, expectedGeneration: o.expectedGeneration, committedGeneration: o.generation, assertionId: o.assertionId, consentRevision: o.consentRevision, admissionPolicyId: o.admissionPolicyId, outcome
    }; }
    private owns(p: Pair, o: RegistrationOwner, stage: RegistrationOwner['stage']): boolean { const n = p.receiver.owner; return p.receiver.status === 'pending' && !!n && n.nonce === o.nonce && n.generation === o.generation && n.stage === stage && n.assertionId === o.assertionId && n.consentRevision === o.consentRevision && n.admissionPolicyId === this.config.admissionPolicyId && +n.leaseExpiresAt === +o.leaseExpiresAt && +n.leaseExpiresAt > this.now(); }
    private advance(v: CreditReceiver, s: CreditAuthoritySnapshot, digest: string, push: boolean): CreditReceiver | undefined {
        if (!validSnapshot(s) || authorityDigest(s) !== digest || s.route !== v.route || s.verifiedAtMs > this.now())
            fail();
        const old = v.snapshot;
        if (old) {
            if (s.lifecycleEpoch !== old.lifecycleEpoch || s.enrollmentId !== old.enrollmentId)
                fail();
            if (s.lifecycleGeneration < old.lifecycleGeneration || s.publicationRevision < old.publicationRevision)
                return push ? undefined : {
                    ...v
                };
            if (s.publicationRevision === old.publicationRevision) {
                if (digest !== v.digest)
                    fail();
                return {
                    ...v
                };
            }
            if (s.lifecycleStatus === 'retired' && old.lifecycleStatus !== 'retired' && s.lifecycleGeneration !== old.lifecycleGeneration + 1)
                fail();
            if (old.lifecycleStatus === 'retired' || !(s.lifecycleGeneration === old.lifecycleGeneration || s.lifecycleGeneration === old.lifecycleGeneration + 1 && s.lifecycleStatus === 'retired'))
                fail();
        }
        return {
            ...v, snapshot: structuredClone(s), digest
        };
    }
    async applyAuthenticatedSnapshot(snapshot: unknown, digest: unknown, d = this.deadline()): Promise<{
        status: 'applied' | 'ignored' | 'not_registered' | 'unavailable';
    }> {
        d = d.bounded(50000);
        try {
            return await d.run(async () => {
                if (!validSnapshot(snapshot) || !hex(digest) || authorityDigest(snapshot) !== digest || Buffer.byteLength(JSON.stringify(snapshot)) > 4096)
                    fail();
                const s = structuredClone(snapshot);
                return this.options.database.transaction(async (tx) => {
                    d.check();
                    await this.control(tx);
                    const reverse = await tx.get<Route>(C.routes, routeId(s.route));
                    if (!validRoute(reverse))
                        return {
                            status: 'not_registered'
                        };
                    const p = await this.pair(tx, reverse);
                    if (!p)
                        fail();
                    this.bound(p);
                    if (!['pending', 'ready', 'retired'].includes(p.receiver.status) || !p.receiver.snapshot)
                        return {
                            status: 'not_registered'
                        };
                    if (p.receiver.owner && (+p.receiver.owner.leaseExpiresAt <= this.now() || p.receiver.owner.admissionPolicyId !== this.config.admissionPolicyId))
                        fail();
                    const next = this.advance(p.receiver, s, digest, true);
                    if (!next)
                        return {
                            status: 'ignored'
                        };
                    if (next.status !== 'pending' && s.lifecycleStatus === 'retired')
                        next.status = 'retired';
                    d.check();
                    tx.set(C.authority, accountId(p.account.accountSubject), next);
                    return {
                        status: 'applied'
                    };
                });
            });
        }
        catch {
            return {
                status: 'unavailable'
            };
        }
    }
    async evaluate(tokens: VerifyBrokerTokensInput, d = this.deadline()): Promise<EligibilityResult> {
        d = d.bounded(50000);
        try {
            return await d.run(async () => {
                const i = await this.identity(tokens, d);
                const result = await this.options.database.transaction(async (tx) => {
                    d.check();
                    await this.control(tx);
                    const p = await this.pair(tx, i);
                    if (!p)
                        return undefined;
                    const operator = await tx.readOperator(i.uid);
                    if (!operator.entitled || operator.breakerOpen || p.account.consent.status !== 'accepted' || p.receiver.status !== 'ready')
                        return undefined;
                    this.bound(p);
                    const s = p.receiver.snapshot!;
                    if (s.state === 'none')
                        return undefined;
                    const cap = Math.min(s.validUntilMs!, s.verifiedAtMs + this.config.authorityMaxAgeMs, d.expiresAt);
                    if (s.verifiedAtMs > this.now() || this.now() >= cap)
                        return undefined;
                    d.check(cap);
                    return {
                        status: 'eligible' as const, planId: s.planId!, fence: Object.freeze({
                            accountSubject: i.accountSubject, consentRevision: p.account.consent.revision, assertionId: p.account.consent.assertionId,
                            registrationGeneration: p.account.registrationGeneration, lifecycleEpoch: s.lifecycleEpoch, lifecycleGeneration: s.lifecycleGeneration, publicationRevision: s.publicationRevision, digest: p.receiver.digest!, verifiedAtMs: s.verifiedAtMs, expiresAt: cap
                        })
                    };
                });
                if (!result)
                    return {
                        status: 'none'
                    };
                if (this.now() < result.fence.verifiedAtMs)
                    fail();
                d.check(result.fence.expiresAt);
                return Object.freeze(result);
            });
        }
        catch {
            return {
                status: 'unavailable'
            };
        }
    }
}
