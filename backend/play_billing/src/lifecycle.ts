/** Strict reciprocal account routing. No Firebase UID or provider credential. */
export const LIFECYCLE_VERSION = 'play-billing-lifecycle-v1';
export const ROUTE_VERSION = 'play-billing-route-v1';
export interface LifecycleFields { lifecycleEpoch: string; lifecycleGeneration: number }
export type LifecycleStatus = 'active' | 'consent_paused' | 'retired';
export interface LifecycleRoot extends LifecycleFields {
  version: typeof LIFECYCLE_VERSION;
  accountSubject: string;
  status: LifecycleStatus;
  routeFingerprint: string;
  obfuscatedAccountId: string;
  assertionId: string;
  createdAt: Date;
  updatedAt: Date;
  reconcileVersion?: 'play-billing-reconcile-v1';
  reconcileScheduleRevision?: number;
  reconcileOwnerGeneration?: number;
  /** Opaque to core payment safety; bridge operations validate its separate schema. */
  brokerBridge?: unknown;
  authorityVersion?: 'play-billing-authority-v1';
  authorityPublicationRevision?: number;
}
export interface LifecycleRoute extends LifecycleFields {
  version: typeof ROUTE_VERSION;
  accountSubject: string;
  status: LifecycleStatus;
  assertionId: string;
}
export function validLifecycleFields(value: Partial<LifecycleFields>): value is LifecycleFields {
  return typeof value.lifecycleEpoch === 'string' && /^[0-9a-f]{32}$/.test(value.lifecycleEpoch) &&
    Number.isSafeInteger(value.lifecycleGeneration) && value.lifecycleGeneration! > 0;
}
export function sameLifecycle(a: LifecycleFields, b: LifecycleFields): boolean {
  return a.lifecycleEpoch === b.lifecycleEpoch && a.lifecycleGeneration === b.lifecycleGeneration;
}
export function validOpaqueRoute(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value) &&
    Buffer.from(value, 'base64url').byteLength === 32 && Buffer.from(value, 'base64url').toString('base64url') === value;
}
export function validLifecycleRoot(value: LifecycleRoot, subject: string): boolean {
  return exact(value, ['version','accountSubject','status','routeFingerprint','obfuscatedAccountId','assertionId',
    'lifecycleEpoch','lifecycleGeneration','createdAt','updatedAt',
    ...(Object.hasOwn(value, 'brokerBridge') ? ['brokerBridge'] : []),
    ...(value.reconcileVersion === undefined && value.reconcileScheduleRevision === undefined && value.reconcileOwnerGeneration === undefined ? [] : ['reconcileVersion','reconcileScheduleRevision','reconcileOwnerGeneration']),
    ...(value.authorityVersion === undefined && value.authorityPublicationRevision === undefined ? [] : ['authorityVersion','authorityPublicationRevision'])]) &&
    ((value.authorityVersion === undefined && value.authorityPublicationRevision === undefined) || (value.authorityVersion === 'play-billing-authority-v1' &&
      Number.isSafeInteger(value.authorityPublicationRevision) && value.authorityPublicationRevision! >= 0)) &&
    ((value.reconcileVersion === undefined && value.reconcileScheduleRevision === undefined && value.reconcileOwnerGeneration === undefined) ||
      (value.reconcileVersion === 'play-billing-reconcile-v1' && Number.isSafeInteger(value.reconcileScheduleRevision) && value.reconcileScheduleRevision! >= 0 && Number.isSafeInteger(value.reconcileOwnerGeneration) && value.reconcileOwnerGeneration! >= 0)) &&
    value.version === LIFECYCLE_VERSION && value.accountSubject === subject && fingerprint(subject) &&
    validLifecycleFields(value) && status(value.status) && fingerprint(value.routeFingerprint) &&
    validOpaqueRoute(value.obfuscatedAccountId) && assertion(value.assertionId) &&
    value.createdAt instanceof Date && Number.isFinite(value.createdAt.getTime()) &&
    value.updatedAt instanceof Date && Number.isFinite(value.updatedAt.getTime());
}
export function validReciprocalRoute(value: LifecycleRoute, root: LifecycleRoot): boolean {
  return exact(value, ['version','accountSubject','status','assertionId','lifecycleEpoch','lifecycleGeneration']) &&
    value.version === ROUTE_VERSION && value.accountSubject === root.accountSubject &&
    sameLifecycle(value, root) && value.status === root.status && value.assertionId === root.assertionId;
}
export function routeFor(root: LifecycleRoot): LifecycleRoute {
  return { version: ROUTE_VERSION, accountSubject: root.accountSubject, status: root.status,
    assertionId: root.assertionId, lifecycleEpoch: root.lifecycleEpoch, lifecycleGeneration: root.lifecycleGeneration };
}
function fingerprint(v: unknown): boolean { return typeof v === 'string' && /^[a-f0-9]{64}$/.test(v); }
function assertion(v: unknown): boolean { return typeof v === 'string' && /^[a-f0-9]{32}$/.test(v); }
function status(v: unknown): boolean { return ['active','consent_paused','retired'].includes(v as string); }
function exact(value: object, keys: string[]): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && Object.keys(value).every((key) => keys.includes(key));
}
