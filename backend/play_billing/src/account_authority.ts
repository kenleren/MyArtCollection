import { LOCAL_DISPATCH_VERSION, LOCAL_CAPS, validCounts, type DispatchCounts } from './dispatch_budget.js';
import { createHash } from 'node:crypto';
import { PRODUCT_ALLOWLIST, type PlanId, type ProductId } from './constants.js';
import type { NormalizedPaidState } from './contracts.js';
import { sameLifecycle, validLifecycleFields, type LifecycleFields, type LifecycleRoot } from './lifecycle.js';

export const AUTHORITY_VERSION = 'play-billing-authority-v1';
export const SNAPSHOT_VERSION = 'play-billing-authority-snapshot-v1';
export const OUTBOX_VERSION = 'play-billing-authority-outbox-v1';
export type ObservationSource = 'foreground' | 'background';
export type InactiveReason = 'requires_verification' | 'expired' | 'on_hold' | 'paused' | 'revoked' | 'pending' | 'retired';
export interface ObservationOwner {
  requestFingerprint: string;
  nonce: Uint8Array;
  tokenFingerprint: string;
  source: ObservationSource;
  phase: 'working' | 'ack_in_progress' | 'ack_unknown' | 'complete';
  leaseExpiresAt?: Date;
  dispatchVersion?: typeof LOCAL_DISPATCH_VERSION;
  dispatchCounts?: DispatchCounts;
}
export interface AuthoritySnapshot extends LifecycleFields {
  version: typeof SNAPSHOT_VERSION;
  accountSubject: string;
  publicationRevision: number;
  observationGeneration: number;
  state: NormalizedPaidState | 'none';
  reason?: InactiveReason;
  planId?: PlanId;
  productId?: ProductId;
  tokenFingerprint?: string;
  verifiedAt: Date;
  playExpiresAt?: Date;
}
export interface AccountAuthority extends LifecycleFields {
  version: typeof AUTHORITY_VERSION;
  accountSubject: string;
  observationGeneration: number;
  publicationRevision: number;
  owner?: ObservationOwner;
  acknowledgementRecoveryToken?: string;
  snapshot: AuthoritySnapshot;
}
export interface AuthorityOutbox {
  version: typeof OUTBOX_VERSION;
  snapshot: AuthoritySnapshot;
  digest: string;
}
export function fingerprint(value: unknown): value is string { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
export function counter(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function date(value: unknown): value is Date { return value instanceof Date && Number.isFinite(value.getTime()); }
function shape(value: unknown, required: string[], optional: string[] = []): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    required.every(k => Object.hasOwn(value, k)) && Object.keys(value).every(k => required.includes(k) || optional.includes(k));
}
export function validSnapshot(s: AuthoritySnapshot): boolean {
  if (!shape(s, ['version','accountSubject','lifecycleEpoch','lifecycleGeneration','publicationRevision','observationGeneration','state','verifiedAt'],
    ['reason','planId','productId','tokenFingerprint','playExpiresAt']) || s.version !== SNAPSHOT_VERSION || !fingerprint(s.accountSubject) ||
    !validLifecycleFields(s) || !counter(s.publicationRevision) || !counter(s.observationGeneration) || !date(s.verifiedAt) ||
    (s.tokenFingerprint !== undefined && !fingerprint(s.tokenFingerprint))) return false;
  if (s.state === 'none') return ['requires_verification','expired','on_hold','paused','revoked','pending','retired'].includes(s.reason ?? '') &&
    s.planId === undefined && s.productId === undefined && s.playExpiresAt === undefined;
  return ['active','grace','canceled'].includes(s.state) && s.reason === undefined && fingerprint(s.tokenFingerprint) &&
    s.productId !== undefined && Object.hasOwn(PRODUCT_ALLOWLIST, s.productId) &&
    PRODUCT_ALLOWLIST[s.productId].planId === s.planId && date(s.playExpiresAt) && s.playExpiresAt > s.verifiedAt;
}
export function snapshotDigest(snapshot: AuthoritySnapshot): string {
  return createHash('sha256').update(JSON.stringify([snapshot.version, snapshot.accountSubject, snapshot.lifecycleEpoch,
    snapshot.lifecycleGeneration, snapshot.publicationRevision, snapshot.observationGeneration, snapshot.state,
    snapshot.reason ?? null, snapshot.planId ?? null, snapshot.productId ?? null, snapshot.tokenFingerprint ?? null,
    snapshot.verifiedAt.toISOString(), snapshot.playExpiresAt?.toISOString() ?? null])).digest('hex');
}
export function outboxFor(snapshot: AuthoritySnapshot): AuthorityOutbox {
  return { version: OUTBOX_VERSION, snapshot, digest: snapshotDigest(snapshot) };
}
export function validAuthority(a: AccountAuthority, root: LifecycleRoot, outbox: AuthorityOutbox): boolean {
  if (!shape(a, ['version','accountSubject','lifecycleEpoch','lifecycleGeneration','observationGeneration','publicationRevision','snapshot'],
    ['owner','acknowledgementRecoveryToken']) || a.version !== AUTHORITY_VERSION || a.accountSubject !== root.accountSubject ||
    !sameLifecycle(a, root) || !counter(a.observationGeneration) || !counter(a.publicationRevision) ||
    root.authorityVersion !== AUTHORITY_VERSION || root.authorityPublicationRevision !== a.publicationRevision ||
    !validSnapshot(a.snapshot) || !sameLifecycle(a.snapshot, a) || a.snapshot.accountSubject !== a.accountSubject ||
    a.snapshot.publicationRevision !== a.publicationRevision || a.snapshot.observationGeneration > a.observationGeneration ||
    (a.acknowledgementRecoveryToken !== undefined && !fingerprint(a.acknowledgementRecoveryToken)) ||
    !shape(outbox, ['version','snapshot','digest']) || outbox.version !== OUTBOX_VERSION || !validSnapshot(outbox.snapshot) ||
    outbox.digest !== snapshotDigest(a.snapshot) || outbox.digest !== snapshotDigest(outbox.snapshot)) return false;
  if (a.owner === undefined) return a.acknowledgementRecoveryToken === undefined || fingerprint(a.acknowledgementRecoveryToken);
  const o = a.owner;
  return shape(o, ['requestFingerprint','nonce','tokenFingerprint','source','phase'], ['leaseExpiresAt','dispatchVersion','dispatchCounts']) &&
    ((o.dispatchVersion===undefined && o.dispatchCounts===undefined)||(o.dispatchVersion===LOCAL_DISPATCH_VERSION && o.dispatchCounts!==undefined && validCounts(o.dispatchCounts,LOCAL_CAPS))) &&
    a.observationGeneration > 0 && fingerprint(o.requestFingerprint) && fingerprint(o.tokenFingerprint) &&
    o.nonce instanceof Uint8Array && o.nonce.byteLength === 16 && ['foreground','background'].includes(o.source) &&
    ['working','ack_in_progress','ack_unknown','complete'].includes(o.phase) &&
    ((o.phase === 'working' || o.phase === 'ack_in_progress') ? date(o.leaseExpiresAt) : o.leaseExpiresAt === undefined) &&
    (!(o.phase === 'ack_in_progress' || o.phase === 'ack_unknown') || a.acknowledgementRecoveryToken === o.tokenFingerprint);
}
export function initialAuthority(root: LifecycleRoot, now: Date): AccountAuthority {
  return { version: AUTHORITY_VERSION, accountSubject: root.accountSubject, lifecycleEpoch: root.lifecycleEpoch,
    lifecycleGeneration: root.lifecycleGeneration, observationGeneration: 0, publicationRevision: 0,
    snapshot: { version: SNAPSHOT_VERSION, accountSubject: root.accountSubject, lifecycleEpoch: root.lifecycleEpoch,
      lifecycleGeneration: root.lifecycleGeneration, observationGeneration: 0, publicationRevision: 0,
      state: 'none', reason: 'requires_verification', verifiedAt: now } };
}
