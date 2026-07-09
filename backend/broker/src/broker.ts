import { validateCanonicalPayloadV1 } from './canonical_payload.js';
import {
  CURRENT_CONSENT_COPY_VERSION,
  type BrokerContext,
  type BrokerFailure,
  type BrokerRequest,
  type BrokerResearchOutput,
  type BrokerResponse,
  type BrokerResult,
  type BrokerTerminalOutcome,
  type ProviderClient,
  type ProviderResearchResult,
} from './contracts.js';
import type { BrokerErrorCondition } from './error_contract.js';
import { FakeResearchProvider } from './fake_provider.js';
import {
  InMemoryRequestLifecycle,
  type RequestLifecycleStore,
  type SettlementIntent,
} from './request_lifecycle.js';
import { authorizeProviderRequest } from './provider_authorization.js';

export interface ProviderProvisioner {
  configure(): unknown | Promise<unknown>;
  construct(configuration: unknown): ProviderClient | Promise<ProviderClient>;
}

export interface BrokerDependencies {
  providerProvisioner: ProviderProvisioner;
  requestLifecycle: RequestLifecycleStore;
  authorizeProvider: (request: BrokerRequest) => void | Promise<void>;
  now: () => Date;
  orderTrace?: string[];
  testProvider?: ProviderClient;
}

export function createFakeBrokerDependencies(
  overrides: Partial<BrokerDependencies> & { provider?: ProviderClient } = {},
): BrokerDependencies {
  const provider = overrides.provider ?? overrides.testProvider ?? new FakeResearchProvider();
  return {
    providerProvisioner: {
      configure: () => ({ mode: 'fake' }),
      construct: () => provider,
    },
    requestLifecycle: new InMemoryRequestLifecycle(),
    authorizeProvider: authorizeProviderRequest,
    now: () => new Date(),
    testProvider: provider,
    ...overrides,
  };
}

export async function handleResearchRequest(
  request: BrokerRequest,
  context: BrokerContext,
  dependencies: BrokerDependencies = createFakeBrokerDependencies(),
): Promise<BrokerResult> {
  const trace = dependencies.orderTrace;

  trace?.push('auth_context');
  const authError = validateAuthContext(context);
  if (authError !== undefined) {
    return failure(authError, request.request_id);
  }

  trace?.push('consent');
  if (request.consent_status !== 'approved') {
    return failure('consent_required', request.request_id);
  }
  if (request.consent_copy_version !== CURRENT_CONSENT_COPY_VERSION) {
    return failure('stale_consent', request.request_id);
  }

  trace?.push('entitlement');
  if (!context.entitled) {
    return failure('not_entitled', request.request_id);
  }

  trace?.push('breaker');
  if (context.breaker_open) {
    return failure('broker_breaker_open', request.request_id);
  }

  trace?.push('canonical_payload');
  const canonicalError = validateCanonicalPayloadV1(request);
  if (canonicalError !== undefined) {
    return failure(canonicalError, request.request_id);
  }

  trace?.push('idempotency_replay');
  trace?.push('credit_reservation');
  let acquired;
  try {
    acquired = await dependencies.requestLifecycle.acquire({
      quota_subject: context.quota_subject,
      request_id: request.request_id,
      payload_hash: request.payload_hash,
      credit_cost: 1,
      now: dependencies.now(),
    });
  } catch {
    return failure('durable_store_failure', request.request_id);
  }

  switch (acquired.kind) {
    case 'replay':
      await settlePendingBestEffort(acquired.record, dependencies, trace);
      return replayedResult(acquired.outcome);
    case 'conflict':
      return failure('idempotency_conflict', request.request_id);
    case 'in_flight':
      return failure('quota_subject_in_flight', request.request_id);
    case 'outcome_unknown':
      return failure('dispatch_outcome_unknown', request.request_id);
    case 'credits_exhausted':
      return failure('credits_exhausted', request.request_id);
    case 'unsafe_record':
      return failure('malformed_durable_record', request.request_id);
    case 'reserved':
      break;
  }

  const record = acquired.record;
  let configuration: unknown;
  trace?.push('provider_config');
  try {
    configuration = await dependencies.providerProvisioner.configure();
  } catch {
    return terminalError(
      record,
      'provider_config_failure',
      'refund',
      dependencies,
      trace,
    );
  }

  let provider: ProviderClient;
  trace?.push('provider_construction');
  try {
    provider = await dependencies.providerProvisioner.construct(configuration);
  } catch {
    return terminalError(
      record,
      'provider_construction_failure',
      'refund',
      dependencies,
      trace,
    );
  }

  trace?.push('provider_authorization');
  try {
    await dependencies.authorizeProvider(request);
  } catch {
    return terminalError(
      record,
      'provider_authorization_failure',
      'refund',
      dependencies,
      trace,
    );
  }

  trace?.push('dispatch_persistence');
  let dispatchStarted;
  try {
    dispatchStarted = await dependencies.requestLifecycle.markDispatchStarted(
      record,
      dependencies.now(),
    );
  } catch {
    return terminalError(
      record,
      'dispatch_persistence_failure',
      'refund',
      dependencies,
      trace,
    );
  }
  if (dispatchStarted.kind === 'lease_expired') {
    await settlePendingBestEffort(dispatchStarted.record, dependencies, trace);
    return outcomeToResult(dispatchStarted.outcome);
  }

  trace?.push('provider_fetch');
  let providerResult: ProviderResearchResult;
  try {
    providerResult = await provider.research(request);
  } catch {
    providerResult = { kind: 'failure' };
  }

  return completeProviderResult(
    request,
    provider,
    providerResult,
    record,
    dependencies,
    trace,
  );
}

