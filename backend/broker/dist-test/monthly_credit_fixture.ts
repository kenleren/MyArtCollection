import { randomUUID } from 'node:crypto';
import { creditIdentityFixture, TEST_ACCOUNT_KEY } from './credit_identity_fixture.js';
import { initializeMonthlyCutover } from '../src/monthly_credit_store.js';
import { createMonthlyBrokerSession, type MonthlyBrokerOptions } from '../src/monthly_broker.js';
import { M, type MonthlyPolicy } from '../src/monthly_credit_protocol.js';
import { request, ResultProvider } from './test_helpers.js';
import type { BrokerRequest } from '../src/contracts.js';
export const MONTHLY_POLICY: MonthlyPolicy = {
    version: 'broker-monthly-policy-v1', enabled: true, policyId: '1'.repeat(32), cutoverId: '2'.repeat(32), accountKeyVersion: 'broker-account-v1', allowances: {
        starter: 2, collector: 4, archive: 6
    }, globalMonthlyExposure: 20, globalLifetimeExposure: 40, globalMonthlyDispatchStarts: 20, globalLifetimeDispatchStarts: 40, oneInFlight: true
};
export async function monthlyFixture(options: {
    nowMs?: number;
    policy?: MonthlyPolicy;
    prefix?: string;
    appIds?: string[];
    ownerUids?: string[];
} = {}) {
    const f = await creditIdentityFixture({
        nowMs: options.nowMs, collectionPrefix: options.prefix, appIds: options.appIds, ownerUids: options.ownerUids
    });
    const prefix = options.prefix ?? 'brokerDurable', policy = options.policy ?? MONTHLY_POLICY;
    f.db.setForTest(`${prefix}Control`, 'live', {
        record_version: 'broker-control-v1', breakerOpen: false, perSubjectCreditCap: 3, brokerCreditCap: 10, oneInFlightPerSubject: true
    });
    await initializeMonthlyCutover(f.db, prefix, policy, '3'.repeat(64), f.deadline());
    const provider = new ResultProvider();
    const deps: MonthlyBrokerOptions = {
        database: f.db, identityService: f.service, accountKey: TEST_ACCOUNT_KEY, collectionPrefix: prefix, providerProvisioner: { configure: () => ({ mode: 'synthetic' }), construct: () => provider }, authorizeProvider: () => undefined, now: f.clock.now
    };
    const open = async (input: BrokerRequest = request({ request_id: randomUUID() }), overrides: Partial<MonthlyBrokerOptions> = {}) => {
        const result = await createMonthlyBrokerSession(policy, () => ({ ...deps, ...overrides }), f.tokens(), input, f.deadline());
        if (!result)
            throw Error('fixture disabled');
        return result;
    };
    const first = await open();
    await first.enroll();
    const row = <T = any>(c: string, id: string): T => f.db.snapshotForTest().get(`${c}/${id}`) as T;
    const control = () => row(M.control, 'control');
    const account = () => row(M.accounts, f.accountSubject);
    return {
        ...f, prefix, policy, provider, deps, open, row, control, account
    };
}
