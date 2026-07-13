import 'dart:io';

import 'package:flutter/services.dart';

/// Frozen v1 contract for app-private attachment byte custody.
///
/// This bridge deliberately has no path-based delete or scan API. Native code
/// derives every destination from opaque identifiers under its platform-owned
/// attachment root. `sourcePath` is a one-time import input only; it is never
/// persisted or used to resolve a destination.
class AttachmentCustodyBridge {
  AttachmentCustodyBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'app.archivale/attachment_custody_v1';
  static final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
  static const _canonicalPayloadNames = <String>{
    'payload.jpg',
    'payload.jpeg',
    'payload.png',
    'payload.heic',
    'payload.heif',
    'payload.pdf',
  };

  final MethodChannel _channel;

  Future<AttachmentCustodyResult> capabilities() => _invoke('capabilities');

  Future<AttachmentCustodyResult> selfTest() => _invoke('selfTest');

  Future<AttachmentCustodyResult> publish({
    required String operationId,
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
    required File sourceFile,
  }) {
    _validatePublication(operationId, artworkId, attachmentId, canonicalName);
    return _invoke('publish', <String, Object?>{
      'operationId': operationId,
      'artworkId': artworkId,
      'attachmentId': attachmentId,
      'canonicalName': canonicalName,
      'sourcePath': sourceFile.path,
    });
  }

  Future<AttachmentCustodyResult> publicationStatus({
    required String operationId,
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
  }) => _publicationOperation(
    'publicationStatus',
    operationId,
    artworkId,
    attachmentId,
    canonicalName,
  );

  Future<AttachmentCustodyResult> recoverPublication({
    required String operationId,
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
  }) => _publicationOperation(
    'recoverPublication',
    operationId,
    artworkId,
    attachmentId,
    canonicalName,
  );

  Future<AttachmentCustodyResult> rollbackPublication({
    required String operationId,
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
  }) => _publicationOperation(
    'rollbackPublication',
    operationId,
    artworkId,
    attachmentId,
    canonicalName,
  );

  Future<AttachmentCustodyResult> cleanupPublication({
    required String operationId,
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
  }) => _publicationOperation(
    'cleanupPublication',
    operationId,
    artworkId,
    attachmentId,
    canonicalName,
  );

  Future<AttachmentCustodyResult> remove({
    required String artworkId,
    required String attachmentId,
    required String canonicalName,
  }) {
    _validateTarget(artworkId, attachmentId, canonicalName);
    return _invoke('remove', <String, Object?>{
      'artworkId': artworkId,
      'attachmentId': attachmentId,
      'canonicalName': canonicalName,
    });
  }

  /// Enumerates only canonical payload geometry and reports unsafe nodes.
  /// Callers must treat `unsafeNode` as blocked work, not as an empty store.
  Future<AttachmentCustodyResult> scan() => _invoke('scan');

