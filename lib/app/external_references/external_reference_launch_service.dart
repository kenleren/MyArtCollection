import '../storage/external_reference.dart';
import 'external_reference_launch_gateway.dart';
import 'external_reference_url_codec.dart';

typedef ExternalReferenceLoader =
    Future<ExternalReferenceRecord?> Function(String referenceId);

enum ExternalReferenceLaunchFailure { staleOrInvalid, openFailed }

class ExternalReferenceLaunchException implements Exception {
  const ExternalReferenceLaunchException(this.failure);
  final ExternalReferenceLaunchFailure failure;
}

class ExternalReferenceLaunchService {
  const ExternalReferenceLaunchService({
    required this.referenceLoader,
    required this.gateway,
    this.urlCodec = const ExternalReferenceUrlCodec(),
  });

  final ExternalReferenceLoader referenceLoader;
  final ExternalReferenceLaunchGateway gateway;
  final ExternalReferenceUrlCodec urlCodec;

  Future<void> open({
    required String referenceId,
    required String expectedUrl,
  }) async {
    try {
      final reservation = gateway.reserveExternalLaunch();
      if (gateway.requiresSynchronousReservation && reservation == null) {
        throw const ExternalReferenceLaunchException(
          ExternalReferenceLaunchFailure.openFailed,
        );
      }
      try {
        final current = await _reload(referenceId);
        if (current == null || current.url != expectedUrl) {
          throw const ExternalReferenceLaunchException(
            ExternalReferenceLaunchFailure.staleOrInvalid,
          );
        }
        final canonical = urlCodec.canonicalize(current.url);
        if (canonical != current.url) {
          throw const ExternalReferenceLaunchException(
            ExternalReferenceLaunchFailure.staleOrInvalid,
          );
        }
        final uri = Uri.tryParse(canonical);
        if (uri == null) {
          throw const ExternalReferenceLaunchException(
            ExternalReferenceLaunchFailure.openFailed,
          );
        }
        final launched = reservation == null
            ? await gateway.launchExternal(uri)
            : await reservation.launch(uri);
        if (!launched) {
          throw const ExternalReferenceLaunchException(
            ExternalReferenceLaunchFailure.openFailed,
          );
        }
      } on ExternalReferenceLaunchException {
        reservation?.close();
        rethrow;
      } on ExternalReferenceUrlException {
        reservation?.close();
        throw const ExternalReferenceLaunchException(
          ExternalReferenceLaunchFailure.staleOrInvalid,
        );
      } catch (_) {
        reservation?.close();
        throw const ExternalReferenceLaunchException(
          ExternalReferenceLaunchFailure.openFailed,
        );
      }
    } on ExternalReferenceLaunchException {
      rethrow;
    } catch (_) {
      throw const ExternalReferenceLaunchException(
        ExternalReferenceLaunchFailure.openFailed,
      );
    }
  }

  Future<ExternalReferenceRecord?> _reload(String referenceId) async {
    try {
      return await referenceLoader(referenceId);
    } catch (_) {
      throw const ExternalReferenceLaunchException(
        ExternalReferenceLaunchFailure.staleOrInvalid,
      );
    }
  }
}
