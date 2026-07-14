import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ExportArtifactKind { report, archive }

class ExportArtifact {
  const ExportArtifact({
    required this.kind,
    required this.file,
    required this.createdAt,
    required this.warnings,
    this.subjectId,
  });

  final ExportArtifactKind kind;
  final File file;
  final DateTime createdAt;
  final List<String> warnings;
  final String? subjectId;

  String get displayName => p.basename(file.path);
  String get mimeType =>
      kind == ExportArtifactKind.report ? 'application/pdf' : 'application/zip';
}

class ExportArtifactStore {
  const ExportArtifactStore._(this.root);

  final Directory root;

  static Future<ExportArtifactStore> open() async {
    final documents = await getApplicationDocumentsDirectory();
    return openAt(Directory(p.join(documents.path, 'generated_exports')));
  }

  static Future<ExportArtifactStore> openAt(Directory root) async {
    await root.create(recursive: true);
    return ExportArtifactStore._(root);
  }

  static String reportId(String subjectId, DateTime createdAt) {
    _validateId(subjectId);
    return '${_reportPrefix(subjectId)}${createdAt.toUtc().microsecondsSinceEpoch}';
  }

  Future<File> stagingFile(ExportArtifactKind kind, String id) async {
    _validateId(id);
    final directory = Directory(p.join(root.path, '.staging'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, '${kind.name}-$id.partial'));
  }

  Future<ExportArtifact> commit({
    required ExportArtifactKind kind,
    required String id,
    required File staging,
    required DateTime createdAt,
    required List<String> warnings,
    String? subjectId,
  }) async {
    _validateId(id);
    _validateSubject(kind, subjectId);
    if (kind == ExportArtifactKind.report &&
        !id.startsWith(_reportPrefix(subjectId!))) {
      throw ArgumentError(
        'Report artifact identity does not match its artwork.',
      );
    }
    final directory = Directory(p.join(root.path, '${kind.name}s'));
    await directory.create(recursive: true);
    final extension = kind == ExportArtifactKind.report ? 'pdf' : 'zip';
    final destination = File(p.join(directory.path, '$id.$extension'));
    final metadata = File('${destination.path}.json');
    final metadataStaging = File('${metadata.path}.partial');
    if (await destination.exists() || await metadata.exists()) {
      throw StateError('An export artifact with this identity already exists.');
    }
    try {
      await metadataStaging.writeAsString(
        jsonEncode({
          'kind': kind.name,
          'subject_id': subjectId,
          'created_at': createdAt.toUtc().toIso8601String(),
          'warnings': warnings,
        }),
        flush: true,
      );
      await staging.rename(destination.path);
      await metadataStaging.rename(metadata.path);
      return ExportArtifact(
        kind: kind,
        file: destination,
        createdAt: createdAt,
        warnings: List.unmodifiable(warnings),
        subjectId: subjectId,
      );
    } on Object {
      await _deleteIfFile(staging);
      await _deleteIfFile(metadataStaging);
      await _deleteIfFile(metadata);
      await _deleteIfFile(destination);
      rethrow;
    }
  }

  Future<ExportArtifact?> latest(
    ExportArtifactKind kind, {
    String? subjectId,
  }) async {
    _validateSubject(kind, subjectId);
    final directory = Directory(p.join(root.path, '${kind.name}s'));
    if (!await directory.exists()) return null;
    final extension = kind == ExportArtifactKind.report ? '.pdf' : '.zip';
    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith(extension))
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    files.sort((left, right) => right.path.compareTo(left.path));
    for (final file in files) {
      try {
        final metadata =
            jsonDecode(await File('${file.path}.json').readAsString())
                as Map<String, Object?>;
        if (metadata.keys.join(',') != 'kind,subject_id,created_at,warnings' ||
            metadata['kind'] != kind.name ||
            metadata['subject_id'] != subjectId ||
            (kind == ExportArtifactKind.report &&
                !p.basename(file.path).startsWith(_reportPrefix(subjectId!)))) {
          continue;
        }
        return ExportArtifact(
          kind: kind,
          file: file,
          createdAt: DateTime.parse(metadata['created_at']! as String),
          warnings: (metadata['warnings']! as List<Object?>).cast<String>(),
          subjectId: metadata['subject_id'] as String?,
        );
      } on Object {
        // Corrupt, legacy, or incomplete metadata is never trusted.
      }
    }
    return null;
  }

  Future<void> discard(File staging) async {
    if (await staging.exists()) await staging.delete();
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Must be an opaque identifier.');
    }
  }

  static void _validateSubject(ExportArtifactKind kind, String? subjectId) {
    if (kind == ExportArtifactKind.report) {
      if (subjectId == null) {
        throw ArgumentError('Report artifacts require an artwork identity.');
      }
      _validateId(subjectId);
    } else if (subjectId != null) {
      throw ArgumentError(
        'Collection archives cannot have an artwork identity.',
      );
    }
  }

  static Future<void> _deleteIfFile(File file) async {
    if (await file.exists()) await file.delete();
  }

  static String _reportPrefix(String subjectId) {
    final digest = sha256.convert(utf8.encode(subjectId)).toString();
    return 'report-${digest.substring(0, 24)}-';
  }
}
