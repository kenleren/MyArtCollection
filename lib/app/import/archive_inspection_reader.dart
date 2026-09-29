import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../export/archive_v1_codec.dart';
import '../export/archive_v2_codec.dart';
import '../export/external_reference_export_codec.dart';
import 'archive_inspection.dart';
import 'archive_inspection_json.dart';
import 'archive_inspection_zip.dart';

enum ArchiveInspectionPhase { copying, copied, validating, parsing, validated }

/// The caller supplies app-private, backup-excluded scratch space. No live
/// repository or attachment store is opened. All owned scratch is removed
/// before returning a metadata-only result, including on cancellation/failure.
class ArchiveInspectionReader {
  const ArchiveInspectionReader({required this.scratchDirectory});
  final Directory scratchDirectory;

  Future<ArchiveInspection> inspect(
    File source, {
    ArchiveInspectionCancellation? cancellation,
    FutureOr<void> Function(ArchiveInspectionPhase)? onPhase,
  }) async {
    final token = cancellation ?? ArchiveInspectionCancellation();
    Directory? owned;
    RandomAccessFile? snapshot;
    try {
      token.check();
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        invalidInspection();
      }
      final initial = await source.stat();
      inspectionLimit(initial.size > ArchiveInspectionLimits.inputBytes);
      await onPhase?.call(ArchiveInspectionPhase.copying);
      token.check();
      owned = await scratchDirectory.createTemp('archive-inspection-');
      final copy = File('${owned.path}/input.zip');
      final destination = await copy.open(mode: FileMode.write);
      late _Fingerprint fingerprint;
      try {
        fingerprint = await _hashFile(source, token, destination: destination);
        await destination.flush();
      } finally {
        await destination.close();
      }
      await onPhase?.call(ArchiveInspectionPhase.copied);
      token.check();
      snapshot = await copy.open();
      await onPhase?.call(ArchiveInspectionPhase.validating);
      final entries = await InspectionZipReader(
        snapshot,
        fingerprint.bytes,
        token,
      ).read();
      await onPhase?.call(ArchiveInspectionPhase.parsing);
      final result = await _validate(entries, fingerprint, token);
      await onPhase?.call(ArchiveInspectionPhase.validated);
      token.check();
      // Bind all reads to the privately copied bytes, then reject source or
      // snapshot mutation. No pathname-based payload capability is returned.
      final snapshotAfter = await _hashFile(copy, token);
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const ArchiveInspectionException(
          ArchiveInspectionFailure.sourceChanged,
        );
      }
      final sourceAfter = await _hashFile(source, token);
      final finalStat = await source.stat();
      if (snapshotAfter != fingerprint ||
          sourceAfter != fingerprint ||
          finalStat.size != initial.size ||
          finalStat.modified != initial.modified ||
          finalStat.changed != initial.changed ||
          await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const ArchiveInspectionException(
          ArchiveInspectionFailure.sourceChanged,
        );
      }
      token.check();
      return result;
    } on ArchiveInspectionException {
      rethrow;
    } on FileSystemException {
      throw const ArchiveInspectionException(
        ArchiveInspectionFailure.ioFailure,
      );
    } on Object {
      // Never surface parser/provider paths or raw archive contents as errors.
      throw const ArchiveInspectionException(
        ArchiveInspectionFailure.invalidArchive,
      );
    } finally {
      try {
        try {
          await snapshot?.close();
        } finally {
          if (owned != null) await owned.delete(recursive: true);
        }
      } on FileSystemException {
        throw const ArchiveInspectionException(
          ArchiveInspectionFailure.ioFailure,
        );
      }
    }
  }
}

Future<_Fingerprint> _hashFile(
  File file,
  ArchiveInspectionCancellation token, {
  RandomAccessFile? destination,
}) async {
  final input = await file.open();
  final digest = InspectionDigestSink();
  final hash = sha256.startChunkedConversion(digest);
  var count = 0;
  try {
    inspectionLimit(await input.length() > ArchiveInspectionLimits.inputBytes);
    while (true) {
      token.check();
      final chunk = await input.read(
        min(
          ArchiveInspectionLimits.bufferBytes,
          ArchiveInspectionLimits.inputBytes - count + 1,
        ),
      );
      if (chunk.isEmpty) break;
      count += chunk.length;
      inspectionLimit(count > ArchiveInspectionLimits.inputBytes);
      hash.add(chunk);
      if (destination != null) await destination.writeFrom(chunk);
    }
    hash.close();
    return _Fingerprint(count, digest.value!.toString());
  } finally {
    await input.close();
  }
}

