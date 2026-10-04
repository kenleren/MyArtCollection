import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../import/archive_inspection.dart';
import '../import/archive_inspection_json.dart';
import 'backup_record_bundle.dart';
import 'backup_record_codec.dart';
import 'backup_record_schema.dart';
import 'private_backup_envelope.dart';

typedef OpenPrivateBackupPayload =
    Stream<List<int>> Function(PrivateBackupPayload payload);
typedef StagePrivateBackupPayload =
    Future<void> Function(
      PrivateBackupPayload payload,
      Stream<Uint8List> bytes,
    );

/// An authenticated opaque target, never an input path or a filename from a
/// collector document. A controller must own its quarantine before staging.
final class PrivateBackupPayload {
  const PrivateBackupPayload._(
    this.artworkId,
    this.attachmentId,
    this.mimeType,
    this.canonicalName,
    this.length,
    this.sha256,
  );
  final String artworkId;
  final String attachmentId;
  final String mimeType;
  final String canonicalName;
  final int length;
  final String sha256;

  Map<String, Object> _json() => {
    'artworkId': artworkId,
    'attachmentId': attachmentId,
    'mimeType': mimeType,
    'canonicalName': canonicalName,
    'length': length,
    'sha256': sha256,
  };
}

/// Records and a streaming payload plan; no paths, persistence or activation.
final class PrivateBackupContent {
  PrivateBackupContent._(
    this._manifest,
    this._records,
    this.payloads,
    this.omissions,
    this.plaintextLength,
  );
  final Uint8List _manifest;
  final Uint8List _records;
  final List<PrivateBackupPayload> payloads;
  final Map<String, int> omissions;
  final int plaintextLength;

  /// Only feed this into encryption while the archive capture lease is held.
  /// Partial consumption or changed bytes cannot produce a successful seal.
  Stream<Uint8List> stream(
    OpenPrivateBackupPayload openPayload, {
    BackupRecordCancellation? cancellation,
  }) async* {
    final cancel = cancellation ?? BackupRecordCancellation();
    try {
      cancel.check();
      final size = Uint8List(4);
      ByteData.sublistView(size).setUint32(0, _manifest.length);
      yield size;
      for (final bytes in [_manifest, _records]) {
        for (var offset = 0; offset < bytes.length; offset += 65536) {
          cancel.check();
          yield Uint8List.fromList(
            bytes.sublist(offset, min(offset + 65536, bytes.length)),
          );
        }
      }
      for (final payload in payloads) {
        cancel.check();
        final source = PrivateBackupByteReader(openPayload(payload), cancel);
        final digest = _DigestSink();
        final hash = sha256.startChunkedConversion(digest);
        try {
          var remaining = payload.length;
          while (remaining > 0) {
            cancel.check();
            final bytes = await source.readExact(min(65536, remaining));
            cancel.check();
            hash.add(bytes);
            remaining -= bytes.length;
            yield bytes;
          }
          await source.requireEnd();
          cancel.check();
          hash.close();
          if (digest.value?.toString() != payload.sha256) _invalid();
        } finally {
          await source.close();
        }
      }
      cancel.check();
    } on PrivateBackupException {
      cancel.cancel();
      rethrow;
    } on BackupRecordException catch (error) {
      cancel.cancel();
      _recordFailure(error);
    } catch (_) {
      cancel.cancel();
      throw const PrivateBackupException(
        PrivateBackupFailure.sourceUnavailable,
      );
    }
  }
}

/// Fully inspected content stays inert. It grants no database/native write
/// authority and cannot be treated as a completed restore by an app screen.
final class PrivateBackupContentInspection {
  const PrivateBackupContentInspection._(
    this.records,
    this.snapshotId,
    this.snapshotAt,
    this.payloads,
    this.omissions,
  );
  final BackupRecordBundle records;
  final String snapshotId;
  final DateTime snapshotAt;
  final List<PrivateBackupPayload> payloads;
  final Map<String, int> omissions;
  bool get supportsActivation => false;
}

/// V1 content explicitly contains the immutable schema10 records component.
/// A schema11 component must use a separately versioned content contract.
class PrivateBackupContentCodec {
  const PrivateBackupContentCodec();
  static const maxManifestBytes = 512 * 1024;
  static const maxPayloads = 2048;
  static const _format = 'archivale-private-backup-content-v1';
  static final _opaque = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static const _mimes = {
    'image/jpeg': ('payload.jpg', 25 * 1024 * 1024),
    'image/png': ('payload.png', 25 * 1024 * 1024),
    'image/heic': ('payload.heic', 25 * 1024 * 1024),
    'image/heif': ('payload.heif', 25 * 1024 * 1024),
    'application/pdf': ('payload.pdf', 50 * 1024 * 1024),
  };

