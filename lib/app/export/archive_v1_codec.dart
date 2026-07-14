import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../storage/artwork_record.dart';
import '../storage/external_reference.dart';
import 'external_reference_export_codec.dart';

class ArchiveV1FormatException implements Exception {
  const ArchiveV1FormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DecodedArchivaleArchiveV1 {
  const DecodedArchivaleArchiveV1({
    required this.manifest,
    required this.artworks,
    required this.externalReferences,
    required this.attachmentOutcomes,
    required this.payloads,
  });

  final Map<String, Object?> manifest;
  final List<ArtworkRecord> artworks;
  final List<ExternalReferenceRecord> externalReferences;
  final List<Map<String, Object?>> attachmentOutcomes;
  final Map<String, Uint8List> payloads;
}

class ArchivaleArchiveV1Codec {
  const ArchivaleArchiveV1Codec({
    this.externalReferenceCodec = const ExternalReferenceExportCodec(),
  });

  static const archiveContract = 'ARCHIVALE_ARCHIVE_V1';
  static const artworkContract = 'ARCHIVALE_ARTWORK_RECORDS_V1';
  static const version = 1;
  static const attachmentContract =
      'supporting_record_attachment_export_contract_v1';

  final ExternalReferenceExportCodec externalReferenceCodec;

  Uint8List encodeArtworks(List<ArtworkRecord> artworks) {
    final sorted = List<ArtworkRecord>.of(artworks)
      ..sort((left, right) => left.id.compareTo(right.id));
    final ids = <String>{};
    for (final artwork in sorted) {
      _validateOpaqueId(artwork.id, 'artwork_id');
      if (!ids.add(artwork.id)) {
        throw const ArchiveV1FormatException(
          'Artwork identifiers must be unique.',
        );
      }
    }
    return _utf8(
      _canonicalJson({
        'contract': artworkContract,
        'version': version,
        'artworks': sorted.map(_encodeArtwork).toList(growable: false),
      }),
    );
  }

  List<ArtworkRecord> decodeArtworks(Uint8List bytes) {
    final root = _decodeCanonicalObject(bytes, 'Artwork records');
    _requireExactKeys(root, const ['contract', 'version', 'artworks']);
    if (root['contract'] != artworkContract || root['version'] != version) {
      throw const ArchiveV1FormatException(
        'Artwork record contract or version is unsupported.',
      );
    }
    final rows = root['artworks'];
    if (rows is! List<Object?>) {
      throw const ArchiveV1FormatException('Artwork rows must be a list.');
    }
    final artworks = rows.map(_decodeArtwork).toList(growable: false);
    final canonical = encodeArtworks(artworks);
    if (!_bytesEqual(bytes, canonical)) {
      throw const ArchiveV1FormatException(
        'Artwork record bytes are not canonical.',
      );
    }
    return List.unmodifiable(artworks);
  }

