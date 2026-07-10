import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachment_record.dart';
import 'artwork_record.dart';

enum AttachmentImportFailure {
  sourceMissing,
  unsupportedMimeType,
  mimeTypeMismatch,
  malformedFile,
  unreadableSource,
  fileTooLarge,
  storageFailure,
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
    String? derivedFromAttachmentId,
    String? transformSummary,
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
        '$mimeType files are not supported for attachment storage.',
      );
    }

    if (!_extensionMatchesMime(
      p.extension(originalFileName).toLowerCase(),
      mimeType,
    )) {
      throw const AttachmentImportException(
        AttachmentImportFailure.mimeTypeMismatch,
        'The selected file type does not match its file name.',
      );
    }

    final int fileSizeBytes;
    var committed = false;
    try {
      fileSizeBytes = await sourceFile.length();
    } on FileSystemException {
      throw const AttachmentImportException(
        AttachmentImportFailure.unreadableSource,
        'The selected file could not be read.',
      );
    }
    if (fileSizeBytes > maxBytes) {
      throw AttachmentImportException(
        AttachmentImportFailure.fileTooLarge,
        'Selected file exceeds the attachment limit for $mimeType.',
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
    final staging = File(
      p.join(storageRoot.path, '.staging', '$attachmentId.partial'),
    );

    try {
      await staging.parent.create(recursive: true);
      if (await staging.exists()) {
        await staging.delete();
      }
      await sourceFile.copy(staging.path);
      final stagedFileSize = await staging.length();
      if (stagedFileSize > maxBytes) {
        throw AttachmentImportException(
          AttachmentImportFailure.fileTooLarge,
          'Selected file exceeds the attachment limit for $mimeType.',
        );
      }
      final bytes = await staging.readAsBytes();
      _validateSignature(bytes, mimeType);

      await destination.parent.create(recursive: true);
      if (await destination.exists()) {
        throw const AttachmentImportException(
          AttachmentImportFailure.storageFailure,
          'Could not save the selected file.',
        );
      }
      await staging.rename(destination.path);

      // Reopen after the final move so metadata is never returned for bytes
      // that cannot be read back from the app-private payload location.
      final reopenedBytes = await destination.readAsBytes();
      _validateSignature(reopenedBytes, mimeType);
      final checksum = sha256.convert(reopenedBytes).toString();

      final record = AttachmentRecord(
        id: attachmentId,
        artworkId: artworkId,
        type: type,
        role: role,
        fileName: p.basename(originalFileName),
        mimeType: mimeType,
        fileSizeBytes: stagedFileSize,
        importedAt: importedAt,
        capturedAt: capturedAt,
        derivedFromAttachmentId: derivedFromAttachmentId,
        transformSummary: transformSummary,
        source: source,
        relativePath: relativePath,
        checksum: checksum,
        extractionSummary: extractionSummary,
        notes: notes,
      );
      committed = true;
      return record;
    } on AttachmentImportException {
      rethrow;
    } on FileSystemException {
      throw const AttachmentImportException(
        AttachmentImportFailure.storageFailure,
        'Could not save the selected file.',
      );
    } finally {
      if (await staging.exists()) {
        await staging.delete();
      }
      if (!committed && await destination.exists()) {
        await destination.delete();
      }
    }
  }

  Future<bool> exists(AttachmentRecord attachment) async {
    return fileFor(attachment).exists();
  }

  Future<AttachmentPayloadStatus> payloadStatus(
    AttachmentRecord attachment,
  ) async {
    final file = fileFor(attachment);
    try {
      if (!await file.exists()) {
        return AttachmentPayloadStatus.missing;
      }
      final bytes = await file.readAsBytes();
      return sha256.convert(bytes).toString() == attachment.checksum
          ? AttachmentPayloadStatus.available
          : AttachmentPayloadStatus.checksumMismatch;
    } on FileSystemException {
      return AttachmentPayloadStatus.missing;
    }
  }

  Future<void> discardPayload(AttachmentRecord attachment) async {
    final file = fileFor(attachment);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Uri scopedUriFor(AttachmentRecord attachment) {
    return fileFor(attachment).uri;
  }

  File fileFor(AttachmentRecord attachment) {
    final normalizedRoot = p.normalize(storageRoot.path);
    final normalizedPath = p.normalize(
      p.join(normalizedRoot, attachment.relativePath),
    );
    if (!p.isWithin(normalizedRoot, normalizedPath)) {
      throw const AttachmentImportException(
        AttachmentImportFailure.storageFailure,
        'The saved attachment location is unavailable.',
      );
    }
    return File(normalizedPath);
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

  static void _validateSignature(List<int> bytes, String mimeType) {
    final isValid = switch (mimeType) {
      'application/pdf' =>
        bytes.length >= 8 &&
            _startsWith(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d]) &&
            _containsNearEnd(bytes, const [0x25, 0x25, 0x45, 0x4f, 0x46]),
      'image/jpeg' =>
        bytes.length >= 4 && _startsWith(bytes, const [0xff, 0xd8, 0xff]),
      'image/png' =>
        bytes.length >= 8 &&
            _startsWith(bytes, const [
              0x89,
              0x50,
              0x4e,
              0x47,
              0x0d,
              0x0a,
              0x1a,
              0x0a,
            ]),
      'image/heic' || 'image/heif' => _hasIsoBaseMediaFileType(bytes),
      _ => false,
    };
    if (!isValid) {
      throw const AttachmentImportException(
        AttachmentImportFailure.malformedFile,
        'The selected file is malformed or does not match its declared type.',
      );
    }
  }

  static bool _startsWith(List<int> bytes, List<int> signature) {
    if (bytes.length < signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  static bool _containsNearEnd(List<int> bytes, List<int> marker) {
    final start = bytes.length > 1024 ? bytes.length - 1024 : 0;
    for (var index = start; index <= bytes.length - marker.length; index++) {
      var matched = true;
      for (var markerIndex = 0; markerIndex < marker.length; markerIndex++) {
        if (bytes[index + markerIndex] != marker[markerIndex]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return true;
      }
    }
    return false;
  }

  static bool _hasIsoBaseMediaFileType(List<int> bytes) {
    if (bytes.length < 16 ||
        bytes[4] != 0x66 ||
        bytes[5] != 0x74 ||
        bytes[6] != 0x79 ||
        bytes[7] != 0x70) {
      return false;
    }
    const brands = {
      'heic',
      'heix',
      'hevc',
      'hevx',
      'heim',
      'heis',
      'mif1',
      'msf1',
    };
    final limit = bytes.length < 64 ? bytes.length : 64;
    for (var index = 8; index + 3 < limit; index += 4) {
      final brand = String.fromCharCodes(bytes.sublist(index, index + 4));
      if (brands.contains(brand)) {
        return true;
      }
    }
    return false;
  }
}

enum AttachmentPayloadStatus { available, missing, checksumMismatch }
