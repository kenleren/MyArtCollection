import '../storage/ai_research_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';

class OnlineResearchRequest {
  const OnlineResearchRequest({
    required this.artworkId,
    required this.consentSummary,
    required this.querySummary,
    this.consentState = ResearchConsentState.missing,
    this.searchTerms = const [],
  });

  final String artworkId;
  final String consentSummary;
  final String querySummary;
  final ResearchConsentState consentState;
  final List<String> searchTerms;
}

enum ResearchConsentState { missing, declined, approved }

abstract class OnlineResearchClient {
  Future<ResearchJob> research(OnlineResearchRequest request);
}

class OnlineResearchService {
  OnlineResearchService({
    required LocalArtworkRepository repository,
    required OnlineResearchClient client,
    ProfessionalSourceAllowlist? allowlist,
  }) : this._(
         repository,
         client,
         allowlist ?? ProfessionalSourceAllowlist.initial(),
       );

  OnlineResearchService._(this._repository, this._client, this._allowlist);

  final LocalArtworkRepository _repository;
  final OnlineResearchClient _client;
  final ProfessionalSourceAllowlist _allowlist;

  Future<ResearchJob> runResearch(OnlineResearchRequest request) async {
    _requireApprovedResearchConsent(request);
    final job = _TrustedResearchResponse(
      request: request,
      job: await _client.research(request),
      allowlist: _allowlist,
    ).sanitize();
    await _repository.upsertResearchJob(job);
    return job;
  }