  Map<String, Object?> decodeManifest(Uint8List bytes) {
    final root = _decodeCanonicalObject(bytes, 'Archive manifest');
    _requireExactKeys(root, const [
      'contract',
      'version',
      'created_at',
      'archive_status',
      'trust_notice',
      'counts',
      'warnings',
      'files',
      'exclusions',
    ]);
    if (root['contract'] != archiveContract || root['version'] != version) {
      throw const ArchiveV1FormatException(
        'Archive contract or version is unsupported.',
      );
    }
    _canonicalTimestamp(_string(root, 'created_at'));
    if (root['archive_status'] != 'complete' &&
        root['archive_status'] != 'with_warnings') {
      throw const ArchiveV1FormatException('Archive status is invalid.');
    }
    _string(root, 'trust_notice');
    final counts = _object(root['counts'], 'Archive counts');
    _requireExactKeys(counts, const [
      'artworks',
      'external_references',
      'attachments_included',
      'attachments_excluded',
    ]);
    for (final value in counts.values) {
      if (value is! int || value < 0) {
        throw const ArchiveV1FormatException(
          'Archive counts must be non-negative integers.',
        );
      }
    }
    final warnings = _stringList(root['warnings'], 'Archive warnings');
    if (!_isStrictlySorted(warnings)) {
      throw const ArchiveV1FormatException(
        'Archive warning codes must be sorted and unique.',
      );
    }
    const warningAllowlist = {'excluded_missing', 'excluded_checksum_mismatch'};
    if (warnings.any((warning) => !warningAllowlist.contains(warning)) ||
        (warnings.isEmpty) != (root['archive_status'] == 'complete')) {
      throw const ArchiveV1FormatException(
        'Archive status or warning codes are inconsistent.',
      );
    }
    final files = root['files'];
    if (files is! List<Object?>) {
      throw const ArchiveV1FormatException('Archive files must be a list.');
    }
    final paths = <String>{};
    final orderedPaths = <String>[];
    for (final value in files) {
      final row = _object(value, 'Archive file');
      _requireExactKeys(row, const ['path', 'size_bytes', 'checksum_sha256']);
      final path = _string(row, 'path');
      _validateArchivePath(path);
      if (!paths.add(path)) {
        throw const ArchiveV1FormatException(
          'Archive manifest paths must be unique.',
        );
      }
      orderedPaths.add(path);
      if (row['size_bytes'] is! int || (row['size_bytes']! as int) < 0) {
        throw const ArchiveV1FormatException('Archive file size is invalid.');
      }
      _validateChecksum(_string(row, 'checksum_sha256'));
    }
    const structuredPaths = [
      'records/artworks.json',
      'records/external_references.json',
      'records/attachments.json',
    ];
    if (orderedPaths.length < structuredPaths.length ||
        !_listEquals(
          orderedPaths.take(structuredPaths.length).toList(),
          structuredPaths,
        )) {
      throw const ArchiveV1FormatException(
        'Archive structured files are missing or out of order.',
      );
    }
    final payloadPaths = orderedPaths.skip(structuredPaths.length).toList();
    final sortedPayloadPaths = List<String>.of(payloadPaths)..sort();
    if (!_listEquals(payloadPaths, sortedPayloadPaths) ||
        payloadPaths.any((path) => !path.startsWith('attachments/'))) {
      throw const ArchiveV1FormatException(
        'Archive payload files are not in canonical order.',
      );
    }
    final exclusions = _stringList(root['exclusions'], 'Archive exclusions');
    const expectedExclusions = [
      'generated_reports_and_exports',
      'ai_and_research_job_caches',
      'telemetry',
      'billing_state',
      'credentials_and_device_paths',
    ];
    if (!_listEquals(exclusions, expectedExclusions)) {
      throw const ArchiveV1FormatException(
        'Archive exclusions do not match v1.',
      );
    }
    if (!_bytesEqual(bytes, _utf8(_canonicalJson(root)))) {
      throw const ArchiveV1FormatException(
        'Archive manifest bytes are not canonical.',
      );
    }
    return root;
  }

  List<Map<String, Object?>> decodeAttachmentOutcomes(Uint8List bytes) {
    final root = _decodeCanonicalObject(bytes, 'Attachment index');
    _requireExactKeys(root, const ['contract_version', 'attachments']);
    if (root['contract_version'] != attachmentContract) {
      throw const ArchiveV1FormatException(
        'Attachment contract version is unsupported.',
      );
    }
    final rows = root['attachments'];
    if (rows is! List<Object?>) {
      throw const ArchiveV1FormatException('Attachment rows must be a list.');
    }
    final outcomes = <Map<String, Object?>>[];
    final ids = <String>{};
    for (final value in rows) {
      final row = _object(value, 'Attachment row');
      final status = _string(row, 'archive_status');
      if (status == 'included') {
        _requireExactKeys(row, const [
          'attachment_id',
          'artwork_id',
          'attachment_type',
          'attachment_role',
          'file_name',
          'mime_type',
          'file_size_bytes',
          'checksum_sha256',
          'imported_at',
          'lifecycle_status',
          'archive_status',
          'payload_path',
        ]);
        _string(row, 'file_name');
        final mimeType = _string(row, 'mime_type');
        if (row['file_size_bytes'] is! int ||
            (row['file_size_bytes']! as int) < 0) {
          throw const ArchiveV1FormatException(
            'Attachment payload size is invalid.',
          );
        }
        _validateChecksum(_string(row, 'checksum_sha256'));
        _canonicalTimestamp(_string(row, 'imported_at'));
        final path = _string(row, 'payload_path');
        _validateAttachmentPayloadPath(
          path,
          _string(row, 'attachment_id'),
          mimeType,
        );
        if (row['lifecycle_status'] != 'active') {
          throw const ArchiveV1FormatException(
            'Only active attachments can be included.',
          );
        }
      } else {
        _requireExactKeys(row, const [
          'attachment_id',
          'artwork_id',
          'attachment_type',
          'attachment_role',
          'lifecycle_status',
          'archive_status',
        ]);
        const excluded = {
          'excluded_missing',
          'excluded_checksum_mismatch',
          'excluded_superseded',
          'excluded_user_removed',
        };
        if (!excluded.contains(status)) {
          throw const ArchiveV1FormatException(
            'Attachment archive status is invalid.',
          );
        }
        final lifecycle = row['lifecycle_status'];
        final consistent = switch (status) {
          'excluded_superseded' => lifecycle == 'superseded',
          'excluded_user_removed' => lifecycle == 'removed',
          _ => lifecycle == 'active' || lifecycle == 'unavailable',
        };
        if (!consistent) {
          throw const ArchiveV1FormatException(
            'Attachment lifecycle and archive status are inconsistent.',
          );
        }
      }
      final id = _string(row, 'attachment_id');
      _validateOpaqueId(id, 'attachment_id');
      _validateOpaqueId(_string(row, 'artwork_id'), 'artwork_id');
      if (!ids.add(id)) {
        throw const ArchiveV1FormatException(
          'Attachment identifiers must be unique.',
        );
      }
      _validateAttachmentEnumValues(row);
      outcomes.add(Map.unmodifiable(row));
    }
    final sortedIds =
        outcomes.map((row) => row['attachment_id']! as String).toList()..sort();
    if (!_listEquals(
      outcomes.map((row) => row['attachment_id']! as String).toList(),
      sortedIds,
    )) {
      throw const ArchiveV1FormatException(
        'Attachment rows are not in canonical order.',
      );
    }
    if (!_bytesEqual(bytes, _utf8(_canonicalJson(root)))) {
      throw const ArchiveV1FormatException(
        'Attachment index bytes are not canonical.',
      );
    }
    return List.unmodifiable(outcomes);
  }