class _Fingerprint {
  const _Fingerprint(this.bytes, this.sha);
  final int bytes;
  final String sha;
  @override
  bool operator ==(Object other) =>
      other is _Fingerprint && bytes == other.bytes && sha == other.sha;
  @override
  int get hashCode => Object.hash(bytes, sha);
}

Future<ArchiveInspection> _validate(
  List<InspectedZipEntry> entries,
  _Fingerprint source,
  ArchiveInspectionCancellation token,
) async {
  final byName = {for (final entry in entries) entry.name: entry};
  final objects = <String, Map<String, Object?>>{};
  for (final path in inspectionStructuredPaths) {
    final bytes = byName[path]?.metadata;
    if (bytes == null) invalidInspection();
    final value = await decodeInspectionJson(bytes, token);
    if (value is! Map<String, Object?>) invalidInspection();
    if (path == 'manifest.json' &&
        (value['contract'] != ArchivaleArchiveV2Codec.archiveContract ||
            value['version'] != 2)) {
      throw const ArchiveInspectionException(
        ArchiveInspectionFailure.unsupportedVersion,
      );
    }
    objects[path] = value;
  }
  Uint8List bytes(String path) => byName[path]!.metadata!;
  final root = objects['manifest.json']!;
  const v2 = ArchivaleArchiveV2Codec();
  const v1 = ArchivaleArchiveV1Codec();
  v2.decodeManifest(bytes('manifest.json'));
  v1.decodeArtworks(bytes('records/artworks.json'));
  const ExternalReferenceExportCodec().decodeStandalone(
    bytes('records/external_references.json'),
  );
  final attachmentRows = v1.decodeAttachmentOutcomes(
    bytes('records/attachments.json'),
  );
  v2.decodeGroupings(bytes('records/groupings.json'));
  final fileRows = _rows(root['files']);
  if (!_same(entries.map((e) => e.name).toList(), [
    'manifest.json',
    ...fileRows.map((e) => e['path']),
  ])) {
    invalidInspection();
  }
  for (final row in fileRows) {
    final entry = byName[row['path']];
    if (entry == null ||
        entry.expanded != row['size_bytes'] ||
        entry.sha256Hex != row['checksum_sha256']) {
      invalidInspection();
    }
  }
  if (root['trust_notice'] is! String ||
      !_same(root['exclusions'], const [
        'generated_reports_and_exports',
        'ai_and_research_job_caches',
        'telemetry',
        'billing_state',
        'credentials_and_device_paths',
      ])) {
    invalidInspection();
  }
  final warnings =
      attachmentRows
          .map((r) => r['archive_status'])
          .where(
            (s) => s == 'excluded_missing' || s == 'excluded_checksum_mismatch',
          )
          .toSet()
          .toList()
        ..sort((a, b) => (a as String).compareTo(b as String));
  if (!_same(root['warnings'], warnings) ||
      root['archive_status'] !=
          (warnings.isEmpty ? 'complete' : 'with_warnings')) {
    invalidInspection();
  }

  final artworks = _rows(objects['records/artworks.json']!['artworks']);
  final references = _rows(
    objects['records/external_references.json']!['references'],
  );
  final grouping = objects['records/groupings.json']!;
  final groups = _rows(grouping['groups']);
  final memberships = _rows(grouping['memberships']);
  final preferences = _rows(grouping['preferences']);
  final artworkIds = artworks.map((r) => r['artwork_id']).toSet();
  final groupIds = groups.map((r) => r['group_id']).toSet();
  if (groupIds.length != groups.length) invalidInspection();
  final attachmentById = {
    for (final row in attachmentRows) row['attachment_id']: row,
  };
  final rows = <InspectedArchiveRow>[];
  final attachments = <InspectedArchiveAttachment>[];
  final relations = <InspectedArchiveRelationship>[];
  void relation(String kind, String subject, {bool unprovable = false}) =>
      relations.add(
        InspectedArchiveRelationship(
          kind,
          subject,
          unprovable
              ? ArchiveRelationshipCoverage.unprovableFromVersion
              : ArchiveRelationshipCoverage.verified,
        ),
      );
  void child(Map<String, Object?> row, String kind, String id) {
    if (!artworkIds.contains(row['artwork_id'])) invalidInspection();
    relation(kind, id);
  }

  for (final artwork in artworks) {
    token.check();
    final id = artwork['artwork_id'] as String;
    rows.add(InspectedArchiveRow('artworks', id, artwork));
    for (final field in _rows(artwork['fields'])) {
      rows.add(
        InspectedArchiveRow('artwork_fields', '$id/${field['field_key']}', {
          ...field,
          'artwork_id': id,
          'source_state': field['source'],
        }),
      );
    }
    final primaryId = artwork['primary_image_attachment_id'];
    if (primaryId != null) {
      final primary = attachmentById[primaryId];
      if (primary != null &&
          (primary['artwork_id'] != id ||
              primary['attachment_type'] != 'photo' ||
              primary['attachment_role'] != 'primary_artwork_photo')) {
        invalidInspection();
      }
      relation('primary_image', id, unprovable: primary == null);
    }
  }
  final indexedPayloads = <String>{};
  for (final entry in attachmentRows) {
    token.check();
    final id = entry['attachment_id'] as String;
    child(entry, 'attachment_artwork', id);
    final row = InspectedArchiveRow('attachments', id, {
      ...entry,
      if (entry.containsKey('checksum_sha256'))
        'checksum': entry['checksum_sha256'],
    });
    rows.add(row);
    final status = entry['archive_status'] as String;
    final path = entry['payload_path'] as String?;
    if (status == 'included') {
      final payload = byName[path];
      if (path == null ||
          !indexedPayloads.add(path) ||
          payload == null ||
          payload.expanded != entry['file_size_bytes'] ||
          payload.sha256Hex != entry['checksum_sha256']) {
        invalidInspection();
      }
    }
    attachments.add(
      InspectedArchiveAttachment(
        row: row,
        archiveStatus: status,
        payloadPath: path,
        payloadCoverage: status == 'included'
            ? ArchivePayloadCoverage.included
            : status == 'excluded_superseded' ||
                  status == 'excluded_user_removed'
            ? ArchivePayloadCoverage.excludedByLifecycle
            : ArchivePayloadCoverage.unavailable,
      ),
    );
    relation('attachment_lineage', id, unprovable: true);
    relation('attachment_supersession', id, unprovable: true);
  }
  if (byName.keys
      .where((p) => p.startsWith('attachments/'))
      .toSet()
      .difference(indexedPayloads)
      .isNotEmpty) {
    invalidInspection();
  }
  for (final row in references) {
    final id = row['reference_id'] as String;
    child(row, 'reference_artwork', id);
    rows.add(InspectedArchiveRow('external_references', id, row));
  }
  for (final row in groups) {
    rows.add(
      InspectedArchiveRow('artwork_groups', row['group_id'] as String, row),
    );
  }
  for (final row in memberships) {
    final id = '${row['artwork_id']}/${row['group_id']}';
    child(row, 'membership_artwork', id);
    if (!groupIds.contains(row['group_id'])) invalidInspection();
    relation('membership_group', id);
    rows.add(InspectedArchiveRow('artwork_group_memberships', id, row));
  }
  for (final row in preferences) {
    final id = row['artwork_id'] as String;
    child(row, 'preference_artwork', id);
    rows.add(InspectedArchiveRow('artwork_preferences', id, row));
  }
  final counts = root['counts'] as Map<String, Object?>;
  final included = attachments
      .where((a) => a.payloadCoverage == ArchivePayloadCoverage.included)
      .length;
  final actualCounts = {
    'artworks': artworks.length,
    'external_references': references.length,
    'attachments_included': included,
    'attachments_excluded': attachments.length - included,
    'groups': groups.length,
    'memberships': memberships.length,
    'preferences': preferences.length,
  };
  if (actualCounts.entries.any((e) => counts[e.key] != e.value)) {
    invalidInspection();
  }
  return ArchiveInspection(
    sourceSha256: source.sha,
    sourceBytes: source.bytes,
    createdAt: DateTime.parse(root['created_at'] as String),
    rows: rows,
    attachments: attachments,
    relationships: relations,
  );
}

List<Map<String, Object?>> _rows(Object? value) {
  if (value is! List<Object?>) invalidInspection();
  return value.cast<Map<String, Object?>>();
}

bool _same(Object? left, List<Object?> right) {
  if (left is! List<Object?> || left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