  void _requireApprovedResearchConsent(OnlineResearchRequest request) {
    if (request.consentState != ResearchConsentState.approved) {
      throw ResearchConsentRequiredException(request.consentState);
    }
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
    if (uri == null || host == null || host.isEmpty || scheme != 'https') {
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

class InvalidResearchResponseException implements Exception {
  const InvalidResearchResponseException(this.message);

  final String message;

  @override
  String toString() => 'Invalid online research response: $message';
}

class ResearchConsentRequiredException implements Exception {
  const ResearchConsentRequiredException(this.consentState);

  final ResearchConsentState consentState;

  @override
  String toString() =>
      'Online research requires explicit approved consent: $consentState';
}

class _TrustedResearchResponse {
  _TrustedResearchResponse({
    required this.request,
    required this.job,
    required this.allowlist,
  });

  final OnlineResearchRequest request;
  final ResearchJob job;
  final ProfessionalSourceAllowlist allowlist;

  ResearchJob sanitize() {
    if (job.artworkId != request.artworkId) {
      throw InvalidResearchResponseException(
        'response artwork id ${job.artworkId} does not match request '
        '${request.artworkId}',
      );
    }

    final sourceHitsById = <String, ResearchSourceHit>{};
    final sanitizedSourceHits = <ResearchSourceHit>[];
    for (final sourceHit in job.sourceHits) {
      if (sourceHit.researchJobId != job.id) {
        throw InvalidResearchResponseException(
          'source ${sourceHit.id} belongs to another research job',
        );
      }
      if (sourceHitsById.containsKey(sourceHit.id)) {
        throw InvalidResearchResponseException(
          'duplicate source hit id ${sourceHit.id}',
        );
      }

      final source = _requireAllowedSource(sourceHit.sourceUrl);
      final imageUrl = sourceHit.imageUrl;
      if (imageUrl != null && !_isAllowedUrl(imageUrl)) {
        throw DisallowedResearchSourceException(imageUrl);
      }

      final sanitized = ResearchSourceHit(
        id: sourceHit.id,
        researchJobId: sourceHit.researchJobId,
        sourceName: source.name,
        sourceType: source.type,
        confidence: sourceHit.confidence,
        sourceUrl: sourceHit.sourceUrl!.trim(),
        objectId: _sanitizeNullableEvidenceText(sourceHit.objectId),
        title: _sanitizeNullableEvidenceText(sourceHit.title),
        artist: _sanitizeNullableEvidenceText(sourceHit.artist),
        dateText: _sanitizeNullableEvidenceText(sourceHit.dateText),
        medium: _sanitizeNullableEvidenceText(sourceHit.medium),
        dimensions: _sanitizeNullableEvidenceText(sourceHit.dimensions),
        imageUrl: imageUrl?.trim(),
        matchReason: _sanitizeNullableEvidenceText(sourceHit.matchReason),
        rawSnippet: _sanitizeNullableEvidenceText(sourceHit.rawSnippet),
      );
      sourceHitsById[sanitized.id] = sanitized;
      sanitizedSourceHits.add(sanitized);
    }

    final sanitizedCandidates = <CandidateAttribution>[];
    for (final candidate in job.candidateAttributions) {
      if (candidate.researchJobId != job.id) {
        throw InvalidResearchResponseException(
          'candidate ${candidate.id} belongs to another research job',
        );
      }
      final sourceHitId = candidate.sourceHitId;
      if (sourceHitId == null || !sourceHitsById.containsKey(sourceHitId)) {
        throw InvalidResearchResponseException(
          'candidate ${candidate.id} is not linked to validated source evidence',
        );
      }
      sanitizedCandidates.add(
        CandidateAttribution(
          id: candidate.id,
          researchJobId: candidate.researchJobId,
          sourceHitId: sourceHitId,
          title: _sanitizeNullableEvidenceText(candidate.title),
          artist: _sanitizeNullableEvidenceText(candidate.artist),
          year: _sanitizeNullableEvidenceText(candidate.year),
          medium: _sanitizeNullableEvidenceText(candidate.medium),
          confidence: candidate.confidence,
          matchReason: _sanitizeRequiredEvidenceText(candidate.matchReason),
          fieldSources: candidate.fieldSources,
        ),
      );
    }

    final sanitizedSignals = <ComparableValueSignal>[];
    for (final signal in job.comparableValueSignals) {
      if (signal.researchJobId != job.id) {
        throw InvalidResearchResponseException(
          'comparable signal ${signal.id} belongs to another research job',
        );
      }
      sanitizedSignals.add(_sanitizeComparableSignal(signal, sourceHitsById));
    }

    return ResearchJob(
      id: job.id,
      artworkId: job.artworkId,
      status: job.status,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      completedAt: job.completedAt,
      consentSummary: job.consentSummary,
      querySummary: job.querySummary,
      provider: job.provider,
      errorMessage: job.errorMessage,
      sourceHits: sanitizedSourceHits,
      candidateAttributions: sanitizedCandidates,
      comparableValueSignals: sanitizedSignals,
    );
  }

  ComparableValueSignal _sanitizeComparableSignal(
    ComparableValueSignal signal,
    Map<String, ResearchSourceHit> sourceHitsById,
  ) {
    if (signal.kind == ComparableValueKind.noReliableComparable) {
      return ComparableValueSignal(
        id: signal.id,
        researchJobId: signal.researchJobId,
        kind: ComparableValueKind.noReliableComparable,
        label: ComparableValueKind.noReliableComparable.displayLabel,
        sourceName: 'Professional-source search',
        caveat: _sanitizeComparableCaveat(
          signal.caveat,
          ComparableValueKind.noReliableComparable,
        ),
      );
    }

    final sourceHitId = signal.sourceHitId;
    if (sourceHitId == null || !sourceHitsById.containsKey(sourceHitId)) {
      throw InvalidResearchResponseException(
        'comparable signal ${signal.id} is not linked to validated source '
        'evidence',
      );
    }

    final sourceHit = sourceHitsById[sourceHitId]!;
    final sourceUrl = signal.sourceUrl?.trim();
    if (sourceUrl != null && sourceUrl != sourceHit.sourceUrl) {
      throw InvalidResearchResponseException(
        'comparable signal ${signal.id} citation does not match its source',
      );
    }
    if (signal.kind == ComparableValueKind.userProvidedInsuranceValue) {
      throw InvalidResearchResponseException(
        'online research cannot provide user-entered insurance values',
      );
    }

    final hasAmount =
        _hasText(signal.amountLow) ||
        _hasText(signal.amountHigh) ||
        _hasText(signal.currency);
    if (sourceHit.sourceType != ResearchSourceType.auctionHouse &&
        (signal.kind.canDisplayAmount || hasAmount)) {
      throw InvalidResearchResponseException(
        'comparable signal ${signal.id} carries market data without an '
        'auction source',
      );
    }

    return ComparableValueSignal(
      id: signal.id,
      researchJobId: signal.researchJobId,
      sourceHitId: sourceHitId,
      kind: signal.kind,
      label: signal.kind.displayLabel,
      sourceName: sourceHit.sourceName,
      sourceUrl: sourceHit.sourceUrl,
      amountLow: _sanitizeNullableEvidenceText(signal.amountLow),
      amountHigh: _sanitizeNullableEvidenceText(signal.amountHigh),
      currency: _sanitizeNullableEvidenceText(signal.currency),
      signalDate: signal.signalDate,
      caveat: _sanitizeComparableCaveat(signal.caveat, signal.kind),
    );
  }

  ProfessionalSource _requireAllowedSource(String? url) {
    final source = allowlist.sourceForUrl(url);
    if (source == null) {
      throw DisallowedResearchSourceException(url ?? '');
    }
    return source;
  }

  bool _isAllowedUrl(String url) => allowlist.sourceForUrl(url) != null;
}

String _sanitizeComparableCaveat(String text, ComparableValueKind kind) {
  final sanitized = _sanitizeRequiredEvidenceText(text);
  if (sanitized == _unsafeEvidenceTextReplacement) {
    return switch (kind) {
      ComparableValueKind.noReliableComparable =>
        'No source-backed comparable was available for this draft.',
      ComparableValueKind.publicEstimate ||
      ComparableValueKind.comparableSaleSignal ||
      ComparableValueKind.userProvidedInsuranceValue =>
        'Comparable data may not apply to this artwork; confirm with an expert.',
    };
  }
  return sanitized;
}

String? _sanitizeNullableEvidenceText(String? text) {
  if (text == null) {
    return null;
  }
  final normalized = _normalizeEvidenceText(text);
  if (normalized.isEmpty) {
    return null;
  }
  if (_containsUnsafeResearchText(normalized)) {
    return null;
  }
  return _capEvidenceText(normalized);
}

String _sanitizeRequiredEvidenceText(String text) {
  final normalized = _normalizeEvidenceText(text);
  if (normalized.isEmpty || _containsUnsafeResearchText(normalized)) {
    return _unsafeEvidenceTextReplacement;
  }
  return _capEvidenceText(normalized);
}

String _normalizeEvidenceText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _capEvidenceText(String text) {
  const maxLength = 220;
  if (text.length <= maxLength) {
    return text;
  }
  return '${text.substring(0, maxLength - 3).trimRight()}...';
}

bool _containsUnsafeResearchText(String text) {
  final normalized = text.toLowerCase();
  const blockedFragments = [
    'ignore previous',
    'ignore all previous',
    'system prompt',
    'developer message',
    'developer instruction',
    'prompt injection',
    'reveal secrets',
    'override instructions',
    'do not follow',
    'you are chatgpt',
    'market value',
    'appraised at',
    'certified value',
    'authentic value',
    'guaranteed authentic',
    'confirmed authentic',
    'proves authenticity',
    'authenticity is confirmed',
    'definitely authentic',
  ];
  if (blockedFragments.any(normalized.contains)) {
    return true;
  }
  return RegExp(
    r'\b(worth|valuation|appraisal|valued\s+at|authenticity)\b',
  ).hasMatch(normalized);
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

const _unsafeEvidenceTextReplacement =
    'Source text removed because it contained unsupported claims.';

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
