import type { BrokerTerminalOutcome } from './contracts.js';
import { isBrokerErrorCondition } from './error_contract.js';

export const REQUEST_LIFECYCLE_RECORD_VERSION = 'broker-request-lifecycle-v1';

export type RequestLifecycleState = 'reserved' | 'dispatch_started' | 'terminal';
export type SettlementState =
  | 'reserved'
  | 'pending_refund'
  | 'refunded'
  | 'pending_finalize'
  | 'finalized';

export interface StoredRequestRecord {
  record_version: typeof REQUEST_LIFECYCLE_RECORD_VERSION;
  quota_subject: string;
  request_id: string;
  payload_hash: string;
  state: RequestLifecycleState;
  credit_cost: number;
  reservation_lease_expires_at: string;
  retention_expires_at: string;
  settlement_state: SettlementState;
  terminal_outcome?: BrokerTerminalOutcome;
}

export type ParsedStoredRequest =
  | { kind: 'valid'; record: StoredRequestRecord }
  | { kind: 'absent' }
  | { kind: 'unsafe' };

export function parseStoredRequest(value: unknown): ParsedStoredRequest {
  if (value === undefined) {
    return { kind: 'absent' };
  }
  if (!isRecord(value)) {
    return { kind: 'unsafe' };
  }
  if (!hasOnlyKeys(value, REQUEST_RECORD_KEYS)) {
    return { kind: 'unsafe' };
  }
  if (
    value.record_version !== REQUEST_LIFECYCLE_RECORD_VERSION ||
    !nonEmptyString(value.quota_subject) ||
    !nonEmptyString(value.request_id) ||
    !/^[a-f0-9]{64}$/.test(stringOrEmpty(value.payload_hash)) ||
    !isLifecycleState(value.state) ||
    value.credit_cost !== 1 ||
    !isIsoDate(value.reservation_lease_expires_at) ||
    !isIsoDate(value.retention_expires_at) ||
    !isSettlementState(value.settlement_state)
  ) {
    return { kind: 'unsafe' };
  }

  const terminalOutcome = parseTerminalOutcome(value.terminal_outcome);
  if (
    (value.state === 'terminal' && terminalOutcome === undefined) ||
    (value.state !== 'terminal' && value.terminal_outcome !== undefined) ||
    (value.state !== 'terminal' && value.settlement_state !== 'reserved') ||
    (value.state === 'terminal' && value.settlement_state === 'reserved')
  ) {
    return { kind: 'unsafe' };
  }

  if (Date.parse(value.reservation_lease_expires_at) > Date.parse(value.retention_expires_at)) {
    return { kind: 'unsafe' };
  }

  const record = {
    record_version: REQUEST_LIFECYCLE_RECORD_VERSION,
    quota_subject: value.quota_subject as string,
    request_id: value.request_id as string,
    payload_hash: value.payload_hash as string,
    state: value.state as RequestLifecycleState,
    credit_cost: 1,
    reservation_lease_expires_at: value.reservation_lease_expires_at as string,
    retention_expires_at: value.retention_expires_at as string,
    settlement_state: value.settlement_state as SettlementState,
    ...(terminalOutcome === undefined ? {} : { terminal_outcome: terminalOutcome }),
  } satisfies StoredRequestRecord;
  if (!hasConsistentTerminalBinding(record)) {
    return { kind: 'unsafe' };
  }

  return {
    kind: 'valid',
    record,
  };
}

export function storedRequestMatchesKey(
  record: StoredRequestRecord,
  quotaSubject: string,
  requestId: string,
): boolean {
  return record.quota_subject === quotaSubject && record.request_id === requestId;
}

function parseTerminalOutcome(value: unknown): BrokerTerminalOutcome | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  if (
    value.kind === 'success' &&
    hasOnlyKeys(value, new Set(['kind', 'response'])) &&
    isBrokerResponse(value.response)
  ) {
    return value as unknown as BrokerTerminalOutcome;
  }
  if (
    value.kind === 'error' &&
    hasOnlyKeys(value, new Set(['kind', 'failure'])) &&
    isRecord(value.failure) &&
    hasOnlyKeys(value.failure, new Set(['request_id', 'condition', 'retry_after_seconds'])) &&
    isBrokerErrorCondition(value.failure.condition) &&
    nonEmptyString(value.failure.request_id) &&
    (value.failure.retry_after_seconds === undefined ||
      (typeof value.failure.retry_after_seconds === 'number' &&
        Number.isFinite(value.failure.retry_after_seconds)))
  ) {
    return value as unknown as BrokerTerminalOutcome;
  }
  return undefined;
}

function hasConsistentTerminalBinding(record: StoredRequestRecord): boolean {
  if (record.state !== 'terminal') {
    return true;
  }
  const outcome = record.terminal_outcome!;
  if (outcome.kind === 'success') {
    return outcome.response.request_id === record.request_id &&
      (record.settlement_state === 'pending_finalize' || record.settlement_state === 'finalized');
  }
  if (outcome.failure.request_id !== record.request_id) {
    return false;
  }
  const expected = settlementIntentForCondition(outcome.failure.condition);
  return expected === 'refund'
    ? record.settlement_state === 'pending_refund' || record.settlement_state === 'refunded'
    : expected === 'finalize' &&
        (record.settlement_state === 'pending_finalize' || record.settlement_state === 'finalized');
}

