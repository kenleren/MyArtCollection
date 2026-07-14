import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ExportArtifactKind { report, archive }

class ExportArtifact {
  const ExportArtifact({
    required this.kind,
    required this.file,
    required this.createdAt,
    required this.warnings,
  });

  final ExportArtifactKind kind;
  final File file;
  final DateTime createdAt;
  final List<String> warnings;

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
  }) async {
    _validateId(id);
    final directory = Directory(p.join(root.path, '${kind.name}s'));
    await directory.create(recursive: true);
    final extension = kind == ExportArtifactKind.report ? 'pdf' : 'zip';
    final destination = File(p.join(directory.path, '$id.$extension'));
    if (await destination.exists()) await destination.delete();
    await staging.rename(destination.path);
    final metadata = File('${destination.path}.json');
    final metadataStaging = File('${metadata.path}.partial');
    await metadataStaging.writeAsString(
      jsonEncode({
        'kind': kind.name,
        'created_at': createdAt.toUtc().toIso8601String(),
        'warnings': warnings,
      }),
      flush: true,
    );
    if (await metadata.exists()) await metadata.delete();
    await metadataStaging.rename(metadata.path);
    return ExportArtifact(
      kind: kind,
      file: destination,
      createdAt: createdAt,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<ExportArtifact?> latest(ExportArtifactKind kind) async {
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
    final file = files.first;
    try {
      final metadata =
          jsonDecode(await File('${file.path}.json').readAsString())
              as Map<String, Object?>;
      return ExportArtifact(
        kind: kind,
        file: file,
        createdAt: DateTime.parse(metadata['created_at']! as String),
        warnings: (metadata['warnings']! as List<Object?>).cast<String>(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> discard(File staging) async {
    if (await staging.exists()) await staging.delete();
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Must be an opaque identifier.');
    }
  }
}
