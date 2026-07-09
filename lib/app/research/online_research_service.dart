import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    this.brokerPayload,
  });

  final String artworkId;
  final String consentSummary;
  final String querySummary;
  final ResearchConsentState consentState;
  final List<String> searchTerms;
  final BrokerResearchPayload? brokerPayload;
}

enum ResearchConsentState { missing, declined, approved }

abstract class OnlineResearchClient {
  Future<ResearchJob> research(OnlineResearchRequest request);
}

const brokerConsentCopyVersion = 'research-consent-v1';
const brokerPayloadContractVersion = 'art-research-payload-v1';
const brokerApprovedPayloadClass = 'image_only_or_image_plus_draft_hints';

enum BrokerConsentScope {
  imageOnly('image_only'),
  imagePlusDraftHints('image_plus_draft_hints');

  const BrokerConsentScope(this.storageValue);

  final String storageValue;
}

class BrokerImagePayload {
  const BrokerImagePayload({
    required this.mimeType,
    required this.byteSize,
    required this.longEdgePx,
  });

  final String mimeType;
  final int byteSize;
  final int longEdgePx;

  Map<String, Object?> toJson() {
    return {
      'mime_type': mimeType,
      'byte_size': byteSize,
      'long_edge_px': longEdgePx,
    };
  }
}

class BrokerDraftHints {
  const BrokerDraftHints({
    this.titleHint,
    this.artistHint,
    this.searchTerms = const [],
  });

  final String? titleHint;
  final String? artistHint;
  final List<String> searchTerms;

  Map<String, Object?> toJson() {
    final title = _safeBrokerHint(titleHint);
    final artist = _safeBrokerHint(artistHint);
    final terms = _safeBrokerSearchTerms(searchTerms);
    final json = <String, Object?>{};
    if (title != null) {
      json['title_hint'] = title;
    }
    if (artist != null) {
      json['artist_hint'] = artist;
    }
    if (terms.isNotEmpty) {
      json['search_terms'] = terms;
    }
    return json;
  }
}

class BrokerResearchPayload {
  const BrokerResearchPayload({
    required this.requestId,
    required this.consentScope,
    required this.image,
    this.draftHints,
  });

  final String requestId;
  final BrokerConsentScope consentScope;
  final BrokerImagePayload image;
  final BrokerDraftHints? draftHints;

  Map<String, Object?> toBrokerRequest(ResearchConsentState consentState) {
    final request = <String, Object?>{
      'request_id': requestId,
      'consent_status': consentState.name,
      'consent_scope': consentScope.storageValue,
      'consent_copy_version': brokerConsentCopyVersion,
      'payload_contract_version': brokerPayloadContractVersion,
      'approved_payload_class': brokerApprovedPayloadClass,
      'image': image.toJson(),
      if (draftHints?.toJson() case final hints? when hints.isNotEmpty)
        'draft_hints': hints,
    };
    return {...request, 'payload_hash': _sha256Hex(_canonicalJson(request))};
  }
}

abstract interface class FakeBrokerResearchEndpoint {
  Future<FakeBrokerAdapterEnvelope> send(Map<String, Object?> brokerRequest);
}

sealed class FakeBrokerAdapterEnvelope {
  const FakeBrokerAdapterEnvelope();
}

class FakeBrokerAdapterSuccessEnvelope extends FakeBrokerAdapterEnvelope {
  const FakeBrokerAdapterSuccessEnvelope({
    required this.status,
    required this.body,
  });

  final int status;
  final Map<String, Object?> body;
}

class FakeBrokerAdapterErrorEnvelope extends FakeBrokerAdapterEnvelope {
  const FakeBrokerAdapterErrorEnvelope({
    required this.status,
    required this.body,
  });

  final int status;
  final BrokerErrorBody body;
}

class BrokerErrorBody {
  const BrokerErrorBody({
    required this.status,
    required this.provider,
    required this.error,
    this.requestId,
  });

  final String? requestId;
  final String status;
  final String provider;
  final BrokerErrorDetail error;
}

class BrokerErrorDetail {
  const BrokerErrorDetail({
    required this.code,
    required this.message,
    required this.stage,
  });

  final String code;
  final String message;
  final String stage;
}