async function completeProviderResult(
  request: BrokerRequest,
  provider: ProviderClient,
  providerResult: ProviderResearchResult,
  record: Parameters<RequestLifecycleStore['markDispatchStarted']>[0],
  dependencies: BrokerDependencies,
  trace: string[] | undefined,
): Promise<BrokerResult> {
  switch (providerResult.kind) {
    case 'rate_limited':
      return terminalError(
        record,
        'provider_rate_limited',
        'refund',
        dependencies,
        trace,
        providerResult.retry_after_seconds,
      );
    case 'refusal':
      return terminalError(record, 'provider_refusal', 'finalize', dependencies, trace);
    case 'timeout':
      return terminalError(record, 'provider_timeout', 'refund', dependencies, trace);
    case 'failure':
      return terminalError(record, 'provider_failure', 'finalize', dependencies, trace);
    case 'invalid_output':
      return terminalError(record, 'provider_invalid_output', 'finalize', dependencies, trace);
    case 'success':
      break;
  }

  trace?.push('output_validation');
  if (validateOutput(providerResult.output) !== undefined) {
    return terminalError(record, 'provider_invalid_output', 'finalize', dependencies, trace);
  }

  const response: BrokerResponse = {
    request_id: request.request_id,
    status: 'completed',
    provider: provider.providerName,
    model: provider.modelName,
    reasoning_effort: provider.reasoningEffort,
    completed_at: dependencies.now().toISOString(),
    sources: providerResult.output.sources,
    candidate_attributions: providerResult.output.candidate_attributions,
    comparable_value_signals: providerResult.output.comparable_value_signals,
    warnings: providerResult.output.warnings,
  };
  return persistTerminalAndSettle(
    record,
    { kind: 'success', response },
    'finalize',
    dependencies,
    trace,
  );
}

async function terminalError(
  record: Parameters<RequestLifecycleStore['markDispatchStarted']>[0],
  condition: BrokerErrorCondition,
  settlement: SettlementIntent,
  dependencies: BrokerDependencies,
  trace: string[] | undefined,
  retryAfterSeconds?: number,
): Promise<BrokerResult> {
  const outcome: BrokerTerminalOutcome = {
    kind: 'error',
    failure: {
      request_id: record.request_id,
      condition,
      ...(retryAfterSeconds === undefined ? {} : { retry_after_seconds: retryAfterSeconds }),
    },
  };
  return persistTerminalAndSettle(record, outcome, settlement, dependencies, trace);
}

