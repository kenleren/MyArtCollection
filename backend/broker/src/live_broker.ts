import {
  createOpenAiProvider,
  readOpenAiProviderConfigFromEnv,
  type OpenAiProviderConfig,
} from './openai_provider.js';
import type { BrokerDependencies } from './broker.js';
import { createFakeBrokerDependencies } from './broker.js';
import {
  handleBrokerAdapterRequest,
  type BrokerAdapterIdentity,
  type BrokerAdapterEnvelope,
} from './adapter.js';

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
      dependencies: BrokerDependencies;
      ownerUidAllowlist: ReadonlySet<string>;
      durableProtection: true;
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
  durableProtectionAvailable = false,
): ConfiguredBrokerDependenciesResult {
  if (!isResearchBrokerLiveEnabled(env)) {
    return { kind: 'disabled' };
  }

  const ownerUidAllowlist = parseAllowlist(env[BROKER_OWNER_UID_ALLOWLIST_ENV]);
  if (ownerUidAllowlist.size === 0) {
    return { kind: 'misconfigured', code: 'missing_owner_uid_allowlist' };
  }

  if (!durableProtectionAvailable) {
    return { kind: 'misconfigured', code: DURABLE_PROTECTION_UNAVAILABLE_CODE };
  }

  const providerConfig = configReader(env, overrides);
  if (!providerConfig.ok) {
    return { kind: 'misconfigured', code: providerConfig.code };
  }

  return {
    kind: 'ready',
    ownerUidAllowlist,
    durableProtection: true,
    dependencies: createFakeBrokerDependencies({
      provider: createOpenAiProvider(providerConfig.config),
    }),
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

    const identity = identityFromHeaders(request.headers);
    if (!configured.ownerUidAllowlist.has(identity.auth.uid ?? '')) {
      sendJson(response, 403, { ok: false, error: 'forbidden' });
      return;
    }

    const requestBody = unwrapCallableData(await readJsonBody(request));
    const envelope = await handleBrokerAdapterRequest(
      requestBody,
      identity,
      configured.dependencies,
    );
    sendJson(response, envelope.status, envelope.ok ? envelope.body : envelope.body);
  };
}

function identityFromHeaders(
  headers: MinimalRequest['headers'],
): BrokerAdapterIdentity {
  return {
    auth: {
      appCheckVerified: header(headers, 'x-archivale-broker-app-check-verified') === 'true',
      authVerified: header(headers, 'x-archivale-broker-auth-verified') === 'true',
      uid: header(headers, 'x-archivale-broker-auth-uid'),
      authProjectId: header(headers, 'x-archivale-broker-auth-project-id'),
      signInProvider: header(headers, 'x-archivale-broker-auth-provider') ?? 'anonymous',
    },
    app: {
      appId: header(headers, 'x-archivale-broker-app-id'),
      appProjectId: header(headers, 'x-archivale-broker-app-project-id'),
    },
    quotaSubject: header(headers, 'x-archivale-broker-quota-subject'),
    entitled: header(headers, 'x-archivale-broker-entitled') === 'true',
    creditAvailable: header(headers, 'x-archivale-broker-credit-available') === 'true',
    breakerOpen: header(headers, 'x-archivale-broker-breaker-open') === 'true',
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

function hasHeaders(
  value: MinimalRequest | Record<string, string | string[] | undefined>,
): value is MinimalRequest {
  return 'headers' in value;
}