function settlementIntentForCondition(condition: string): 'refund' | 'finalize' | undefined {
  switch (condition) {
    case 'reservation_lease_expired':
    case 'provider_config_failure':
    case 'provider_construction_failure':
    case 'provider_authorization_failure':
    case 'dispatch_persistence_failure':
    case 'provider_rate_limited':
    case 'provider_timeout':
      return 'refund';
    case 'provider_refusal':
    case 'provider_failure':
    case 'provider_invalid_output':
      return 'finalize';
    default:
      return undefined;
  }
}

function isBrokerResponse(value: unknown): boolean {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, BROKER_RESPONSE_KEYS) ||
    !nonEmptyString(value.request_id) ||
    value.status !== 'completed' ||
    (value.provider !== 'fake-provider' && value.provider !== 'openai') ||
    !nonEmptyString(value.model) ||
    (value.reasoning_effort !== 'none' && value.reasoning_effort !== 'medium' &&
      value.reasoning_effort !== 'high' && value.reasoning_effort !== 'xhigh') ||
    !isIsoDate(value.completed_at) ||
    !Array.isArray(value.sources) ||
    !Array.isArray(value.candidate_attributions) ||
    !Array.isArray(value.comparable_value_signals) ||
    !isStringArray(value.warnings) ||
    !value.sources.every(isBrokerSource)
  ) {
    return false;
  }

  const sourceIds = new Set(value.sources.map((source) => source.source_id));
  return value.candidate_attributions.every((candidate) =>
    isBrokerCandidate(candidate, sourceIds)) &&
    value.comparable_value_signals.every((signal) =>
      isComparableValueSignal(signal, sourceIds));
}

function isBrokerSource(value: unknown): value is Record<string, unknown> & { source_id: string } {
  return isRecord(value) &&
    hasOnlyKeys(value, BROKER_SOURCE_KEYS) &&
    typeof value.source_id === 'string' &&
    typeof value.source_name === 'string' &&
    (value.source_type === 'museum' || value.source_type === 'auction_house') &&
    typeof value.source_url === 'string' &&
    value.source_url.startsWith('https://') &&
    typeof value.title === 'string' &&
    typeof value.accessed_at === 'string' &&
    typeof value.citation_excerpt === 'string' &&
    isStringArray(value.matched_fields);
}

function isBrokerCandidate(value: unknown, sourceIds: ReadonlySet<string>): boolean {
  return isRecord(value) &&
    hasOnlyKeys(value, BROKER_CANDIDATE_KEYS) &&
    typeof value.candidate_id === 'string' &&
    (value.confidence === 'possible' || value.confidence === 'likely' ||
      value.confidence === 'insufficient_evidence') &&
    typeof value.match_reason === 'string' &&
    optionalStringField(value.title) &&
    optionalStringField(value.artist) &&
    optionalStringField(value.year) &&
    optionalStringField(value.medium) &&
    isFieldSources(value.field_sources) &&
    isStringArray(value.source_refs) &&
    value.source_refs.length > 0 &&
    value.source_refs.every((sourceRef) => sourceIds.has(sourceRef));
}

function isComparableValueSignal(value: unknown, sourceIds: ReadonlySet<string>): boolean {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, COMPARABLE_VALUE_SIGNAL_KEYS) ||
    (value.kind !== 'public_estimate' && value.kind !== 'comparable_sale_signal' &&
      value.kind !== 'no_reliable_comparable') ||
    typeof value.label !== 'string' ||
    !isStringArray(value.source_refs) ||
    typeof value.caveat !== 'string' ||
    !value.source_refs.every((sourceRef) => sourceIds.has(sourceRef))
  ) {
    return false;
  }
  return value.kind === 'no_reliable_comparable' || value.source_refs.length > 0;
}

function isFieldSources(value: unknown): boolean {
  return isRecord(value) && Object.values(value).every((source) => source === 'ai_suggested');
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((entry) => typeof entry === 'string');
}

function optionalStringField(value: unknown): boolean {
  return value === undefined || typeof value === 'string';
}

function isLifecycleState(value: unknown): value is RequestLifecycleState {
  return value === 'reserved' || value === 'dispatch_started' || value === 'terminal';
}

function isSettlementState(value: unknown): value is SettlementState {
  return value === 'reserved' || value === 'pending_refund' || value === 'refunded' ||
    value === 'pending_finalize' || value === 'finalized';
}

function isIsoDate(value: unknown): value is string {
  return typeof value === 'string' && Number.isFinite(Date.parse(value));
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

function stringOrEmpty(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

const REQUEST_RECORD_KEYS = new Set([
  'record_version',
  'quota_subject',
  'request_id',
  'payload_hash',
  'state',
  'credit_cost',
  'reservation_lease_expires_at',
  'retention_expires_at',
  'settlement_state',
  'terminal_outcome',
]);
const BROKER_RESPONSE_KEYS = new Set([
  'request_id',
  'status',
  'provider',
  'model',
  'reasoning_effort',
  'completed_at',
  'sources',
  'candidate_attributions',
  'comparable_value_signals',
  'warnings',
]);
const BROKER_SOURCE_KEYS = new Set([
  'source_id',
  'source_name',
  'source_type',
  'source_url',
  'title',
  'accessed_at',
  'citation_excerpt',
  'matched_fields',
]);
const BROKER_CANDIDATE_KEYS = new Set([
  'candidate_id',
  'confidence',
  'match_reason',
  'title',
  'artist',
  'year',
  'medium',
  'field_sources',
  'source_refs',
]);
const COMPARABLE_VALUE_SIGNAL_KEYS = new Set([
  'kind',
  'label',
  'source_refs',
  'caveat',
]);
