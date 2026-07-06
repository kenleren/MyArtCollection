import {
  type BrokerContext,
  type BrokerRequest,
  type BrokerResponse,
} from './contracts.js';
import {
  type BrokerDependencies,
  createFakeBrokerDependencies,
  handleResearchRequest,
} from './broker.js';

export interface LocalBrokerAuthPlaceholder {
  appCheckVerified: boolean;
  authVerified: boolean;
  uid?: string;
  authProjectId?: string;
  signInProvider?: 'anonymous' | string;
}

export interface LocalBrokerAppPlaceholder {
  appId?: string;
  appProjectId?: string;
}

export interface FakeBrokerAdapterIdentity {
  auth: LocalBrokerAuthPlaceholder;
  app: LocalBrokerAppPlaceholder;
  quotaSubject?: string;
  entitled: boolean;
  creditAvailable: boolean;
  breakerOpen: boolean;
}

export interface FakeBrokerAdapterSuccessEnvelope {
  ok: true;
  status: 200;
  body: BrokerResponse;
}

export interface FakeBrokerAdapterErrorEnvelope {
  ok: false;
  status: number;
  body: {
    request_id?: string;
    status: 'rejected' | 'conflict';
    provider: 'fake-provider';
    error: {
      code: string;
      message: string;
      stage: string;
    };
  };
}

export type FakeBrokerAdapterEnvelope =
  | FakeBrokerAdapterSuccessEnvelope
  | FakeBrokerAdapterErrorEnvelope;

export async function handleFakeBrokerAdapterRequest(
  jsonRequest: unknown,
  identity: FakeBrokerAdapterIdentity,
  dependencies: BrokerDependencies = createFakeBrokerDependencies(),
): Promise<FakeBrokerAdapterEnvelope> {
  const authError = validateLocalIdentity(identity);
  if (authError !== undefined) {
    return errorEnvelope(authError.code, authError.stage, undefined);
  }

  const requestParse = parseBrokerRequest(jsonRequest);
  if (!requestParse.ok) {
    return errorEnvelope(requestParse.code, requestParse.stage, requestParse.requestId);
  }

  const response = await handleResearchRequest(
    requestParse.request,
    contextFromIdentity(identity),
    dependencies,
  );

  if (response.error !== undefined) {
    return errorEnvelope(response.error.code, response.error.stage, response.request_id);
  }

  return {
    ok: true,
    status: 200,
    body: response,
  };
}

function validateLocalIdentity(
  identity: FakeBrokerAdapterIdentity,
): { code: string; stage: string } | undefined {
  if (!identity.auth.appCheckVerified || !identity.auth.authVerified) {
    return { code: 'unauthorized', stage: 'auth' };
  }
  if (
    empty(identity.auth.uid) ||
    empty(identity.auth.authProjectId) ||
    empty(identity.app.appId) ||
    empty(identity.app.appProjectId)
  ) {
    return { code: 'missing_auth_subject', stage: 'auth' };
  }
  if (identity.auth.authProjectId !== identity.app.appProjectId) {
    return { code: 'identity_project_mismatch', stage: 'auth' };
  }
  if (identity.auth.signInProvider !== 'anonymous') {
    return { code: 'unsupported_auth_provider', stage: 'auth' };
  }
  if (empty(identity.quotaSubject)) {
    return { code: 'invalid_quota_subject', stage: 'auth' };
  }
  return undefined;
}

function contextFromIdentity(identity: FakeBrokerAdapterIdentity): BrokerContext {
  return {
    app_check_verified: identity.auth.appCheckVerified,
    auth_verified: identity.auth.authVerified,
    auth_identity: {
      uid: identity.auth.uid ?? '',
      project_id: identity.auth.authProjectId ?? '',
      sign_in_provider: 'anonymous',
    },
    app_identity: {
      app_id: identity.app.appId ?? '',
      project_id: identity.app.appProjectId ?? '',
    },
    quota_subject: identity.quotaSubject ?? '',
    entitled: identity.entitled,
    credit_available: identity.creditAvailable,
    breaker_open: identity.breakerOpen,
  };
}

type RequestParseResult =
  | { ok: true; request: BrokerRequest }
  | { ok: false; code: string; stage: string; requestId?: string };