class BrokerResearchClient implements OnlineResearchClient {
  BrokerResearchClient({required this.endpoint, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final FakeBrokerResearchEndpoint endpoint;
  final DateTime Function() _now;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    if (request.consentState != ResearchConsentState.approved) {
      throw ResearchConsentRequiredException(request.consentState);
    }

    final payload = request.brokerPayload;
    if (payload == null) {
      return _failedJob(
        request: request,
        errorMessage:
            'Source-backed research is not ready for this draft yet. Keep reviewing your draft and try again later.',
      );
    }

    final envelope = await endpoint.send(
      payload.toBrokerRequest(request.consentState),
    );
    return switch (envelope) {
      FakeBrokerAdapterSuccessEnvelope(:final body) => _jobFromSuccess(
        request,
        body,
      ),
      FakeBrokerAdapterErrorEnvelope(:final body) => _failedJob(
        request: request,
        requestId: body.requestId,
        errorMessage: _safeBrokerErrorMessage(body.error.code),
      ),
    };
  }

  ResearchJob _jobFromSuccess(
    OnlineResearchRequest request,
    Map<String, Object?> body,
  ) {
    final now = _now().toUtc();
    final requestId = _stringValue(body['request_id']) ?? 'unknown-request';
    final jobId = 'research-${request.artworkId}-$requestId';
    final sources = _sourcesFromBody(jobId, body['sources']);
    return ResearchJob(
      id: jobId,
      artworkId: request.artworkId,
      status: ResearchJobStatus.completed,
      createdAt: now,
      updatedAt: now,
      completedAt: _dateValue(body['completed_at']) ?? now,
      consentSummary: request.consentSummary,
      querySummary: request.querySummary,
      provider: 'archivale-broker-fake-endpoint',
      sourceHits: sources.values.toList(growable: false),
      candidateAttributions: _candidatesFromBody(
        jobId,
        body['candidate_attributions'],
        sources,
      ),
      comparableValueSignals: _valueSignalsFromBody(
        jobId,
        body['comparable_value_signals'],
        sources,
      ),
    );
  }

  Map<String, ResearchSourceHit> _sourcesFromBody(String jobId, Object? value) {
    if (value is! List<Object?>) {
      return const {};
    }
    final sources = <String, ResearchSourceHit>{};
    for (final item in value) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }
      final sourceId = _stringValue(item['source_id']);
      if (sourceId == null || sources.containsKey(sourceId)) {
        continue;
      }
      sources[sourceId] = ResearchSourceHit(
        id: sourceId,
        researchJobId: jobId,
        sourceName: _stringValue(item['source_name']) ?? 'Professional source',
        sourceType: _sourceType(_stringValue(item['source_type'])),
        confidence: ResearchConfidence.possible,
        sourceUrl: _stringValue(item['source_url']),
        title: _stringValue(item['title']),
        rawSnippet: _stringValue(item['citation_excerpt']),
      );
    }
    return sources;
  }

  List<CandidateAttribution> _candidatesFromBody(
    String jobId,
    Object? value,
    Map<String, ResearchSourceHit> sources,
  ) {
    if (value is! List<Object?>) {
      return const [];
    }
    final candidates = <CandidateAttribution>[];
    for (final item in value) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }
      final sourceHitId = _firstKnownSourceRef(item['source_refs'], sources);
      candidates.add(
        CandidateAttribution(
          id:
              _stringValue(item['candidate_id']) ??
              '$jobId-candidate-${candidates.length + 1}',
          researchJobId: jobId,
          sourceHitId: sourceHitId,
          title: _stringValue(item['title']),
          artist: _stringValue(item['artist']),
          year: _stringValue(item['year']),
          medium: _stringValue(item['medium']),
          confidence: _confidence(_stringValue(item['confidence'])),
          matchReason:
              _stringValue(item['match_reason']) ??
              'Source record shares details worth reviewing.',
          fieldSources: _fieldSources(item['field_sources']),
        ),
      );
    }
    return candidates;
  }

  List<ComparableValueSignal> _valueSignalsFromBody(
    String jobId,
    Object? value,
    Map<String, ResearchSourceHit> sources,
  ) {
    if (value is! List<Object?>) {
      return const [];
    }
    final signals = <ComparableValueSignal>[];
    for (final item in value) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }
      final sourceHitId = _firstKnownSourceRef(item['source_refs'], sources);
      final source = sourceHitId == null ? null : sources[sourceHitId];
      final kind = _valueKind(_stringValue(item['kind']));
      signals.add(
        ComparableValueSignal(
          id: '$jobId-value-${signals.length + 1}',
          researchJobId: jobId,
          sourceHitId: sourceHitId,
          kind: kind,
          label: kind.displayLabel,
          sourceName: source?.sourceName ?? 'Professional-source search',
          sourceUrl: source?.sourceUrl,
          caveat:
              _stringValue(item['caveat']) ??
              'Comparable data may not apply to this artwork; confirm with an expert.',
        ),
      );
    }
    return signals;
  }

  ResearchJob _failedJob({
    required OnlineResearchRequest request,
    required String errorMessage,
    String? requestId,
  }) {
    final now = _now().toUtc();
    final jobId =
        'research-${request.artworkId}-${requestId ?? now.microsecondsSinceEpoch}';
    return ResearchJob(
      id: jobId,
      artworkId: request.artworkId,
      status: ResearchJobStatus.failed,
      createdAt: now,
      updatedAt: now,
      consentSummary: request.consentSummary,
      querySummary: request.querySummary,
      provider: 'archivale-broker-fake-endpoint',
      errorMessage: errorMessage,
    );
  }
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
  String toString() => 'Archivale research response was invalid: $message';
}

