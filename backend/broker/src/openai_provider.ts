import type {
  BrokerCandidate,
  BrokerRequest,
  BrokerResearchOutput,
  BrokerSource,
  ProviderClient,
  ProviderResearchResult,
} from './contracts.js';

export const OPENAI_API_KEY_ENV_NAMES = [
  'OPENAI_API_KEY',
  'ARCHIVALE_OPENAI_API_KEY',
] as const;

export const OPENAI_ALLOWED_DOMAINS_ENV_NAMES = [
  'OPENAI_ALLOWED_DOMAINS',
  'ARCHIVALE_OPENAI_ALLOWED_DOMAINS',
] as const;

export const OPENAI_MODEL_ENV_NAMES = [
  'OPENAI_RESPONSES_MODEL',
  'ARCHIVALE_OPENAI_RESPONSES_MODEL',
] as const;

export const OPENAI_EXTERNAL_WEB_ACCESS_ENV_NAMES = [
  'OPENAI_WEB_SEARCH_EXTERNAL_ACCESS',
  'ARCHIVALE_OPENAI_WEB_SEARCH_EXTERNAL_ACCESS',
] as const;

export const OPENAI_SEARCH_CONTEXT_SIZE_ENV_NAMES = [
  'OPENAI_WEB_SEARCH_CONTEXT_SIZE',
  'ARCHIVALE_OPENAI_WEB_SEARCH_CONTEXT_SIZE',
] as const;

export const DEFAULT_OPENAI_RESPONSES_URL = 'https://api.openai.com/v1/responses';
export const DEFAULT_OPENAI_MODEL = 'gpt-5.4';
export const DEFAULT_SEARCH_CONTEXT_SIZE = 'medium';
export const DEFAULT_REASONING_EFFORT = 'high';

type FetchLike = typeof fetch;

export interface OpenAiProviderConfig {
  apiKey: string;
  allowedDomains: readonly string[];
  endpointUrl?: string;
  model?: string;
  reasoningEffort?: 'medium' | 'high' | 'xhigh';
  searchContextSize?: 'low' | 'medium' | 'high';
  externalWebAccess?: boolean;
  fetchImpl?: FetchLike;
}

export type ReadOpenAiProviderConfigResult =
  | {
      ok: true;
      config: OpenAiProviderConfig;
    }
  | {
      ok: false;
      code: 'missing_openai_api_key' | 'missing_allowed_domains' | 'invalid_search_context_size';
      message: string;
    };

interface OpenAiResponseOutputText {
  type?: string;
  text?: string;
  annotations?: unknown[];
}

interface OpenAiResponseOutputItem {
  type?: string;
  content?: OpenAiResponseOutputText[];
  action?: {
    sources?: unknown[];
  };
}

interface OpenAiResponseBody {
  output?: OpenAiResponseOutputItem[];
}

interface NormalizedStructuredOutput {
  sources: BrokerSource[];
  candidate_attributions: BrokerCandidate[];
  comparable_value_signals: BrokerResearchOutput['comparable_value_signals'];
  warnings: string[];
}

interface OpenAiRequestConfigView {
  allowedDomains: readonly string[];
  externalWebAccess: boolean;
  modelName: string;
  reasoningEffort: 'medium' | 'high' | 'xhigh';
  searchContextSize: 'low' | 'medium' | 'high';
}

export function readOpenAiProviderConfigFromEnv(
  env: NodeJS.ProcessEnv = process.env,
  overrides: Partial<OpenAiProviderConfig> = {},
): ReadOpenAiProviderConfigResult {
  const maybeApiKey = overrides.apiKey ?? firstConfiguredEnvValue(env, OPENAI_API_KEY_ENV_NAMES);
  if (maybeApiKey === undefined || maybeApiKey.trim().length === 0) {
    return {
      ok: false,
      code: 'missing_openai_api_key',
      message: 'A server-side OpenAI API key env var is required.',
    };
  }
  const apiKey = maybeApiKey;

  const allowedDomains = overrides.allowedDomains ?? parseDomainList(
    firstConfiguredEnvValue(env, OPENAI_ALLOWED_DOMAINS_ENV_NAMES),
  );
  if (allowedDomains.length === 0) {
    return {
      ok: false,
      code: 'missing_allowed_domains',
      message: 'An explicit OpenAI allowed-domain list is required.',
    };
  }

  const searchContextSize = overrides.searchContextSize ?? parseSearchContextSize(
    firstConfiguredEnvValue(env, OPENAI_SEARCH_CONTEXT_SIZE_ENV_NAMES),
  );
  if (searchContextSize === 'invalid') {
    return {
      ok: false,
      code: 'invalid_search_context_size',
      message: 'OpenAI web search context size must be low, medium, or high.',
    };
  }

  return {
    ok: true,
    config: {
      apiKey,
      allowedDomains,
      endpointUrl: overrides.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_URL,
      model:
        overrides.model ??
        firstConfiguredEnvValue(env, OPENAI_MODEL_ENV_NAMES) ??
        DEFAULT_OPENAI_MODEL,
      reasoningEffort: overrides.reasoningEffort ?? DEFAULT_REASONING_EFFORT,
      searchContextSize,
      externalWebAccess: overrides.externalWebAccess ?? parseBooleanEnv(
        firstConfiguredEnvValue(env, OPENAI_EXTERNAL_WEB_ACCESS_ENV_NAMES),
      ) ?? false,
      fetchImpl: overrides.fetchImpl,
    },
  };
}

