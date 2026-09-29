/** Internal, injected bridge only. No callable, provider, IAM or secret construction. */
import { randomBytes } from 'node:crypto';
import type { Auth } from 'firebase-admin/auth';
import { COLLECTIONS } from './constants.js';
import { BillingDeadline } from './deadline.js';
import { verifyCallableIdentity, type BillingCallableContext } from './identity.js';
import type { BillingDatabase, BillingTransaction, DisclosureRecord } from './store.js';
import { BillingRepository, validDisclosure } from './store.js';
import type { LifecycleRoot } from './lifecycle.js';
import { validAuthority, type AccountAuthority, type AuthorityOutbox } from './account_authority.js';
import { ACCOUNT_KEY, ROUTE_KEY, PROJECT, authorityDigest, controls, enrollControls, fail, hex, nonce, positive, shape, uuid, parseConfig, routeForUid, validRead, type AuthorityReply, type CreditAuthoritySnapshot, type CreditIdentityConfig } from './credit_identity_protocol.js';
export * from './credit_identity_protocol.js';
interface Marker {
    version: 'play-broker-marker-v1';
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    enrollmentId: string;
    lifecycleEpoch: string;
    enrolledGeneration: number;
}
interface Binding extends Omit<Marker, 'version'> {
    version: 'play-broker-binding-v1';
    accountSubject: string;
    createdAt: Date;
}
function validMarker(v: unknown): v is Marker {
    return shape(v, ['version', 'routingKeyVersion', 'route', 'enrollmentId', 'lifecycleEpoch', 'enrolledGeneration']) &&
        v.version === 'play-broker-marker-v1' && v.routingKeyVersion === ROUTE_KEY && hex(v.route) && nonce(v.enrollmentId) && nonce(v.lifecycleEpoch) && positive(v.enrolledGeneration);
}
function matches(v: unknown, m: Marker, subject: string): v is Binding {
    return shape(v, ['version', 'routingKeyVersion', 'route', 'enrollmentId', 'lifecycleEpoch', 'enrolledGeneration', 'accountSubject', 'createdAt']) &&
        v.version === 'play-broker-binding-v1' && v.accountSubject === subject && v.createdAt instanceof Date && Number.isFinite(+v.createdAt) &&
        v.routingKeyVersion === m.routingKeyVersion && v.route === m.route && v.enrollmentId === m.enrollmentId && v.lifecycleEpoch === m.lifecycleEpoch && v.enrolledGeneration === m.enrolledGeneration;
}
export const bridgeRouteId = (route: string) => `${ROUTE_KEY}_${route}`;
export interface BillingBridgeOptions {
    database: BillingDatabase;
    repository: BillingRepository;
    config: CreditIdentityConfig;
    routingKey: string;
    accountSubject: (uid: string) => string;
    auth: Pick<Auth, 'verifyIdToken'>;
    approvedAppId: string;
    now?: () => Date;
    newNonce?: () => string;
}
export function createBillingBridge(config: unknown, dependencies: () => Omit<BillingBridgeOptions, 'config'>): BillingBrokerBridge | undefined {
    if (!config || typeof config !== 'object' || !('enabled' in config) || config.enabled !== true)
        return undefined;
    const parsed = parseConfig(config);
    return new BillingBrokerBridge({
        ...dependencies(), config: parsed
    });
}
export class BillingBrokerBridge {
    private readonly config: Readonly<CreditIdentityConfig>;
    private readonly now: () => Date;
    private readonly newNonce: () => string;
    constructor(private readonly options: BillingBridgeOptions) { this.config = parseConfig(options.config); this.now = options.now ?? (() => new Date()); this.newNonce = options.newNonce ?? (() => randomBytes(16).toString('hex')); }
    async enroll(context: BillingCallableContext, input: unknown, deadline = new BillingDeadline(Date.now() + 50000)): Promise<{
        status: 'enrolled';
        enrollmentId: string;
    }> {
        return deadline.run(async () => {
            if (!shape(input, ['version', 'requestId', 'lifecycleEpoch', 'lifecycleGeneration']) || input.version !== 'credit-billing-enrollment-v1' || !uuid(input.requestId) || !nonce(input.lifecycleEpoch) || !positive(input.lifecycleGeneration))
                fail();
            const command = Object.freeze({
                ...input
            });
            const identity = await deadline.run(() => verifyCallableIdentity(context, this.options.auth, this.options.approvedAppId));
            if (!identity)
                fail();
            const subject = this.options.accountSubject(identity.uid), route = routeForUid(this.options.routingKey, identity.uid);
            if (!hex(subject))
                fail();
            return this.options.database.runTransaction(async (tx) => {
                deadline.check();
                const root = await this.options.repository.readLifecycleForBridge(tx, subject);
                if (!root || root.status !== 'active' || root.lifecycleEpoch !== command.lifecycleEpoch || root.lifecycleGeneration !== command.lifecycleGeneration)
                    fail();
                const disclosure = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, subject);
                const binding = await tx.get(COLLECTIONS.brokerBindings, subject), reverse = await tx.get(COLLECTIONS.brokerRoutes, bridgeRouteId(route));
                const control = await tx.get(COLLECTIONS.brokerBridgeControl, 'control'), initialization = await tx.get(COLLECTIONS.brokerBridgeControl, 'initialization');
                const pair = controls(control, initialization, this.config, 'billing');
                if (!disclosure || !validDisclosure(disclosure, subject) || disclosure.status !== 'accepted' || disclosure.assertionId !== root.assertionId || disclosure.retentionExpiresAt <= this.now())
                    fail();
                if (Object.hasOwn(root, 'brokerBridge') || binding !== undefined || reverse !== undefined) {
                    const m = root.brokerBridge;
                    if (!validMarker(m) || m.route !== route || m.lifecycleEpoch !== root.lifecycleEpoch || m.enrolledGeneration !== root.lifecycleGeneration || !matches(binding, m, subject) || !matches(reverse, m, subject) || +binding.createdAt !== +reverse.createdAt)
                        fail();
                    deadline.check();
                    return {
                        status: 'enrolled', enrollmentId: m.enrollmentId
                    };
                }
                // Reverse survivors under another route cannot be adopted beside a clean-looking subject slot.
                if (await tx.findSubjectBrokerRoute(subject) !== undefined)
                    fail();
                const enrollmentId = this.newNonce();
                if (!nonce(enrollmentId))
                    fail();
                const marker: Marker = {
                    version: 'play-broker-marker-v1', routingKeyVersion: ROUTE_KEY, route, enrollmentId, lifecycleEpoch: root.lifecycleEpoch, enrolledGeneration: root.lifecycleGeneration
                };
                const record: Binding = {
                    ...marker, version: 'play-broker-binding-v1', accountSubject: subject, createdAt: this.now()
                };
                const next = enrollControls(pair);
                deadline.check();
                tx.set(COLLECTIONS.lifecycles, subject, {
                    ...root, brokerBridge: marker
                });
                tx.set(COLLECTIONS.brokerBindings, subject, record);
                tx.set(COLLECTIONS.brokerRoutes, bridgeRouteId(route), record);
                tx.set(COLLECTIONS.brokerBridgeControl, 'control', next.control);
                tx.set(COLLECTIONS.brokerBridgeControl, 'initialization', next.initialization);
                return {
                    status: 'enrolled', enrollmentId
                };
            });
        }, 50000);
    }
    /** Only an authenticated internal service transport may call this; never a client payload handler. */
    async read(input: unknown, deadline = new BillingDeadline(Date.now() + 50000)): Promise<AuthorityReply> {
        return deadline.run(async () => {
            if (!validRead(input))
                fail();
            const request = Object.freeze({
                ...input
            });
            return this.options.database.runTransaction(async (tx) => {
                deadline.check();
                const reverse = await tx.get<Binding>(COLLECTIONS.brokerRoutes, bridgeRouteId(request.route));
                if (!reverse || !hex(reverse.accountSubject))
                    fail();
                const root = await this.options.repository.readLifecycleForBridge(tx, reverse.accountSubject);
                if (!root)
                    fail();
                await this.validate(tx, root, request.route);
                const a = await tx.get<AccountAuthority>(COLLECTIONS.authorities, root.accountSubject), outbox = await tx.get<AuthorityOutbox>(COLLECTIONS.authorityOutbox, root.accountSubject);
                const d = await tx.get<DisclosureRecord>(COLLECTIONS.disclosures, root.accountSubject);
                if (!a || !outbox || !validAuthority(a, root, outbox))
                    fail();
                const s = a.snapshot, m = root.brokerBridge as Marker;
                const terminal = s.state === 'none' && (s.reason === 'revoked' || s.reason === 'retired');
                if (!terminal && (!d || !validDisclosure(d, root.accountSubject) || d.status !== 'accepted' || d.assertionId !== root.assertionId || d.retentionExpiresAt <= this.now()))
                    fail();
                const base: CreditAuthoritySnapshot = {
                    version: 'credit-authority-v1', projectId: PROJECT, routingKeyVersion: ROUTE_KEY, route: request.route, enrollmentId: m.enrollmentId,
                    lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration, publicationRevision: s.publicationRevision, lifecycleStatus: root.status, state: s.state, verifiedAtMs: +s.verifiedAt
                };
                let snapshot: CreditAuthoritySnapshot;
                if (s.state === 'none')
                    snapshot = {
                        ...base, reason: s.reason
                    };
                else {
                    const now = this.now();
                    if (root.status !== 'active' || !d || !validDisclosure(d, root.accountSubject) || d.status !== 'accepted' || d.assertionId !== root.assertionId || d.retentionExpiresAt <= now || s.playExpiresAt! <= now || s.verifiedAt > now)
                        fail();
                    snapshot = {
                        ...base, planId: s.planId, playExpiresAtMs: +s.playExpiresAt!, validUntilMs: Math.min(+s.playExpiresAt!, +d.retentionExpiresAt)
                    };
                }
                const digest = authorityDigest(snapshot);
                deadline.check();
                return {
                    version: 'credit-authority-read-result-v1', challenge: request.challenge, snapshot, digest
                };
            });
        }, 10000);
    }
    private async validate(tx: BillingTransaction, root: LifecycleRoot, route: string): Promise<void> {
        const m = root.brokerBridge;
        if (!validMarker(m) || m.route !== route || m.lifecycleEpoch !== root.lifecycleEpoch ||
            !(m.enrolledGeneration === root.lifecycleGeneration || root.status === 'retired' && m.enrolledGeneration + 1 === root.lifecycleGeneration))
            fail();
        const binding = await tx.get(COLLECTIONS.brokerBindings, root.accountSubject), reverse = await tx.get(COLLECTIONS.brokerRoutes, bridgeRouteId(route));
        if (!matches(binding, m, root.accountSubject) || !matches(reverse, m, root.accountSubject) || +binding.createdAt !== +reverse.createdAt)
            fail();
        // Controls gate bridge reads, never core safety operations.
        controls(await tx.get(COLLECTIONS.brokerBridgeControl, 'control'), await tx.get(COLLECTIONS.brokerBridgeControl, 'initialization'), this.config, 'billing');
    }
}
