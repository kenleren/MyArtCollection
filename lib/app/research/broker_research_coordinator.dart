import 'dart:io';

import 'broker_http_client.dart';
import 'broker_payload.dart';
import 'image_derivative_service.dart';

/// Production entry point for a source image research submission.
///
/// The source file is neither resolved nor decoded until the client has checked
/// the supplied typed consent and both research gates for this operation.
class BrokerResearchCoordinator {
  const BrokerResearchCoordinator({
    required this.derivativeCreator,
    required this.client,
  });

  final ResearchImageDerivativeCreator derivativeCreator;
  final BrokerHttpClient client;

  Future<BrokerClientResult> submitSource({
    required Future<File?> Function() resolveSource,
    required BrokerResearchConsent? consent,
    BrokerDraftHints? draftHints,
    String? requestId,
  }) async {
    if (consent == null || requestId == null) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent must be confirmed again.',
        ),
      );
    }
    return client.submitAfterConsent(
      requestId: requestId,
      consent: consent,
      preparePayload: () async {
        final source = await resolveSource();
        if (source == null) return null;
        final derivative = await derivativeCreator.create(source);
        return BrokerRequestPayload.create(
          consent: consent,
          derivative: derivative,
          draftHints: draftHints,
          requestId: requestId,
        );
      },
    );
  }

  Future<BrokerClientResult> retry(
    String requestId, {
    required BrokerResearchConsent? consent,
  }) async {
    if (consent == null) {
      return const BrokerClientResult.failure(
        BrokerClientFailure(
          code: 'consent_required',
          message: 'Research consent must be confirmed again.',
        ),
      );
    }
    return client.retryAfterConsent(requestId, consent: consent);
  }
}
