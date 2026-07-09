import type { BrokerErrorCondition } from './error_contract.js';

export const CURRENT_CONSENT_COPY_VERSION = 'research-consent-v1';
export const CURRENT_PAYLOAD_CONTRACT_VERSION = 'art-research-payload-v1';
export const CURRENT_CANONICAL_PAYLOAD_VERSION = 'canonical-payload-v1';
export const CURRENT_ERROR_CONTRACT_VERSION = 'broker-error-v1';
export const APPROVED_PAYLOAD_CLASS = 'image_only_or_image_plus_draft_hints';

export type ConsentScope = 'image_only' | 'image_plus_draft_hints';
export type ConsentStatus = 'approved' | 'declined' | 'missing';

export interface BrokerRequest {
  request_id: string;
  consent_status: ConsentStatus;
  consent_scope: ConsentScope;
  consent_copy_version: string;
  payload_contract_version: string;
  payload_hash: string;
  approved_payload_class: string;
  image: {
    mime_type: 'image/jpeg' | 'image/webp';
    byte_size: number;
    long_edge_px: number;
    content_base64: string;
  };
  draft_hints?: {
    title_hint?: string;
    artist_hint?: string;
    search_terms?: string[];
  };
}

export interface BrokerContext {
  app_check_verified: boolean;
  auth_verified: boolean;
  auth_identity: {
    uid: string;
    project_id: string;
    sign_in_provider: 'anonymous';
  };
  app_identity: {
    app_id: string;
    project_id: string;
  };
  quota_subject: string;
  entitled: boolean;
  breaker_open: boolean;
}

export interface BrokerSource {
  source_id: string;
  source_name: string;
  source_type: 'museum' | 'auction_house';
  source_url: string;
  title: string;
  accessed_at: string;
  citation_excerpt: string;
  matched_fields: string[];
}

export interface BrokerCandidate {
  candidate_id: string;
  confidence: 'possible' | 'likely' | 'insufficient_evidence';
  match_reason: string;
  title?: string;
  artist?: string;
  year?: string;
  medium?: string;
  field_sources: Record<string, 'ai_suggested'>;
  source_refs: string[];
}

export interface BrokerResearchOutput {
  sources: BrokerSource[];
  candidate_attributions: BrokerCandidate[];
  comparable_value_signals: Array<{
    kind: 'public_estimate' | 'comparable_sale_signal' | 'no_reliable_comparable';
    label: string;
    source_refs: string[];
    caveat: string;
  }>;
  warnings: string[];
}

export interface BrokerResponse {
  request_id: string;
  status: 'completed';
  provider: 'fake-provider' | 'openai';
  model: string;
  reasoning_effort: 'none' | 'medium' | 'high' | 'xhigh';
  completed_at: string;
  replayed?: boolean;
  sources: BrokerSource[];
  candidate_attributions: BrokerCandidate[];
  comparable_value_signals: BrokerResearchOutput['comparable_value_signals'];
  warnings: string[];
}

export interface BrokerFailure {
  request_id?: string;
  condition: BrokerErrorCondition;
  retry_after_seconds?: number;
  replayed?: boolean;
}

export type BrokerResult =
  | { ok: true; response: BrokerResponse }
  | { ok: false; failure: BrokerFailure };

export type BrokerTerminalOutcome =
  | { kind: 'success'; response: BrokerResponse }
  | { kind: 'error'; failure: BrokerFailure };

export type ProviderResearchResult =
  | { kind: 'success'; output: BrokerResearchOutput }
  | { kind: 'invalid_output' }
  | { kind: 'rate_limited'; retry_after_seconds?: number }
  | { kind: 'refusal' }
  | { kind: 'timeout' }
  | { kind: 'failure' };

export interface ProviderClient {
  readonly providerName: BrokerResponse['provider'];
  readonly modelName: string;
  readonly reasoningEffort: BrokerResponse['reasoning_effort'];
  readonly callCount: number;
  research(request: BrokerRequest): Promise<ProviderResearchResult>;
}
