export const CURRENT_CONSENT_COPY_VERSION = 'research-consent-v1';
export const CURRENT_PAYLOAD_CONTRACT_VERSION = 'art-research-payload-v1';
export const APPROVED_PAYLOAD_CLASS = 'image_only_or_image_plus_draft_hints';

export type ConsentScope = 'image_only' | 'image_plus_draft_hints';
export type ConsentStatus = 'approved' | 'declined' | 'missing';
export type BrokerStatus = 'completed' | 'rejected' | 'conflict';

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
  };
  draft_hints?: {
    title_hint?: string;
    artist_hint?: string;
    search_terms?: string[];
  };
}

export interface BrokerContext {
  uid: string;
  app_check_verified: boolean;
  auth_verified: boolean;
  entitled: boolean;
  credit_available: boolean;
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
  status: BrokerStatus;
  provider: 'fake-provider';
  model: 'fake-local-model';
  reasoning_effort: 'none';
  completed_at?: string;
  replayed?: boolean;
  sources: BrokerSource[];
  candidate_attributions: BrokerCandidate[];
  comparable_value_signals: BrokerResearchOutput['comparable_value_signals'];
  warnings: string[];
  error?: {
    code: string;
    message: string;
    stage: string;
  };
}

export interface ProviderClient {
  readonly callCount: number;
  research(request: BrokerRequest): Promise<BrokerResearchOutput>;
}
