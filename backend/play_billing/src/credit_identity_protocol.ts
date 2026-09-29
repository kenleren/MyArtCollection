/** Identical, dependency-free protocol in billing and broker; parity tested across builds. */
import { createHash, createHmac } from 'node:crypto';
export const PROJECT = 'my-art-collections';
export const ROUTE_KEY = 'entitlement-route-v1';
export const ACCOUNT_KEY = 'broker-account-v1';
export class CreditIdentityError extends Error {
    constructor() { super('credit identity unavailable'); }
}
export function fail(): never { throw new CreditIdentityError(); }
export function shape(v: unknown, required: readonly string[], optional: readonly string[] = []): v is Record<string, any> {
    return v !== null && typeof v === 'object' && !Array.isArray(v) &&
        required.every(k => Object.hasOwn(v, k)) && Object.keys(v).every(k => required.includes(k) || optional.includes(k));
}
export const hex = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);
export const nonce = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{32}$/.test(v);
export const count = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;
export const positive = (v: unknown): v is number => count(v) && v > 0;
export const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
export const date = (v: unknown): v is Date => v instanceof Date && Number.isFinite(+v);
export function increment(v: number): number {
    if (!count(v) || !count(v + 1))
        fail();
    return v + 1;
}
export function hash(v: unknown): string { return createHash('sha256').update(JSON.stringify(v)).digest('hex'); }
export function routeForUid(key: string, uid: string): string { return derive(key, uid, 'archivale-entitlement-route-v1'); }
export function accountForUid(key: string, uid: string): string { return derive(key, uid, 'archivale-broker-account-v1'); }
function derive(key: string, uid: string, domain: string): string {
    if (typeof key !== 'string' || Buffer.byteLength(key) < 32 || typeof uid !== 'string' || uid.length < 1 || uid.length > 128)
        fail();
    return createHmac('sha256', key).update(JSON.stringify([domain, PROJECT, uid])).digest('hex');
}
export interface CreditIdentityConfig {
    version: 'credit-identity-config-v1';
    projectId: typeof PROJECT;
    enabled: true;
    routingKeyVersion: typeof ROUTE_KEY;
    accountKeyVersion: typeof ACCOUNT_KEY;
    cutoverId: string;
    maxAccounts: number;
    authorityMaxAgeMs: number;
    admissionPolicyId: string;
}
export function parseConfig(v: unknown): Readonly<CreditIdentityConfig> {
    if (!shape(v, ['version', 'projectId', 'enabled', 'routingKeyVersion', 'accountKeyVersion', 'cutoverId', 'maxAccounts', 'authorityMaxAgeMs', 'admissionPolicyId']) ||
        v.version !== 'credit-identity-config-v1' || v.projectId !== PROJECT || v.enabled !== true || v.routingKeyVersion !== ROUTE_KEY || v.accountKeyVersion !== ACCOUNT_KEY ||
        !nonce(v.cutoverId) || !nonce(v.admissionPolicyId) || !positive(v.maxAccounts) || v.maxAccounts > 10000 || !positive(v.authorityMaxAgeMs) || v.authorityMaxAgeMs > 300000)
        fail();
    return Object.freeze({
        ...v
    }) as unknown as Readonly<CreditIdentityConfig>;
}
export interface BridgeControl {
    version: 'credit-identity-control-v1';
    projectId: typeof PROJECT;
    side: 'billing' | 'broker';
    cutoverId: string;
    routingKeyVersion: typeof ROUTE_KEY;
    accountKeyVersion: typeof ACCOUNT_KEY;
    admissionPolicyId: string;
    revision: number;
    enrolledAccounts: number;
    admissionPolicyDigest?: string;
    enabled?: boolean;
    maxAccounts?: number;
}
export function initialControls(c: CreditIdentityConfig, side: 'billing' | 'broker', admissionPolicyDigest?: string): {
    control: BridgeControl;
    initialization: BridgeControl;
} {
    parseConfig(c);
    if (side === 'broker' ? !hex(admissionPolicyDigest) : admissionPolicyDigest !== undefined)
        fail();
    const initialization: BridgeControl = {
        version: 'credit-identity-control-v1', projectId: PROJECT, side, cutoverId: c.cutoverId, routingKeyVersion: ROUTE_KEY,
        accountKeyVersion: ACCOUNT_KEY, admissionPolicyId: c.admissionPolicyId, revision: 0, enrolledAccounts: 0, ...(side === 'broker' ? {
            admissionPolicyDigest
        } : {})
    };
    return {
        initialization, control: {
            ...initialization, enabled: true, maxAccounts: c.maxAccounts
        }
    };
}
export function controls(control: unknown, marker: unknown, c: CreditIdentityConfig, side: 'billing' | 'broker', digest?: string): {
    control: BridgeControl;
    initialization: BridgeControl;
} {
    const keys = ['version', 'projectId', 'side', 'cutoverId', 'routingKeyVersion', 'accountKeyVersion', 'admissionPolicyId', 'revision', 'enrolledAccounts', ...(side === 'broker' ? ['admissionPolicyDigest'] : [])];
    for (const [value, extra] of [[control, ['enabled', 'maxAccounts']], [marker, []]] as const) {
        if (!shape(value, [...keys, ...extra]) || value.version !== 'credit-identity-control-v1' || value.projectId !== PROJECT || value.side !== side || value.cutoverId !== c.cutoverId ||
            value.routingKeyVersion !== ROUTE_KEY || value.accountKeyVersion !== ACCOUNT_KEY || value.admissionPolicyId !== c.admissionPolicyId ||
            !count(value.revision) || !count(value.enrolledAccounts) || value.revision !== value.enrolledAccounts ||
            (side === 'broker' && (!hex(digest) || value.admissionPolicyDigest !== digest)))
            fail();
    }
    const a = control as BridgeControl, b = marker as BridgeControl;
    if (a.enabled !== true || a.maxAccounts !== c.maxAccounts || a.revision !== b.revision || a.enrolledAccounts !== b.enrolledAccounts || a.enrolledAccounts > c.maxAccounts)
        fail();
    return {
        control: a, initialization: b
    };
}
export function enrollControls(pair: {
    control: BridgeControl;
    initialization: BridgeControl;
}): typeof pair {
    if (pair.control.enrolledAccounts >= pair.control.maxAccounts!)
        fail();
    const fields = {
        revision: increment(pair.control.revision), enrolledAccounts: increment(pair.control.enrolledAccounts)
    };
    return {
        control: {
            ...pair.control, ...fields
        }, initialization: {
            ...pair.initialization, ...fields
        }
    };
}
export type CreditPlan = 'starter' | 'collector' | 'archive';
export interface CreditAuthoritySnapshot {
    version: 'credit-authority-v1';
    projectId: typeof PROJECT;
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    enrollmentId: string;
    lifecycleEpoch: string;
    lifecycleGeneration: number;
    publicationRevision: number;
    lifecycleStatus: 'active' | 'consent_paused' | 'retired';
    state: 'active' | 'grace' | 'canceled' | 'none';
    verifiedAtMs: number;
    reason?: 'requires_verification' | 'expired' | 'on_hold' | 'paused' | 'revoked' | 'pending' | 'retired';
    planId?: CreditPlan;
    playExpiresAtMs?: number;
    validUntilMs?: number;
}
const SNAPSHOT_KEYS = ['version', 'projectId', 'routingKeyVersion', 'route', 'enrollmentId', 'lifecycleEpoch', 'lifecycleGeneration', 'publicationRevision', 'lifecycleStatus', 'state', 'verifiedAtMs'];
export function validSnapshot(v: unknown): v is CreditAuthoritySnapshot {
    if (!shape(v, SNAPSHOT_KEYS, ['reason', 'planId', 'playExpiresAtMs', 'validUntilMs']) || v.version !== 'credit-authority-v1' || v.projectId !== PROJECT || v.routingKeyVersion !== ROUTE_KEY ||
        !hex(v.route) || !nonce(v.enrollmentId) || !nonce(v.lifecycleEpoch) || !positive(v.lifecycleGeneration) || !count(v.publicationRevision) || !count(v.verifiedAtMs) ||
        !['active', 'consent_paused', 'retired'].includes(v.lifecycleStatus))
        return false;
    if (v.state === 'none')
        return shape(v, [...SNAPSHOT_KEYS, 'reason']) && ['requires_verification', 'expired', 'on_hold', 'paused', 'revoked', 'pending', 'retired'].includes(v.reason) &&
            (v.lifecycleStatus !== 'retired' || v.reason === 'retired') && (v.lifecycleStatus !== 'consent_paused' || v.reason === 'revoked') && (v.reason !== 'retired' || v.lifecycleStatus === 'retired');
    return shape(v, [...SNAPSHOT_KEYS, 'planId', 'playExpiresAtMs', 'validUntilMs']) && ['active', 'grace', 'canceled'].includes(v.state) && v.lifecycleStatus === 'active' &&
        ['starter', 'collector', 'archive'].includes(v.planId) && count(v.playExpiresAtMs) && count(v.validUntilMs) && v.playExpiresAtMs > v.verifiedAtMs && v.validUntilMs > v.verifiedAtMs && v.validUntilMs <= v.playExpiresAtMs;
}
export function authorityDigest(s: CreditAuthoritySnapshot): string {
    if (!validSnapshot(s))
        fail();
    return hash([s.version, s.projectId, s.routingKeyVersion, s.route, s.enrollmentId, s.lifecycleEpoch, s.lifecycleGeneration, s.publicationRevision,
        s.lifecycleStatus, s.state, s.verifiedAtMs, s.reason ?? null, s.planId ?? null, s.playExpiresAtMs ?? null, s.validUntilMs ?? null]);
}
export interface AuthorityRead {
    version: 'credit-authority-read-v1';
    routingKeyVersion: typeof ROUTE_KEY;
    route: string;
    challenge: string;
}
export interface AuthorityReply {
    version: 'credit-authority-read-result-v1';
    challenge: string;
    snapshot: CreditAuthoritySnapshot;
    digest: string;
}
export function validRead(v: unknown): v is AuthorityRead { return shape(v, ['version', 'routingKeyVersion', 'route', 'challenge']) && v.version === 'credit-authority-read-v1' && v.routingKeyVersion === ROUTE_KEY && hex(v.route) && nonce(v.challenge); }
export function parseReply(v: unknown, request: AuthorityRead): AuthorityReply {
    if (!shape(v, ['version', 'challenge', 'snapshot', 'digest']) || v.version !== 'credit-authority-read-result-v1' || v.challenge !== request.challenge || !validSnapshot(v.snapshot) ||
        v.snapshot.route !== request.route || v.digest !== authorityDigest(v.snapshot) || Buffer.byteLength(JSON.stringify(v)) > 4096)
        fail();
    return structuredClone(v) as unknown as AuthorityReply;
}
