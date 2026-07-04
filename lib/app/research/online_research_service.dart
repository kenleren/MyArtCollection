import '../storage/ai_research_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';

class OnlineResearchRequest {
  const OnlineResearchRequest({
    required this.artworkId,
    required this.consentSummary,
    required this.querySummary,
    this.searchTerms = const [],
  });

  final String artworkId;
  final String consentSummary;
  final String querySummary;
  final List<String> searchTerms;
}

abstract class OnlineResearchClient {
  Future<ResearchJob> research(OnlineResearchRequest request);
}

class OnlineResearchService {
  const OnlineResearchService({
    required LocalArtworkRepository repository,
    required OnlineResearchClient client,
  }) : this._(repository, client);

  const OnlineResearchService._(this._repository, this._client);

  final LocalArtworkRepository _repository;
  final OnlineResearchClient _client;

  Future<ResearchJob> runResearch(OnlineResearchRequest request) async {
    final job = await _client.research(request);
    await _repository.upsertResearchJob(job);
    return job;
  }
}

class ProfessionalSourceAllowlist {
  const ProfessionalSourceAllowlist(this.entries);

  factory ProfessionalSourceAllowlist.initial() {
    return const ProfessionalSourceAllowlist([
      ProfessionalSource(
        host: 'metmuseum.org',
        name: 'The Met Collection',
        type: ResearchSourceType.museumCollection,
      ),
      ProfessionalSource(
        host: 'artic.edu',
        name: 'Art Institute of Chicago',
        type: ResearchSourceType.museumCollection,
      ),
      ProfessionalSource(
        host: 'harvardartmuseums.org',
        name: 'Harvard Art Museums',
        type: ResearchSourceType.museumCollection,
      ),
      ProfessionalSource(
        host: 'europeana.eu',
        name: 'Europeana',
        type: ResearchSourceType.culturalHeritageApi,
      ),
      ProfessionalSource(
        host: 'getty.edu',
        name: 'Getty Research',
        type: ResearchSourceType.reference,
      ),
    ]);
  }

  final List<ProfessionalSource> entries;

  ProfessionalSource? sourceForUrl(String? url) {
    if (url == null || url.trim().isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(url.trim());
    final scheme = uri?.scheme.toLowerCase();
    final host = uri?.host.toLowerCase();
    if (uri == null ||
        host == null ||
        host.isEmpty ||
        (scheme != 'https' && scheme != 'http')) {
      return null;
    }

    for (final entry in entries) {
      if (host == entry.host || host.endsWith('.${entry.host}')) {
        return entry;
      }
    }
    return null;
  }

  bool isAllowed(String? url) => sourceForUrl(url) != null;
}

class ProfessionalSource {
  const ProfessionalSource({
    required this.host,
    required this.name,
    required this.type,
  });

  final String host;
  final String name;
  final ResearchSourceType type;
}

class DisallowedResearchSourceException implements Exception {
  const DisallowedResearchSourceException(this.url);

  final String url;

  @override
  String toString() => 'Disallowed professional research source: $url';
}

class FixtureProfessionalSourceResearchClient implements OnlineResearchClient {
  FixtureProfessionalSourceResearchClient({
    ProfessionalSourceAllowlist? allowlist,
    List<ResearchFixtureHit>? fixtureHits,
    DateTime Function()? now,
  }) : _allowlist = allowlist ?? ProfessionalSourceAllowlist.initial(),
       _fixtureHits = fixtureHits ?? _defaultFixtureHits,
       _now = now ?? DateTime.now;

  final ProfessionalSourceAllowlist _allowlist;
  final List<ResearchFixtureHit> _fixtureHits;
  final DateTime Function() _now;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    final now = _now().toUtc();
    final jobId = 'research-${request.artworkId}-${now.microsecondsSinceEpoch}';
    final matchingHits = _fixtureHits
        .where((hit) => hit.matches(request.querySummary, request.searchTerms))
        .toList(growable: false);
    final hits = <ResearchSourceHit>[];
    final candidates = <CandidateAttribution>[];
    ComparableValueSignal? comparableValueSignal;

    for (var index = 0; index < matchingHits.length; index += 1) {
      final fixture = matchingHits[index];
      final source = _requireAllowed(fixture.sourceUrl);
      if (fixture.imageUrl != null && !_allowlist.isAllowed(fixture.imageUrl)) {
        throw DisallowedResearchSourceException(fixture.imageUrl!);
      }

      final sourceHitId = '$jobId-source-${index + 1}';
      hits.add(
        ResearchSourceHit(
          id: sourceHitId,
          researchJobId: jobId,
          sourceName: source.name,
          sourceType: source.type,
          confidence: fixture.confidence,
          sourceUrl: fixture.sourceUrl,
          objectId: fixture.objectId,
          title: fixture.title,
          artist: fixture.artist,
          dateText: fixture.dateText,
          medium: fixture.medium,
          dimensions: fixture.dimensions,
          imageUrl: fixture.imageUrl,
          matchReason: fixture.matchReason,
          rawSnippet: fixture.rawSnippet,
        ),
      );
      candidates.add(
        CandidateAttribution(
          id: '$jobId-candidate-${index + 1}',
          researchJobId: jobId,
          sourceHitId: sourceHitId,
          title: fixture.title,
          artist: fixture.artist,
          year: fixture.dateText,
          medium: fixture.medium,
          confidence: fixture.confidence,
          matchReason: fixture.matchReason,
          fieldSources: const {
            ArtworkFieldKeys.title: ArtworkFieldSource.aiSuggested,
            ArtworkFieldKeys.artist: ArtworkFieldSource.aiSuggested,
            ArtworkFieldKeys.year: ArtworkFieldSource.aiSuggested,
            ArtworkFieldKeys.medium: ArtworkFieldSource.aiSuggested,
          },
        ),
      );

      comparableValueSignal ??= _valueSignalForFixture(
        jobId: jobId,
        sourceHitId: sourceHitId,
        fixture: fixture,
        source: source,
      );
    }