  /// Atomically publishes validated v1 erasure control outside attachments.
  Future<AttachmentCustodyResult> writeErasureControl(String operationId) {
    _validateOpaqueId(operationId, 'operation');
    return _invoke('writeErasureControl', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<AttachmentCustodyResult> readErasureControl([String? operationId]) {
    if (operationId == null) return _invoke('readErasureControl');
    _validateOpaqueId(operationId, 'operation');
    return _invoke('readErasureControl', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<AttachmentCustodyResult> recoverErasureControl(String operationId) {
    _validateOpaqueId(operationId, 'operation');
    return _invoke('recoverErasureControl', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<AttachmentCustodyResult> clearErasureControl(String operationId) {
    _validateOpaqueId(operationId, 'operation');
    return _invoke('clearErasureControl', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<AttachmentCustodyResult> cleanupErasureControl(String operationId) {
    _validateOpaqueId(operationId, 'operation');
    return _invoke('cleanupErasureControl', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<AttachmentCustodyResult> _publicationOperation(
    String operation,
    String operationId,
    String artworkId,
    String attachmentId,
    String canonicalName,
  ) {
    _validatePublication(operationId, artworkId, attachmentId, canonicalName);
    return _invoke(operation, <String, Object?>{
      'operationId': operationId,
      'artworkId': artworkId,
      'attachmentId': attachmentId,
      'canonicalName': canonicalName,
    });
  }

  Future<AttachmentCustodyResult> _invoke(
    String operation, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        operation,
        arguments,
      );
      if (response == null) {
        return const AttachmentCustodyResult(
          AttachmentCustodyOutcome.unsupported,
          detail: 'The native custody service returned no result.',
        );
      }
      return AttachmentCustodyResult.fromMap(response);
    } on MissingPluginException {
      return const AttachmentCustodyResult(
        AttachmentCustodyOutcome.unsupported,
        detail: 'Native attachment custody is unavailable on this platform.',
      );
    } on PlatformException catch (error) {
      return AttachmentCustodyResult(
        AttachmentCustodyOutcome.ioFailure,
        detail: error.message ?? 'The native custody service failed.',
      );
    }
  }

  static void _validateTarget(
    String artworkId,
    String attachmentId,
    String canonicalName,
  ) {
    _validateOpaqueId(artworkId, 'artwork');
    _validateOpaqueId(attachmentId, 'attachment');
    if (!_canonicalPayloadNames.contains(canonicalName)) {
      throw ArgumentError.value(
        canonicalName,
        'canonicalName',
        'must be an approved canonical payload name',
      );
    }
  }

  static void _validatePublication(
    String operationId,
    String artworkId,
    String attachmentId,
    String canonicalName,
  ) {
    _validateOpaqueId(operationId, 'operation');
    _validateTarget(artworkId, attachmentId, canonicalName);
  }

  static void _validateOpaqueId(String value, String label) {
    if (!_opaqueId.hasMatch(value)) {
      throw ArgumentError.value(value, label, 'must be an opaque identifier');
    }
  }
}

enum AttachmentCustodyOutcome {
  available,
  published,
  publicationPending,
  publicationPartial,
  publicationRecovered,
  publicationRolledBack,
  publicationAbsent,
  publicationConflict,
  cleanupComplete,
  removed,
  missing,
  erasureOwned,
  erasurePending,
  erasureConflict,
  erasureUnsafe,
  erasureAbsent,
  scanComplete,
  invalidRequest,
  unsafeNode,
  unsupported,
  sourceMissing,
  alreadyExists,
  ioFailure;

  static AttachmentCustodyOutcome fromWire(String? value) {
    return AttachmentCustodyOutcome.values.firstWhere(
      (outcome) => outcome.name == value,
      orElse: () => AttachmentCustodyOutcome.ioFailure,
    );
  }
}

class AttachmentCustodyResult {
  const AttachmentCustodyResult(
    this.outcome, {
    this.detail,
    this.entries = const [],
    this.publications = const [],
    this.owner,
    this.phase,
  });

  factory AttachmentCustodyResult.fromMap(Map<String, Object?> value) {
    final rawEntries = value['entries'];
    final rawPublications = value['publications'];
    return AttachmentCustodyResult(
      AttachmentCustodyOutcome.fromWire(value['outcome'] as String?),
      detail: value['detail'] as String?,
      entries: rawEntries is List
          ? rawEntries
                .whereType<Map>()
                .map(
                  (entry) => AttachmentCustodyEntry.fromMap(
                    entry.cast<String, Object?>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      publications: rawPublications is List
          ? rawPublications
                .whereType<Map>()
                .map(
                  (entry) => AttachmentCustodyPublication.fromMap(
                    entry.cast<String, Object?>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      owner: value['owner'] as String?,
      phase: value['phase'] as String?,
    );
  }

  final AttachmentCustodyOutcome outcome;
  final String? detail;
  final List<AttachmentCustodyEntry> entries;
  final List<AttachmentCustodyPublication> publications;
  final String? owner;
  final String? phase;

  bool get isSuccess => switch (outcome) {
    AttachmentCustodyOutcome.available ||
    AttachmentCustodyOutcome.published ||
    AttachmentCustodyOutcome.publicationRecovered ||
    AttachmentCustodyOutcome.publicationRolledBack ||
    AttachmentCustodyOutcome.publicationAbsent ||
    AttachmentCustodyOutcome.cleanupComplete ||
    AttachmentCustodyOutcome.removed ||
    AttachmentCustodyOutcome.missing ||
    AttachmentCustodyOutcome.erasureOwned ||
    AttachmentCustodyOutcome.erasureAbsent ||
    AttachmentCustodyOutcome.scanComplete => true,
    _ => false,
  };
}

class AttachmentCustodyPublication {
  const AttachmentCustodyPublication({
    required this.operationId,
    required this.artworkId,
    required this.attachmentId,
    required this.canonicalName,
    required this.phase,
    required this.size,
    required this.sha256,
  });

  factory AttachmentCustodyPublication.fromMap(Map<String, Object?> value) {
    return AttachmentCustodyPublication(
      operationId: value['operationId'] as String? ?? '',
      artworkId: value['artworkId'] as String? ?? '',
      attachmentId: value['attachmentId'] as String? ?? '',
      canonicalName: value['canonicalName'] as String? ?? '',
      phase: value['phase'] as String? ?? '',
      size: value['size'] as int? ?? 0,
      sha256: value['sha256'] as String? ?? '',
    );
  }

  final String operationId;
  final String artworkId;
  final String attachmentId;
  final String canonicalName;
  final String phase;
  final int size;
  final String sha256;
}

class AttachmentCustodyEntry {
  const AttachmentCustodyEntry({
    required this.artworkId,
    required this.attachmentId,
    required this.canonicalName,
  });

  factory AttachmentCustodyEntry.fromMap(Map<String, Object?> value) {
    return AttachmentCustodyEntry(
      artworkId: value['artworkId'] as String? ?? '',
      attachmentId: value['attachmentId'] as String? ?? '',
      canonicalName: value['canonicalName'] as String? ?? '',
    );
  }

  final String artworkId;
  final String attachmentId;
  final String canonicalName;
}
