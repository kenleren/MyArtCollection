import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/artwork_group.dart';
import '../storage/external_reference.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'export_artifact_store.dart';
import 'external_reference_export_codec.dart';
import 'archive_v1_codec.dart';
import 'archive_v2_codec.dart';

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
    this.attachmentReadPassHookForTest,
  });

  static const contract = ArchivaleArchiveV2Codec.archiveContract;
  static const version = ArchivaleArchiveV2Codec.version;

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final ExportArtifactStore artifactStore;
  final DateTime Function() clock;
  final void Function(AttachmentRecord record, int completedPass)?
  attachmentReadPassHookForTest;

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
      final totalItems = prepared.included.length + 5;
      final totalBytes = prepared.included.fold<int>(
        0,
        (sum, item) => sum + item.record.fileSizeBytes,
      );
      final artworksJson = const ArchivaleArchiveV1Codec().encodeArtworks(
        snapshot.artworks,
      );
      final externalReferences = const ExternalReferenceExportCodec()
          .encodeSectionValue(snapshot.externalReferences);
      final attachmentsJson = <String, Object?>{
        'contract_version': 'supporting_record_attachment_export_contract_v1',
        'attachments': prepared.entries,
      };
      final groupingsJson = const ArchivaleArchiveV2Codec().encodeGroupings(
        snapshot.groupings,
      );
      final warnings = prepared.warningCodes;
      final contentFiles = <String, Uint8List>{
        'records/artworks.json': artworksJson,
        'records/external_references.json': _utf8(
          _canonicalJson(externalReferences),
        ),
        'records/attachments.json': _utf8(_canonicalJson(attachmentsJson)),
        'records/groupings.json': groupingsJson,
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
          'groups': snapshot.groupings.groups.length,
          'memberships': snapshot.groupings.memberships.length,
          'preferences': snapshot.groupings.preferences.length,
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
        if (await FileSystemEntity.type(item.file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const ExportIntegrityException(
            'A supporting record changed while the archive was being prepared. Please retry.',
          );
        }
        final source = _HashingInputStream(
          InputFileStream(item.file.path),
          onPassComplete: (pass) =>
              attachmentReadPassHookForTest?.call(item.record, pass),
        );
        if (!source.open()) {
          throw const ExportIntegrityException(
            'A supporting record could not be opened safely. Please retry.',
          );
        }
        encoder.addArchiveFile(ArchiveFile.stream(item.payloadPath, source));
        if (source.completedPasses.length < 2 ||
            source.completedPasses.any(
              (digest) =>
                  digest.byteSize != item.record.fileSizeBytes ||
                  digest.checksumSha256 != item.record.checksum,
            )) {
          throw const ExportIntegrityException(
            'A supporting record changed while its exact bytes were being written. Please retry.',
          );
        }
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
      await _verifyCompletedArchive(staging);
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

  Future<void> _verifyCompletedArchive(File staging) async {
    final input = InputFileStream(staging.path);
    if (!input.open()) {
      throw const ExportIntegrityException(
        'The completed archive could not be reopened for verification.',
      );
    }
    Archive? archive;
    try {
      archive = ZipDecoder().decodeStream(input);
      final manifestEntry = archive.findFile('manifest.json');
      if (manifestEntry == null || !manifestEntry.isFile) {
        throw const ExportIntegrityException(
          'The completed archive is missing its manifest.',
        );
      }
      final manifestBytes = manifestEntry.content;
      const ArchivaleArchiveV2Codec().decodeArchive(
        Uint8List.fromList(await staging.readAsBytes()),
      );
      final manifest = jsonDecode(utf8.decode(manifestBytes));
      if (manifest is! Map<String, Object?> ||
          manifest['contract'] != contract ||
          manifest['version'] != version ||
          manifest['files'] is! List) {
        throw const ExportIntegrityException(
          'The completed archive manifest is invalid.',
        );
      }
      final rows = (manifest['files']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final expectedPaths = <String>{'manifest.json'};
      for (final row in rows) {
        final path = row['path'];
        final size = row['size_bytes'];
        final checksum = row['checksum_sha256'];
        if (path is! String ||
            size is! int ||
            checksum is! String ||
            !expectedPaths.add(path)) {
          throw const ExportIntegrityException(
            'The completed archive manifest has duplicate or invalid entries.',
          );
        }
        final entry = archive.findFile(path);
        if (entry == null || !entry.isFile || entry.isSymbolicLink) {
          throw const ExportIntegrityException(
            'The completed archive does not match its manifest.',
          );
        }
        final digest = _digestArchiveEntry(entry);
        if (digest.byteSize != size || digest.checksumSha256 != checksum) {
          throw const ExportIntegrityException(
            'The completed archive bytes do not match its manifest.',
          );
        }
      }
      if (archive.files.length != expectedPaths.length ||
          archive.files.any((entry) => !expectedPaths.contains(entry.name))) {
        throw const ExportIntegrityException(
          'The completed archive contains an unlisted entry.',
        );
      }
    } on ExportIntegrityException {
      rethrow;
    } on Object {
      throw const ExportIntegrityException(
        'The completed archive failed integrity verification.',
      );
    } finally {
      if (archive != null) {
        await archive.clear();
      } else {
        await input.close();
      }
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
    final groupings = await repository.groupingExportData();
    return _ArchiveSnapshot(
      artworks: artworks,
      attachments: attachments,
      externalReferences: references,
      groupings: groupings,
      fingerprint: _snapshotFingerprint(
        artworks,
        attachments,
        references,
        groupings,
      ),
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
  ArtworkGroupingExportData groupings,
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
          'groupings': const ArchivaleArchiveV2Codec().encodeGroupings(
            groupings,
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
    required this.groupings,
    required this.fingerprint,
  });
  final List<ArtworkRecord> artworks;
  final List<AttachmentRecord> attachments;
  final List<ExternalReferenceRecord> externalReferences;
  final ArtworkGroupingExportData groupings;
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

_StreamDigest _digestArchiveEntry(ArchiveFile entry) {
  final raw = entry.rawContent?.getStream(decompress: false);
  if (raw == null) {
    throw const ExportIntegrityException(
      'The completed archive contains an unreadable entry.',
    );
  }
  raw.reset();
  final output = _HashingOutputStream();
  switch (entry.compression) {
    case CompressionType.deflate:
      ZLibDecoder().decodeStream(raw, output, raw: true);
    case CompressionType.none:
    case null:
      output.writeStream(raw);
    default:
      throw const ExportIntegrityException(
        'The completed archive uses an unsupported compression mode.',
      );
  }
  return output.finish();
}

class _HashingInputStream extends InputStream {
  _HashingInputStream(this._delegate, {this.onPassComplete})
    : super(byteOrder: _delegate.byteOrder);

  final InputFileStream _delegate;
  final void Function(int completedPass)? onPassComplete;
  final List<_StreamDigest> completedPasses = [];
  late ByteConversionSink _sink;
  int _passBytes = 0;
  _DigestSink? _currentDigestSink;

  void _ensureSink() {
    if (_currentDigestSink != null) return;
    _currentDigestSink = _DigestSink();
    _sink = sha256.startChunkedConversion(_currentDigestSink!);
  }

  void _add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _ensureSink();
    _sink.add(bytes);
    _passBytes += bytes.length;
  }

  void _finishPass() {
    if (_passBytes == 0) return;
    _sink.close();
    final digest = _currentDigestSink!.digest;
    completedPasses.add(
      _StreamDigest(byteSize: _passBytes, checksumSha256: digest.toString()),
    );
    onPassComplete?.call(completedPasses.length);
    _passBytes = 0;
    _currentDigestSink = null;
  }

  @override
  bool open() => _delegate.open();

  @override
  Future<void> close() async {
    _finishPass();
    await _delegate.close();
  }

  @override
  void closeSync() {
    _finishPass();
    _delegate.closeSync();
  }

  @override
  int get position => _delegate.position;

  @override
  set position(int value) => setPosition(value);

  @override
  int get length => _delegate.length;

  @override
  bool get isEOS => _delegate.isEOS;

  @override
  void reset() {
    if (_delegate.position != 0) _finishPass();
    _delegate.reset();
  }

  @override
  void setPosition(int value) {
    if (value != 0) {
      throw UnsupportedError('Verified export streams only support reset.');
    }
    reset();
  }

  @override
  void rewind([int length = 1]) =>
      throw UnsupportedError('Verified export streams cannot rewind.');

  @override
  void skip(int length) =>
      throw UnsupportedError('Verified export streams cannot skip bytes.');

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) =>
      throw UnsupportedError('Verified export streams cannot expose subsets.');

  @override
  int readByte() {
    final wasEos = _delegate.isEOS;
    final value = _delegate.readByte();
    if (!wasEos) _add([value]);
    return value;
  }

  @override
  InputStream readBytes(int count) {
    final bytes = _delegate.readBytes(count).toUint8List();
    _add(bytes);
    return InputMemoryStream(bytes);
  }

  @override
  Uint8List toUint8List() {
    final bytes = _delegate.toUint8List();
    _delegate.skip(bytes.length);
    _add(bytes);
    return bytes;
  }
}

class _HashingOutputStream extends OutputStream {
  _HashingOutputStream() : super(byteOrder: ByteOrder.littleEndian);

  final _digestSink = _DigestSink();
  late final ByteConversionSink _sink = sha256.startChunkedConversion(
    _digestSink,
  );
  int _length = 0;
  bool _finished = false;

  @override
  int get length => _length;

  @override
  void clear() => throw UnsupportedError('Integrity output cannot be cleared.');

  @override
  void flush() {}

  @override
  void writeByte(int value) => writeBytes([value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count == 0) return;
    final value = count == bytes.length ? bytes : bytes.sublist(0, count);
    _sink.add(value);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final bytes = stream
          .readBytes(stream.length > chunkSize ? chunkSize : stream.length)
          .toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('Integrity output does not retain bytes.');

  _StreamDigest finish() {
    if (!_finished) {
      _sink.close();
      _finished = true;
    }
    return _StreamDigest(
      byteSize: _length,
      checksumSha256: _digestSink.digest.toString(),
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest ?? (throw StateError('Digest is incomplete.'));

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

class _StreamDigest {
  const _StreamDigest({required this.byteSize, required this.checksumSha256});

  final int byteSize;
  final String checksumSha256;
}
