import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ExportArtifactKind { report, archive }

/// A completed export capability issued only after the store validates the
/// payload and its adjacent metadata. Call [revalidate] immediately before an
/// external destination because app-private files can still be changed after
/// generation.
class ExportArtifact {
  const ExportArtifact._({
    required this._store,
    required this.id,
    required this.kind,
    required this.file,
    required this.createdAt,
    required this.warnings,
    required this.byteSize,
    required this.checksumSha256,
    this.subjectId,
  });

  final ExportArtifactStore _store;
  final String id;
  final ExportArtifactKind kind;
  final File file;
  final DateTime createdAt;
  final List<String> warnings;
  final int byteSize;
  final String checksumSha256;
  final String? subjectId;

  String get displayName => p.basename(file.path);
  String get mimeType => ExportArtifactStore.mimeTypeFor(kind);

  Future<ExportArtifact?> revalidate() => _store.validate(this);
}

class ExportArtifactStore {
  const ExportArtifactStore._(this.root);

  static const metadataVersion = 1;
  static const metadataStateComplete = 'complete';

  final Directory root;

  static Future<ExportArtifactStore> open() async {
    final documents = await getApplicationDocumentsDirectory();
    return openAt(Directory(p.join(documents.path, 'generated_exports')));
  }

  static Future<ExportArtifactStore> openAt(Directory root) async {
    await root.create(recursive: true);
    return ExportArtifactStore._(root.absolute);
  }

  static String reportId(String subjectId, DateTime createdAt) {
    _validateId(subjectId);
    return '${_reportPrefix(subjectId)}${createdAt.toUtc().microsecondsSinceEpoch}';
  }

  static String mimeTypeFor(ExportArtifactKind kind) =>
      kind == ExportArtifactKind.report ? 'application/pdf' : 'application/zip';

  static String extensionFor(ExportArtifactKind kind) =>
      kind == ExportArtifactKind.report ? 'pdf' : 'zip';

  Future<File> stagingFile(ExportArtifactKind kind, String id) async {
    _validateId(id);
    final directory = Directory(p.join(root.path, '.staging'));
    await directory.create(recursive: true);
    final nonce = List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return File(p.join(directory.path, '${kind.name}-$id-$nonce.partial'));
  }

  Future<ExportArtifact> commit({
    required ExportArtifactKind kind,
    required String id,
    required File staging,
    required DateTime createdAt,
    required List<String> warnings,
    String? subjectId,
  }) async {
    _validateIdentity(kind: kind, id: id, subjectId: subjectId);
    await _validateStaging(kind: kind, id: id, staging: staging);

    final directory = Directory(p.join(root.path, '${kind.name}s'));
    final claims = Directory(p.join(root.path, '.claims'));
    await directory.create(recursive: true);
    await claims.create(recursive: true);
    final extension = extensionFor(kind);
    final destination = File(p.join(directory.path, '$id.$extension'));
    final metadata = File('${destination.path}.json');
    final claim = File(p.join(claims.path, '${kind.name}-$id.claim'));
    final metadataStaging = File(
      p.join(
        root.path,
        '.staging',
        '${kind.name}-$id-${p.basename(staging.path)}.json.partial',
      ),
    );
    var ownsClaim = false;
    var payloadPublished = false;
    var metadataPublished = false;
    try {
      await claim.create(exclusive: true);
      ownsClaim = true;
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(metadata.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw StateError(
          'An export artifact with this identity already exists.',
        );
      }

      final digest = await _digestRegularFile(staging);
      final metadataValue = <String, Object?>{
        'metadata_version': metadataVersion,
        'state': metadataStateComplete,
        'artifact_id': id,
        'kind': kind.name,
        'subject_id': subjectId,
        'file_name': p.basename(destination.path),
        'mime_type': mimeTypeFor(kind),
        'byte_size': digest.byteSize,
        'checksum_sha256': digest.checksumSha256,
        'created_at': createdAt.toUtc().toIso8601String(),
        'warnings': List<String>.unmodifiable(warnings),
      };
      await metadataStaging.writeAsString(
        jsonEncode(metadataValue),
        flush: true,
      );
      await staging.rename(destination.path);
      payloadPublished = true;
      await metadataStaging.rename(metadata.path);
      metadataPublished = true;

      final candidate = ExportArtifact._(
        store: this,
        id: id,
        kind: kind,
        file: destination,
        createdAt: createdAt.toUtc(),
        warnings: List<String>.unmodifiable(warnings),
        byteSize: digest.byteSize,
        checksumSha256: digest.checksumSha256,
        subjectId: subjectId,
      );
      final validated = await validate(candidate);
      if (validated == null) {
        throw StateError(
          'The completed export artifact failed final validation.',
        );
      }
      return validated;
    } on Object {
      await _deleteIfOwned(metadataStaging);
      await _deleteIfOwned(staging);
      if (metadataPublished) await _deleteIfOwned(metadata);
      if (payloadPublished) await _deleteIfOwned(destination);
      rethrow;
    } finally {
      if (ownsClaim) await _deleteIfOwned(claim);
    }
  }