  DecodedArchivaleArchiveV1 decodeArchive(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object {
      throw const ArchiveV1FormatException('Archive ZIP data is corrupt.');
    }
    final entries = <String, Uint8List>{};
    for (final file in archive.files) {
      _validateArchivePath(file.name);
      if (!file.isFile || entries.containsKey(file.name)) {
        throw const ArchiveV1FormatException(
          'Archive entries must be unique files.',
        );
      }
      entries[file.name] = Uint8List.fromList(file.content as List<int>);
    }
    final manifestBytes = entries['manifest.json'];
    if (manifestBytes == null) {
      throw const ArchiveV1FormatException('Archive manifest is missing.');
    }
    final manifest = decodeManifest(manifestBytes);
    final fileRows = (manifest['files']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final expectedPaths = {'manifest.json'};
    for (final row in fileRows) {
      final path = row['path']! as String;
      expectedPaths.add(path);
      final content = entries[path];
      if (content == null ||
          content.length != row['size_bytes'] ||
          sha256.convert(content).toString() != row['checksum_sha256']) {
        throw const ArchiveV1FormatException(
          'Archive file size or checksum does not match the manifest.',
        );
      }
    }
    if (entries.keys.toSet().difference(expectedPaths).isNotEmpty ||
        expectedPaths.difference(entries.keys.toSet()).isNotEmpty) {
      throw const ArchiveV1FormatException(
        'Archive entries do not match the manifest.',
      );
    }
    final artworkBytes = entries['records/artworks.json'];
    final referenceBytes = entries['records/external_references.json'];
    final attachmentBytes = entries['records/attachments.json'];
    if (artworkBytes == null ||
        referenceBytes == null ||
        attachmentBytes == null) {
      throw const ArchiveV1FormatException(
        'Archive structured records are incomplete.',
      );
    }
    final artworks = decodeArtworks(artworkBytes);
    final references = _decodeExternalReferences(referenceBytes);
    final attachmentOutcomes = decodeAttachmentOutcomes(attachmentBytes);
    final artworkIds = artworks.map((record) => record.id).toSet();
    if (references.any((record) => !artworkIds.contains(record.artworkId)) ||
        attachmentOutcomes.any(
          (row) => !artworkIds.contains(row['artwork_id']),
        )) {
      throw const ArchiveV1FormatException(
        'Archive child records reference an unknown artwork.',
      );
    }
    final payloads = <String, Uint8List>{};
    final indexedPayloadPaths = <String>{};
    for (final row in attachmentOutcomes) {
      if (row['archive_status'] != 'included') continue;
      final path = row['payload_path']! as String;
      if (!indexedPayloadPaths.add(path)) {
        throw const ArchiveV1FormatException(
          'Attachment payload paths must be unique.',
        );
      }
      final payload = entries[path];
      if (payload == null ||
          payload.length != row['file_size_bytes'] ||
          sha256.convert(payload).toString() != row['checksum_sha256']) {
        throw const ArchiveV1FormatException(
          'Attachment payload does not match its index.',
        );
      }
      payloads[path] = payload;
    }
    final manifestPayloadPaths = fileRows
        .map((row) => row['path']! as String)
        .where((path) => path.startsWith('attachments/'))
        .toSet();
    if (manifestPayloadPaths.difference(indexedPayloadPaths).isNotEmpty ||
        indexedPayloadPaths.difference(manifestPayloadPaths).isNotEmpty) {
      throw const ArchiveV1FormatException(
        'Attachment payload entries do not match the index.',
      );
    }
    final counts = manifest['counts']! as Map<String, Object?>;
    final includedCount = attachmentOutcomes
        .where((row) => row['archive_status'] == 'included')
        .length;
    if (counts['artworks'] != artworks.length ||
        counts['external_references'] != references.length ||
        counts['attachments_included'] != includedCount ||
        counts['attachments_excluded'] !=
            attachmentOutcomes.length - includedCount) {
      throw const ArchiveV1FormatException(
        'Archive counts do not match its records.',
      );
    }
    return DecodedArchivaleArchiveV1(
      manifest: Map.unmodifiable(manifest),
      artworks: artworks,
      externalReferences: references,
      attachmentOutcomes: attachmentOutcomes,
      payloads: Map.unmodifiable(payloads),
    );
  }

  Map<String, Object?> _encodeArtwork(ArtworkRecord record) => {
    'artwork_id': record.id,
    'record_state': record.recordState.name,
    'lifecycle_status': record.lifecycleStatus.storageValue,
    'primary_image_attachment_id': record.primaryImageAttachmentId,
    'created_at': record.createdAt.toUtc().toIso8601String(),
    'updated_at': record.updatedAt.toUtc().toIso8601String(),
    'fields': [
      for (final entry
          in (record.fields.entries.toList()
            ..sort((left, right) => left.key.compareTo(right.key))))
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

  ArtworkRecord _decodeArtwork(Object? value) {
    final row = _object(value, 'Artwork row');
    _requireExactKeys(row, const [
      'artwork_id',
      'record_state',
      'lifecycle_status',
      'primary_image_attachment_id',
      'created_at',
      'updated_at',
      'fields',
    ]);
    final id = _string(row, 'artwork_id');
    _validateOpaqueId(id, 'artwork_id');
    final recordStateText = _string(row, 'record_state');
    final recordStates = ArtworkRecordState.values.map((value) => value.name);
    if (!recordStates.contains(recordStateText)) {
      throw const ArchiveV1FormatException('Artwork record state is invalid.');
    }
    final lifecycleText = _string(row, 'lifecycle_status');
    final lifecycles = ArtworkLifecycleStatus.values.map(
      (value) => value.storageValue,
    );
    if (!lifecycles.contains(lifecycleText)) {
      throw const ArchiveV1FormatException(
        'Artwork lifecycle status is invalid.',
      );
    }
    final primary = row['primary_image_attachment_id'];
    if (primary != null && primary is! String) {
      throw const ArchiveV1FormatException(
        'Primary image attachment identity has the wrong type.',
      );
    }
    if (primary is String) {
      _validateOpaqueId(primary, 'primary_image_attachment_id');
    }
    final fieldsValue = row['fields'];
    if (fieldsValue is! List<Object?>) {
      throw const ArchiveV1FormatException('Artwork fields must be a list.');
    }
    final fields = <String, ArtworkFieldValue>{};
    for (final value in fieldsValue) {
      final field = _object(value, 'Artwork field');
      _requireExactKeys(field, const [
        'field_key',
        'value',
        'source',
        'source_note',
        'last_confirmed_at',
        'money_amount',
        'money_currency_code',
      ]);
      final key = _string(field, 'field_key');
      if (key.isEmpty || fields.containsKey(key)) {
        throw const ArchiveV1FormatException(
          'Artwork field keys must be non-empty and unique.',
        );
      }
      final sourceText = _string(field, 'source');
      final sources = ArtworkFieldSource.values.map((value) => value.label);
      if (!sources.contains(sourceText)) {
        throw const ArchiveV1FormatException(
          'Artwork field source is invalid.',
        );
      }
      final confirmedAt = _nullableString(field, 'last_confirmed_at');
      final moneyAmount = _nullableString(field, 'money_amount');
      final moneyCurrency = _nullableString(field, 'money_currency_code');
      fields[key] = ArtworkFieldValue(
        value: _string(field, 'value'),
        source: ArtworkFieldSource.values.singleWhere(
          (value) => value.label == sourceText,
        ),
        note: _string(field, 'source_note'),
        lastConfirmedAt: confirmedAt == null
            ? null
            : _canonicalTimestamp(confirmedAt),
        moneyAmount: moneyAmount,
        moneyCurrencyCode: moneyCurrency,
      );
    }
    final sortedKeys = fields.keys.toList()..sort();
    if (!_listEquals(fields.keys.toList(), sortedKeys)) {
      throw const ArchiveV1FormatException(
        'Artwork fields are not in canonical order.',
      );
    }
    return ArtworkRecord(
      id: id,
      recordState: ArtworkRecordState.values.singleWhere(
        (value) => value.name == recordStateText,
      ),
      lifecycleStatus: ArtworkLifecycleStatus.values.singleWhere(
        (value) => value.storageValue == lifecycleText,
      ),
      primaryImageAttachmentId: primary as String?,
      createdAt: _canonicalTimestamp(_string(row, 'created_at')),
      updatedAt: _canonicalTimestamp(_string(row, 'updated_at')),
      fields: Map.unmodifiable(fields),
    );
  }

  List<ExternalReferenceRecord> _decodeExternalReferences(Uint8List bytes) {
    try {
      return externalReferenceCodec.decodeStandalone(bytes);
    } on ExternalReferenceExportException catch (error) {
      throw ArchiveV1FormatException(error.message);
    }
  }
}

Map<String, Object?> _decodeCanonicalObject(Uint8List bytes, String label) {
  final String source;
  try {
    source = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw ArchiveV1FormatException('$label is not valid UTF-8.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw ArchiveV1FormatException('$label is not valid JSON.');
  }
  return _object(decoded, label);
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw ArchiveV1FormatException('$label must be an object.');
  }
  return value;
}

void _requireExactKeys(Map<String, Object?> value, List<String> expected) {
  if (!_listEquals(value.keys.toList(), expected)) {
    throw const ArchiveV1FormatException(
      'Archive fields are missing, unknown, or out of order.',
    );
  }
}

String _string(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String) {
    throw ArchiveV1FormatException('Archive field $key has the wrong type.');
  }
  return field;
}

String? _nullableString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field != null && field is! String) {
    throw ArchiveV1FormatException('Archive field $key has the wrong type.');
  }
  return field as String?;
}

List<String> _stringList(Object? value, String label) {
  if (value is! List<Object?> || value.any((entry) => entry is! String)) {
    throw ArchiveV1FormatException('$label must be a string list.');
  }
  return value.cast<String>();
}

DateTime _canonicalTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toUtc().toIso8601String() != value) {
    throw const ArchiveV1FormatException(
      'Archive timestamps must be canonical UTC ISO-8601.',
    );
  }
  return parsed;
}

