import { CURRENT_ERROR_CONTRACT_VERSION } from './contracts.js';

export const DEFAULT_RETRY_AFTER_SECONDS = 30;
export const MIN_RETRY_AFTER_SECONDS = 5;
export const MAX_RETRY_AFTER_SECONDS = 300;

export type BrokerErrorCondition =
  | 'method_not_allowed'
  | 'unsupported_media_type'
  | 'invalid_json'
  | 'broker_disabled'
  | 'broker_misconfigured'
  | 'missing_auth_token'
  | 'invalid_auth_token'
  | 'wrong_project_auth'
  | 'missing_app_check_token'
  | 'invalid_app_check_token'
  | 'wrong_project_app_check'
  | 'app_check_replayed'
  | 'identity_project_mismatch'
  | 'unsupported_auth_provider'
  | 'unapproved_app'
  | 'forbidden_uid'
  | 'consent_required'
  | 'stale_consent'
  | 'not_entitled'
  | 'broker_breaker_open'
  | 'invalid_request_payload'
  | 'invalid_request_id'
  | 'payload_contract_mismatch'
  | 'payload_class_mismatch'
  | 'invalid_payload_hash'
  | 'payload_hash_mismatch'
  | 'unsupported_image_mime_type'
  | 'invalid_image_size'
  | 'invalid_image_dimensions'
  | 'invalid_image_encoding'
  | 'invalid_unicode'
  | 'idempotency_conflict'
  | 'quota_subject_in_flight'
  | 'credits_exhausted'
  | 'reservation_lease_expired'
  | 'dispatch_outcome_unknown'
  | 'malformed_durable_record'
  | 'durable_store_failure'
  | 'provider_config_failure'
  | 'provider_construction_failure'
  | 'provider_authorization_failure'
  | 'dispatch_persistence_failure'
  | 'terminal_persistence_failure'
  | 'provider_rate_limited'
  | 'provider_refusal'
  | 'provider_timeout'
  | 'provider_failure'
  | 'provider_invalid_output';

export interface BrokerErrorDefinition {
  http_status: number;
  code: string;
  message: string;
  retryable: boolean;
  retry_after_seconds?: number;
}

export interface BrokerErrorEnvelope {
  ok: false;
  error_contract_version: typeof CURRENT_ERROR_CONTRACT_VERSION;
  request_id?: string;
  status: 'rejected' | 'conflict';
  error: {
    code: string;
    message: string;
    retryable: boolean;
    retry_after_seconds?: number;
  };
}

const PAYLOAD_INVALID = definition(400, 'payload_invalid', 'The request payload is invalid.', false);
const UNAUTHORIZED = definition(401, 'unauthorized', 'Authentication could not be verified.', false);
const FORBIDDEN = definition(403, 'forbidden', 'This request is not allowed.', false);
const BROKER_UNAVAILABLE = definition(
  503,
  'temporarily_unavailable',
  'Research is temporarily unavailable.',
  true,
  DEFAULT_RETRY_AFTER_SECONDS,
);
const OUTCOME_UNKNOWN = definition(
  409,
  'request_outcome_unknown',
  'The prior request outcome cannot be safely retried.',
  false,
);

