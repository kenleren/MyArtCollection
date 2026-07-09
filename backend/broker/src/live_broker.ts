import { handleBrokerAdapterRequest, parseBrokerRequest } from './adapter.js';
import type { BrokerDependencies } from './broker.js';
import { CURRENT_CONSENT_COPY_VERSION } from './contracts.js';
import { authorizeProviderRequest } from './provider_authorization.js';
import {
  durableConfigFromEnv,
  MISSING_DURABLE_CONFIG_CODE,
  MISSING_QUOTA_SECRET_CODE,
  type DurableBrokerProtection,
} from './durable_protection.js';
import { brokerErrorEnvelope, type BrokerErrorCondition } from './error_contract.js';
import {
  createOpenAiProvider,
  readOpenAiProviderConfigFromEnv,
  type OpenAiProviderConfig,
} from './openai_provider.js';

export type MinimalRequest = AsyncIterable<Buffer | string> & {
  method?: string;
  headers: Record<string, string | string[] | undefined>;
  body?: unknown;
};

export type MinimalResponse = {
  status(code: number): MinimalResponse;
  setHeader(name: string, value: string): void;
  end(body: string): void;
};

export const BROKER_HTTP_ENABLED_ENV = 'BROKER_HTTP_ENABLED';
export const BROKER_PROVIDER_MODE_ENV = 'BROKER_PROVIDER_MODE';
export const BROKER_OPENAI_LIVE_TEST_ENABLED_ENV = 'BROKER_OPENAI_LIVE_TEST_ENABLED';
export const BROKER_OWNER_UID_ALLOWLIST_ENV = 'BROKER_OWNER_UID_ALLOWLIST';
export const DURABLE_PROTECTION_UNAVAILABLE_CODE = 'durable_protection_unavailable';

export interface ResearchBrokerHttpHandlerOptions {
  env?: NodeJS.ProcessEnv;
  dependenciesFactory?: (env: NodeJS.ProcessEnv) => ConfiguredBrokerDependenciesResult;
}

export type ConfiguredBrokerDependenciesResult =
  | {
      kind: 'ready';
      createDependencies: () => BrokerDependencies;
      ownerUidAllowlist: ReadonlySet<string>;
      durableProtection: true;
      protection: DurableBrokerProtection;
    }
  | { kind: 'disabled' }
  | { kind: 'misconfigured'; code: string };

export function isResearchBrokerLiveEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[BROKER_HTTP_ENABLED_ENV] === 'true' &&
    env[BROKER_PROVIDER_MODE_ENV] === 'openai' &&
    env[BROKER_OPENAI_LIVE_TEST_ENABLED_ENV] === 'true';
}

export function createConfiguredResearchBrokerDependencies(
  env: NodeJS.ProcessEnv = process.env,
  overrides: Partial<OpenAiProviderConfig> = {},
  configReader: (
    currentEnv: NodeJS.ProcessEnv,
    currentOverrides: Partial<OpenAiProviderConfig>,
  ) => ReturnType<typeof readOpenAiProviderConfigFromEnv> = readOpenAiProviderConfigFromEnv,
  protection?: DurableBrokerProtection,
): ConfiguredBrokerDependenciesResult {
  if (!isResearchBrokerLiveEnabled(env)) {
    return { kind: 'disabled' };
  }
  const ownerUidAllowlist = parseAllowlist(env[BROKER_OWNER_UID_ALLOWLIST_ENV]);
  if (ownerUidAllowlist.size === 0) {
    return { kind: 'misconfigured', code: 'missing_owner_uid_allowlist' };
  }
  const durableConfig = durableConfigFromEnv(env);
  if (!durableConfig.ok) {
    return { kind: 'misconfigured', code: durableConfig.code };
  }
  if (protection === undefined) {
    return { kind: 'misconfigured', code: DURABLE_PROTECTION_UNAVAILABLE_CODE };
  }

  return {
    kind: 'ready',
    ownerUidAllowlist,
    durableProtection: true,
    protection,
    createDependencies: () => ({
      requestLifecycle: protection.createRequestLifecycle(),
      providerProvisioner: {
        configure: () => {
          const result = configReader(env, overrides);
          if (!result.ok) {
            throw new BrokerProviderConfigError(result.code);
          }
          return result.config;
        },
        construct: (configuration) => createOpenAiProvider(configuration as OpenAiProviderConfig),
      },
      authorizeProvider: authorizeProviderRequest,
      now: () => new Date(),
    }),
  };
}

