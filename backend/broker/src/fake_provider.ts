import type {
  BrokerRequest,
  BrokerResearchOutput,
  ProviderClient,
  ProviderResearchResult,
} from './contracts.js';

export class FakeResearchProvider implements ProviderClient {
  readonly providerName = 'fake-provider';
  readonly modelName = 'fake-local-model';
  readonly reasoningEffort = 'none';
  callCount = 0;

  async research(_request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;

    const output: BrokerResearchOutput = {
      sources: [
        {
          source_id: 'src_fake_museum_1',
          source_name: 'Archivale Fake Museum',
          source_type: 'museum',
          source_url: 'https://museum.example/research/fake-artwork',
          title: 'Fake collection record',
          accessed_at: new Date('2026-07-06T00:00:00.000Z').toISOString(),
          citation_excerpt: 'Fixture excerpt for local broker tests.',
          matched_fields: ['title', 'artist'],
        },
      ],
      candidate_attributions: [
        {
          candidate_id: 'candidate_fake_1',
          confidence: 'possible',
          match_reason: 'Fixture result produced by fake provider only.',
          title: 'Untitled fake artwork',
          artist: 'Archivale Fixture Artist',
          field_sources: {
            title: 'ai_suggested',
            artist: 'ai_suggested',
          },
          source_refs: ['src_fake_museum_1'],
        },
      ],
      comparable_value_signals: [
        {
          kind: 'no_reliable_comparable',
          label: 'No reliable comparable found',
          source_refs: [],
          caveat: 'Fixture output does not estimate value.',
        },
      ],
      warnings: [],
    };

    return {
      kind: 'success',
      output,
    };
  }
}