export function createOpenAiProvider(config: OpenAiProviderConfig): ProviderClient {
  return new OpenAiResearchProvider(config);
}

class OpenAiResearchProvider implements ProviderClient {
  readonly providerName = 'openai';
  readonly modelName: string;
  readonly reasoningEffort: 'medium' | 'high' | 'xhigh';
  readonly allowedDomains: readonly string[];
  private readonly endpointUrl: string;
  private readonly fetchImpl: FetchLike;
  private readonly searchContextSize: 'low' | 'medium' | 'high';
  private readonly externalWebAccess: boolean;
  callCount = 0;

  constructor(config: OpenAiProviderConfig) {
    this.modelName = config.model ?? DEFAULT_OPENAI_MODEL;
    this.reasoningEffort = config.reasoningEffort ?? DEFAULT_REASONING_EFFORT;
    this.allowedDomains = config.allowedDomains;
    this.endpointUrl = config.endpointUrl ?? DEFAULT_OPENAI_RESPONSES_URL;
    this.fetchImpl = config.fetchImpl ?? fetch;
    this.searchContextSize = config.searchContextSize ?? DEFAULT_SEARCH_CONTEXT_SIZE;
    this.externalWebAccess = config.externalWebAccess ?? false;
    this.apiKey = config.apiKey;
  }

  private readonly apiKey: string;

  async research(request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;

    const response = await this.fetchImpl(this.endpointUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify(buildOpenAiResponsesRequest(request, {
        allowedDomains: this.allowedDomains,
        externalWebAccess: this.externalWebAccess,
        modelName: this.modelName,
        reasoningEffort: this.reasoningEffort,
        searchContextSize: this.searchContextSize,
      })),
    });

    if (!response.ok) {
      throw new Error(`openai_responses_http_${response.status}`);
    }

    const body = await response.json() as OpenAiResponseBody;
    return normalizeOpenAiResponse(body, this.allowedDomains);
  }
}

export function buildOpenAiResponsesRequest(
  request: BrokerRequest,
  config: OpenAiRequestConfigView,
): Record<string, unknown> {
  const userContent: Array<Record<string, unknown>> = [
    {
      type: 'input_text',
      text: renderUserPrompt(request),
    },
  ];

  if (!empty(request.image.content_base64)) {
    userContent.push({
      type: 'input_image',
      image_url: `data:${request.image.mime_type};base64,${request.image.content_base64}`,
      detail: 'high',
    });
  }

  return {
    model: config.modelName,
    store: false,
    reasoning: {
      effort: config.reasoningEffort,
    },
    tool_choice: 'required',
    include: ['web_search_call.action.sources'],
    tools: [
      {
        type: 'web_search',
        filters: {
          allowed_domains: [...config.allowedDomains],
        },
        search_context_size: config.searchContextSize,
        external_web_access: config.externalWebAccess,
      },
    ],
    text: {
      format: {
        type: 'json_schema',
        name: 'archivale_art_research_response',
        strict: true,
        schema: OPENAI_RESEARCH_OUTPUT_SCHEMA,
      },
    },
    input: [
      {
        role: 'system',
        content: [
          {
            type: 'input_text',
            text: [
              'You are the server-side Archivale art research broker.',
              'Use only allowlisted professional sources returned by web_search.',
              'Return strict JSON matching the requested schema.',
              'Do not claim authenticity, certainty, or certified value.',
              'Keep citation excerpts short and plain-text.',
            ].join(' '),
          },
        ],
      },
      {
        role: 'user',
        content: userContent,
      },
    ],
  };
}