    return ResearchJob(
      id: jobId,
      artworkId: request.artworkId,
      status: ResearchJobStatus.completed,
      createdAt: now,
      updatedAt: now,
      completedAt: now,
      consentSummary: request.consentSummary,
      querySummary: _querySummary(request),
      provider: 'fixture-professional-source-search',
      sourceHits: hits,
      candidateAttributions: candidates,
      comparableValueSignals: [
        comparableValueSignal ?? _noReliableComparableSignal(jobId),
      ],
    );
  }

  ProfessionalSource _requireAllowed(String url) {
    final source = _allowlist.sourceForUrl(url);
    if (source == null) {
      throw DisallowedResearchSourceException(url);
    }
    return source;
  }

  ComparableValueSignal? _valueSignalForFixture({
    required String jobId,
    required String sourceHitId,
    required ResearchFixtureHit fixture,
    required ProfessionalSource source,
  }) {
    if (source.type != ResearchSourceType.auctionHouse ||
        fixture.comparableAmountLow == null &&
            fixture.comparableAmountHigh == null) {
      return null;
    }

    return ComparableValueSignal(
      id: '$jobId-value-1',
      researchJobId: jobId,
      sourceHitId: sourceHitId,
      kind: fixture.comparableKind,
      label: fixture.comparableKind.displayLabel,
      sourceName: source.name,
      sourceUrl: fixture.sourceUrl,
      amountLow: fixture.comparableAmountLow,
      amountHigh: fixture.comparableAmountHigh,
      currency: fixture.comparableCurrency,
      signalDate: fixture.comparableSignalDate,
      caveat:
          fixture.comparableCaveat ??
          'Comparable data may not apply to this artwork; confirm with an expert.',
    );
  }

  ComparableValueSignal _noReliableComparableSignal(String jobId) {
    return ComparableValueSignal(
      id: '$jobId-value-1',
      researchJobId: jobId,
      kind: ComparableValueKind.noReliableComparable,
      label: ComparableValueKind.noReliableComparable.displayLabel,
      sourceName: 'Professional-source search',
      caveat: 'No source-backed comparable was available for this draft.',
    );
  }

  String _querySummary(OnlineResearchRequest request) {
    final terms = request.searchTerms
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty)
        .join(', ');
    return terms.isEmpty
        ? request.querySummary
        : '${request.querySummary} | $terms';
  }
}

class ResearchFixtureHit {
  const ResearchFixtureHit({
    required this.sourceUrl,
    required this.title,
    required this.artist,
    required this.dateText,
    required this.medium,
    required this.matchReason,
    this.objectId,
    this.dimensions,
    this.imageUrl,
    this.rawSnippet,
    this.confidence = ResearchConfidence.possible,
    this.matchTerms = const [],
    this.comparableKind = ComparableValueKind.publicEstimate,
    this.comparableAmountLow,
    this.comparableAmountHigh,
    this.comparableCurrency,
    this.comparableSignalDate,
    this.comparableCaveat,
  });

  final String sourceUrl;
  final String? objectId;
  final String title;
  final String artist;
  final String dateText;
  final String medium;
  final String? dimensions;
  final String? imageUrl;
  final String matchReason;
  final String? rawSnippet;
  final ResearchConfidence confidence;
  final List<String> matchTerms;
  final ComparableValueKind comparableKind;
  final String? comparableAmountLow;
  final String? comparableAmountHigh;
  final String? comparableCurrency;
  final DateTime? comparableSignalDate;
  final String? comparableCaveat;

  bool matches(String querySummary, List<String> searchTerms) {
    final haystack = [querySummary, ...searchTerms].join(' ').toLowerCase();
    return matchTerms.isEmpty ||
        matchTerms.any((term) => haystack.contains(term.toLowerCase()));
  }
}

const _defaultFixtureHits = [
  ResearchFixtureHit(
    sourceUrl: 'https://www.metmuseum.org/art/collection/search/437133',
    objectId: '437133',
    title: 'Interior Study',
    artist: 'Example Collection Artist',
    dateText: 'circa 1980',
    medium: 'Oil on canvas',
    dimensions: '50 x 70 cm',
    matchReason: 'Professional collection record shares subject and medium.',
    rawSnippet: 'Collection record with interior subject and oil medium.',
    matchTerms: ['interior', 'oil', 'canvas'],
  ),
  ResearchFixtureHit(
    sourceUrl: 'https://www.artic.edu/artworks/27992/interior',
    objectId: '27992',
    title: 'Interior',
    artist: 'Example Institute Artist',
    dateText: '20th century',
    medium: 'Lithograph',
    matchReason: 'Museum record is useful for medium and title comparison.',
    rawSnippet: 'Artwork record from a professional museum collection.',
    matchTerms: ['interior', 'lithograph', 'print'],
  ),
];
