/** Internal injected factory only. No live HTTP export, provider or credentials. */
import { handleResearchRequest, type ProviderProvisioner, type BrokerDependencies } from './broker.js';
import { validateCanonicalPayloadV1 } from './canonical_payload.js';
import { CURRENT_CONSENT_COPY_VERSION, type BrokerContext, type BrokerRequest, type BrokerResult } from './contracts.js';
import { CreditIdentityDeadline } from './credit_identity_deadline.js';
import type { CreditIdentityService } from './credit_identity.js';
import type { CreditIdentityDatabase } from './credit_identity_store.js';
import type { VerifyBrokerTokensInput } from './durable_protection.js';
import { authorizeProviderRequest } from './provider_authorization.js';
import { MonthlyCreditStore } from './monthly_credit_store.js';
import { parsePolicy, unsafe, type MonthlyRequest } from './monthly_credit_protocol.js';
export interface MonthlyBrokerOptions {
    database: CreditIdentityDatabase;
    identityService: CreditIdentityService;
    accountKey: string;
    collectionPrefix: string;
    providerProvisioner: ProviderProvisioner;
    now?: () => number;
    authorizeProvider?: (request: BrokerRequest) => void | Promise<void>;
    orderTrace?: string[];
}
export interface MonthlyBrokerSession {
    enroll(): Promise<void>;
    research(): Promise<BrokerResult>;
}
function freeze<T>(v: T): T {
    if (v && typeof v === 'object') {
        for (const value of Object.values(v))
            freeze(value);
        Object.freeze(v);
    }
    return v;
}
/** False/missing config returns before any dependency construction or authentication. */
export async function createMonthlyBrokerSession(config: unknown, dependencies: () => MonthlyBrokerOptions, tokens: VerifyBrokerTokensInput, input: BrokerRequest, parent?: CreditIdentityDeadline): Promise<MonthlyBrokerSession | undefined> {
    if (!config || typeof config !== 'object' || !('enabled' in config) || config.enabled !== true)
        return undefined;
    const policy = parsePolicy(config), o = dependencies(), now = o.now ?? Date.now;
    if (o.database.collectionPrefix !== o.collectionPrefix)
        unsafe();
    const d = (parent ?? new CreditIdentityDeadline(now() + 50000, now)).bounded(50000);
    const request = freeze(structuredClone(input));
    if (validateCanonicalPayloadV1(request) !== undefined || request.consent_status !== 'approved' || request.consent_copy_version !== CURRENT_CONSENT_COPY_VERSION)
        unsafe();
    const identity = await o.identityService.authenticateAccounting(tokens, d);
    // Replay still requires current consent/admission/privacy, but need not be paid.
    await d.run(() => o.database.transaction(tx => o.identityService.readAccountingIdentity(tx, identity, d)));
    const store = new MonthlyCreditStore({
        ...o, identity, policy, deadline: d, now
    });
    const context: BrokerContext = {
        auth_verified: true, app_check_verified: true, auth_identity: {
            uid: identity.uid, project_id: 'my-art-collections', sign_in_provider: identity.signInProvider
        }, app_identity: { app_id: identity.appId, project_id: 'my-art-collections' }, quota_subject: `credit_account_v2_${identity.accountSubject}`, entitled: true, breaker_open: false
    };
    const deps: BrokerDependencies<MonthlyRequest> = {
        lifecycleVersion: 'v2', requestLifecycle: store, now: () => new Date(now()), orderTrace: o.orderTrace,
        providerProvisioner: { configure: () => d.run(async () => o.providerProvisioner.configure()), construct: c => d.run(async () => o.providerProvisioner.construct(c)) },
        authorizeProvider: r => d.run(async () => (o.authorizeProvider ?? authorizeProviderRequest)(r)),
        dispatchMonthly: (r, q, p, late) => store.dispatch(r, q, p, late),
    };
    let started = false;
    return Object.freeze({
        enroll: () => store.enroll(),
        research: async () => {
            if (started)
                return { ok: false, failure: { condition: 'dispatch_outcome_unknown', request_id: request.request_id } } as BrokerResult;
            started = true;
            return handleResearchRequest(request, context, deps);
        },
    });
}