void _validateOpaqueId(String value, String label) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
    throw ArchiveV1FormatException('$label is not a safe opaque identity.');
  }
}

void _validateChecksum(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const ArchiveV1FormatException('SHA-256 checksum is invalid.');
  }
}

void _validateArchivePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      value.contains('\\') ||
      value.contains('%') ||
      value.contains('?') ||
      value.contains('#') ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
      value
          .split('/')
          .any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
    throw const ArchiveV1FormatException('Archive path is not canonical.');
  }
}

void _validateAttachmentPayloadPath(
  String path,
  String attachmentId,
  String mimeType,
) {
  const extensions = {
    'application/pdf': {'pdf'},
    'image/jpeg': {'jpg', 'jpeg'},
    'image/png': {'png'},
    'image/heic': {'heic'},
    'image/heif': {'heif'},
  };
  final allowed = extensions[mimeType];
  final prefix = 'attachments/$attachmentId/payload.';
  if (allowed == null ||
      !path.startsWith(prefix) ||
      !allowed.contains(path.substring(prefix.length))) {
    throw const ArchiveV1FormatException(
      'Attachment payload path or MIME type is invalid.',
    );
  }
  _validateArchivePath(path);
}

void _validateAttachmentEnumValues(Map<String, Object?> row) {
  const types = {
    'photo',
    'receipt',
    'certificate',
    'appraisal',
    'auction_record',
    'provenance_note',
    'other_supporting_document',
  };
  const roles = {
    'primary_artwork_photo',
    'supporting_photo',
    'supporting_document',
  };
  const lifecycles = {'active', 'unavailable', 'superseded', 'removed'};
  if (!types.contains(row['attachment_type']) ||
      !roles.contains(row['attachment_role']) ||
      !lifecycles.contains(row['lifecycle_status'])) {
    throw const ArchiveV1FormatException(
      'Attachment type, role, or lifecycle is invalid.',
    );
  }
}

bool _isStrictlySorted(List<String> values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index - 1].compareTo(values[index]) >= 0) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));
String _canonicalJson(Object? value) => jsonEncode(value);
