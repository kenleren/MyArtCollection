// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_cast

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../storage/artwork_group.dart';
import 'archive_v1_codec.dart';
import 'external_reference_export_codec.dart';

class ArchiveV2FormatException implements Exception {
  const ArchiveV2FormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DecodedArchivaleArchiveV2 {
  const DecodedArchivaleArchiveV2({
    required this.manifest,
    required this.groupings,
  });
  final Map<String, Object?> manifest;
  final ArtworkGroupingExportData groupings;
}

/// Strict successor envelope. v1 remains isolated in [ArchivaleArchiveV1Codec].
class ArchivaleArchiveV2Codec {
  const ArchivaleArchiveV2Codec();

  static const archiveContract = 'ARCHIVALE_ARCHIVE_V2';
  static const version = 2;
  static const groupingsContract = 'ARCHIVALE_GROUPINGS_V1';
  static const _structuredPaths = <String>[
    'records/artworks.json',
    'records/external_references.json',
    'records/attachments.json',
    'records/groupings.json',
  ];

  Uint8List encodeGroupings(ArtworkGroupingExportData data) {
    final groups = List<ArtworkGroup>.of(data.groups)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final root = <String, Object?>{
      'contract': groupingsContract,
      'version': 1,
      'groups': groups.map(_groupJson).toList(growable: false),
      'memberships': data.memberships,
      'preferences': data.preferences,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(root)));
  }

  ArtworkGroupingExportData decodeGroupings(Uint8List bytes) {
    final root = _object(_json(bytes, 'Groupings'), 'Groupings');
    _keys(root, const [
      'contract',
      'version',
      'groups',
      'memberships',
      'preferences',
    ]);
    if (root['contract'] != groupingsContract || root['version'] != 1) {
      throw const ArchiveV2FormatException(
        'Groupings contract or version is unsupported.',
      );
    }
    final rawGroups = _list(root['groups'], 'Groups');
    final groups = <ArtworkGroup>[];
    var expectedOrder = 0;
    String? previousId;
    for (final value in rawGroups) {
      final row = _object(value, 'Group');
      _keys(row, const [
        'group_id',
        'name',
        'normalized_name',
        'sort_order',
        'created_at',
        'updated_at',
      ]);
      final id = _id(row['group_id'], 'group_id');
      final name = _string(row['name'], 'name');
      final normalized = _string(row['normalized_name'], 'normalized_name');
      if (normalizeArtworkGroupDisplayName(name) != name ||
          normalizeArtworkGroupName(name) != normalized ||
          row['sort_order'] != expectedOrder ||
          (previousId != null &&
              id.compareTo(previousId) <= 0 &&
              expectedOrder == 0)) {
        throw const ArchiveV2FormatException('Group rows are not canonical.');
      }
      groups.add(
        ArtworkGroup(
          id: id,
          name: name,
          normalizedName: normalized,
          sortOrder: expectedOrder,
          createdAt: _time(row['created_at']),
          updatedAt: _time(row['updated_at']),
          memberCount: 0,
        ),
      );
      expectedOrder++;
      previousId = id;
    }
    final memberships = _validatedRows(
      _list(root['memberships'], 'Memberships'),
      const ['artwork_id', 'group_id', 'created_at'],
      (row) {
        _id(row['artwork_id'], 'artwork_id');
        _id(row['group_id'], 'group_id');
        _time(row['created_at']);
      },
      'artwork_id',
      secondary: 'group_id',
    );
    final preferences = _validatedRows(
      _list(root['preferences'], 'Preferences'),
      const ['artwork_id', 'is_favorite', 'updated_at'],
      (row) {
        _id(row['artwork_id'], 'artwork_id');
        if (row['is_favorite'] != 0 && row['is_favorite'] != 1)
          throw const ArchiveV2FormatException(
            'Preference favorite is invalid.',
          );
        _time(row['updated_at']);
      },
      'artwork_id',
    );
    final result = ArtworkGroupingExportData(
      groups: List.unmodifiable(groups),
      memberships: memberships,
      preferences: preferences,
    );
    if (!_same(bytes, encodeGroupings(result)))
      throw const ArchiveV2FormatException(
        'Groupings bytes are not canonical.',
      );
    return result;
  }

  DecodedArchivaleArchiveV2 decodeArchive(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final names = archive.files
        .map((entry) => entry.name)
        .toList(growable: false);
    if (names.isEmpty ||
        names.first != 'manifest.json' ||
        names.toSet().length != names.length)
      throw const ArchiveV2FormatException(
        'Archive entries are missing or duplicated.',
      );
    final manifestBytes = _entry(archive, 'manifest.json');
    final manifest = decodeManifest(manifestBytes);
    final rows = _list(
      manifest['files'],
      'Archive files',
    ).map((value) => _object(value, 'Archive file')).toList();
    final expected = [
      'manifest.json',
      ...rows.map((row) => row['path'] as String),
    ];
    if (!_sameStrings(names, expected))
      throw const ArchiveV2FormatException(
        'Archive entries are not in canonical order.',
      );
    for (final row in rows) {
      final path = row['path'] as String;
      final content = _entry(archive, path);
      if (content.length != row['size_bytes'] ||
          sha256.convert(content).toString() != row['checksum_sha256'])
        throw const ArchiveV2FormatException(
          'Archive file checksum does not match manifest.',
        );
    }
    final artworks = const ArchivaleArchiveV1Codec().decodeArtworks(
      _entry(archive, _structuredPaths[0]),
    );
    final references = const ExternalReferenceExportCodec().decodeStandalone(
      _entry(archive, _structuredPaths[1]),
    );
    final attachments = const ArchivaleArchiveV1Codec()
        .decodeAttachmentOutcomes(_entry(archive, _structuredPaths[2]));
    final groupings = decodeGroupings(_entry(archive, _structuredPaths[3]));
    final counts = _object(manifest['counts'], 'Archive counts');
    if (counts['artworks'] != artworks.length ||
        counts['external_references'] != references.length ||
        counts['attachments_included'] !=
            attachments
                .where((row) => row['archive_status'] == 'included')
                .length ||
        counts['attachments_excluded'] !=
            attachments
                .where((row) => row['archive_status'] != 'included')
                .length ||
        counts['groups'] != groupings.groups.length ||
        counts['memberships'] != groupings.memberships.length ||
        counts['preferences'] != groupings.preferences.length) {
      throw const ArchiveV2FormatException(
        'Archive counts do not match records.',
      );
    }
    return DecodedArchivaleArchiveV2(manifest: manifest, groupings: groupings);
  }

