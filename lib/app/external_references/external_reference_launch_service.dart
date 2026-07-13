import '../storage/local_artwork_repository.dart';
import '../storage/external_reference.dart';
import 'external_reference_launch_gateway.dart';
import 'external_reference_url_codec.dart';

enum ExternalReferenceLaunchFailure { staleOrInvalid, openFailed }

class ExternalReferenceLaunchException implements Exception {
  const ExternalReferenceLaunchException(this.failure);
  final ExternalReferenceLaunchFailure failure;
}

class ExternalReferenceLaunchService {
  const ExternalReferenceLaunchService({
    required this.repository,
    required this.gateway,
    this.urlCodec = const ExternalReferenceUrlCodec(),
  });

  final LocalArtworkRepository repository;
  final ExternalReferenceLaunchGateway gateway;
  final ExternalReferenceUrlCodec urlCodec;

  Future<void> open({
    required String referenceId,
    required String expectedUrl,
  }) async {
    final current = await _reload(referenceId);
    if (current == null || current.url != expectedUrl) {
      throw const ExternalReferenceLaunchException(
        ExternalReferenceLaunchFailure.staleOrInvalid,
      );
    }
    final String canonical;
    try {
      canonical = urlCodec.canonicalize(current.url);
    } on ExternalReferenceUrlException {
      throw const ExternalReferenceLaunchException(
        ExternalReferenceLaunchFailure.staleOrInvalid,
      );
    }
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
    try {
      if (!await gateway.launchExternal(uri)) {
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
      return await repository.getExternalReference(referenceId);
    } catch (_) {
      throw const ExternalReferenceLaunchException(
        ExternalReferenceLaunchFailure.staleOrInvalid,
      );
    }
  }
}
