import 'dart:io';
import 'dart:math';

import '../storage/ai_research_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'broker_http_client.dart';
import 'broker_payload.dart' as broker;
import 'broker_research_coordinator.dart';
import 'image_derivative_service.dart';
import 'online_research_service.dart';

/// A presentation-safe failure. Broker codes remain internal to this adapter
/// so the UI can use fixed collector-facing states without rendering server text.
class BrokerResearchFailureException implements Exception {
  const BrokerResearchFailureException(this.code, {this.requestId});

  final String code;
  final String? requestId;
}

/// Bridges the typed #188 broker client into the existing persisted research UI.
/// It has no fixture fallback and only accepts a typed consent supplied after UI
/// confirmation. Resolving an attachment returns a path; image bytes are read by
/// [BrokerResearchCoordinator] only after that consent is checked.
class BrokerOnlineResearchClient implements RetryableOnlineResearchClient {
  BrokerOnlineResearchClient({
    required this.repository,
    required this.attachmentStore,
    required this.httpClient,
    this.derivativeCreator = const ResearchImageDerivativeService(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final BrokerHttpClient httpClient;
  final ResearchImageDerivativeCreator derivativeCreator;
  final DateTime Function() _now;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    final consent = request.brokerConsent;
    if (consent == null) {
      throw const BrokerResearchFailureException('consent_required');
    }
    final source = await _primaryImage(request.artworkId);
    if (source == null) {
      throw const BrokerResearchFailureException('image_unavailable');
    }
    final requestId = _newRequestId();
    final result =
        await BrokerResearchCoordinator(
          consentProvider: _FixedConsentProvider(consent),
          derivativeCreator: derivativeCreator,
          client: httpClient,
        ).submitSource(
          source: source,
          requestId: requestId,
          draftHints: request.brokerDraftHints,
        );
    return _jobFromResult(request, result, requestId);
  }

  @override
  Future<ResearchJob> retry(
    OnlineResearchRequest request,
    String requestId,
  ) async {
    final consent = request.brokerConsent;
    if (consent == null) {
      throw const BrokerResearchFailureException('consent_required');
    }
    final result = await BrokerResearchCoordinator(
      consentProvider: _FixedConsentProvider(consent),
      derivativeCreator: derivativeCreator,
      client: httpClient,
    ).retry(requestId);
    return _jobFromResult(request, result, requestId);
  }

  Future<File?> _primaryImage(String artworkId) async {
    final record = await repository.get(artworkId);
    final attachmentId = record?.primaryImageAttachmentId;
    if (attachmentId == null) return null;
    final attachment = await repository.getAttachment(attachmentId);
    if (attachment == null || !attachment.isPrimaryImageCandidate) return null;
    final file = attachmentStore.fileFor(attachment);
    return await file.exists() ? file : null;
  }

  ResearchJob _jobFromResult(
    OnlineResearchRequest request,
    BrokerClientResult result,
    String requestId,
  ) {
    final response = result.response;
    if (response == null) {
      throw BrokerResearchFailureException(
        result.failure!.code,
        requestId: requestId,
      );
    }
    final now = _now().toUtc();
    final sources = response.sources
        .map(
          (source) => ResearchSourceHit(
            id: source.sourceId,
            researchJobId:
                'research-${request.artworkId}-${response.requestId}',
            sourceName: source.sourceName,
            sourceType: source.sourceType == 'auction_house'
                ? ResearchSourceType.auctionHouse
                : ResearchSourceType.museumCollection,
            confidence: ResearchConfidence.possible,
            sourceUrl: source.sourceUrl,
            title: source.title,
            rawSnippet: source.citationExcerpt,
          ),
        )
        .toList(growable: false);
    final jobId = 'research-${request.artworkId}-${response.requestId}';
    return ResearchJob(
      id: jobId,
      artworkId: request.artworkId,
      status: ResearchJobStatus.completed,
      createdAt: now,
      updatedAt: now,
      completedAt: response.completedAt,
      consentSummary: request.consentSummary,
      querySummary: request.querySummary,
      provider: 'archivale-broker',
      sourceHits: sources,
      candidateAttributions: response.candidateAttributions
          .map(
            (candidate) => CandidateAttribution(
              id: candidate.candidateId,
              researchJobId: jobId,
              sourceHitId: candidate.sourceRefs.first,
              title: candidate.title,
              artist: candidate.artist,
              year: candidate.year,
              medium: candidate.medium,
              confidence: _confidence(candidate.confidence),
              matchReason: candidate.matchReason,
              fieldSources: const {
                ArtworkFieldKeys.title: ArtworkFieldSource.aiSuggested,
                ArtworkFieldKeys.artist: ArtworkFieldSource.aiSuggested,
                ArtworkFieldKeys.year: ArtworkFieldSource.aiSuggested,
                ArtworkFieldKeys.medium: ArtworkFieldSource.aiSuggested,
              },
            ),
          )
          .toList(growable: false),
      comparableValueSignals: response.comparableValueSignals
          .map(
            (signal) => ComparableValueSignal(
              id: '$jobId-value-${response.comparableValueSignals.indexOf(signal) + 1}',
              researchJobId: jobId,
              kind: _valueKind(signal.kind),
              label: signal.label,
              sourceName: signal.sourceRefs.isEmpty
                  ? 'Professional-source search'
                  : sources
                        .firstWhere(
                          (source) => source.id == signal.sourceRefs.first,
                        )
                        .sourceName,
              sourceHitId: signal.sourceRefs.isEmpty
                  ? null
                  : signal.sourceRefs.first,
              sourceUrl: signal.sourceRefs.isEmpty
                  ? null
                  : sources
                        .firstWhere(
                          (source) => source.id == signal.sourceRefs.first,
                        )
                        .sourceUrl,
              caveat: signal.caveat,
            ),
          )
          .toList(growable: false),
    );
  }
}

class _FixedConsentProvider implements BrokerResearchConsentProvider {
  const _FixedConsentProvider(this.consent);
  final broker.BrokerResearchConsent consent;
  @override
  Future<broker.BrokerResearchConsent?> currentApprovedConsent() async =>
      consent;
}

ResearchConfidence _confidence(String value) => switch (value) {
  'likely' => ResearchConfidence.likely,
  'insufficient_evidence' => ResearchConfidence.insufficientEvidence,
  _ => ResearchConfidence.possible,
};

ComparableValueKind _valueKind(String value) => switch (value) {
  'public_estimate' => ComparableValueKind.publicEstimate,
  'comparable_sale_signal' => ComparableValueKind.comparableSaleSignal,
  _ => ComparableValueKind.noReliableComparable,
};

String _newRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
