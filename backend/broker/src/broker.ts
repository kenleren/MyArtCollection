import {
  APPROVED_PAYLOAD_CLASS,
  CURRENT_CONSENT_COPY_VERSION,
  CURRENT_PAYLOAD_CONTRACT_VERSION,
  type BrokerContext,
  type BrokerRequest,
  type BrokerResearchOutput,
  type BrokerResponse,
  type ProviderClient,
} from './contracts.js';
import { PlaceholderCreditLedger } from './credit_ledger.js';
import { FakeResearchProvider } from './fake_provider.js';
import { InMemoryIdempotencyStore } from './idempotency.js';

export interface BrokerDependencies {
  provider: ProviderClient;
  idempotency: InMemoryIdempotencyStore;
  creditLedger: PlaceholderCreditLedger;
  now: () => Date;
  orderTrace?: string[];
}

export function createFakeBrokerDependencies(
  overrides: Partial<BrokerDependencies> = {},
): BrokerDependencies {
  return {
    provider: new FakeResearchProvider(),
    idempotency: new InMemoryIdempotencyStore(),
    creditLedger: new PlaceholderCreditLedger(),
    now: () => new Date(),
    ...overrides,
  };
}

export async function handleResearchRequest(
  request: BrokerRequest,
  context: BrokerContext,
  dependencies: BrokerDependencies = createFakeBrokerDependencies(),
): Promise<BrokerResponse> {
  const trace = dependencies.orderTrace;
  const creditCost = 1;
  const fail = (code: string, message: string, stage: string): BrokerResponse => ({
    request_id: request.request_id,
    status: code === 'idempotency_conflict' ? 'conflict' : 'rejected',
    provider: 'fake-provider',
    model: 'fake-local-model',
    reasoning_effort: 'none',
    sources: [],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
    error: { code, message, stage },
  });

  trace?.push('auth');
  const authError = validateAuthAndQuotaSubject(context);
  if (authError !== undefined) {
    return fail(authError.code, authError.message, 'auth');
  }
  if (!context.app_check_verified || !context.auth_verified) {
    return fail('unauthorized', 'Broker auth placeholders failed closed.', 'auth');
  }

  trace?.push('consent');
  if (request.consent_status !== 'approved') {
    return fail('consent_required', 'Approved research consent is required.', 'consent');
  }
  if (request.consent_copy_version !== CURRENT_CONSENT_COPY_VERSION) {
    return fail('stale_consent', 'Consent copy version is not current.', 'consent');
  }

  trace?.push('payload_receipt');
  const receiptError = validatePayloadReceipt(request);
  if (receiptError !== undefined) {
    return fail(receiptError.code, receiptError.message, 'payload_receipt');
  }

  trace?.push('entitlement');
  if (!context.entitled || !context.credit_available) {
    return fail('entitlement_or_credit_denied', 'Entitlement or credit placeholder denied the request.', 'entitlement');
  }

  trace?.push('breaker');
  if (context.breaker_open) {
    return fail('broker_breaker_open', 'Broker breaker is open.', 'breaker');
  }

  trace?.push('payload');
  const payloadError = validatePayload(request);
  if (payloadError !== undefined) {
    return fail(payloadError.code, payloadError.message, 'payload');
  }

  trace?.push('idempotency');
  const existing = dependencies.idempotency.get(context.quota_subject, request.request_id);
  if (existing !== undefined) {
    if (existing.payloadHash !== request.payload_hash) {
      return fail(
        'idempotency_conflict',
        'The request id already exists with a different payload hash.',
        'idempotency',
      );
    }
    if (existing.response !== undefined) {
      return { ...existing.response, replayed: true };
    }
    if (existing.inFlight !== undefined) {
      const response = await existing.inFlight;
      return { ...response, replayed: true };
    }
  }

  const idempotencyEntry = dependencies.idempotency.begin(
    context.quota_subject,
    request.request_id,
    request.payload_hash,
  );
  const inFlight = runReservedProviderRequest(
    request,
    context.quota_subject,
    dependencies,
    fail,
    trace,
    creditCost,
  );
  dependencies.idempotency.setInFlight(idempotencyEntry, inFlight);

  try {
    const response = await inFlight;
    dependencies.idempotency.complete(idempotencyEntry, response);
    return response;
  } catch (error) {
    dependencies.idempotency.forget(context.quota_subject, request.request_id);
    throw error;
  }
}