  Future<PrivateBackupContent> prepare(
    BackupRecordBundle input, {
    required String snapshotId,
    required DateTime snapshotAt,
    BackupRecordCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? BackupRecordCancellation();
    try {
      _validateSnapshot(snapshotId, snapshotAt.toUtc().toIso8601String());
      final bundle = await validateBackupBundle(input, cancel);
      final (payloads, omissions) = _payloadPlan(bundle, cancel);
      final records = await const BackupRecordCodec().encode(
        bundle,
        cancellation: cancel,
      );
      final manifest = Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            _manifest(
              snapshotId,
              snapshotAt.toUtc().toIso8601String(),
              records,
              payloads,
              omissions,
            ),
          ),
        ),
      );
      _limit(manifest.length > maxManifestBytes);
      final length =
          4 +
          manifest.length +
          records.length +
          payloads.fold<int>(0, (n, p) => n + p.length);
      PrivateBackupEnvelope.ciphertextLength(length);
      cancel.check();
      return PrivateBackupContent._(
        manifest,
        records,
        payloads,
        omissions,
        length,
      );
    } on BackupRecordException catch (error) {
      _recordFailure(error);
    }
  }

  /// Call only after durable PREPARING ownership exists. Staging may receive
  /// authenticated chunks before final envelope authentication; none may be
  /// published or activated until this future and controller checks succeed.
  Future<PrivateBackupContentInspection> inspect(
    Stream<List<int>> plaintext, {
    required StagePrivateBackupPayload stagePayload,
    BackupRecordCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? BackupRecordCancellation();
    final reader = PrivateBackupByteReader(plaintext, cancel);
    try {
      cancel.check();
      final length = ByteData.sublistView(
        await reader.readExact(4),
      ).getUint32(0);
      _limit(length > maxManifestBytes);
      if (length == 0) _invalid();
      final bytes = await reader.readExact(length);
      final raw = await decodeInspectionJson(bytes, cancel);
      if (raw is! Map<String, Object?> || raw['format'] != _format) _invalid();
      final snapshotId = raw['snapshotId'], snapshotAt = raw['snapshotAt'];
      if (snapshotId is! String || snapshotAt is! String) _invalid();
      final time = _validateSnapshot(snapshotId, snapshotAt);
      final recordLength = raw['recordLength'];
      if (recordLength is! int || recordLength <= 0) _invalid();
      _limit(recordLength > BackupRecordLimits.bytes);
      final recordsBytes = await reader.readExact(recordLength);
      final bundle = await const BackupRecordCodec().decode(
        recordsBytes,
        cancellation: cancel,
      );
      final (payloads, omissions) = _payloadPlan(bundle, cancel);
      if (!_sameJson(
        raw,
        _manifest(snapshotId, snapshotAt, recordsBytes, payloads, omissions),
      )) {
        _invalid();
      }
      PrivateBackupEnvelope.ciphertextLength(
        4 +
            length +
            recordLength +
            payloads.fold<int>(0, (n, p) => n + p.length),
      );
      for (final payload in payloads) {
        cancel.check();
        var consumed = false;
        Stream<Uint8List> chunks() async* {
          var remaining = payload.length;
          final digest = _DigestSink();
          final hash = sha256.startChunkedConversion(digest);
          while (remaining > 0) {
            cancel.check();
            final bytes = await reader.readExact(min(remaining, 65536));
            cancel.check();
            remaining -= bytes.length;
            hash.add(bytes);
            yield bytes;
          }
          hash.close();
          if (digest.value?.toString() != payload.sha256) _invalid();
          cancel.check();
          consumed = true;
        }

        await _stage(stagePayload(payload, chunks()), cancel);
        cancel.check();
        if (!consumed) _invalid();
      }
      // Exhaust the enclosing decrypted stream: it verifies final tag and EOF.
      await reader.requireEnd();
      cancel.check();
      return PrivateBackupContentInspection._(
        bundle,
        snapshotId,
        time,
        payloads,
        omissions,
      );
    } on PrivateBackupException {
      cancel.cancel();
      rethrow;
    } on BackupRecordException catch (error) {
      cancel.cancel();
      _recordFailure(error);
    } on ArchiveInspectionException catch (error) {
      cancel.cancel();
      if (error.failure == ArchiveInspectionFailure.cancelled) {
        throw const PrivateBackupException(PrivateBackupFailure.cancelled);
      }
      if (error.failure == ArchiveInspectionFailure.unsupportedResourceLimit) {
        throw const PrivateBackupException(PrivateBackupFailure.resourceLimit);
      }
      _invalid();
    } catch (_) {
      cancel.cancel();
      throw const PrivateBackupException(
        PrivateBackupFailure.sourceUnavailable,
      );
    } finally {
      await reader.close();
    }
  }

  static Map<String, Object> _manifest(
    String id,
    String time,
    Uint8List records,
    List<PrivateBackupPayload> payloads,
    Map<String, int> omissions,
  ) => {
    'format': _format,
    'snapshotId': id,
    'snapshotAt': time,
    'recordFormat': 'archivale-record-component-v1',
    'sourceSchema': 10,
    'schemaDigest': backupRecordSchemaDigest,
    'recordLength': records.length,
    'recordSha256': sha256.convert(records).toString(),
    'payloadPolicy': 'eligible_active_only',
    'omissions': omissions,
    'payloads': [for (final p in payloads) p._json()],
  };

  static (List<PrivateBackupPayload>, Map<String, int>) _payloadPlan(
    BackupRecordBundle bundle,
    BackupRecordCancellation cancellation,
  ) {
    if (bundle.diagnostics.isNotEmpty) _invalid();
    for (final row in bundle.tables['artworks']!) {
      if (!_opaque.hasMatch(row.values['artwork_id']! as String)) _invalid();
    }
    final rows = bundle.tables['attachments']!;
    _limit(rows.length > maxPayloads);
    final payloads = <PrivateBackupPayload>[];
    final omissions = {'removed': 0, 'unavailable': 0, 'superseded': 0};
    for (final row in rows) {
      cancellation.check();
      final v = row.values;
      final id = v['attachment_id']! as String;
      final artwork = v['artwork_id']! as String;
      if (!_opaque.hasMatch(id) || !_opaque.hasMatch(artwork)) _invalid();
      final status = v['lifecycle_status']! as String;
      if (status != 'active') {
        if (!omissions.containsKey(status)) _invalid();
        omissions[status] = omissions[status]! + 1;
        continue;
      }
      final mime = v['mime_type']! as String;
      final hash = v['checksum']! as String;
      final length = v['file_size_bytes']! as int;
      final type = _mimes[mime];
      if (!_digest.hasMatch(hash) || type == null || length <= 0) {
        _invalid();
      }
      _limit(length > type.$2);
      payloads.add(
        PrivateBackupPayload._(artwork, id, mime, type.$1, length, hash),
      );
    }
    return (List.unmodifiable(payloads), Map.unmodifiable(omissions));
  }

  static DateTime _validateSnapshot(String id, String time) {
    if (!_uuid.hasMatch(id) || time.length > 40 || !time.endsWith('Z')) {
      _invalid();
    }
    try {
      final value = DateTime.parse(time).toUtc();
      if (value.toIso8601String() != time) _invalid();
      return value;
    } on FormatException {
      _invalid();
    }
  }
}