  Future<ExportArtifact?> validate(ExportArtifact capability) async {
    if (!identical(capability._store, this)) return null;
    return _validateNamedArtifact(
      kind: capability.kind,
      id: capability.id,
      subjectId: capability.subjectId,
      expectedCapability: capability,
    );
  }

  Future<ExportArtifact?> latest(
    ExportArtifactKind kind, {
    String? subjectId,
  }) async {
    _validateSubject(kind, subjectId);
    final directory = Directory(p.join(root.path, '${kind.name}s'));
    if (!await directory.exists()) return null;
    final extension = '.${extensionFor(kind)}';
    final files = await directory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File &&
              p.extension(entry.path) == extension &&
              !p.basename(entry.path).endsWith('.partial'),
        )
        .cast<File>()
        .toList();
    files.sort((left, right) => right.path.compareTo(left.path));
    for (final file in files) {
      final id = p.basenameWithoutExtension(file.path);
      try {
        _validateIdentity(kind: kind, id: id, subjectId: subjectId);
        final artifact = await _validateNamedArtifact(
          kind: kind,
          id: id,
          subjectId: subjectId,
        );
        if (artifact != null) return artifact;
      } on Object {
        // Corrupt, legacy, or incomplete entries are never surfaced.
      }
    }
    return null;
  }

  Future<ExportArtifact?> _validateNamedArtifact({
    required ExportArtifactKind kind,
    required String id,
    required String? subjectId,
    ExportArtifact? expectedCapability,
  }) async {
    _validateIdentity(kind: kind, id: id, subjectId: subjectId);
    final extension = extensionFor(kind);
    final directory = Directory(p.join(root.path, '${kind.name}s'));
    final file = File(p.join(directory.path, '$id.$extension'));
    final metadataFile = File('${file.path}.json');
    if (!await _isExactRegularFile(file, directory) ||
        !await _isExactRegularFile(metadataFile, directory)) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(await metadataFile.readAsString());
    } on Object {
      return null;
    }
    if (decoded is! Map<String, Object?> ||
        decoded.keys.join(',') !=
            'metadata_version,state,artifact_id,kind,subject_id,file_name,mime_type,byte_size,checksum_sha256,created_at,warnings') {
      return null;
    }
    final byteSize = decoded['byte_size'];
    final checksum = decoded['checksum_sha256'];
    final warningsValue = decoded['warnings'];
    final createdAtValue = decoded['created_at'];
    if (decoded['metadata_version'] != metadataVersion ||
        decoded['state'] != metadataStateComplete ||
        decoded['artifact_id'] != id ||
        decoded['kind'] != kind.name ||
        decoded['subject_id'] != subjectId ||
        decoded['file_name'] != p.basename(file.path) ||
        decoded['mime_type'] != mimeTypeFor(kind) ||
        byteSize is! int ||
        byteSize < 1 ||
        checksum is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
        createdAtValue is! String ||
        warningsValue is! List<Object?> ||
        warningsValue.any((value) => value is! String)) {
      return null;
    }
    final DateTime createdAt;
    try {
      createdAt = DateTime.parse(createdAtValue).toUtc();
    } on Object {
      return null;
    }
    if (createdAt.toIso8601String() != createdAtValue) return null;

    final digest = await _digestRegularFile(file);
    if (digest.byteSize != byteSize || digest.checksumSha256 != checksum) {
      return null;
    }
    if (expectedCapability != null &&
        (expectedCapability.file.absolute.path != file.absolute.path ||
            expectedCapability.byteSize != byteSize ||
            expectedCapability.checksumSha256 != checksum ||
            expectedCapability.createdAt.toUtc() != createdAt ||
            expectedCapability.displayName != decoded['file_name'] ||
            expectedCapability.mimeType != decoded['mime_type'])) {
      return null;
    }
    return ExportArtifact._(
      store: this,
      id: id,
      kind: kind,
      file: file,
      createdAt: createdAt,
      warnings: List<String>.unmodifiable(warningsValue.cast<String>()),
      byteSize: byteSize,
      checksumSha256: checksum,
      subjectId: subjectId,
    );
  }

  Future<void> discard(File staging) => _deleteIfOwned(staging);

  Future<void> _validateStaging({
    required ExportArtifactKind kind,
    required String id,
    required File staging,
  }) async {
    final stagingDirectory = Directory(p.join(root.path, '.staging'));
    final name = p.basename(staging.path);
    if (!name.startsWith('${kind.name}-$id-') ||
        !name.endsWith('.partial') ||
        !await _isExactRegularFile(staging, stagingDirectory)) {
      throw ArgumentError(
        'Export staging file is outside the reserved staging area.',
      );
    }
  }

  Future<bool> _isExactRegularFile(File file, Directory expectedParent) async {
    try {
      final rootResolved = await root.resolveSymbolicLinks();
      final parentResolved = await expectedParent.resolveSymbolicLinks();
      final expectedParentPath = p.join(
        rootResolved,
        p.relative(expectedParent.absolute.path, from: root.absolute.path),
      );
      return p.equals(parentResolved, expectedParentPath) &&
          p.equals(
            p.dirname(file.absolute.path),
            expectedParent.absolute.path,
          ) &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file;
    } on Object {
      return false;
    }
  }

  static Future<_FileDigest> _digestRegularFile(File file) async {
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file || before.size < 1) {
      throw StateError('Export artifact must be a non-empty regular file.');
    }
    final checksum = await sha256.bind(file.openRead()).first;
    final after = await file.stat();
    if (after.type != FileSystemEntityType.file || after.size != before.size) {
      throw StateError('Export artifact changed while it was validated.');
    }
    return _FileDigest(
      byteSize: after.size,
      checksumSha256: checksum.toString(),
    );
  }

  static void _validateIdentity({
    required ExportArtifactKind kind,
    required String id,
    required String? subjectId,
  }) {
    _validateId(id);
    _validateSubject(kind, subjectId);
    if (kind == ExportArtifactKind.report &&
        !id.startsWith(_reportPrefix(subjectId!))) {
      throw ArgumentError(
        'Report artifact identity does not match its artwork.',
      );
    }
    if (kind == ExportArtifactKind.archive && !id.startsWith('archive-')) {
      throw ArgumentError('Archive artifact identity has the wrong kind.');
    }
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

  static Future<void> _deleteIfOwned(File file) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    } on Object {
      // Cleanup is best effort; the original operation outcome wins.
    }
  }

  static String _reportPrefix(String subjectId) {
    final digest = sha256.convert(utf8.encode(subjectId)).toString();
    return 'report-${digest.substring(0, 24)}-';
  }
}

class _FileDigest {
  const _FileDigest({required this.byteSize, required this.checksumSha256});

  final int byteSize;
  final String checksumSha256;
}
