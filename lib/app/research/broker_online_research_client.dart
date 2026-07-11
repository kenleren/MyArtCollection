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

enum BrokerResearchFailureAction {
  none,
  newAttempt,
  retrySameRequest,
  freshConsent,
}

class BrokerResearchFailureException implements Exception {
  const BrokerResearchFailureException._({
    required this.code,
    required this.collectorMessage,
    required this.action,
    required this.showManagePlan,
    this.requestId,
  });

  final String code;
  final String collectorMessage;
  final BrokerResearchFailureAction action;
  final bool showManagePlan;
  final String? requestId;

  factory BrokerResearchFailureException.fromFailure(
    BrokerClientFailure failure, {
    String? requestId,
  }) {
    final presentation = _presentationForFailure(failure);
    return BrokerResearchFailureException._(
      code: failure.code,
      collectorMessage: presentation.message,
      action: presentation.action,
      showManagePlan: presentation.showManagePlan,
      requestId:
          presentation.action == BrokerResearchFailureAction.retrySameRequest
          ? requestId
          : null,
    );
  }
}

abstract interface class BrokerResearchImageSource {
  Future<File?> primaryImage(String artworkId);
}

class LocalBrokerResearchImageSource implements BrokerResearchImageSource {
  const LocalBrokerResearchImageSource({
    required this.repository,
    required this.attachmentStore,
  });

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;

  @override
  Future<File?> primaryImage(String artworkId) async {
    final record = await repository.get(artworkId);
    final attachmentId = record?.primaryImageAttachmentId;
    if (attachmentId == null) return null;
    final attachment = await repository.getAttachment(attachmentId);
    if (attachment == null || !attachment.isPrimaryImageCandidate) return null;
    final file = attachmentStore.fileFor(attachment);
    return await file.exists() ? file : null;
  }
}

/// Bridges the typed #188 broker client into the existing persisted research UI.
/// It has no fixture fallback and only accepts a typed consent supplied after UI
/// confirmation. Resolving an attachment returns a path; image bytes are read by
/// [BrokerResearchCoordinator] only after that consent is checked.
class BrokerOnlineResearchClient implements RetryableOnlineResearchClient {
  BrokerOnlineResearchClient({
    required this.imageSource,
    required this.httpClient,
    this.derivativeCreator = const ResearchImageDerivativeService(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BrokerResearchImageSource imageSource;
  final BrokerHttpClient httpClient;
  final ResearchImageDerivativeCreator derivativeCreator;
  final DateTime Function() _now;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    final consent = request.brokerConsent;
    if (consent == null) {
      throw BrokerResearchFailureException.fromFailure(
        const BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent is required.',
        ),
      );
    }
    final gate = await httpClient.authorizeAfterConsent();
    if (!gate.isAuthorized) {
      throw BrokerResearchFailureException.fromFailure(gate.failure!);
    }
    final source = await imageSource.primaryImage(request.artworkId);
    if (source == null) {
      throw BrokerResearchFailureException.fromFailure(
        const BrokerClientFailure(
          code: 'image_unavailable',
          message: 'The selected image is unavailable.',
        ),
      );
    }
    final requestId = _newRequestId();
    final result =
        await BrokerResearchCoordinator(
          consentProvider: _FixedConsentProvider(consent),
          derivativeCreator: derivativeCreator,
          client: httpClient,
        ).submitSource(
          source: source,
          authorization: gate.authorization!,
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
      throw BrokerResearchFailureException.fromFailure(
        const BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent is required.',
        ),
      );
    }
    final gate = await httpClient.authorizeAfterConsent();
    if (!gate.isAuthorized) {
      throw BrokerResearchFailureException.fromFailure(gate.failure!);
    }
    final result = await BrokerResearchCoordinator(
      consentProvider: _FixedConsentProvider(consent),
      derivativeCreator: derivativeCreator,
      client: httpClient,
    ).retry(requestId, authorization: gate.authorization!);
    return _jobFromResult(request, result, requestId);
  }

