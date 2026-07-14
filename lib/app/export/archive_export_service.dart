import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/external_reference.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'export_artifact_store.dart';
import 'external_reference_export_codec.dart';

class ExportCancelledException implements Exception {
  const ExportCancelledException();
}

class ExportIntegrityException implements Exception {
  const ExportIntegrityException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ExportCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const ExportCancelledException();
  }
}

class ExportProgress {
  const ExportProgress({
    required this.completedItems,
    required this.totalItems,
    required this.bytesProcessed,
    required this.totalBytes,
  });
  final int completedItems;
  final int totalItems;
  final int bytesProcessed;
  final int totalBytes;
  double get fraction => totalItems == 0 ? 1 : completedItems / totalItems;
}

typedef ExportProgressCallback = void Function(ExportProgress progress);

class ArchiveExportService {
  ArchiveExportService({
    required this.repository,
    required this.attachmentStore,
    required this.artifactStore,
    this.clock = DateTime.now,
  });

  static const contract = 'ARCHIVALE_ARCHIVE_V1';
  static const version = 1;

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final ExportArtifactStore artifactStore;
  final DateTime Function() clock;

  Future<ExportArtifact> generate({
    ExportCancellationToken? cancellationToken,
    ExportProgressCallback? onProgress,
  }) async {
    final token = cancellationToken ?? ExportCancellationToken();
    final createdAt = clock().toUtc();
    final id = 'archive-${createdAt.microsecondsSinceEpoch}';
    final staging = await artifactStore.stagingFile(
      ExportArtifactKind.archive,
      id,
    );
    final encoder = ZipFileEncoder();
    var encoderOpen = false;
    try {
      token.throwIfCancelled();
      final snapshot = await _loadSnapshot();
      token.throwIfCancelled();
      final prepared = await _prepareAttachments(
        snapshot.attachments
            .where((attachment) => attachment.isOriginalCapture)
            .toList(growable: false),
        token,
      );
      final totalItems = prepared.included.length + 4;
      final totalBytes = prepared.included.fold<int>(
        0,
        (sum, item) => sum + item.record.fileSizeBytes,
      );
      final artworksJson = _canonicalJson(
        snapshot.artworks.map(_artworkJson).toList(growable: false),
      );
      final externalReferences = const ExternalReferenceExportCodec()
          .encodeSectionValue(snapshot.externalReferences);
      final attachmentsJson = <String, Object?>{
        'contract_version': 'supporting_record_attachment_export_contract_v1',
        'attachments': prepared.entries,
      };
      final warnings = prepared.warningCodes;
      final contentFiles = <String, Uint8List>{
        'records/artworks.json': _utf8(artworksJson),
        'records/external_references.json': _utf8(
          _canonicalJson(externalReferences),
        ),
        'records/attachments.json': _utf8(_canonicalJson(attachmentsJson)),
      };
      final manifest = <String, Object?>{
        'contract': contract,
        'version': version,
        'created_at': createdAt.toIso8601String(),
        'archive_status': warnings.isEmpty ? 'complete' : 'with_warnings',
        'trust_notice':
            'Values are user-provided or source-labeled. Supporting records do not prove authenticity, attribution, provenance, value, ownership, or insurance acceptance.',
        'counts': {
          'artworks': snapshot.artworks.length,
          'external_references': snapshot.externalReferences.length,
          'attachments_included': prepared.included.length,
          'attachments_excluded':
              prepared.entries.length - prepared.included.length,
        },
        'warnings': warnings,
        'files': [
          for (final entry in contentFiles.entries)
            {
              'path': entry.key,
              'size_bytes': entry.value.length,
              'checksum_sha256': sha256.convert(entry.value).toString(),
            },
          for (final item in prepared.included)
            {
              'path': item.payloadPath,
              'size_bytes': item.record.fileSizeBytes,
              'checksum_sha256': item.record.checksum,
            },
        ],
        'exclusions': [
          'generated_reports_and_exports',
          'ai_and_research_job_caches',
          'telemetry',
          'billing_state',
          'credentials_and_device_paths',
        ],
      };

      encoder.create(staging.path, level: ZipFileEncoder.gzip);
      encoderOpen = true;
      encoder.addArchiveFile(
        ArchiveFile.string('manifest.json', _canonicalJson(manifest)),
      );
      var completed = 1;
      onProgress?.call(
        ExportProgress(
          completedItems: completed,
          totalItems: totalItems,
          bytesProcessed: 0,
          totalBytes: totalBytes,
        ),
      );
      for (final entry in contentFiles.entries) {
        token.throwIfCancelled();
        encoder.addArchiveFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
        completed++;
        onProgress?.call(
          ExportProgress(
            completedItems: completed,
            totalItems: totalItems,
            bytesProcessed: 0,
            totalBytes: totalBytes,
          ),
        );
      }
      var bytesProcessed = 0;
      for (final item in prepared.included) {
        token.throwIfCancelled();
        final status = await attachmentStore.payloadStatus(item.record);
        if (status != AttachmentPayloadStatus.available) {
          throw const ExportIntegrityException(
            'A supporting record changed while the archive was being prepared. Please retry.',
          );
        }
        await encoder.addFile(item.file, item.payloadPath);
        bytesProcessed += item.record.fileSizeBytes;
        completed++;
        onProgress?.call(
          ExportProgress(
            completedItems: completed,
            totalItems: totalItems,
            bytesProcessed: bytesProcessed,
            totalBytes: totalBytes,
          ),
        );
      }
      token.throwIfCancelled();
      await _verifySnapshotUnchanged(snapshot);
      await encoder.close();
      encoderOpen = false;
      return artifactStore.commit(
        kind: ExportArtifactKind.archive,
        id: id,
        staging: staging,
        createdAt: createdAt,
        warnings: warnings,
      );
    } on Object {
      if (encoderOpen) {
        try {
          await encoder.close();
        } on Object {
          // The partial output is deleted below; the original error wins.
        }
      }
      await artifactStore.discard(staging);
      rethrow;
    }
  }