  Map<String, Object?> decodeManifest(Uint8List bytes) {
    final root = _object(_json(bytes, 'Archive manifest'), 'Archive manifest');
    _keys(root, const [
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
    if (root['contract'] != archiveContract || root['version'] != version)
      throw const ArchiveV2FormatException(
        'Archive contract or version is unsupported.',
      );
    _time(root['created_at']);
    final counts = _object(root['counts'], 'Archive counts');
    _keys(counts, const [
      'artworks',
      'external_references',
      'attachments_included',
      'attachments_excluded',
      'groups',
      'memberships',
      'preferences',
    ]);
    if (counts.values.any((value) => value is! int || value < 0))
      throw const ArchiveV2FormatException('Archive counts are invalid.');
    final files = _list(root['files'], 'Archive files');
    final paths = <String>[];
    for (final value in files) {
      final row = _object(value, 'Archive file');
      _keys(row, const ['path', 'size_bytes', 'checksum_sha256']);
      final path = _string(row['path'], 'path');
      if (row['size_bytes'] is! int ||
          (row['size_bytes'] as int) < 0 ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(_string(row['checksum_sha256'], 'checksum')))
        throw const ArchiveV2FormatException(
          'Archive file metadata is invalid.',
        );
      paths.add(path);
    }
    if (paths.length < _structuredPaths.length ||
        !_sameStrings(
          paths.take(_structuredPaths.length).toList(),
          _structuredPaths,
        ))
      throw const ArchiveV2FormatException(
        'Archive structured files are missing or out of order.',
      );
    final payloads = paths.skip(_structuredPaths.length).toList();
    if (payloads.toSet().length != payloads.length ||
        !_sameStrings(payloads, List<String>.of(payloads)..sort()) ||
        payloads.any((path) => !path.startsWith('attachments/')))
      throw const ArchiveV2FormatException(
        'Archive payload files are not canonical.',
      );
    if (!_same(bytes, Uint8List.fromList(utf8.encode(jsonEncode(root)))))
      throw const ArchiveV2FormatException(
        'Archive manifest bytes are not canonical.',
      );
    return root;
  }
}

Map<String, Object?> _groupJson(ArtworkGroup group) => {
  'group_id': group.id,
  'name': group.name,
  'normalized_name': group.normalizedName,
  'sort_order': group.sortOrder,
  'created_at': group.createdAt.toUtc().toIso8601String(),
  'updated_at': group.updatedAt.toUtc().toIso8601String(),
};
Object? _json(Uint8List bytes, String label) {
  try {
    return jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } on Object {
    throw ArchiveV2FormatException('$label is not valid UTF-8 JSON.');
  }
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>)
    throw ArchiveV2FormatException('$label must be an object.');
  return value;
}

List<Object?> _list(Object? value, String label) {
  if (value is! List<Object?>)
    throw ArchiveV2FormatException('$label must be a list.');
  return value;
}

String _string(Object? value, String label) {
  if (value is! String)
    throw ArchiveV2FormatException('$label must be a string.');
  return value;
}

String _id(Object? value, String label) {
  final id = _string(value, label);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(id))
    throw ArchiveV2FormatException('$label is not a safe opaque identity.');
  return id;
}

DateTime _time(Object? value) {
  try {
    final result = DateTime.parse(_string(value, 'timestamp'));
    if (result.toUtc().toIso8601String() != value)
      throw const FormatException();
    return result.toUtc();
  } on Object {
    throw const ArchiveV2FormatException('Timestamp is not canonical UTC.');
  }
}

void _keys(Map<String, Object?> value, List<String> expected) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected))
    throw const ArchiveV2FormatException(
      'Object keys do not match the contract.',
    );
}

List<Map<String, Object?>> _validatedRows(
  List<Object?> values,
  List<String> keys,
  void Function(Map<String, Object?> row) validate,
  String primary, {
  String? secondary,
}) {
  final result = <Map<String, Object?>>[];
  String? previous;
  for (final value in values) {
    final row = _object(value, 'Row');
    _keys(row, keys);
    validate(row);
    final key =
        '${row[primary]}\u0000${secondary == null ? '' : row[secondary]}';
    if (previous != null && key.compareTo(previous) <= 0)
      throw const ArchiveV2FormatException('Rows are not in canonical order.');
    previous = key;
    result.add(row);
  }
  return List.unmodifiable(result);
}

Uint8List _entry(Archive archive, String path) {
  final entry = archive.findFile(path);
  if (entry == null || !entry.isFile || entry.isSymbolicLink)
    throw ArchiveV2FormatException('Archive entry $path is missing.');
  return entry.content as Uint8List;
}

bool _same(Uint8List left, Uint8List right) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => left[index] == right[index],
    ).every((value) => value);
bool _sameStrings(List<String> left, List<String> right) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => left[index] == right[index],
    ).every((value) => value);
