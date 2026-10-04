import assert from 'node:assert/strict';
import test from 'node:test';
import { MemoryFirestore, FIXED_NOW } from './test_helpers.js';
import { FirestoreDurableBrokerStore } from '../src/durable_protection.js';
import { FirestoreCreditIdentityDatabase } from '../src/credit_identity_store.js';
import { CreditIdentityDeadline } from '../src/credit_identity_deadline.js';
import { initializeMonthlyCutover } from '../src/monthly_credit_store.js';
import { initialMonthlyControls, M } from '../src/monthly_credit_protocol.js';
import { MONTHLY_POLICY } from './monthly_credit_fixture.js';
const input = {
    quota_subject: 'quota_subject_v1_' + 'a'.repeat(64), request_id: '11111111-1111-4111-8111-111111111111', payload_hash: 'b'.repeat(64), credit_cost: 1 as const, now: FIXED_NOW
};
for (const prefix of ['brokerDurable', 'isolatedLegacy'])
    test(`actual v1 ${prefix} control witness denies new requests even when both monthly records disappear`, async () => {
        const db = new MemoryFirestore(), store = new FirestoreDurableBrokerStore(db, { collectionPrefix: prefix });
        const live = {
            record_version: 'broker-control-v1', breakerOpen: false, perSubjectCreditCap: 3, brokerCreditCap: 20, oneInFlightPerSubject: true
        };
        db.seed(`${prefix}Control/live`, live);
        const old = store.createRequestLifecycle();
        assert.equal((await old.acquire(input)).kind, 'reserved');
        const p = initialMonthlyControls(MONTHLY_POLICY, 'a'.repeat(64));
        db.seed(`${prefix}Control/live`, { ...live, monthlyCutover: p.witness });
        db.seed(M.control + '/control', p.control as any);
        db.seed(M.control + '/initialization', p.initialization as any);
        assert.equal((await old.acquire(input)).kind, 'in_flight');
        const next = { ...input, request_id: '22222222-2222-4222-8222-222222222222' };
        assert.equal((await old.acquire(next)).kind, 'migration_required');
        db.documents.delete(M.control + '/control');
        db.documents.delete(M.control + '/initialization');
        const before = structuredClone(db.documents);
        assert.equal((await old.acquire(next)).kind, 'unsafe_record');
        assert.deepEqual(db.documents, before);
    });
for (const prefix of ['brokerDurable', 'isolatedLegacy'])
    test(`actual adapter ${prefix} rejects independent cutover namespace before any transaction`, async () => {
        const raw = Object.assign(new MemoryFirestore(), { databaseId: '(default)' }), legacy = new FirestoreDurableBrokerStore(raw, { collectionPrefix: prefix }), db = new FirestoreCreditIdentityDatabase(raw, legacy);
        let calls = 0;
        const original = raw.runTransaction.bind(raw);
        raw.runTransaction = fn => { calls++; return original(fn); };
        await assert.rejects(initializeMonthlyCutover(db, prefix + 'Wrong', MONTHLY_POLICY, 'a'.repeat(64), new CreditIdentityDeadline()));
        assert.equal(calls, 0);
        assert.equal(raw.documents.size, 0);
    });