function renderUserPrompt(request: BrokerRequest): string {
  const lines = [
    'Research one artwork and return structured findings only.',
    `Consent scope: ${request.consent_scope}.`,
    `Image derivative metadata: ${request.image.mime_type}, ${request.image.byte_size} bytes, ${request.image.long_edge_px}px long edge.`,
  ];

  if (request.draft_hints?.title_hint !== undefined) {
    lines.push(`Title hint: ${request.draft_hints.title_hint}.`);
  }
  if (request.draft_hints?.artist_hint !== undefined) {
    lines.push(`Artist hint: ${request.draft_hints.artist_hint}.`);
  }
  if (request.draft_hints?.search_terms !== undefined && request.draft_hints.search_terms.length > 0) {
    lines.push(`Search terms: ${request.draft_hints.search_terms.join(', ')}.`);
  }
  if (empty(request.image.content_base64)) {
    lines.push('No inline image payload is attached to this request; rely on the metadata and hints provided.');
  }

  return lines.join(' ');
}

function normalizeOpenAiResponse(
  body: OpenAiResponseBody,
  allowedDomains: readonly string[],
): ProviderResearchResult {
  const textOutput = extractStructuredOutputText(body);
  if (textOutput === undefined) {
    return outputError('Provider response did not include structured output text.');
  }

  let parsed: unknown;
  const text = textOutput.text;
  if (text === undefined) {
    return outputError('Provider response did not include structured output text.');
  }
  try {
    parsed = JSON.parse(text);
  } catch {
    return outputError('Provider structured output was not valid JSON.');
  }

  const output = normalizeStructuredOutput(parsed, allowedDomains, extractGroundedSourceUrls(body));
  if (!output.ok) {
    return outputError(output.message);
  }

  return {
    kind: 'success',
    output: output.value,
  };
}

function extractStructuredOutputText(body: OpenAiResponseBody): OpenAiResponseOutputText | undefined {
  for (const item of body.output ?? []) {
    if (item.type !== 'message') {
      continue;
    }
    for (const content of item.content ?? []) {
      if ((content.type === 'output_text' || content.type === 'text') && typeof content.text === 'string') {
        return content;
      }
    }
  }
  return undefined;
}

function extractGroundedSourceUrls(body: OpenAiResponseBody): Set<string> {
  const urls = new Set<string>();

  for (const item of body.output ?? []) {
    if (item.type === 'message') {
      for (const content of item.content ?? []) {
        for (const annotation of content.annotations ?? []) {
          const url = annotationUrl(annotation);
          if (url !== undefined) {
            urls.add(url);
          }
        }
      }
    }

    if (item.type === 'web_search_call') {
      for (const source of item.action?.sources ?? []) {
        const url = sourceUrl(source);
        if (url !== undefined) {
          urls.add(url);
        }
      }
    }
  }

  return urls;
}

function normalizeStructuredOutput(
  value: unknown,
  allowedDomains: readonly string[],
  groundedUrls: ReadonlySet<string>,
): { ok: true; value: BrokerResearchOutput } | { ok: false; message: string } {
  if (!isRecord(value)) {
    return { ok: false, message: 'Provider output payload shape is invalid.' };
  }

  const sources = normalizeSources(value.sources, allowedDomains, groundedUrls);
  if (!sources.ok) {
    return sources;
  }

  const candidates = normalizeCandidates(value.candidate_attributions, sources.value);
  if (!candidates.ok) {
    return candidates;
  }

  const comparableValueSignals = normalizeComparableValueSignals(
    value.comparable_value_signals,
    new Set(sources.value.map((source) => source.source_id)),
  );
  if (!comparableValueSignals.ok) {
    return comparableValueSignals;
  }

  const warnings = normalizeWarnings(value.warnings);
  if (!warnings.ok) {
    return warnings;
  }

  return {
    ok: true,
    value: {
      sources: sources.value,
      candidate_attributions: candidates.value,
      comparable_value_signals: comparableValueSignals.value,
      warnings: warnings.value,
    },
  };
}