  @override
  Future<void> cancel(String requestId) async {
    await httpClient.cancel(requestId);
  }

  ResearchJob _jobFromResult(
    OnlineResearchRequest request,
    BrokerClientResult result,
    String requestId,
  ) {
    final response = result.response;
    if (response == null) {
      throw BrokerResearchFailureException.fromFailure(
        result.failure!,
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

class _BrokerFailurePresentation {
  const _BrokerFailurePresentation(
    this.message,
    this.action, {
    this.showManagePlan = false,
  });

  final String message;
  final BrokerResearchFailureAction action;
  final bool showManagePlan;
}

_BrokerFailurePresentation _presentationForFailure(
  BrokerClientFailure failure,
) {
  return switch (failure.code) {
    'consent_required' || 'consent_stale' => const _BrokerFailurePresentation(
      'Research consent needs to be reviewed before Archivale can continue.',
      BrokerResearchFailureAction.freshConsent,
    ),
    'offline' => const _BrokerFailurePresentation(
      'Research needs a connection. Your draft stays on this device.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'identity_unavailable' ||
    'token_unavailable' ||
    'unauthorized' ||
    'forbidden' => const _BrokerFailurePresentation(
      'Research is unavailable because a private connection could not be established.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'not_entitled' => const _BrokerFailurePresentation(
      'Online research is not included for this account. Your draft and records remain available.',
      BrokerResearchFailureAction.none,
      showManagePlan: true,
    ),
    'credits_exhausted' => const _BrokerFailurePresentation(
      'Online research credits are unavailable. Your draft and records remain available.',
      BrokerResearchFailureAction.none,
      showManagePlan: true,
    ),
    'request_in_flight' => const _BrokerFailurePresentation(
      'A research request is already in progress. Retry this same request shortly.',
      BrokerResearchFailureAction.retrySameRequest,
    ),
    'transport_unavailable' => const _BrokerFailurePresentation(
      'The connection ended before Archivale received the outcome. Retry this same request.',
      BrokerResearchFailureAction.retrySameRequest,
    ),
    'rate_limited' => const _BrokerFailurePresentation(
      'Research is busy right now. Start a new request later.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'idempotency_conflict' => const _BrokerFailurePresentation(
      'This research request conflicts with an earlier request and cannot be retried.',
      BrokerResearchFailureAction.none,
    ),
    'request_outcome_unknown' => const _BrokerFailurePresentation(
      'The research outcome cannot be confirmed safely, so Archivale will not retry it.',
      BrokerResearchFailureAction.none,
    ),
    'upstream_timeout' => const _BrokerFailurePresentation(
      'Research took too long to finish. Start a new request later.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'temporarily_unavailable' when failure.retryable =>
      const _BrokerFailurePresentation(
        'Research is temporarily unavailable. Start a new request later.',
        BrokerResearchFailureAction.newAttempt,
      ),
    'request_expired' => const _BrokerFailurePresentation(
      'The earlier request expired before research began. Start a new request.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'invalid_broker_response' ||
    'upstream_failure' ||
    'upstream_invalid_output' ||
    'upstream_refusal' => const _BrokerFailurePresentation(
      'Archivale could not display a safe source-backed result. Start a new request later.',
      BrokerResearchFailureAction.newAttempt,
    ),
    'research_disabled' ||
    'endpoint_unavailable' => const _BrokerFailurePresentation(
      'Archivale research is not available right now. Your local draft remains available.',
      BrokerResearchFailureAction.none,
    ),
    'payload_invalid' ||
    'payload_too_large' ||
    'unsupported_media_type' ||
    'method_not_allowed' ||
    'retry_storage_unavailable' ||
    'retry_not_available' ||
    'image_unavailable' ||
    'cancelled' ||
    'temporarily_unavailable' => const _BrokerFailurePresentation(
      'Archivale could not finish source-backed research safely.',
      BrokerResearchFailureAction.none,
    ),
    _ => const _BrokerFailurePresentation(
      'Archivale could not finish source-backed research safely.',
      BrokerResearchFailureAction.none,
    ),
  };
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