export const BROKER_ERROR_DEFINITIONS: Readonly<Record<BrokerErrorCondition, BrokerErrorDefinition>> = {
  method_not_allowed: definition(405, 'method_not_allowed', 'Only POST requests are accepted.', false),
  unsupported_media_type: definition(
    415,
    'unsupported_media_type',
    'Content-Type must be application/json.',
    false,
  ),
  invalid_json: PAYLOAD_INVALID,
  broker_disabled: BROKER_UNAVAILABLE,
  broker_misconfigured: BROKER_UNAVAILABLE,
  missing_auth_token: UNAUTHORIZED,
  invalid_auth_token: UNAUTHORIZED,
  wrong_project_auth: UNAUTHORIZED,
  missing_app_check_token: UNAUTHORIZED,
  invalid_app_check_token: UNAUTHORIZED,
  wrong_project_app_check: UNAUTHORIZED,
  app_check_replayed: definition(
    401,
    'unauthorized',
    'Authentication could not be verified.',
    true,
  ),
  identity_project_mismatch: UNAUTHORIZED,
  unsupported_auth_provider: FORBIDDEN,
  unapproved_app: FORBIDDEN,
  forbidden_uid: FORBIDDEN,
  consent_required: definition(
    403,
    'consent_required',
    'Approved research consent is required.',
    false,
  ),
  stale_consent: definition(
    403,
    'consent_stale',
    'Research consent must be refreshed.',
    false,
  ),
  not_entitled: definition(
    403,
    'not_entitled',
    'Online research is not included for this account.',
    false,
  ),
  broker_breaker_open: BROKER_UNAVAILABLE,
  invalid_request_payload: PAYLOAD_INVALID,
  invalid_request_id: PAYLOAD_INVALID,
  payload_contract_mismatch: PAYLOAD_INVALID,
  payload_class_mismatch: PAYLOAD_INVALID,
  invalid_payload_hash: PAYLOAD_INVALID,
  payload_hash_mismatch: PAYLOAD_INVALID,
  unsupported_image_mime_type: definition(
    415,
    'unsupported_media_type',
    'The image media type is not supported.',
    false,
  ),
  invalid_image_size: definition(413, 'payload_too_large', 'The image payload is too large.', false),
  invalid_image_dimensions: PAYLOAD_INVALID,
  invalid_image_encoding: PAYLOAD_INVALID,
  invalid_unicode: PAYLOAD_INVALID,
  idempotency_conflict: definition(
    409,
    'idempotency_conflict',
    'The request ID was already used for a different payload.',
    false,
  ),
  quota_subject_in_flight: definition(
    409,
    'request_in_flight',
    'A research request is already in progress.',
    true,
    MIN_RETRY_AFTER_SECONDS,
  ),
  credits_exhausted: definition(
    402,
    'credits_exhausted',
    'No online research credits remain.',
    false,
  ),
  reservation_lease_expired: definition(
    409,
    'request_expired',
    'The prior request expired before provider dispatch.',
    false,
  ),
  dispatch_outcome_unknown: OUTCOME_UNKNOWN,
  malformed_durable_record: definition(
    503,
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    false,
  ),
  durable_store_failure: BROKER_UNAVAILABLE,
  provider_config_failure: BROKER_UNAVAILABLE,
  provider_construction_failure: BROKER_UNAVAILABLE,
  provider_authorization_failure: BROKER_UNAVAILABLE,
  dispatch_persistence_failure: definition(
    503,
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    true,
    MIN_RETRY_AFTER_SECONDS,
  ),
  terminal_persistence_failure: definition(
    503,
    'temporarily_unavailable',
    'Research is temporarily unavailable.',
    false,
  ),
  provider_rate_limited: definition(
    429,
    'rate_limited',
    'The research service is busy. Try again later.',
    true,
    DEFAULT_RETRY_AFTER_SECONDS,
  ),
  provider_refusal: definition(
    502,
    'upstream_refusal',
    'The research provider declined this request.',
    false,
  ),
  provider_timeout: definition(
    504,
    'upstream_timeout',
    'The research provider did not finish in time.',
    false,
  ),
  provider_failure: definition(
    502,
    'upstream_failure',
    'The research provider could not complete the request.',
    false,
  ),
  provider_invalid_output: definition(
    502,
    'upstream_invalid_output',
    'The research result did not pass validation.',
    false,
  ),
};

export function brokerErrorEnvelope(
  condition: BrokerErrorCondition,
  requestId?: string,
  retryAfterSeconds?: number,
): { status: number; body: BrokerErrorEnvelope } {
  const definition = BROKER_ERROR_DEFINITIONS[condition];
  const safeRequestId = requestId !== undefined && isUuid(requestId) ? requestId : undefined;
  const dynamicRetryAfter = condition === 'provider_rate_limited'
    ? clampRetryAfterSeconds(retryAfterSeconds)
    : definition.retry_after_seconds;
  return {
    status: definition.http_status,
    body: {
      ok: false,
      error_contract_version: CURRENT_ERROR_CONTRACT_VERSION,
      ...(safeRequestId === undefined ? {} : { request_id: safeRequestId }),
      status: condition === 'idempotency_conflict' ? 'conflict' : 'rejected',
      error: {
        code: definition.code,
        message: definition.message,
        retryable: definition.retryable,
        ...(dynamicRetryAfter === undefined
          ? {}
          : { retry_after_seconds: dynamicRetryAfter }),
      },
    },
  };
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

export function clampRetryAfterSeconds(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value) || value <= 0) {
    return DEFAULT_RETRY_AFTER_SECONDS;
  }
  return Math.min(MAX_RETRY_AFTER_SECONDS, Math.max(MIN_RETRY_AFTER_SECONDS, Math.ceil(value)));
}

export function isBrokerErrorCondition(value: unknown): value is BrokerErrorCondition {
  return typeof value === 'string' &&
    Object.prototype.hasOwnProperty.call(BROKER_ERROR_DEFINITIONS, value);
}

function definition(
  http_status: number,
  code: string,
  message: string,
  retryable: boolean,
  retry_after_seconds?: number,
): BrokerErrorDefinition {
  return {
    http_status,
    code,
    message,
    retryable,
    ...(retry_after_seconds === undefined ? {} : { retry_after_seconds }),
  };
}