class ResearchConsentRequiredException implements Exception {
  const ResearchConsentRequiredException(this.consentState);

  final ResearchConsentState consentState;

  @override
  String toString() =>
      'Research consent is required before Archivale can run source-backed research.';
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

String? _safeBrokerHint(String? value) {
  if (value == null) {
    return null;
  }
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty || normalized.length > 120) {
    return null;
  }
  if (RegExp(r'https?://|@|[\\<>]').hasMatch(normalized)) {
    return null;
  }
  if (!RegExp(r"^[A-Za-z0-9 .,'&:/()?-]+$").hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

List<String> _safeBrokerSearchTerms(List<String> values) {
  final terms = <String>[];
  var totalLength = 0;
  for (final value in values) {
    final term = _safeBrokerHint(value);
    if (term == null || term.length > 32 || terms.contains(term)) {
      continue;
    }
    if (terms.length == 8 || totalLength + term.length > 128) {
      break;
    }
    terms.add(term);
    totalLength += term.length;
  }
  return terms;
}

String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      sorted[entry.key.toString()] = _canonicalValue(entry.value);
    }
    return sorted;
  }
  if (value is List) {
    return value.map(_canonicalValue).toList(growable: false);
  }
  return value;
}

String _sha256Hex(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String _safeBrokerErrorMessage(String code) {
  return switch (code) {
    'consent_required' ||
    'stale_consent' => 'Please review and confirm research consent again.',
    'broker_breaker_open' =>
      'Archivale research is temporarily unavailable. Try again later.',
    'quota_subject_monthly_cap_exceeded' || 'broker_monthly_cap_exceeded' =>
      'Archivale research is temporarily unavailable. Try again later.',
    'entitlement_or_credit_denied' =>
      'Archivale research is not available right now.',
    'unauthorized' ||
    'missing_auth_subject' ||
    'invalid_quota_subject' ||
    'identity_project_mismatch' ||
    'unsupported_auth_provider' =>
      'Archivale research is not available right now.',
    _ => 'Archivale research could not complete. Try again later.',
  };
}

String? _stringValue(Object? value) {
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

DateTime? _dateValue(Object? value) {
  final text = _stringValue(value);
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}

ResearchSourceType _sourceType(String? value) {
  return switch (value) {
    'museum' => ResearchSourceType.museumCollection,
    'auction_house' => ResearchSourceType.auctionHouse,
    _ => ResearchSourceType.unknown,
  };
}

ResearchConfidence _confidence(String? value) {
  return ResearchConfidence.values.firstWhere(
    (confidence) => confidence.storageValue == value,
    orElse: () => ResearchConfidence.insufficientEvidence,
  );
}

ComparableValueKind _valueKind(String? value) {
  return ComparableValueKind.values.firstWhere(
    (kind) => kind.storageValue == value,
    orElse: () => ComparableValueKind.noReliableComparable,
  );
}

String? _firstKnownSourceRef(
  Object? value,
  Map<String, ResearchSourceHit> sources,
) {
  if (value is! List<Object?>) {
    return null;
  }
  for (final sourceRef in value) {
    final sourceId = _stringValue(sourceRef);
    if (sourceId != null && sources.containsKey(sourceId)) {
      return sourceId;
    }
  }
  return null;
}

Map<String, ArtworkFieldSource> _fieldSources(Object? value) {
  if (value is! Map) {
    return const {};
  }
  final fieldSources = <String, ArtworkFieldSource>{};
  for (final entry in value.entries) {
    final key = _stringValue(entry.key);
    if (key == null) {
      continue;
    }
    fieldSources[key] = _stringValue(entry.value) == 'ai_suggested'
        ? ArtworkFieldSource.aiSuggested
        : ArtworkFieldSource.unknown;
  }
  return fieldSources;
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