  Future<_ArchiveSnapshot> _loadSnapshot() async {
    final artworks = await repository.list();
    final attachments = <AttachmentRecord>[];
    final references = <ExternalReferenceRecord>[];
    for (final artwork in artworks) {
      attachments.addAll(await repository.allAttachmentsForArtwork(artwork.id));
      references.addAll(
        await repository.externalReferencesForArtwork(artwork.id),
      );
    }
    artworks.sort((a, b) => a.id.compareTo(b.id));
    attachments.sort((a, b) => a.id.compareTo(b.id));
    return _ArchiveSnapshot(
      artworks: artworks,
      attachments: attachments,
      externalReferences: references,
      fingerprint: _snapshotFingerprint(artworks, attachments, references),
    );
  }

  Future<void> _verifySnapshotUnchanged(_ArchiveSnapshot before) async {
    final after = await _loadSnapshot();
    if (after.fingerprint != before.fingerprint) {
      throw const ExportIntegrityException(
        'The collection changed while the archive was being prepared. Please retry.',
      );
    }
  }

  Future<_PreparedAttachments> _prepareAttachments(
    List<AttachmentRecord> records,
    ExportCancellationToken token,
  ) async {
    final entries = <Map<String, Object?>>[];
    final included = <_IncludedAttachment>[];
    final warningCodes = <String>{};
    final payloadPaths = <String>{};
    for (final record in records) {
      token.throwIfCancelled();
      final lifecycle = record.lifecycleStatus;
      if (lifecycle == AttachmentLifecycleStatus.superseded ||
          lifecycle == AttachmentLifecycleStatus.removed) {
        final status = lifecycle == AttachmentLifecycleStatus.superseded
            ? 'excluded_superseded'
            : 'excluded_user_removed';
        entries.add(_excludedAttachmentJson(record, status));
        continue;
      }
      final payloadStatus = await attachmentStore.payloadStatus(record);
      if (lifecycle == AttachmentLifecycleStatus.unavailable) {
        final status = payloadStatus == AttachmentPayloadStatus.checksumMismatch
            ? 'excluded_checksum_mismatch'
            : 'excluded_missing';
        entries.add(_excludedAttachmentJson(record, status));
        warningCodes.add(status);
        continue;
      }
      if (payloadStatus != AttachmentPayloadStatus.available) {
        final status = payloadStatus == AttachmentPayloadStatus.checksumMismatch
            ? 'excluded_checksum_mismatch'
            : 'excluded_missing';
        entries.add(_excludedAttachmentJson(record, status));
        warningCodes.add(status);
        continue;
      }
      final extension = _approvedExtension(record.mimeType);
      final payloadPath = 'attachments/${record.id}/payload.$extension';
      _validatePayloadPath(payloadPath, record.id);
      if (!payloadPaths.add(payloadPath)) {
        throw const ExportIntegrityException(
          'Duplicate attachment payload identity prevented archive creation.',
        );
      }
      entries.add({
        'attachment_id': record.id,
        'artwork_id': record.artworkId,
        'attachment_type': record.type.storageValue,
        'attachment_role': record.role.storageValue,
        'file_name': record.fileName,
        'mime_type': record.mimeType,
        'file_size_bytes': record.fileSizeBytes,
        'checksum_sha256': record.checksum,
        'imported_at': record.importedAt.toUtc().toIso8601String(),
        'lifecycle_status': record.lifecycleStatus.storageValue,
        'archive_status': 'included',
        'payload_path': payloadPath,
      });
      included.add(
        _IncludedAttachment(
          record: record,
          file: attachmentStore.fileFor(record),
          payloadPath: payloadPath,
        ),
      );
    }
    return _PreparedAttachments(
      entries: entries,
      included: included,
      warningCodes: warningCodes.toList()..sort(),
    );
  }
}