function parseBrokerRequest(value: unknown): RequestParseResult {
  if (!isRecord(value)) {
    return { ok: false, code: 'invalid_request_payload', stage: 'adapter' };
  }

  const requestId = stringValue(value.request_id);
  const image = value.image;
  if (
    requestId === undefined ||
    stringValue(value.consent_status) === undefined ||
    stringValue(value.consent_scope) === undefined ||
    stringValue(value.consent_copy_version) === undefined ||
    stringValue(value.payload_contract_version) === undefined ||
    stringValue(value.payload_hash) === undefined ||
    stringValue(value.approved_payload_class) === undefined ||
    !isRecord(image) ||
    stringValue(image.mime_type) === undefined ||
    numberValue(image.byte_size) === undefined ||
    numberValue(image.long_edge_px) === undefined ||
    !validDraftHintsShape(value.draft_hints)
  ) {
    return {
      ok: false,
      code: 'invalid_request_payload',
      stage: 'adapter',
      requestId,
    };
  }

  return {
    ok: true,
    request: value as unknown as BrokerRequest,
  };
}

function validDraftHintsShape(value: unknown): boolean {
  if (value === undefined) {
    return true;
  }
  if (!isRecord(value)) {
    return false;
  }
  if (value.title_hint !== undefined && stringValue(value.title_hint) === undefined) {
    return false;
  }
  if (value.artist_hint !== undefined && stringValue(value.artist_hint) === undefined) {
    return false;
  }
  if (value.search_terms !== undefined) {
    return Array.isArray(value.search_terms) &&
      value.search_terms.every((term) => stringValue(term) !== undefined);
  }
  return true;
}

function errorEnvelope(
  code: string,
  stage: string,
  requestId: string | undefined,
): FakeBrokerAdapterErrorEnvelope {
  return {
    ok: false,
    status: statusForErrorCode(code),
    body: {
      ...(requestId === undefined ? {} : { request_id: requestId }),
      status: code === 'idempotency_conflict' ? 'conflict' : 'rejected',
      provider: 'fake-provider',
      error: {
        code,
        message: safeMessageForErrorCode(code),
        stage,
      },
    },
  };
}

function statusForErrorCode(code: string): number {
  switch (code) {
    case 'unauthorized':
    case 'missing_auth_subject':
    case 'invalid_quota_subject':
      return 401;
    case 'identity_project_mismatch':
    case 'unsupported_auth_provider':
    case 'consent_required':
    case 'stale_consent':
    case 'entitlement_or_credit_denied':
      return 403;
    case 'idempotency_conflict':
      return 409;
    case 'quota_subject_monthly_cap_exceeded':
    case 'broker_monthly_cap_exceeded':
      return 429;
    case 'broker_breaker_open':
      return 503;
    case 'provider_failure':
    case 'invalid_source_url':
    case 'candidate_missing_source':
    case 'candidate_unknown_source':
      return 502;
    default:
      return 400;
  }
}

function safeMessageForErrorCode(code: string): string {
  switch (code) {
    case 'unauthorized':
    case 'missing_auth_subject':
    case 'invalid_quota_subject':
    case 'identity_project_mismatch':
    case 'unsupported_auth_provider':
      return 'Broker auth placeholders failed closed.';
    case 'consent_required':
      return 'Approved research consent is required.';
    case 'stale_consent':
      return 'Research consent must be refreshed.';
    case 'invalid_request_payload':
      return 'Broker request payload is invalid.';
    case 'invalid_request_id':
      return 'Broker request id is invalid.';
    case 'payload_contract_mismatch':
      return 'Broker payload contract is not current.';
    case 'payload_class_mismatch':
      return 'Broker payload class is not allowed.';
    case 'invalid_payload_hash':
      return 'Broker payload hash is invalid.';
    case 'unsupported_image_mime_type':
      return 'Image derivative MIME type is not allowed.';
    case 'invalid_image_size':
      return 'Image derivative size is outside allowed bounds.';
    case 'invalid_image_dimensions':
      return 'Image derivative dimensions are outside allowed bounds.';
    case 'entitlement_or_credit_denied':
      return 'Broker entitlement or credit placeholder denied the request.';
    case 'broker_breaker_open':
      return 'Broker breaker is open.';
    case 'idempotency_conflict':
      return 'Broker request id conflicts with a prior payload.';
    case 'quota_subject_monthly_cap_exceeded':
    case 'broker_monthly_cap_exceeded':
      return 'Broker quota placeholder denied the request.';
    case 'provider_failure':
    case 'invalid_source_url':
    case 'candidate_missing_source':
    case 'candidate_unknown_source':
      return 'Fake provider output failed broker validation.';
    default:
      return 'Broker request was rejected.';
  }
}

function empty(value: string | undefined): boolean {
  return value === undefined || value.length === 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}
