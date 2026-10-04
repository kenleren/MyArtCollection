import { FINANCIAL_EVENT_VERSION, validFinancialEvent, type FinancialVoid, type FinancialRole, type FinancialVerification } from './financial_void.js';
import { LOCAL_DISPATCH_VERSION } from './dispatch_budget.js';
import { fingerprint, counter } from './account_authority.js';
import { validLifecycleFields, type LifecycleFields } from './lifecycle.js';
import { validKeyVersion, validBase64 } from './token_custody.js';

export const EVENT_WORK_VERSION = 'play-event-work-v1';
export const EVENT_CUSTODY_VERSION = 'play-event-token-custody-v1';
export const EVENT_CONTROL_VERSION = 'play-event-control-v1';
export const EVENT_LEASE_MS = 90_000;
export const EVENT_TOPIC = 'projects/my-art-collections/topics/archivale-play-rtdn';
export const EVENT_SOURCE = `//pubsub.googleapis.com/${EVENT_TOPIC}`;
export const EVENT_TYPE = 'google.cloud.pubsub.topic.v1.messagePublished';
export const COST_KINDS = ['discoveryGet','verificationGet','eventKms','accountKms','ack'] as const;
export type CostKind = typeof COST_KINDS[number];
export type EventReason = 'none' | 'transient' | 'unsafe' | 'unresolved' | 'consent' | 'retired' | 'budget' | 'unsupported' | 'configuration' | 'duplicate_order' | 'financial_conflict' | 'unknown_enum' | 'unsupported_one_time' | 'unsupported_partial';
export interface EventEnvelope { version: typeof EVENT_CUSTODY_VERSION; keyVersion: string; ciphertext: string }
export interface ResolvedEventAccount extends LifecycleFields { accountSubject: string }
export interface EventWorkFence { eventFingerprint: string; generation: number; nonce: Uint8Array }
export interface EventWorkRecord extends EventWorkFence {
  version: typeof EVENT_WORK_VERSION | typeof FINANCIAL_EVENT_VERSION;
  financial?: FinancialVoid;
  financialRole?: FinancialRole;
  financialOwnerEventFingerprint?: string;
  verification?: FinancialVerification;
  payloadDigest: string;
  tokenFingerprint?: string;
  category: 'subscription' | 'unsupported' | 'test' | 'one_time' | 'void' | 'refund_review';
  state: 'reserving' | 'ready' | 'working' | 'retry' | 'completed' | 'blocked';
  receivedAt: Date;
  dueAt: Date;
  leaseExpiresAt?: Date;
  envelope?: EventEnvelope;
  resolved?: ResolvedEventAccount;
  reason: EventReason;
  attemptStarts: Date[];
  totalAttempts: number;
  dispatchTotals: Record<CostKind, number>;
  dispatchVersion?: typeof LOCAL_DISPATCH_VERSION;
  dispatchBase?: Record<CostKind, number>;
}
export interface EventDescriptor { eventFingerprint: string; payloadDigest: string; tokenFingerprint?: string; category: EventWorkRecord['category'] }
export interface EventLimits { rows: number; admissions: number; gets: number; discoveries: number; kms: number; acknowledgements: number }
export const CLOSED_EVENT_LIMITS: EventLimits = Object.freeze({ rows:0, admissions:0, gets:0, discoveries:0, kms:0, acknowledgements:0 });
export const BOUNDED_EVENT_LIMITS: EventLimits = Object.freeze({ rows:20_000, admissions:120, gets:120, discoveries:30, kms:60, acknowledgements:30 });
export function record(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === 'object' && !Array.isArray(value); }
export function shape(value: unknown, required: string[], optional: string[] = []): boolean {
  return record(value) && required.every(k => Object.hasOwn(value, k)) && Object.keys(value).every(k => required.includes(k) || optional.includes(k));
}
export function finiteDate(v: unknown): v is Date { return v instanceof Date && Number.isFinite(v.getTime()); }
export function validResolved(v: ResolvedEventAccount): boolean {
  return shape(v, ['accountSubject','lifecycleEpoch','lifecycleGeneration']) && fingerprint(v.accountSubject) && validLifecycleFields(v);
}
export function validEventEnvelope(v: unknown): v is EventEnvelope {
  return shape(v, ['version','keyVersion','ciphertext']) && record(v) && v.version === EVENT_CUSTODY_VERSION &&
    validKeyVersion(v.keyVersion) && typeof v.ciphertext === 'string' && validBase64(v.ciphertext, 8192);
}
export function validEventWork(v: EventWorkRecord, id: string): boolean {
  if (!record(v)) return false;
  return shape(v, ['version','eventFingerprint','payloadDigest','category','state','receivedAt','dueAt','generation','nonce','reason','attemptStarts','totalAttempts','dispatchTotals'],
    ['tokenFingerprint','leaseExpiresAt','envelope','resolved','dispatchVersion','dispatchBase', ...(v.version === FINANCIAL_EVENT_VERSION ? ['financial','financialRole','financialOwnerEventFingerprint','verification'] : [])]) &&
    (v.version === EVENT_WORK_VERSION || validFinancialEvent(v)) && v.eventFingerprint === id && fingerprint(id) && fingerprint(v.payloadDigest) &&
    (v.tokenFingerprint === undefined || fingerprint(v.tokenFingerprint)) && ['subscription','unsupported','test','one_time','void','refund_review'].includes(v.category) && (['test','refund_review'].includes(v.category) ? v.tokenFingerprint === undefined : v.tokenFingerprint !== undefined) &&
    ['reserving','ready','working','retry','completed','blocked'].includes(v.state) && finiteDate(v.receivedAt) && finiteDate(v.dueAt) &&
    counter(v.generation) && v.generation > 0 && v.nonce instanceof Uint8Array && v.nonce.byteLength === 16 &&
    ['none','transient','unsafe','unresolved','consent','retired','budget','unsupported','configuration', ...(v.version === FINANCIAL_EVENT_VERSION ? ['duplicate_order','financial_conflict','unknown_enum','unsupported_one_time','unsupported_partial'] : [])].includes(v.reason) &&
    Array.isArray(v.attemptStarts) && v.attemptStarts.length <= 12 && v.attemptStarts.every(finiteDate) && counter(v.totalAttempts) && v.totalAttempts >= v.attemptStarts.length &&
    shape(v.dispatchTotals, [...COST_KINDS]) && COST_KINDS.every(k => counter(v.dispatchTotals[k])) &&
    ((v.dispatchVersion===undefined&&v.dispatchBase===undefined)||(v.dispatchVersion===LOCAL_DISPATCH_VERSION&&v.dispatchBase!==undefined&&shape(v.dispatchBase,[...COST_KINDS])&&COST_KINDS.every(k=>counter(v.dispatchBase![k])&&v.dispatchBase![k]<=v.dispatchTotals[k]))) &&
    (v.resolved === undefined || validResolved(v.resolved)) && (v.envelope === undefined || validEventEnvelope(v.envelope)) &&
    ((v.state === 'reserving' || v.state === 'working') ? finiteDate(v.leaseExpiresAt) && v.dueAt.getTime() === v.leaseExpiresAt.getTime() : v.leaseExpiresAt === undefined) &&
    (v.state !== 'reserving' || v.envelope === undefined) &&
    (!['ready','working','retry'].includes(v.state) || (v.envelope !== undefined && v.tokenFingerprint !== undefined)) &&
    (v.envelope === undefined || v.tokenFingerprint !== undefined);
}
export function ownsEvent(v: EventWorkRecord | undefined, fence: EventWorkFence, now: Date, state: 'reserving' | 'working' = 'working'): v is EventWorkRecord {
  return v !== undefined && validEventWork(v, fence.eventFingerprint) && v.generation === fence.generation &&
    fence.nonce instanceof Uint8Array && Buffer.from(v.nonce).equals(fence.nonce) && v.state === state && v.leaseExpiresAt! > now;
}
export function emptyCosts(): Record<CostKind, number> { return { discoveryGet:0, verificationGet:0, eventKms:0, accountKms:0, ack:0 }; }
export class EventWorkError extends Error {
  constructor(readonly reason: EventReason | 'disabled') { super(`billing event ${reason}`); }
}