function normalizeSources(
  value: unknown,
  allowedDomains: readonly string[],
  groundedUrls: ReadonlySet<string>,
): { ok: true; value: BrokerSource[] } | { ok: false; message: string } {
  if (!Array.isArray(value)) {
    return { ok: false, message: 'Provider sources must be an array.' };
  }

  const sources: BrokerSource[] = [];
  for (const source of value) {
    if (!isRecord(source)) {
      return { ok: false, message: 'Provider source item shape is invalid.' };
    }

    const sourceId = stringValue(source.source_id);
    const sourceName = stringValue(source.source_name);
    const sourceType = stringValue(source.source_type);
    const sourceUrlValue = stringValue(source.source_url);
    const title = stringValue(source.title);
    const accessedAt = stringValue(source.accessed_at);
    const citationExcerpt = stringValue(source.citation_excerpt);
    const matchedFields = stringArray(source.matched_fields);
    if (
      sourceId === undefined ||
      sourceName === undefined ||
      (sourceType !== 'museum' && sourceType !== 'auction_house') ||
      sourceUrlValue === undefined ||
      title === undefined ||
      accessedAt === undefined ||
      citationExcerpt === undefined ||
      matchedFields === undefined
    ) {
      return { ok: false, message: 'Provider source item is missing required fields.' };
    }

    if (!groundedUrls.has(sourceUrlValue)) {
      return { ok: false, message: 'Provider source URL was not grounded in returned citations.' };
    }
    if (!isAllowedDomain(sourceUrlValue, allowedDomains)) {
      return { ok: false, message: 'Provider source URL is not in the allowlist.' };
    }

    sources.push({
      source_id: sourceId,
      source_name: sourceName,
      source_type: sourceType,
      source_url: sourceUrlValue,
      title,
      accessed_at: accessedAt,
      citation_excerpt: citationExcerpt,
      matched_fields: matchedFields,
    });
  }

  return { ok: true, value: sources };
}

function normalizeCandidates(
  value: unknown,
  sources: readonly BrokerSource[],
): { ok: true; value: BrokerCandidate[] } | { ok: false; message: string } {
  if (!Array.isArray(value)) {
    return { ok: false, message: 'Provider candidates must be an array.' };
  }

  const sourceIds = new Set(sources.map((source) => source.source_id));
  const candidates: BrokerCandidate[] = [];
  for (const candidate of value) {
    if (!isRecord(candidate)) {
      return { ok: false, message: 'Provider candidate item shape is invalid.' };
    }

    const candidateId = stringValue(candidate.candidate_id);
    const confidence = stringValue(candidate.confidence);
    const matchReason = stringValue(candidate.match_reason);
    const sourceRefs = stringArray(candidate.source_refs);
    const fieldSources = normalizeFieldSources(candidate.field_sources);
    if (
      candidateId === undefined ||
      (confidence !== 'possible' && confidence !== 'likely' && confidence !== 'insufficient_evidence') ||
      matchReason === undefined ||
      sourceRefs === undefined ||
      fieldSources === undefined
    ) {
      return { ok: false, message: 'Provider candidate item is missing required fields.' };
    }

    if (sourceRefs.some((sourceRef) => !sourceIds.has(sourceRef))) {
      return { ok: false, message: 'Provider candidate references an unknown source id.' };
    }

    candidates.push({
      candidate_id: candidateId,
      confidence,
      match_reason: matchReason,
      title: optionalString(candidate.title),
      artist: optionalString(candidate.artist),
      year: optionalString(candidate.year),
      medium: optionalString(candidate.medium),
      field_sources: fieldSources,
      source_refs: sourceRefs,
    });
  }

  return { ok: true, value: candidates };
}

function normalizeComparableValueSignals(
  value: unknown,
  sourceIds: ReadonlySet<string>,
): { ok: true; value: BrokerResearchOutput['comparable_value_signals'] } | { ok: false; message: string } {
  if (!Array.isArray(value)) {
    return { ok: false, message: 'Provider comparable value signals must be an array.' };
  }

  const signals: BrokerResearchOutput['comparable_value_signals'] = [];
  for (const signal of value) {
    if (!isRecord(signal)) {
      return { ok: false, message: 'Provider comparable value signal shape is invalid.' };
    }

    const kind = stringValue(signal.kind);
    const label = stringValue(signal.label);
    const caveat = stringValue(signal.caveat);
    const sourceRefs = stringArray(signal.source_refs);
    if (
      (kind !== 'public_estimate' &&
        kind !== 'comparable_sale_signal' &&
        kind !== 'no_reliable_comparable') ||
      label === undefined ||
      caveat === undefined ||
      sourceRefs === undefined
    ) {
      return { ok: false, message: 'Provider comparable value signal is missing required fields.' };
    }

    if (sourceRefs.some((sourceRef) => !sourceIds.has(sourceRef))) {
      return { ok: false, message: 'Provider comparable value signal references an unknown source id.' };
    }
    if (kind !== 'no_reliable_comparable' && sourceRefs.length === 0) {
      return { ok: false, message: 'Provider comparable value signal requires a cited source.' };
    }

    signals.push({
      kind,
      label,
      source_refs: sourceRefs,
      caveat,
    });
  }

  return { ok: true, value: signals };
}

