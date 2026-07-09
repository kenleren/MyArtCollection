import type { BrokerContext, BrokerRequest, BrokerResponse } from './contracts.js';
import {
  type BrokerDependencies,
  createFakeBrokerDependencies,
  handleResearchRequest,
} from './broker.js';
import {
  brokerErrorEnvelope,
  type BrokerErrorCondition,
  type BrokerErrorEnvelope,
} from './error_contract.js';

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

export interface BrokerAdapterIdentity {
  auth: LocalBrokerAuthPlaceholder;
  app: LocalBrokerAppPlaceholder;
  quotaSubject?: string;
  entitled: boolean;
  breakerOpen: boolean;
}

export interface BrokerAdapterSuccessEnvelope {
  ok: true;
  status: 200;
  body: BrokerResponse;
}

export interface BrokerAdapterErrorEnvelope {
  ok: false;
  status: number;
  body: BrokerErrorEnvelope;
}

export type BrokerAdapterEnvelope = BrokerAdapterSuccessEnvelope | BrokerAdapterErrorEnvelope;
export type FakeBrokerAdapterIdentity = BrokerAdapterIdentity;
export type FakeBrokerAdapterEnvelope = BrokerAdapterEnvelope;

export async function handleBrokerAdapterRequest(
  jsonRequest: unknown,
  identity: BrokerAdapterIdentity,
  dependencies: BrokerDependencies = createFakeBrokerDependencies(),
): Promise<BrokerAdapterEnvelope> {
  const identityError = validateLocalIdentity(identity);
  if (identityError !== undefined) {
    return adapterError(identityError);
  }

  const parsed = parseBrokerRequest(jsonRequest);
  if (!parsed.ok) {
    return adapterError(parsed.condition, parsed.requestId);
  }

  const result = await handleResearchRequest(
    parsed.request,
    contextFromIdentity(identity),
    dependencies,
  );
  if (!result.ok) {
    return adapterError(
      result.failure.condition,
      result.failure.request_id,
      result.failure.retry_after_seconds,
    );
  }
  return { ok: true, status: 200, body: result.response };
}

export async function handleFakeBrokerAdapterRequest(
  jsonRequest: unknown,
  identity: FakeBrokerAdapterIdentity,
  dependencies: BrokerDependencies = createFakeBrokerDependencies(),
): Promise<FakeBrokerAdapterEnvelope> {
  return handleBrokerAdapterRequest(jsonRequest, identity, dependencies);
}

export type RequestParseResult =
  | { ok: true; request: BrokerRequest }
  | { ok: false; condition: 'invalid_request_payload'; requestId?: string };

export function parseBrokerRequest(value: unknown): RequestParseResult {
  if (!isRecord(value) || !hasOnlyAllowedKeys(value, ALLOWED_TOP_LEVEL_FIELDS)) {
    return { ok: false, condition: 'invalid_request_payload' };
  }

  const rawRequestId = stringValue(value.request_id);
  const requestId = rawRequestId !== undefined && isUuid(rawRequestId) ? rawRequestId : undefined;
  const image = value.image;
  if (
    rawRequestId === undefined ||
    requestId === undefined ||
    !isConsentStatus(value.consent_status) ||
    !isConsentScope(value.consent_scope) ||
    stringValue(value.consent_copy_version) === undefined ||
    stringValue(value.payload_contract_version) === undefined ||
    stringValue(value.payload_hash) === undefined ||
    stringValue(value.approved_payload_class) === undefined ||
    !isRecord(image) ||
    !hasOnlyAllowedKeys(image, ALLOWED_IMAGE_FIELDS) ||
    stringValue(image.mime_type) === undefined ||
    numberValue(image.byte_size) === undefined ||
    numberValue(image.long_edge_px) === undefined ||
    stringValue(image.content_base64) === undefined ||
    !validDraftHintsShape(value.draft_hints)
  ) {
    return {
      ok: false,
      condition: 'invalid_request_payload',
      ...(requestId === undefined ? {} : { requestId }),
    };
  }
  return { ok: true, request: value as unknown as BrokerRequest };
}

function adapterError(
  condition: BrokerErrorCondition,
  requestId?: string,
  retryAfterSeconds?: number,
): BrokerAdapterErrorEnvelope {
  const envelope = brokerErrorEnvelope(condition, requestId, retryAfterSeconds);
  return { ok: false, status: envelope.status, body: envelope.body };
}

function validateLocalIdentity(identity: BrokerAdapterIdentity): BrokerErrorCondition | undefined {
  if (!identity.auth.appCheckVerified || !identity.auth.authVerified) {
    return 'invalid_auth_token';
  }
  if (
    empty(identity.auth.uid) ||
    empty(identity.auth.authProjectId) ||
    empty(identity.app.appId) ||
    empty(identity.app.appProjectId) ||
    empty(identity.quotaSubject)
  ) {
    return 'invalid_auth_token';
  }
  if (identity.auth.authProjectId !== identity.app.appProjectId) {
    return 'identity_project_mismatch';
  }
  if (identity.auth.signInProvider !== 'anonymous') {
    return 'unsupported_auth_provider';
  }
  return undefined;
}

function contextFromIdentity(identity: BrokerAdapterIdentity): BrokerContext {
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
    breaker_open: identity.breakerOpen,
  };
}

function validDraftHintsShape(value: unknown): boolean {
  if (value === undefined) {
    return true;
  }
  if (!isRecord(value) || !hasOnlyAllowedKeys(value, ALLOWED_DRAFT_HINT_FIELDS)) {
    return false;
  }
  if (value.title_hint !== undefined && stringValue(value.title_hint) === undefined) {
    return false;
  }
  if (value.artist_hint !== undefined && stringValue(value.artist_hint) === undefined) {
    return false;
  }
  return value.search_terms === undefined ||
    (Array.isArray(value.search_terms) && value.search_terms.every((term) => stringValue(term) !== undefined));
}

function isConsentStatus(value: unknown): boolean {
  return value === 'approved' || value === 'declined' || value === 'missing';
}

function isConsentScope(value: unknown): boolean {
  return value === 'image_only' || value === 'image_plus_draft_hints';
}

const ALLOWED_TOP_LEVEL_FIELDS = new Set([
  'request_id',
  'consent_status',
  'consent_scope',
  'consent_copy_version',
  'payload_contract_version',
  'payload_hash',
  'approved_payload_class',
  'image',
  'draft_hints',
]);
const ALLOWED_IMAGE_FIELDS = new Set(['mime_type', 'byte_size', 'long_edge_px', 'content_base64']);
const ALLOWED_DRAFT_HINT_FIELDS = new Set(['title_hint', 'artist_hint', 'search_terms']);

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

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

function hasOnlyAllowedKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}
