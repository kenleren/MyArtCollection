import 'dart:io';

import 'broker_http_client.dart';
import 'broker_payload.dart';
import 'image_derivative_service.dart';

/// Resolves the current, user-confirmed protocol consent. Returning null
/// represents missing, declined, or stale consent and is intentionally the
/// only precondition visible to the coordinator before image access.
abstract interface class BrokerResearchConsentProvider {
  Future<BrokerResearchConsent?> currentApprovedConsent();
}

/// Production entry point for a source image research submission.
///
/// The source file is neither read nor decoded until [consentProvider] returns
/// a current typed approval. This keeps the image boundary independent of UI
/// rendering and prevents callers from accidentally preparing a derivative
/// before consent has been confirmed.
class BrokerResearchCoordinator {
  const BrokerResearchCoordinator({
    required this.consentProvider,
    required this.derivativeCreator,
    required this.client,
  });

  final BrokerResearchConsentProvider consentProvider;
  final ResearchImageDerivativeCreator derivativeCreator;
  final BrokerHttpClient client;

  Future<BrokerClientResult> submitSource({
    required File source,
    required BrokerResearchAuthorization authorization,
    BrokerDraftHints? draftHints,
    String? requestId,
  }) async {
    final consent = await _currentConsent();
    if (consent == null) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent must be confirmed again.',
        ),
      );
    }
    late BrokerImageDerivative derivative;
    try {
      derivative = await derivativeCreator.create(source);
    } on Object {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'image_unavailable',
          message: 'The selected image could not be prepared for research.',
        ),
      );
    }
    return client.submitAuthorized(
      BrokerRequestPayload.create(
        consent: consent,
        derivative: derivative,
        draftHints: draftHints,
        requestId: requestId,
      ),
      authorization,
    );
  }

  Future<BrokerClientResult> retry(
    String requestId, {
    required BrokerResearchAuthorization authorization,
  }) async {
    final consent = await _currentConsent();
    if (consent == null) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent must be confirmed again.',
        ),
      );
    }
    return client.retryAuthorized(
      requestId,
      consent: consent,
      authorization: authorization,
    );
  }

  Future<BrokerResearchConsent?> _currentConsent() async {
    try {
      return await consentProvider.currentApprovedConsent();
    } on Object {
      return null;
    }
  }
}
