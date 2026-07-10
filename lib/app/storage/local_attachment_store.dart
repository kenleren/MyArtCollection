import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachment_record.dart';
import 'artwork_record.dart';

enum AttachmentImportFailure {
  invalidIdentifier,
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

  static final RegExp _opaquePathComponent = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$',
  );

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
    _validateOpaquePathComponent(artworkId, 'artwork');
    _validateOpaquePathComponent(attachmentId, 'attachment');

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

    final relativePath = _relativePayloadPath(
      artworkId: artworkId,
      attachmentId: attachmentId,
      fileName: originalFileName,
      mimeType: mimeType,
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
    _validateOpaquePathComponent(attachment.artworkId, 'artwork');
    _validateOpaquePathComponent(attachment.id, 'attachment');
    final expectedRelativePath = _relativePayloadPath(
      artworkId: attachment.artworkId,
      attachmentId: attachment.id,
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
    );
    if (!p.equals(attachment.relativePath, expectedRelativePath)) {
      throw const AttachmentImportException(
        AttachmentImportFailure.storageFailure,
        'The saved attachment location is unavailable.',
      );
    }
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

  static String _relativePayloadPath({
    required String artworkId,
    required String attachmentId,
    required String fileName,
    required String mimeType,
  }) {
    return p.join(
      'artworks',
      artworkId,
      'attachments',
      attachmentId,
      'payload${_safeExtension(fileName, mimeType)}',
    );
  }

  static void _validateOpaquePathComponent(String value, String label) {
    if (!_opaquePathComponent.hasMatch(value)) {
      throw AttachmentImportException(
        AttachmentImportFailure.invalidIdentifier,
        'The $label identifier is invalid.',
      );
    }
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
      'application/pdf' => _hasPdfStructure(bytes),
      'image/jpeg' => _hasJpegStructure(bytes),
      'image/png' => _hasPngStructure(bytes),
      'image/heic' || 'image/heif' => _hasIsoBaseMediaFileStructure(bytes),
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

  static bool _hasPdfStructure(List<int> bytes) {
    if (bytes.length < 32 ||
        !_startsWith(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d]) ||
        !_containsNearEnd(bytes, const [0x25, 0x25, 0x45, 0x4f, 0x46])) {
      return false;
    }
    final startXref = _lastIndexOf(bytes, const [
      0x73,
      0x74,
      0x61,
      0x72,
      0x74,
      0x78,
      0x72,
      0x65,
      0x66,
    ]);
    if (startXref < 0) {
      return false;
    }
    var index = startXref + 9;
    while (index < bytes.length && _isPdfWhitespace(bytes[index])) {
      index += 1;
    }
    final numberStart = index;
    while (index < bytes.length &&
        bytes[index] >= 0x30 &&
        bytes[index] <= 0x39) {
      index += 1;
    }
    return index > numberStart;
  }

  static bool _hasJpegStructure(List<int> bytes) {
    if (bytes.length < 24 || !_startsWith(bytes, const [0xff, 0xd8])) {
      return false;
    }
    var index = 2;
    var hasFrame = false;
    var hasScan = false;
    while (index + 1 < bytes.length) {
      if (bytes[index] != 0xff) {
        if (hasScan) {
          index += 1;
          continue;
        }
        return false;
      }
      while (index < bytes.length && bytes[index] == 0xff) {
        index += 1;
      }
      if (index >= bytes.length) {
        return false;
      }
      final marker = bytes[index++];
      if (marker == 0xd9) {
        return hasFrame && hasScan && index == bytes.length;
      }
      if (marker == 0x00 ||
          marker == 0xd8 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (index + 1 >= bytes.length) {
        return false;
      }
      final segmentLength = (bytes[index] << 8) | bytes[index + 1];
      if (segmentLength < 2 || index + segmentLength > bytes.length) {
        return false;
      }
      if (marker >= 0xc0 && marker <= 0xc3 && segmentLength >= 8) {
        hasFrame = true;
      }
      if (marker == 0xda && segmentLength >= 8) {
        hasScan = true;
      }
      index += segmentLength;
    }
    return false;
  }

  static bool _hasPngStructure(List<int> bytes) {
    if (bytes.length < 45 ||
        !_startsWith(bytes, const [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ])) {
      return false;
    }
    var index = 8;
    var firstChunk = true;
    var hasIend = false;
    while (index + 12 <= bytes.length) {
      final length = _readUint32(bytes, index);
      if (length < 0 || length > bytes.length - index - 12) {
        return false;
      }
      final typeStart = index + 4;
      final type = String.fromCharCodes(
        bytes.sublist(typeStart, typeStart + 4),
      );
      final dataStart = index + 8;
      if (firstChunk) {
        if (type != 'IHDR' ||
            length != 13 ||
            _readUint32(bytes, dataStart) <= 0 ||
            _readUint32(bytes, dataStart + 4) <= 0) {
          return false;
        }
        firstChunk = false;
      }
      index += 12 + length;
      if (type == 'IEND') {
        hasIend = length == 0 && index == bytes.length;
        break;
      }
    }
    return !firstChunk && hasIend;
  }

  static bool _hasIsoBaseMediaFileStructure(List<int> bytes) {
    if (bytes.length < 20 ||
        _readUint32(bytes, 0) < 16 ||
        _readUint32(bytes, 0) > bytes.length ||
        String.fromCharCodes(bytes.sublist(4, 8)) != 'ftyp') {
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
    final ftypSize = _readUint32(bytes, 0);
    for (var index = 8; index + 3 < ftypSize; index += 4) {
      final brand = String.fromCharCodes(bytes.sublist(index, index + 4));
      if (brands.contains(brand)) {
        return true;
      }
    }
    return false;
  }

  static int _readUint32(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) {
      return -1;
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _lastIndexOf(List<int> bytes, List<int> marker) {
    for (var index = bytes.length - marker.length; index >= 0; index -= 1) {
      var matches = true;
      for (var markerIndex = 0; markerIndex < marker.length; markerIndex += 1) {
        if (bytes[index + markerIndex] != marker[markerIndex]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return index;
      }
    }
    return -1;
  }

  static bool _isPdfWhitespace(int value) =>
      value == 0x00 ||
      value == 0x09 ||
      value == 0x0a ||
      value == 0x0c ||
      value == 0x0d ||
      value == 0x20;
}

enum AttachmentPayloadStatus { available, missing, checksumMismatch }
