/** Disabled accounting protocol. No initializer, provider or production allowances. */
import { createHash, createHmac } from 'node:crypto';
import type { BrokerTerminalOutcome } from './contracts.js';
import type { SettlementState } from './idempotency.js';
import { parseTerminalOutcome } from './idempotency.js';
import { ACCOUNT_KEY, PROJECT, hex, nonce, uuid } from './credit_identity_protocol.js';
export const M = Object.freeze({
    control: 'brokerMonthlyControl', accounts: 'brokerMonthlyAccounts', months: 'brokerMonthlyMonths',
    globalMonths: 'brokerMonthlyGlobalMonths', requests: 'brokerMonthlyRequests', ledger: 'brokerMonthlyLedger',
    replay: 'brokerMonthlyReplayShards',
});
export const MAX_MONTHS = 240;
export const MAX_ENTRIES = 2048;
export const MAX_STARTS = 1000;
export const MAX_BYTES = 256 * 1024;
export class MonthlyUnsafeError extends Error {
    constructor() { super('monthly accounting unavailable'); }
}
export function unsafe(): never { throw new MonthlyUnsafeError(); }
export function keys(v: unknown, required: readonly string[], optional: readonly string[] = []): v is Record<string, any> {
    return v !== null && typeof v === 'object' && !Array.isArray(v) &&
        Object.keys(v).every(k => required.includes(k) || optional.includes(k)) && required.every(k => Object.hasOwn(v, k));
}
export const integer = (v: unknown): v is number => Number.isSafeInteger(v) && Number(v) >= 0;
export const positive = (v: unknown): v is number => integer(v) && v > 0;
export const month = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-(0[1-9]|1[0-2])$/.test(v);
export const ms = (v: unknown): v is number => integer(v) && v <= 8640000000000000;
export function utcMonth(now: number): string {
    if (!ms(now))
        unsafe();
    return new Date(now).toISOString().slice(0, 7);
}
function canonical(v: unknown): unknown {
    if (v === null || typeof v === 'string' || typeof v === 'boolean' || integer(v))
        return v;
    if (Array.isArray(v))
        return v.map(canonical);
    if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype)
        return Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical((v as any)[k])]));
    return unsafe();
}
export function digest(v: unknown): string { return createHash('sha256').update(JSON.stringify(canonical(v))).digest('hex'); }
export function bounded<T>(v: T): T {
    if (Buffer.byteLength(JSON.stringify(canonical(v))) > MAX_BYTES)
        unsafe();
    return v;
}
export function fingerprint(key: string, subject: string, requestId: string): string {
    if (Buffer.byteLength(key) < 32 || !hex(subject) || !uuid(requestId))
        unsafe();
    return createHmac('sha256', key).update(JSON.stringify(['archivale-monthly-request-v2', PROJECT, subject, requestId])).digest('hex');
}
export interface MonthlyPolicy {
    version: 'broker-monthly-policy-v1';
    enabled: true;
    policyId: string;
    cutoverId: string;
    accountKeyVersion: typeof ACCOUNT_KEY;
    allowances: {
        starter: number;
        collector: number;
        archive: number;
    };
    globalMonthlyExposure: number;
    globalLifetimeExposure: number;
    globalMonthlyDispatchStarts: number;
    globalLifetimeDispatchStarts: number;
    oneInFlight: true;
}
export function parsePolicy(v: unknown): Readonly<MonthlyPolicy> {
    if (!keys(v, ['version', 'enabled', 'policyId', 'cutoverId', 'accountKeyVersion', 'allowances', 'globalMonthlyExposure', 'globalLifetimeExposure', 'globalMonthlyDispatchStarts', 'globalLifetimeDispatchStarts', 'oneInFlight']) ||
        v.version !== 'broker-monthly-policy-v1' || v.enabled !== true || !nonce(v.policyId) || !nonce(v.cutoverId) || v.accountKeyVersion !== ACCOUNT_KEY || v.oneInFlight !== true ||
        !keys(v.allowances, ['starter', 'collector', 'archive']) || Object.values(v.allowances).some(n => !integer(n) || n > MAX_STARTS) ||
        ['globalMonthlyExposure', 'globalLifetimeExposure', 'globalMonthlyDispatchStarts', 'globalLifetimeDispatchStarts'].some(k => !integer(v[k]) || v[k] > 1000000))
        unsafe();
    if (v.allowances.starter > v.allowances.collector || v.allowances.collector > v.allowances.archive)
        unsafe();
    return Object.freeze({ ...v, allowances: Object.freeze({ ...v.allowances }) }) as Readonly<MonthlyPolicy>;
}
export interface CutoverWitness {
    version: 'broker-monthly-cutover-v1';
    cutoverId: string;
    policyId: string;
    accountKeyVersion: typeof ACCOUNT_KEY;
    evidenceDigest: string;
    legacyAdmission: 'drained';
}
export function validWitness(v: unknown): v is CutoverWitness {
    return keys(v, ['version', 'cutoverId', 'policyId', 'accountKeyVersion', 'evidenceDigest', 'legacyAdmission']) &&
        v.version === 'broker-monthly-cutover-v1' && nonce(v.cutoverId) && nonce(v.policyId) && v.accountKeyVersion === ACCOUNT_KEY && hex(v.evidenceDigest) && v.legacyAdmission === 'drained';
}
export interface Totals {
    reservationStarts: number;
    dispatchStarts: number;
    finalized: number;
    refunded: number;
    reserved: number;
    exposed: number;
}
export const zero = (): Totals => ({
    reservationStarts: 0, dispatchStarts: 0, finalized: 0, refunded: 0, reserved: 0, exposed: 0
});
export function validTotals(v: unknown): v is Totals {
    return keys(v, ['reservationStarts', 'dispatchStarts', 'finalized', 'refunded', 'reserved', 'exposed']) && Object.values(v).every(integer) &&
        v.dispatchStarts <= v.reservationStarts && v.finalized <= v.dispatchStarts && v.finalized + v.refunded <= v.reservationStarts && v.reserved === v.reservationStarts - v.finalized - v.refunded && v.exposed === v.reservationStarts - v.refunded;
}
export function change(t: Totals, kind: 'reserve' | 'dispatch' | 'refund' | 'finalize'): Totals {
    const n = { ...t };
    if (kind === 'reserve') {
        n.reservationStarts++;
        n.reserved++;
        n.exposed++;
    }
    if (kind === 'dispatch')
        n.dispatchStarts++;
    if (kind === 'refund') {
        n.refunded++;
        n.reserved--;
        n.exposed--;
    }
    if (kind === 'finalize') {
        n.finalized++;
        n.reserved--;
    }
    if (!validTotals(n))
        unsafe();
    return n;
}
export interface Head {
    revision: number;
    digest: string;
    totals: Totals;
}
export interface ReplayHead {
    revision: number;
    digest: string;
    count: number;
}
export interface MonthlyControl {
    version: 'broker-monthly-control-v1';
    witness: CutoverWitness;
    policy: MonthlyPolicy;
    revision: number;
    enrolledAccounts: number;
    totals: Totals;
    months: Record<string, Head>;
    breakerOpen: boolean;
}
export interface MonthlyInitialization extends Omit<MonthlyControl, 'version' | 'policy' | 'breakerOpen'> {
    version: 'broker-monthly-initialization-v1';
}
export interface InFlight {
    requestFingerprint: string;
    originalMonth: string;
    reservationOrdinal: number;
    ownerNonce: string;
    leaseExpiresAtMs: number;
    phase: 'reserved' | 'dispatch_intent' | 'terminal_pending_settlement';
}
export interface MonthlyAccount {
    version: 'broker-monthly-account-v1';
    accountSubject: string;
    cutoverId: string;
    revision: number;
    latestMonth: string | null;
    totals: Totals;
    months: Record<string, Head>;
    replay: Record<string, ReplayHead>;
    inFlight: InFlight | null;
}
export interface MonthlyMarker {
    version: 'broker-monthly-marker-v1';
    accountSubject: string;
    cutoverId: string;
    monthlyRevision: number;
    monthlyHeadDigest: string;
}
export interface MonthlyMonth {
    version: 'broker-monthly-month-v1';
    accountSubject: string;
    month: string;
    cutoverId: string;
    revision: number;
    allowanceCeiling: number;
    highestEligiblePlanSeen: 'starter' | 'collector' | 'archive';
    totals: Totals;
}
export interface GlobalMonth {
    version: 'broker-monthly-global-month-v1';
    month: string;
    cutoverId: string;
    revision: number;
    totals: Totals;
}
export interface AuthorityBinding {
    assertionId: string;
    consentRevision: number;
    admissionPolicyId: string;
    registrationGeneration: number;
    lifecycleEpoch: string;
    lifecycleGeneration: number;
    publicationRevision: number;
    digest: string;
    verifiedAtMs: number;
    expiresAt: number;
}
export interface MonthlyRequest {
    record_version: 'broker-request-lifecycle-v2';
    requestFingerprint: string;
    accountSubject: string;
    cutoverId: string;
    request_id: string;
    payload_hash: string;
    originalMonth: string;
    reservationOrdinal: number;
    credit_cost: 1;
    ownerNonce: string;
    reservedAtMs: number;
    leaseExpiresAtMs: number;
    state: 'reserved' | 'dispatch_intent' | 'terminal';
    authority: AuthorityBinding;
    settlement_state: SettlementState;
    terminal_outcome?: BrokerTerminalOutcome;
}
export interface MonthlyLedger {
    version: 'broker-monthly-ledger-v1';
    requestFingerprint: string;
    accountSubject: string;
    cutoverId: string;
    originalMonth: string;
    reservationOrdinal: number;
    creditCost: 1;
    state: 'reserved' | 'finalized' | 'refunded';
    refundReason?: string;
}
export interface ReplayEntry {
    originalMonth: string;
    reservationOrdinal: number;
    payloadHash: string;
}
export interface ReplayShard {
    version: 'broker-monthly-replay-v1';
    accountSubject: string;
    cutoverId: string;
    shard: string;
    revision: number;
    entries: Record<string, ReplayEntry>;
}
function sum(heads: Record<string, Head>): Totals {
    const total = zero();
    for (const h of Object.values(heads))
        for (const k of Object.keys(total) as (keyof Totals)[])
            total[k] += h.totals[k];
    if (!validTotals(total))
        unsafe();
    return total;
}
function validHeads(v: unknown): v is Record<string, Head> {
    return v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length <= MAX_MONTHS &&
        Object.entries(v).every(([k, h]) => month(k) && keys(h, ['revision', 'digest', 'totals']) && positive(h.revision) && hex(h.digest) && validTotals(h.totals));
}
export function parseControlPair(control: unknown, initialization: unknown, witness: unknown, policy?: MonthlyPolicy): {
    control: MonthlyControl;
    initialization: MonthlyInitialization;
} {
    if (!validWitness(witness) || !keys(control, ['version', 'witness', 'policy', 'revision', 'enrolledAccounts', 'totals', 'months', 'breakerOpen']) ||
        control.version !== 'broker-monthly-control-v1' || !validWitness(control.witness) || digest(control.witness) !== digest(witness) || !positive(control.revision) || !integer(control.enrolledAccounts) || !validTotals(control.totals) || !validHeads(control.months) || typeof control.breakerOpen !== 'boolean')
        unsafe();
    const p = parsePolicy(control.policy);
    if (p.cutoverId !== witness.cutoverId || p.policyId !== witness.policyId || (policy && digest(p) !== digest(policy)) || digest(sum(control.months)) !== digest(control.totals))
        unsafe();
    const expected = initializationFor(control as MonthlyControl);
    if (!keys(initialization, ['version', 'witness', 'revision', 'enrolledAccounts', 'totals', 'months']) || digest(initialization) !== digest(expected))
        unsafe();
    bounded(control);
    bounded(initialization);
    return { control: structuredClone(control) as MonthlyControl, initialization: structuredClone(initialization) as MonthlyInitialization };
}
export function initializationFor(c: MonthlyControl): MonthlyInitialization {
    return {
        version: 'broker-monthly-initialization-v1', witness: c.witness, revision: c.revision, enrolledAccounts: c.enrolledAccounts, totals: c.totals, months: c.months
    };
}
export function initialMonthlyControls(policy: MonthlyPolicy, evidenceDigest: string): {
    control: MonthlyControl;
    initialization: MonthlyInitialization;
    witness: CutoverWitness;
} {
    const p = parsePolicy(policy);
    if (!hex(evidenceDigest))
        unsafe();
    const witness: CutoverWitness = {
        version: 'broker-monthly-cutover-v1', cutoverId: p.cutoverId, policyId: p.policyId, accountKeyVersion: ACCOUNT_KEY, evidenceDigest, legacyAdmission: 'drained'
    };
    const control: MonthlyControl = {
        version: 'broker-monthly-control-v1', witness, policy: structuredClone(p), revision: 1, enrolledAccounts: 0, totals: zero(), months: {}, breakerOpen: false
    };
    return {
        control, initialization: initializationFor(control), witness
    };
}
export function parseAccount(v: unknown, marker: unknown, subject: string, cutover: string): MonthlyAccount {
    if (!keys(v, ['version', 'accountSubject', 'cutoverId', 'revision', 'latestMonth', 'totals', 'months', 'replay', 'inFlight']) || v.version !== 'broker-monthly-account-v1' || v.accountSubject !== subject || v.cutoverId !== cutover || !positive(v.revision) || !validTotals(v.totals) || !validHeads(v.months) ||
        (v.latestMonth !== null && !month(v.latestMonth)) || v.latestMonth !== (Object.keys(v.months).sort().at(-1) ?? null) || digest(sum(v.months)) !== digest(v.totals) ||
        !v.replay || typeof v.replay !== 'object' || Array.isArray(v.replay) || Object.keys(v.replay).length !== 16 || !Object.entries(v.replay).every(([k, h]) => /^[0-9a-f]$/.test(k) && keys(h, ['revision', 'digest', 'count']) && integer(h.revision) && hex(h.digest) && integer(h.count) && h.count <= MAX_ENTRIES && h.revision === h.count))
        unsafe();
    if (Object.values(v.replay as Record<string, ReplayHead>).reduce((n, h) => n + h.count, 0) !== v.totals.reservationStarts)
        unsafe();
    const f = v.inFlight;
    if (f !== null && (!keys(f, ['requestFingerprint', 'originalMonth', 'reservationOrdinal', 'ownerNonce', 'leaseExpiresAtMs', 'phase']) || !hex(f.requestFingerprint) || !month(f.originalMonth) || !positive(f.reservationOrdinal) || !nonce(f.ownerNonce) || !ms(f.leaseExpiresAtMs) || !['reserved', 'dispatch_intent', 'terminal_pending_settlement'].includes(f.phase)))
        unsafe();
    if ((f === null ? 0 : 1) !== v.totals.reserved || digest(marker) !== digest(markerFor(v as MonthlyAccount)))
        unsafe();
    bounded(v);
    return structuredClone(v) as MonthlyAccount;
}
export function markerFor(a: MonthlyAccount): MonthlyMarker {
    return {
        version: 'broker-monthly-marker-v1', accountSubject: a.accountSubject, cutoverId: a.cutoverId, monthlyRevision: a.revision, monthlyHeadDigest: digest(a)
    };
}
export function headFor(v: MonthlyMonth | GlobalMonth): Head {
    return {
        revision: v.revision, digest: digest(v), totals: v.totals
    };
}
export function replayHead(v: ReplayShard): ReplayHead {
    return {
        revision: v.revision, digest: digest(v), count: Object.keys(v.entries).length
    };
}
export function parseMonth(v: unknown, head: Head | undefined, subject: string, m: string, cutover: string): MonthlyMonth {
    if (!keys(v, ['version', 'accountSubject', 'month', 'cutoverId', 'revision', 'allowanceCeiling', 'highestEligiblePlanSeen', 'totals']) || v.version !== 'broker-monthly-month-v1' || v.accountSubject !== subject || v.month !== m || v.cutoverId !== cutover || !positive(v.revision) || !integer(v.allowanceCeiling) || v.allowanceCeiling > MAX_STARTS || !['starter', 'collector', 'archive'].includes(v.highestEligiblePlanSeen) || !validTotals(v.totals) || v.totals.reservationStarts > MAX_STARTS || digest(head) !== digest(headFor(v as MonthlyMonth)))
        unsafe();
    return structuredClone(v) as MonthlyMonth;
}
export function parseGlobalMonth(v: unknown, head: Head | undefined, m: string, cutover: string): GlobalMonth {
    if (!keys(v, ['version', 'month', 'cutoverId', 'revision', 'totals']) || v.version !== 'broker-monthly-global-month-v1' || v.month !== m || v.cutoverId !== cutover || !positive(v.revision) || !validTotals(v.totals) || digest(head) !== digest(headFor(v as GlobalMonth)))
        unsafe();
    return structuredClone(v) as GlobalMonth;
}
export function parseShard(v: unknown, head: ReplayHead, subject: string, shard: string, cutover: string): ReplayShard {
    if (!keys(v, ['version', 'accountSubject', 'cutoverId', 'shard', 'revision', 'entries']) || v.version !== 'broker-monthly-replay-v1' || v.accountSubject !== subject || v.cutoverId !== cutover || v.shard !== shard || !integer(v.revision) || !v.entries || typeof v.entries !== 'object' || Array.isArray(v.entries) || Object.keys(v.entries).length > MAX_ENTRIES || v.revision !== Object.keys(v.entries).length ||
        !Object.entries(v.entries).every(([k, e]) => hex(k) && k[0] === shard && keys(e, ['originalMonth', 'reservationOrdinal', 'payloadHash']) && month(e.originalMonth) && positive(e.reservationOrdinal) && hex(e.payloadHash)) || digest(head) !== digest(replayHead(v as ReplayShard)))
        unsafe();
    bounded(v);
    return structuredClone(v) as ReplayShard;
}
export function parseRequest(v: unknown): MonthlyRequest {
    if (!keys(v, ['record_version', 'requestFingerprint', 'accountSubject', 'cutoverId', 'request_id', 'payload_hash', 'originalMonth', 'reservationOrdinal', 'credit_cost', 'ownerNonce', 'reservedAtMs', 'leaseExpiresAtMs', 'state', 'authority', 'settlement_state'], ['terminal_outcome']) ||
        v.record_version !== 'broker-request-lifecycle-v2' || !hex(v.requestFingerprint) || !hex(v.accountSubject) || !nonce(v.cutoverId) || !uuid(v.request_id) || !hex(v.payload_hash) || !month(v.originalMonth) || !positive(v.reservationOrdinal) || v.credit_cost !== 1 || !nonce(v.ownerNonce) || !ms(v.reservedAtMs) || !ms(v.leaseExpiresAtMs) || v.leaseExpiresAtMs <= v.reservedAtMs || !['reserved', 'dispatch_intent', 'terminal'].includes(v.state) ||
        !keys(v.authority, ['assertionId', 'consentRevision', 'admissionPolicyId', 'registrationGeneration', 'lifecycleEpoch', 'lifecycleGeneration', 'publicationRevision', 'digest', 'verifiedAtMs', 'expiresAt']) || !nonce(v.authority.assertionId) || !positive(v.authority.consentRevision) || !nonce(v.authority.admissionPolicyId) || !positive(v.authority.registrationGeneration) || !nonce(v.authority.lifecycleEpoch) || !positive(v.authority.lifecycleGeneration) || !integer(v.authority.publicationRevision) || !hex(v.authority.digest) || !ms(v.authority.verifiedAtMs) || !ms(v.authority.expiresAt))
        unsafe();
    if (utcMonth(v.reservedAtMs) !== v.originalMonth || v.authority.verifiedAtMs > v.reservedAtMs || v.leaseExpiresAtMs > v.reservedAtMs + 60000 || v.leaseExpiresAtMs > v.authority.expiresAt)
        unsafe();
    if (v.state === 'terminal') {
        const out = parseTerminalOutcome(v.terminal_outcome);
        if (!out || !['pending_refund', 'pending_finalize', 'refunded', 'finalized'].includes(v.settlement_state) || (out.kind === 'success' ? out.response.request_id : out.failure.request_id) !== v.request_id)
            unsafe();
    }
    else if (v.terminal_outcome !== undefined || v.settlement_state !== 'reserved')
        unsafe();
    if (utcMonth(v.reservedAtMs) !== v.originalMonth || v.authority.verifiedAtMs > v.reservedAtMs || v.leaseExpiresAtMs > v.reservedAtMs + 60000 || v.leaseExpiresAtMs > v.authority.expiresAt)
        unsafe();
    if (v.state === 'terminal') {
        const outcome = v.terminal_outcome as BrokerTerminalOutcome;
        const refund = outcome.kind === 'error' && ['reservation_lease_expired', 'provider_config_failure', 'provider_construction_failure', 'provider_authorization_failure', 'dispatch_persistence_failure', 'provider_timeout', 'provider_rate_limited'].includes(outcome.failure.condition);
        if (v.settlement_state.includes('refund') !== refund)
            unsafe();
    }
    bounded(v);
    return structuredClone(v) as MonthlyRequest;
}
export function parseLedger(v: unknown, r: MonthlyRequest): MonthlyLedger {
    if (!keys(v, ['version', 'requestFingerprint', 'accountSubject', 'cutoverId', 'originalMonth', 'reservationOrdinal', 'creditCost', 'state'], ['refundReason']) || v.version !== 'broker-monthly-ledger-v1' || v.requestFingerprint !== r.requestFingerprint || v.accountSubject !== r.accountSubject || v.cutoverId !== r.cutoverId || v.originalMonth !== r.originalMonth || v.reservationOrdinal !== r.reservationOrdinal || v.creditCost !== 1 || !['reserved', 'refunded', 'finalized'].includes(v.state) ||
        (v.state === 'refunded') !== (typeof v.refundReason === 'string') || (v.state === 'reserved' ? ['refunded', 'finalized'].includes(r.settlement_state) : r.settlement_state !== v.state))
        unsafe();
    if (v.state === 'refunded' && (r.terminal_outcome?.kind !== 'error' || v.refundReason !== r.terminal_outcome.failure.condition))
        unsafe();
    return structuredClone(v) as MonthlyLedger;
}