async function persistTerminalAndSettle(
  record: Parameters<RequestLifecycleStore['markDispatchStarted']>[0],
  outcome: BrokerTerminalOutcome,
  settlement: SettlementIntent,
  dependencies: BrokerDependencies,
  trace: string[] | undefined,
): Promise<BrokerResult> {
  trace?.push('terminal_persistence');
  try {
    await dependencies.requestLifecycle.persistTerminal(record, outcome, settlement);
  } catch {
    return failure('terminal_persistence_failure', record.request_id);
  }

  await settlePendingBestEffort(record, dependencies, trace);
  return outcomeToResult(outcome);
}

async function settlePendingBestEffort(
  record: Parameters<RequestLifecycleStore['markDispatchStarted']>[0],
  dependencies: BrokerDependencies,
  trace: string[] | undefined,
): Promise<void> {
  if (record.settlement_state !== 'pending_refund' && record.settlement_state !== 'pending_finalize') {
    return;
  }
  trace?.push(record.settlement_state === 'pending_refund' ? 'credit_refund' : 'credit_finalize');
  try {
    await dependencies.requestLifecycle.settle(record);
  } catch {
    trace?.push('settlement_pending');
  }
}

function replayedResult(outcome: BrokerTerminalOutcome): BrokerResult {
  if (outcome.kind === 'success') {
    return { ok: true, response: { ...outcome.response, replayed: true } };
  }
  return {
    ok: false,
    failure: { ...outcome.failure, replayed: true },
  };
}

function outcomeToResult(outcome: BrokerTerminalOutcome): BrokerResult {
  return outcome.kind === 'success'
    ? { ok: true, response: outcome.response }
    : { ok: false, failure: outcome.failure };
}

function failure(
  condition: BrokerErrorCondition,
  requestId?: string,
  retryAfterSeconds?: number,
): BrokerResult {
  const safeRequestId = requestId !== undefined && isUuid(requestId) ? requestId : undefined;
  const brokerFailure: BrokerFailure = {
    condition,
    ...(safeRequestId === undefined ? {} : { request_id: safeRequestId }),
    ...(retryAfterSeconds === undefined ? {} : { retry_after_seconds: retryAfterSeconds }),
  };
  return { ok: false, failure: brokerFailure };
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

function validateAuthContext(context: BrokerContext): BrokerErrorCondition | undefined {
  if (!context.app_check_verified || !context.auth_verified) {
    return 'invalid_auth_token';
  }
  if (
    context.auth_identity.uid.length === 0 ||
    context.auth_identity.project_id.length === 0 ||
    context.app_identity.app_id.length === 0 ||
    context.app_identity.project_id.length === 0
  ) {
    return 'invalid_auth_token';
  }
  if (context.auth_identity.project_id !== context.app_identity.project_id) {
    return 'identity_project_mismatch';
  }
  if (context.auth_identity.sign_in_provider !== 'anonymous') {
    return 'unsupported_auth_provider';
  }
  if (!/^quota_subject_v1_[a-f0-9]{16,}$/.test(context.quota_subject)) {
    return 'invalid_auth_token';
  }
  return undefined;
}

function validateOutput(output: BrokerResearchOutput): BrokerErrorCondition | undefined {
  const sourceIds = new Set(output.sources.map((source) => source.source_id));
  for (const source of output.sources) {
    if (!source.source_url.startsWith('https://')) {
      return 'provider_invalid_output';
    }
  }
  for (const candidate of output.candidate_attributions) {
    if (
      candidate.source_refs.length === 0 ||
      candidate.source_refs.some((sourceRef) => !sourceIds.has(sourceRef))
    ) {
      return 'provider_invalid_output';
    }
  }
  return undefined;
}