async function runReservedProviderRequest(
  request: BrokerRequest,
  quotaSubject: string,
  dependencies: BrokerDependencies,
  fail: (code: string, message: string, stage: string) => BrokerResponse,
  trace: string[] | undefined,
  creditCost: number,
): Promise<BrokerResponse> {
  trace?.push('credit_reserve');
  const reservation = dependencies.creditLedger.reserve({
    requestId: request.request_id,
    quotaSubject,
    creditCost,
  });
  if (!reservation.ok) {
    return fail(
      reservation.code ?? 'quota_denied',
      reservation.message ?? 'Quota placeholder denied the request.',
      'credit_reserve',
    );
  }

  const record = reservation.record;
  trace?.push('provider');
  let providerOutput: BrokerResearchOutput;
  try {
    providerOutput = await dependencies.provider.research(request);
  } catch {
    dependencies.creditLedger.refund(record, 'provider_exception');
    return fail('provider_failure', 'Fake provider failed before output validation.', 'provider');
  }

  trace?.push('output_validation');
  const outputError = validateOutput(providerOutput);
  if (outputError !== undefined) {
    dependencies.creditLedger.finalize(record);
    return fail(outputError.code, outputError.message, 'output_validation');
  }

  trace?.push('credit_finalize');
  dependencies.creditLedger.finalize(record);

  const response: BrokerResponse = {
    request_id: request.request_id,
    status: 'completed',
    provider: 'fake-provider',
    model: 'fake-local-model',
    reasoning_effort: 'none',
    completed_at: dependencies.now().toISOString(),
    sources: providerOutput.sources,
    candidate_attributions: providerOutput.candidate_attributions,
    comparable_value_signals: providerOutput.comparable_value_signals,
    warnings: providerOutput.warnings,
  };
  return response;
}

function validatePayload(request: BrokerRequest): { code: string; message: string } | undefined {
  if (request.image.mime_type !== 'image/jpeg' && request.image.mime_type !== 'image/webp') {
    return { code: 'unsupported_image_mime_type', message: 'Image derivative MIME type is not allowed.' };
  }
  if (request.image.byte_size <= 0 || request.image.byte_size > 1_500_000) {
    return { code: 'invalid_image_size', message: 'Image derivative size is outside the v1 bounds.' };
  }
  if (request.image.long_edge_px <= 0 || request.image.long_edge_px > 1600) {
    return { code: 'invalid_image_dimensions', message: 'Image derivative dimensions are outside the v1 bounds.' };
  }
  return undefined;
}

function validateAuthAndQuotaSubject(context: BrokerContext): { code: string; message: string } | undefined {
  if (
    context.auth_identity.uid.length === 0 ||
    context.auth_identity.project_id.length === 0 ||
    context.app_identity.app_id.length === 0 ||
    context.app_identity.project_id.length === 0
  ) {
    return { code: 'missing_auth_subject', message: 'Broker auth and app identity placeholders are required.' };
  }
  if (context.auth_identity.project_id !== context.app_identity.project_id) {
    return { code: 'identity_project_mismatch', message: 'Broker auth and app identity placeholders must share a project.' };
  }
  if (context.auth_identity.sign_in_provider !== 'anonymous') {
    return { code: 'unsupported_auth_provider', message: 'Only anonymous auth placeholder is allowed locally.' };
  }
  if (context.quota_subject.length === 0 || !/^quota_subject_v1_[a-f0-9]{16,}$/.test(context.quota_subject)) {
    return { code: 'invalid_quota_subject', message: 'A derived quota subject placeholder is required.' };
  }
  return undefined;
}

function validatePayloadReceipt(request: BrokerRequest): { code: string; message: string } | undefined {
  if (!isUuid(request.request_id)) {
    return { code: 'invalid_request_id', message: 'request_id must be a UUID.' };
  }
  if (request.payload_contract_version !== CURRENT_PAYLOAD_CONTRACT_VERSION) {
    return { code: 'payload_contract_mismatch', message: 'Payload contract version is not current.' };
  }
  if (request.approved_payload_class !== APPROVED_PAYLOAD_CLASS) {
    return { code: 'payload_class_mismatch', message: 'Payload class is not approved.' };
  }
  if (!/^[a-f0-9]{64}$/.test(request.payload_hash)) {
    return { code: 'invalid_payload_hash', message: 'payload_hash must be a lowercase SHA-256 hex digest.' };
  }
  return undefined;
}

function validateOutput(output: BrokerResearchOutput): { code: string; message: string } | undefined {
  const sourceIds = new Set(output.sources.map((source) => source.source_id));
  for (const source of output.sources) {
    if (!source.source_url.startsWith('https://')) {
      return { code: 'invalid_source_url', message: 'Output source URL must be HTTPS.' };
    }
  }
  for (const candidate of output.candidate_attributions) {
    if (candidate.source_refs.length === 0) {
      return { code: 'candidate_missing_source', message: 'Every candidate requires at least one source ref.' };
    }
    if (candidate.source_refs.some((sourceRef) => !sourceIds.has(sourceRef))) {
      return { code: 'candidate_unknown_source', message: 'Candidate source ref does not match a source.' };
    }
  }
  return undefined;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}
