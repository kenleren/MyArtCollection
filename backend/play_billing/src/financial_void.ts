import { createHash } from 'node:crypto';
import { counter, fingerprint } from './account_authority.js';
import { COLLECTIONS, PACKAGE_NAME } from './constants.js';
import type { BillingIdentifiers } from './crypto.js';
import { sameLifecycle, validLifecycleFields } from './lifecycle.js';
import { EventWorkError, finiteDate, shape, validResolved, validEventWork, type EventWorkRecord } from './event_records.js';
import type { BillingTransaction } from './store.js';

export const FINANCIAL_EVENT_VERSION = 'play-event-work-v2';
export const FINANCIAL_VOID_VERSION = 'play-financial-void-v1';
export interface RawVoid { orderId: string; productType: number; refundType: number }
export interface FinancialVoid {
  version: typeof FINANCIAL_VOID_VERSION;
  orderFingerprint: string;
  productType: number;
  refundType: number;
  semanticDigest: string;
  disposition: 'supported_full_subscription' | 'unsupported_one_time' | 'unsupported_partial' | 'unknown_enum';
}
export type FinancialRole = 'owner' | 'alias' | 'conflict' | 'quarantine';
export interface FinancialOrder {
  version: 'play-financial-order-v1';
  packageName: typeof PACKAGE_NAME;
  orderFingerprint: string;
  tokenFingerprint: string;
  productType: 1;
  refundType: 1;
  semanticDigest: string;
  ownerEventFingerprint: string;
  createdAt: Date;
}
export interface FinancialVerification {
  version: 'play-financial-verification-v1';
  accountSubject: string;
  lifecycleEpoch: string;
  lifecycleGeneration: number;
  requestFingerprint: string;
  observationGeneration: number;
  publicationRevision: number;
  snapshotDigest: string;
  verifiedAt: Date;
  outcome: 'paid' | 'inactive';
  reason?: 'expired' | 'on_hold' | 'paused' | 'revoked' | 'pending';
}
const enumValue = (v: unknown): v is number => Number.isSafeInteger(v) && Number(v) >= 0 && Number(v) <= 0x7fffffff;
function disposition(product: number, refund: number): FinancialVoid['disposition'] {
  if (![1, 2].includes(product) || ![1, 2].includes(refund)) return 'unknown_enum';
  if (product === 2) return 'unsupported_one_time';
  return refund === 2 ? 'unsupported_partial' : 'supported_full_subscription';
}
function semantic(order: string, token: string, product: number, refund: number): string {
  return createHash('sha256').update(JSON.stringify([FINANCIAL_VOID_VERSION, PACKAGE_NAME, order, token, product, refund])).digest('hex');
}
/** Strict new-admission validation is intentionally separate from the legacy parser. */
export function financialVoid(raw: RawVoid | undefined, token: string, ids: BillingIdentifiers): FinancialVoid | undefined {
  if (!raw || !shape(raw, ['orderId', 'productType', 'refundType']) || typeof raw.orderId !== 'string' ||
      !raw.orderId || Buffer.byteLength(raw.orderId) > 1024 || /[\u0000-\u001f\u007f-\u009f]/u.test(raw.orderId) ||
      Buffer.from(raw.orderId).toString('utf8') !== raw.orderId || !enumValue(raw.productType) || !enumValue(raw.refundType)) return undefined;
  const orderFingerprint = ids.financialOrderFingerprint(raw.orderId);
  return { version: FINANCIAL_VOID_VERSION, orderFingerprint, productType: raw.productType, refundType: raw.refundType,
    semanticDigest: semantic(orderFingerprint, token, raw.productType, raw.refundType), disposition: disposition(raw.productType, raw.refundType) };
}
export function validFinancialVoid(v: FinancialVoid, token: unknown): boolean {
  return shape(v, ['version', 'orderFingerprint', 'productType', 'refundType', 'semanticDigest', 'disposition']) &&
    v.version === FINANCIAL_VOID_VERSION && fingerprint(v.orderFingerprint) && fingerprint(token) &&
    enumValue(v.productType) && enumValue(v.refundType) && v.disposition === disposition(v.productType, v.refundType) &&
    v.semanticDigest === semantic(v.orderFingerprint, token, v.productType, v.refundType);
}
export function validFinancialOrder(v: FinancialOrder, id: string): boolean {
  return shape(v, ['version', 'packageName', 'orderFingerprint', 'tokenFingerprint', 'productType', 'refundType', 'semanticDigest', 'ownerEventFingerprint', 'createdAt']) &&
    v.version === 'play-financial-order-v1' && v.packageName === PACKAGE_NAME && v.orderFingerprint === id && fingerprint(id) &&
    fingerprint(v.tokenFingerprint) && v.productType === 1 && v.refundType === 1 && fingerprint(v.ownerEventFingerprint) && finiteDate(v.createdAt) &&
    v.semanticDigest === semantic(id, v.tokenFingerprint, 1, 1);
}
function validVerification(v: FinancialVerification, work: EventWorkRecord): boolean {
  return shape(v, ['version', 'accountSubject', 'lifecycleEpoch', 'lifecycleGeneration', 'requestFingerprint', 'observationGeneration',
    'publicationRevision', 'snapshotDigest', 'verifiedAt', 'outcome'], ['reason']) &&
    v.version === 'play-financial-verification-v1' && fingerprint(v.accountSubject) && validLifecycleFields(v) &&
    fingerprint(v.requestFingerprint) && counter(v.observationGeneration) && v.observationGeneration > 0 &&
    counter(v.publicationRevision) && v.publicationRevision > 0 && fingerprint(v.snapshotDigest) && finiteDate(v.verifiedAt) &&
    work.resolved !== undefined && validResolved(work.resolved) && work.resolved.accountSubject === v.accountSubject && sameLifecycle(work.resolved, v) &&
    (v.outcome === 'paid' ? v.reason === undefined : v.outcome === 'inactive' && ['expired', 'on_hold', 'paused', 'revoked', 'pending'].includes(v.reason ?? ''));
}
export function validFinancialEvent(work: EventWorkRecord): boolean {
  if (work.version !== FINANCIAL_EVENT_VERSION || work.category !== 'void' || !work.financial || !validFinancialVoid(work.financial, work.tokenFingerprint)) return false;
  const role = work.financialRole;
  if (role === 'owner') {
    return work.financial.disposition === 'supported_full_subscription' && work.financialOwnerEventFingerprint === work.eventFingerprint &&
      !['duplicate_order', 'financial_conflict', 'unknown_enum', 'unsupported_one_time', 'unsupported_partial'].includes(work.reason) &&
      (work.state === 'completed' ? work.reason === 'none' && work.verification !== undefined && validVerification(work.verification, work) : work.verification === undefined);
  }
  if (work.state !== 'blocked' || work.envelope !== undefined || work.resolved !== undefined || work.verification !== undefined || work.leaseExpiresAt !== undefined) return false;
  if (role === 'alias') return work.financial.disposition === 'supported_full_subscription' && fingerprint(work.financialOwnerEventFingerprint) &&
    work.financialOwnerEventFingerprint !== work.eventFingerprint && work.reason === 'duplicate_order';
  if (work.financialOwnerEventFingerprint !== undefined) return false;
  if (role === 'conflict') return work.reason === 'financial_conflict';
  return role === 'quarantine' && work.financial.disposition !== 'supported_full_subscription' && work.reason === work.financial.disposition;
}
/** Reads only. Also validates aliases/conflicts against an existing canonical owner. */
export async function financialAnchor(tx: BillingTransaction, id: string): Promise<FinancialOrder | undefined> {
  const anchor = await tx.get<FinancialOrder>(COLLECTIONS.financialOrders, id);
  if (anchor === undefined) return undefined;
  if (!validFinancialOrder(anchor, id)) throw new EventWorkError('unsafe');
  const owner = await tx.get<EventWorkRecord>(COLLECTIONS.eventWork, anchor.ownerEventFingerprint);
  if (!owner || !validEventWork(owner, anchor.ownerEventFingerprint) || owner.financialRole !== 'owner' ||
      owner.financial?.orderFingerprint !== id || owner.tokenFingerprint !== anchor.tokenFingerprint || owner.financial.semanticDigest !== anchor.semanticDigest) throw new EventWorkError('unsafe');
  return anchor;
}
export async function validFinancialReciprocal(tx: BillingTransaction, work: EventWorkRecord): Promise<boolean> {
  if (work.version !== FINANCIAL_EVENT_VERSION) return true;
  if (!validFinancialEvent(work)) return false;
  if (work.financialRole === 'quarantine') return true;
  const anchor = await financialAnchor(tx, work.financial!.orderFingerprint);
  if (!anchor) return false;
  if (work.financialRole === 'conflict') return anchor.tokenFingerprint !== work.tokenFingerprint ||
    ([1, 2].includes(work.financial!.productType) && anchor.productType !== work.financial!.productType);
  return anchor.ownerEventFingerprint === work.financialOwnerEventFingerprint && anchor.tokenFingerprint === work.tokenFingerprint && anchor.semanticDigest === work.financial!.semanticDigest;
}