/// The controller's stager must check the same cancellation/ownership before
/// each write. This bounds waiting; it does not authorize or erase a stage.
Future<void> _stage(Future<void> work, BackupRecordCancellation cancel) async {
  final result = Completer<void>();
  final timer = Timer(PrivateBackupByteReader.readInactivityTimeout, () {
    if (!result.isCompleted) {
      result.completeError(
        const PrivateBackupException(PrivateBackupFailure.sourceUnavailable),
      );
      cancel.cancel();
    }
  });
  cancel.whenCancelled.then((_) {
    if (!result.isCompleted) {
      result.completeError(
        const PrivateBackupException(PrivateBackupFailure.cancelled),
      );
    }
  });
  work.then(
    (_) {
      if (!result.isCompleted) result.complete();
    },
    onError: (Object error, StackTrace _) {
      if (!result.isCompleted) {
        result.completeError(
          error is PrivateBackupException
              ? error
              : const PrivateBackupException(
                  PrivateBackupFailure.sourceUnavailable,
                ),
        );
      }
    },
  );
  try {
    await result.future;
  } finally {
    timer.cancel();
  }
}

bool _sameJson(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        right.keys.every(
          (k) => left.containsKey(k) && _sameJson(left[k], right[k]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (i) => i,
        ).every((i) => _sameJson(left[i], right[i]));
  }
  return left == right;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

void _limit(bool exceeded) {
  if (exceeded) {
    throw const PrivateBackupException(PrivateBackupFailure.resourceLimit);
  }
}

Never _invalid() =>
    throw const PrivateBackupException(PrivateBackupFailure.invalidFormat);
Never _recordFailure(BackupRecordException error) =>
    throw PrivateBackupException(switch (error.failure) {
      BackupRecordFailure.cancelled => PrivateBackupFailure.cancelled,
      BackupRecordFailure.unsupportedResourceLimit =>
        PrivateBackupFailure.resourceLimit,
      BackupRecordFailure.sourceUnavailable =>
        PrivateBackupFailure.sourceUnavailable,
      _ => PrivateBackupFailure.invalidFormat,
    });
