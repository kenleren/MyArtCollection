import {
  createOpenAiProvider,
  readOpenAiProviderConfigFromEnv,
  type OpenAiProviderConfig,
} from './openai_provider.js';
import type { BrokerDependencies } from './broker.js';
import { createFakeBrokerDependencies } from './broker.js';
import {
  handleBrokerAdapterRequest,
} from './adapter.js';
import {
  durableConfigFromEnv,
  MISSING_DURABLE_CONFIG_CODE,
  type DurableBrokerProtection,
} from './durable_protection.js';

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
  dependenciesFactory?: (
    env: NodeJS.ProcessEnv,
  ) => ConfiguredBrokerDependenciesResult;
}

export type ConfiguredBrokerDependenciesResult =
  | {
      kind: 'ready';
      createDependencies: () => BrokerDependencies;
      ownerUidAllowlist: ReadonlySet<string>;
      durableProtection: true;
      protection: DurableBrokerProtection;
    }
  | {
      kind: 'disabled';
    }
  | {
      kind: 'misconfigured';
      code: string;
    };

export function isResearchBrokerLiveEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return (
    env[BROKER_HTTP_ENABLED_ENV] === 'true' &&
    env[BROKER_PROVIDER_MODE_ENV] === 'openai' &&
    env[BROKER_OPENAI_LIVE_TEST_ENABLED_ENV] === 'true'
  );
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
    createDependencies: () => {
      const providerConfig = configReader(env, overrides);
      if (!providerConfig.ok) {
        throw new BrokerProviderConfigError(providerConfig.code);
      }

      return createFakeBrokerDependencies({
        provider: createOpenAiProvider(providerConfig.config),
        idempotency: protection.createIdempotencyStore(),
        creditLedger: protection.createCreditLedger(),
      });
    },
  };
}

export function createResearchBrokerHttpHandler(
  options: ResearchBrokerHttpHandlerOptions = {},
) {
  const env = options.env ?? process.env;
  const dependenciesFactory = options.dependenciesFactory ?? ((currentEnv) =>
    createConfiguredResearchBrokerDependencies(currentEnv));

  return async function researchBrokerHttpHandler(
    request: MinimalRequest,
    response: MinimalResponse,
  ): Promise<void> {
    setSecurityHeaders(response);

    if (request.method !== 'POST') {
      sendJson(response, 405, { ok: false, error: 'method_not_allowed' });
      return;
    }

    if (!isJsonContentType(header(request, 'content-type'))) {
      sendJson(response, 415, { ok: false, error: 'unsupported_media_type' });
      return;
    }

    if (!isResearchBrokerLiveEnabled(env)) {
      sendJson(response, 503, { ok: false, error: 'research_broker_disabled' });
      return;
    }

    const configured = dependenciesFactory(env);
    if (configured.kind === 'disabled') {
      sendJson(response, 503, { ok: false, error: 'research_broker_disabled' });
      return;
    }
    if (configured.kind === 'misconfigured') {
      sendJson(response, 503, { ok: false, error: 'research_broker_disabled' });
      return;
    }
    if (configured.durableProtection !== true) {
      sendJson(response, 503, { ok: false, error: 'research_broker_disabled' });
      return;
    }

    const identityResult = await configured.protection.verifyAndBuildIdentity({
      authorizationHeader: header(request.headers, 'authorization'),
      appCheckToken: header(request.headers, 'x-firebase-appcheck'),
    });
    if (!identityResult.ok) {
      sendJson(response, statusForLiveGateError(identityResult.code), {
        ok: false,
        error: safeLiveGateError(identityResult.code),
      });
      return;
    }

    const identity = identityResult.identity;
    if (!configured.ownerUidAllowlist.has(identity.auth.uid ?? '')) {
      sendJson(response, 403, { ok: false, error: 'forbidden' });
      return;
    }
    if (!identity.entitled || !identity.creditAvailable) {
      sendJson(response, 403, { ok: false, error: 'entitlement_or_credit_denied' });
      return;
    }
    if (identity.breakerOpen) {
      sendJson(response, 503, { ok: false, error: 'broker_breaker_open' });
      return;
    }

    const requestBody = unwrapCallableData(await readJsonBody(request));
    let dependencies: BrokerDependencies;
    try {
      dependencies = configured.createDependencies();
    } catch (error) {
      if (error instanceof BrokerProviderConfigError) {
        sendJson(response, 503, { ok: false, error: 'research_broker_disabled' });
        return;
      }
      throw error;
    }
    const envelope = await handleBrokerAdapterRequest(
      requestBody,
      identity,
      dependencies,
    );
    sendJson(response, envelope.status, envelope.ok ? envelope.body : envelope.body);
  };
}

async function readJsonBody(request: MinimalRequest): Promise<unknown> {
  if (request.body !== undefined) {
    return parseBodyValue(request.body);
  }

  let raw = '';
  for await (const chunk of request) {
    raw += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
  }
  return parseBodyValue(raw);
}

function parseBodyValue(value: unknown): unknown {
  if (Buffer.isBuffer(value)) {
    return parseBodyValue(value.toString('utf8'));
  }
  if (typeof value === 'string') {
    try {
      return JSON.parse(value);
    } catch {
      return undefined;
    }
  }
  return value;
}

function unwrapCallableData(body: unknown): unknown {
  if (!isRecord(body)) {
    return body;
  }

  const keys = Object.keys(body);
  if (keys.length === 1 && keys[0] === 'data') {
    return body.data;
  }
  return body;
}

function parseAllowlist(value: string | undefined): Set<string> {
  if (value === undefined) {
    return new Set();
  }

  return new Set(
    value
      .split(',')
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0),
  );
}

function header(
  source: MinimalRequest | Record<string, string | string[] | undefined>,
  name: string,
): string | undefined {
  const headers = hasHeaders(source) ? source.headers : source;
  const raw = headers[name];
  if (Array.isArray(raw)) {
    return raw[0];
  }
  return raw;
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

function isJsonContentType(value: string | undefined): boolean {
  return value !== undefined && value.toLowerCase().includes('application/json');
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function statusForLiveGateError(code: string): number {
  switch (code) {
    case MISSING_DURABLE_CONFIG_CODE:
    case DURABLE_PROTECTION_UNAVAILABLE_CODE:
      return 503;
    case 'missing_auth_token':
    case 'invalid_auth_token':
    case 'missing_app_check_token':
    case 'invalid_app_check_token':
      return 401;
    default:
      return 403;
  }
}

function safeLiveGateError(code: string): string {
  switch (code) {
    case 'missing_auth_token':
    case 'invalid_auth_token':
    case 'missing_app_check_token':
    case 'invalid_app_check_token':
      return 'unauthorized';
    case 'identity_project_mismatch':
    case 'unsupported_auth_provider':
    case 'unapproved_app':
      return 'forbidden';
    default:
      return 'research_broker_disabled';
  }
}

class BrokerProviderConfigError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

function hasHeaders(
  value: MinimalRequest | Record<string, string | string[] | undefined>,
): value is MinimalRequest {
  return 'headers' in value;
}