function normalizeWarnings(
  value: unknown,
): { ok: true; value: string[] } | { ok: false; message: string } {
  const warnings = stringArray(value);
  if (warnings === undefined) {
    return { ok: false, message: 'Provider warnings must be an array of strings.' };
  }
  return { ok: true, value: warnings };
}

function normalizeFieldSources(value: unknown): Record<string, 'ai_suggested'> | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const result: Record<string, 'ai_suggested'> = {};
  for (const [key, fieldSource] of Object.entries(value)) {
    if (fieldSource !== 'ai_suggested') {
      return undefined;
    }
    result[key] = 'ai_suggested';
  }
  return result;
}

function annotationUrl(value: unknown): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  if (typeof value.url === 'string') {
    return value.url;
  }
  if (isRecord(value.url_citation) && typeof value.url_citation.url === 'string') {
    return value.url_citation.url;
  }
  return undefined;
}

function sourceUrl(value: unknown): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  return stringValue(value.url) ?? stringValue(value.source_url);
}

function isAllowedDomain(urlString: string, allowedDomains: readonly string[]): boolean {
  let url: URL;
  try {
    url = new URL(urlString);
  } catch {
    return false;
  }

  if (url.protocol !== 'https:') {
    return false;
  }

  const hostname = url.hostname.toLowerCase();
  return allowedDomains.some((domain) => {
    const normalized = domain.toLowerCase();
    return hostname === normalized || hostname.endsWith(`.${normalized}`);
  });
}

function outputError(message: string): ProviderResearchResult {
  return {
    kind: 'output_error',
    code: 'provider_output_invalid',
    message,
  };
}

function parseDomainList(value: string | undefined): string[] {
  if (value === undefined) {
    return [];
  }
  return value
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);
}

function parseSearchContextSize(
  value: string | undefined,
): 'low' | 'medium' | 'high' | 'invalid' {
  if (value === undefined) {
    return DEFAULT_SEARCH_CONTEXT_SIZE;
  }
  if (value === 'low' || value === 'medium' || value === 'high') {
    return value;
  }
  return 'invalid';
}

function parseBooleanEnv(value: string | undefined): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (value === 'true') {
    return true;
  }
  if (value === 'false') {
    return false;
  }
  return undefined;
}

function firstConfiguredEnvValue(
  env: NodeJS.ProcessEnv,
  names: readonly string[],
): string | undefined {
  for (const name of names) {
    const value = env[name];
    if (!empty(value)) {
      return value;
    }
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function stringArray(value: unknown): string[] | undefined {
  return Array.isArray(value) && value.every((item) => typeof item === 'string')
    ? [...value]
    : undefined;
}

function empty(value: string | undefined): boolean {
  return value === undefined || value.trim().length === 0;
}

const OPENAI_RESEARCH_OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: [
    'sources',
    'candidate_attributions',
    'comparable_value_signals',
    'warnings',
  ],
  properties: {
    sources: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'source_id',
          'source_name',
          'source_type',
          'source_url',
          'title',
          'accessed_at',
          'citation_excerpt',
          'matched_fields',
        ],
        properties: {
          source_id: { type: 'string' },
          source_name: { type: 'string' },
          source_type: { type: 'string', enum: ['museum', 'auction_house'] },
          source_url: { type: 'string' },
          title: { type: 'string' },
          accessed_at: { type: 'string' },
          citation_excerpt: { type: 'string' },
          matched_fields: {
            type: 'array',
            items: { type: 'string' },
          },
        },
      },
    },
    candidate_attributions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'candidate_id',
          'confidence',
          'match_reason',
          'field_sources',
          'source_refs',
        ],
        properties: {
          candidate_id: { type: 'string' },
          confidence: {
            type: 'string',
            enum: ['possible', 'likely', 'insufficient_evidence'],
          },
          match_reason: { type: 'string' },
          title: { type: 'string' },
          artist: { type: 'string' },
          year: { type: 'string' },
          medium: { type: 'string' },
          field_sources: {
            type: 'object',
            additionalProperties: {
              type: 'string',
              enum: ['ai_suggested'],
            },
          },
          source_refs: {
            type: 'array',
            items: { type: 'string' },
          },
        },
      },
    },
    comparable_value_signals: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['kind', 'label', 'source_refs', 'caveat'],
        properties: {
          kind: {
            type: 'string',
            enum: ['public_estimate', 'comparable_sale_signal', 'no_reliable_comparable'],
          },
          label: { type: 'string' },
          source_refs: {
            type: 'array',
            items: { type: 'string' },
          },
          caveat: { type: 'string' },
        },
      },
    },
    warnings: {
      type: 'array',
      items: { type: 'string' },
    },
  },
} as const;
