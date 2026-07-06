import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachment_record.dart';
import 'artwork_record.dart';

enum AttachmentImportFailure {
  sourceMissing,
  unsupportedMimeType,
  fileTooLarge,
}

class AttachmentImportException implements Exception {
  const AttachmentImportException(this.failure, this.message);

  final AttachmentImportFailure failure;
  final String message;

  @override
  String toString() => message;
}

class LocalAttachmentStore {
  const LocalAttachmentStore._(this.storageRoot);

  final Directory storageRoot;

  static const allowedMimeTypes = <String, int>{
    'image/jpeg': 25 * 1024 * 1024,
    'image/png': 25 * 1024 * 1024,
    'image/heic': 25 * 1024 * 1024,
    'image/heif': 25 * 1024 * 1024,
    'application/pdf': 50 * 1024 * 1024,
  };

  static Future<LocalAttachmentStore> open() async {
    final directory = await getApplicationDocumentsDirectory();
    return openAt(Directory(p.join(directory.path, 'attachments')));
  }

  static Future<LocalAttachmentStore> openAt(Directory storageRoot) async {
    await storageRoot.create(recursive: true);
    return LocalAttachmentStore._(storageRoot);
  }

  Future<AttachmentRecord> saveImportedAttachment({
    required String artworkId,
    required String attachmentId,
    required File sourceFile,
    required String originalFileName,
    required String mimeType,
    required AttachmentType type,
    AttachmentRole? role,
    required ArtworkFieldSource source,
    required DateTime importedAt,
    DateTime? capturedAt,
    String? extractionSummary,
    String? notes,
  }) async {
    if (!sourceFile.existsSync()) {
      throw const AttachmentImportException(
        AttachmentImportFailure.sourceMissing,
        'The selected file could not be found.',
      );
    }

    final maxBytes = allowedMimeTypes[mimeType];
    if (maxBytes == null) {
      throw AttachmentImportException(
        AttachmentImportFailure.unsupportedMimeType,
        '$mimeType files are not supported in this prototype.',
      );
    }

    final fileSizeBytes = await sourceFile.length();
    if (fileSizeBytes > maxBytes) {
      throw AttachmentImportException(
        AttachmentImportFailure.fileTooLarge,
        'Selected file exceeds the prototype limit for $mimeType.',
      );
    }

    final relativePath = p.join(
      'artworks',
      artworkId,
      'attachments',
      attachmentId,
      'payload${_safeExtension(originalFileName, mimeType)}',
    );
    final destination = File(p.join(storageRoot.path, relativePath));

    await destination.parent.create(recursive: true);
    await sourceFile.copy(destination.path);

    final bytes = await destination.readAsBytes();

    return AttachmentRecord(
      id: attachmentId,
      artworkId: artworkId,
      type: type,
      role: role,
      fileName: p.basename(originalFileName),
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      importedAt: importedAt,
      capturedAt: capturedAt,
      source: source,
      relativePath: relativePath,
      checksum: sha256.convert(bytes).toString(),
      extractionSummary: extractionSummary,
      notes: notes,
    );
  }

  Future<bool> exists(AttachmentRecord attachment) async {
    return fileFor(attachment).exists();
  }

  File fileFor(AttachmentRecord attachment) {
    return File(p.join(storageRoot.path, attachment.relativePath));
  }

  static String _safeExtension(String fileName, String mimeType) {
    final extension = p.extension(fileName).toLowerCase();
    if (_extensionMatchesMime(extension, mimeType)) {
      return extension;
    }

    return switch (mimeType) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/heic' => '.heic',
      'image/heif' => '.heif',
      'application/pdf' => '.pdf',
      _ => '',
    };
  }

  static bool _extensionMatchesMime(String extension, String mimeType) {
    return switch (mimeType) {
      'image/jpeg' => extension == '.jpg' || extension == '.jpeg',
      'image/png' => extension == '.png',
      'image/heic' => extension == '.heic',
      'image/heif' => extension == '.heif',
      'application/pdf' => extension == '.pdf',
      _ => false,
    };
  }
}