export function createResearchBrokerHttpHandler(options: ResearchBrokerHttpHandlerOptions = {}) {
  const env = options.env ?? process.env;
  const dependenciesFactory = options.dependenciesFactory ?? ((currentEnv) =>
    createConfiguredResearchBrokerDependencies(currentEnv));

  return async function researchBrokerHttpHandler(
    request: MinimalRequest,
    response: MinimalResponse,
  ): Promise<void> {
    setSecurityHeaders(response);
    if (request.method !== 'POST') {
      sendError(response, 'method_not_allowed');
      return;
    }
    if (!isJsonContentType(header(request, 'content-type'))) {
      sendError(response, 'unsupported_media_type');
      return;
    }
    if (!isResearchBrokerLiveEnabled(env)) {
      sendError(response, 'broker_disabled');
      return;
    }

    let configured: ConfiguredBrokerDependenciesResult;
    try {
      configured = dependenciesFactory(env);
    } catch {
      sendError(response, 'broker_misconfigured');
      return;
    }
    if (configured.kind !== 'ready' || configured.durableProtection !== true) {
      sendError(response, 'broker_misconfigured');
      return;
    }

    let parsedBody: Awaited<ReturnType<typeof readJsonBody>>;
    try {
      parsedBody = await readJsonBody(request);
    } catch {
      sendError(response, 'invalid_json');
      return;
    }
    if (!parsedBody.ok) {
      sendError(response, 'invalid_json');
      return;
    }

    let identityResult: Awaited<ReturnType<DurableBrokerProtection['verifyIdentity']>>;
    try {
      identityResult = await configured.protection.verifyIdentity({
        authorizationHeader: header(request, 'authorization'),
        appCheckToken: header(request, 'x-firebase-appcheck'),
      });
    } catch {
      sendError(response, 'broker_misconfigured');
      return;
    }
    if (!identityResult.ok) {
      const condition: BrokerErrorCondition =
        identityResult.code === MISSING_DURABLE_CONFIG_CODE ||
        identityResult.code === MISSING_QUOTA_SECRET_CODE
          ? 'broker_misconfigured'
          : identityResult.code;
      sendError(
        response,
        condition,
      );
      return;
    }
    if (!configured.ownerUidAllowlist.has(identityResult.identity.auth.uid ?? '')) {
      sendError(response, 'forbidden_uid');
      return;
    }

    const brokerRequest = parseBrokerRequest(unwrapCallableData(parsedBody.value));
    if (!brokerRequest.ok) {
      sendError(response, brokerRequest.condition, brokerRequest.requestId);
      return;
    }
    if (brokerRequest.request.consent_status !== 'approved') {
      sendError(response, 'consent_required', brokerRequest.request.request_id);
      return;
    }
    if (brokerRequest.request.consent_copy_version !== CURRENT_CONSENT_COPY_VERSION) {
      sendError(response, 'stale_consent', brokerRequest.request.request_id);
      return;
    }

    let access: Awaited<ReturnType<DurableBrokerProtection['readAccess']>>;
    try {
      access = await configured.protection.readAccess(identityResult.identity);
    } catch {
      sendError(response, 'broker_misconfigured', brokerRequest.request.request_id);
      return;
    }
    const brokerIdentity = {
      ...identityResult.identity,
      entitled: access.entitled,
      breakerOpen: access.breakerOpen,
    };

    let dependencies: BrokerDependencies;
    try {
      dependencies = configured.createDependencies();
    } catch {
      sendError(response, 'broker_misconfigured');
      return;
    }
    const envelope = await handleBrokerAdapterRequest(
      brokerRequest.request,
      brokerIdentity,
      dependencies,
    );
    if (!envelope.ok && envelope.body.error.retry_after_seconds !== undefined) {
      response.setHeader('Retry-After', String(envelope.body.error.retry_after_seconds));
    }
    sendJson(response, envelope.status, envelope.body);
  };
}

async function readJsonBody(
  request: MinimalRequest,
): Promise<{ ok: true; value: unknown } | { ok: false }> {
  if (request.body !== undefined) {
    return parseBodyValue(request.body);
  }
  let raw = '';
  for await (const chunk of request) {
    raw += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    if (Buffer.byteLength(raw, 'utf8') > 2_100_000) {
      return { ok: false };
    }
  }
  return parseBodyValue(raw);
}

function parseBodyValue(value: unknown): { ok: true; value: unknown } | { ok: false } {
  if (Buffer.isBuffer(value)) {
    return parseBodyValue(value.toString('utf8'));
  }
  if (typeof value !== 'string') {
    return { ok: true, value };
  }
  try {
    return { ok: true, value: JSON.parse(value) as unknown };
  } catch {
    return { ok: false };
  }
}

function unwrapCallableData(body: unknown): unknown {
  if (!isRecord(body)) {
    return body;
  }
  const keys = Object.keys(body);
  return keys.length === 1 && keys[0] === 'data' ? body.data : body;
}

function sendError(
  response: MinimalResponse,
  condition: BrokerErrorCondition,
  requestId?: string,
): void {
  const envelope = brokerErrorEnvelope(condition, requestId);
  if (envelope.body.error.retry_after_seconds !== undefined) {
    response.setHeader('Retry-After', String(envelope.body.error.retry_after_seconds));
  }
  sendJson(response, envelope.status, envelope.body);
}

function sendJson(response: MinimalResponse, status: number, body: unknown): void {
  response.status(status);
  response.end(JSON.stringify(body));
}

function setSecurityHeaders(response: MinimalResponse): void {
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Cache-Control', 'no-store');
}

function header(source: MinimalRequest, name: string): string | undefined {
  const raw = source.headers[name];
  return Array.isArray(raw) ? raw[0] : raw;
}

function isJsonContentType(value: string | undefined): boolean {
  return value !== undefined && value.toLowerCase().includes('application/json');
}

function parseAllowlist(value: string | undefined): Set<string> {
  return new Set(
    (value ?? '').split(',').map((entry) => entry.trim()).filter((entry) => entry.length > 0),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

class BrokerProviderConfigError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