Map<String, Object?> _artworkJson(ArtworkRecord record) => {
  'artwork_id': record.id,
  'record_state': record.recordState.name,
  'lifecycle_status': record.lifecycleStatus.storageValue,
  'primary_image_attachment_id': record.primaryImageAttachmentId,
  'created_at': record.createdAt.toUtc().toIso8601String(),
  'updated_at': record.updatedAt.toUtc().toIso8601String(),
  'fields': [
    for (final entry
        in (record.fields.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key))))
      {
        'field_key': entry.key,
        'value': entry.value.value,
        'source': entry.value.source.label,
        'source_note': entry.value.note,
        'last_confirmed_at': entry.value.lastConfirmedAt
            ?.toUtc()
            .toIso8601String(),
        'money_amount': entry.value.moneyAmount,
        'money_currency_code': entry.value.moneyCurrencyCode,
      },
  ],
};

Map<String, Object?> _excludedAttachmentJson(
  AttachmentRecord record,
  String archiveStatus,
) => {
  'attachment_id': record.id,
  'artwork_id': record.artworkId,
  'attachment_type': record.type.storageValue,
  'attachment_role': record.role.storageValue,
  'lifecycle_status': record.lifecycleStatus.storageValue,
  'archive_status': archiveStatus,
};

String _approvedExtension(String mimeType) => switch (mimeType) {
  'application/pdf' => 'pdf',
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/heic' => 'heic',
  'image/heif' => 'heif',
  _ => throw const ExportIntegrityException(
    'An attachment has an unsupported archive file type.',
  ),
};

void _validatePayloadPath(String path, String attachmentId) {
  final expected = RegExp(
    '^attachments/${RegExp.escape(attachmentId)}/payload\\.(pdf|jpg|jpeg|png|heic|heif)\$',
  );
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(attachmentId) ||
      !expected.hasMatch(path) ||
      path.contains('..') ||
      path.contains('%') ||
      path.contains(r'\')) {
    throw const ExportIntegrityException(
      'An attachment identity cannot be represented safely in the archive.',
    );
  }
}

String _snapshotFingerprint(
  List<ArtworkRecord> artworks,
  List<AttachmentRecord> attachments,
  List<ExternalReferenceRecord> references,
) => sha256
    .convert(
      _utf8(
        _canonicalJson({
          'artworks': artworks.map(_artworkJson).toList(),
          'attachments': attachments
              .map(
                (record) => {
                  'id': record.id,
                  'artwork_id': record.artworkId,
                  'lifecycle': record.lifecycleStatus.storageValue,
                  'type': record.type.storageValue,
                  'role': record.role.storageValue,
                  'file_name': record.fileName,
                  'mime_type': record.mimeType,
                  'imported_at': record.importedAt.toUtc().toIso8601String(),
                  'checksum': record.checksum,
                  'size': record.fileSizeBytes,
                },
              )
              .toList(),
          'references': const ExternalReferenceExportCodec().encodeSectionValue(
            references,
          ),
        }),
      ),
    )
    .toString();

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));
String _canonicalJson(Object? value) => jsonEncode(value);

class _ArchiveSnapshot {
  const _ArchiveSnapshot({
    required this.artworks,
    required this.attachments,
    required this.externalReferences,
    required this.fingerprint,
  });
  final List<ArtworkRecord> artworks;
  final List<AttachmentRecord> attachments;
  final List<ExternalReferenceRecord> externalReferences;
  final String fingerprint;
}

class _IncludedAttachment {
  const _IncludedAttachment({
    required this.record,
    required this.file,
    required this.payloadPath,
  });
  final AttachmentRecord record;
  final File file;
  final String payloadPath;
}

class _PreparedAttachments {
  const _PreparedAttachments({
    required this.entries,
    required this.included,
    required this.warningCodes,
  });
  final List<Map<String, Object?>> entries;
  final List<_IncludedAttachment> included;
  final List<String> warningCodes;
}
