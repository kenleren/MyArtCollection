import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dart_pdf_reader/dart_pdf_reader.dart';
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
  static const _maxDecodedImageBytes = 64 * 1024 * 1024;
  static const _decodedBytesPerPixel = 4;
  static const _maxImagePixels = _maxDecodedImageBytes ~/ _decodedBytesPerPixel;
  static const _maxImageDimension = 16 * 1024;
  static const _validationTimeout = Duration(seconds: 2);

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
      await _validatePayload(bytes, mimeType);

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
      await _validatePayload(reopenedBytes, mimeType);
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

  static Future<void> _validatePayload(List<int> bytes, String mimeType) async {
    if (mimeType == 'application/pdf') {
      if (await _hasParseablePdf(bytes)) {
        return;
      }
      throw const AttachmentImportException(
        AttachmentImportFailure.malformedFile,
        'The selected file is malformed or does not match its declared type.',
      );
    }

    final dimensions = switch (mimeType) {
      'image/jpeg' => _jpegDimensions(bytes),
      'image/png' => _pngDimensions(bytes),
      'image/heic' || 'image/heif' => _isoBaseMediaDimensions(bytes),
      _ => null,
    };
    if (dimensions == null ||
        !_hasSafeImageDimensions(dimensions.width, dimensions.height)) {
      throw const AttachmentImportException(
        AttachmentImportFailure.malformedFile,
        'The selected file is malformed or does not match its declared type.',
      );
    }

    if ((mimeType == 'image/heic' || mimeType == 'image/heif') &&
        !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      return;
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(bytes),
      );
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (!_hasSafeImageDescriptor(descriptor)) {
            throw const FormatException('Decoded image dimensions are unsafe.');
          }
          final codec = await descriptor.instantiateCodec();
          try {
            final frame = await codec.getNextFrame();
            try {
              if (!_hasSafeImageDimensions(
                frame.image.width,
                frame.image.height,
              )) {
                throw const FormatException(
                  'Decoded image dimensions are unsafe.',
                );
              }
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      throw const AttachmentImportException(
        AttachmentImportFailure.malformedFile,
        'The selected file is malformed or does not match its declared type.',
      );
    }
  }

  static Future<bool> _hasParseablePdf(List<int> bytes) async {
    if (bytes.length < 32 ||
        !_startsWith(bytes, const [0x25, 0x50, 0x44, 0x46, 0x2d])) {
      return false;
    }
    try {
      final document = await PDFParser(
        ByteStream(Uint8List.fromList(bytes)),
      ).parse(cacheObjectsHint: false).timeout(_validationTimeout);
      await document.catalog.timeout(_validationTimeout);
      return true;
    } catch (_) {
      return false;
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

  static _ImageDimensions? _jpegDimensions(List<int> bytes) {
    if (bytes.length < 24 || !_startsWith(bytes, const [0xff, 0xd8])) {
      return null;
    }
    var index = 2;
    _ImageDimensions? dimensions;
    var hasScan = false;
    while (index + 1 < bytes.length) {
      if (bytes[index] != 0xff) {
        if (hasScan) {
          index += 1;
          continue;
        }
        return null;
      }
      while (index < bytes.length && bytes[index] == 0xff) {
        index += 1;
      }
      if (index >= bytes.length) {
        return null;
      }
      final marker = bytes[index++];
      if (marker == 0xd9) {
        return dimensions != null && hasScan && index == bytes.length
            ? dimensions
            : null;
      }
      if (marker == 0x00 ||
          marker == 0xd8 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (index + 1 >= bytes.length) {
        return null;
      }
      final segmentLength = (bytes[index] << 8) | bytes[index + 1];
      if (segmentLength < 2 || index + segmentLength > bytes.length) {
        return null;
      }
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        if (segmentLength < 8 || dimensions != null) {
          return null;
        }
        dimensions = _ImageDimensions(
          width: (bytes[index + 5] << 8) | bytes[index + 6],
          height: (bytes[index + 3] << 8) | bytes[index + 4],
        );
      }
      if (marker == 0xda && segmentLength >= 8) {
        hasScan = true;
      }
      index += segmentLength;
    }
    return null;
  }

  static _ImageDimensions? _pngDimensions(List<int> bytes) {
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
      return null;
    }
    var index = 8;
    var firstChunk = true;
    var hasImageData = false;
    var hasIend = false;
    _ImageDimensions? dimensions;
    while (index + 12 <= bytes.length) {
      final length = _readUint32(bytes, index);
      if (length < 0 || length > bytes.length - index - 12) {
        return null;
      }
      final typeStart = index + 4;
      final type = String.fromCharCodes(
        bytes.sublist(typeStart, typeStart + 4),
      );
      final dataStart = index + 8;
      if (firstChunk) {
        if (type != 'IHDR' ||
            length != 13 ||
            bytes[dataStart + 10] != 0 ||
            bytes[dataStart + 11] != 0 ||
            bytes[dataStart + 12] > 1) {
          return null;
        }
        dimensions = _ImageDimensions(
          width: _readUint32(bytes, dataStart),
          height: _readUint32(bytes, dataStart + 4),
        );
        firstChunk = false;
      } else if (type == 'IHDR') {
        return null;
      }
      if (type == 'IDAT' && length > 0) {
        hasImageData = true;
      }
      index += 12 + length;
      if (type == 'IEND') {
        hasIend = length == 0 && index == bytes.length;
        break;
      }
    }
    return !firstChunk && hasImageData && hasIend ? dimensions : null;
  }

  static _ImageDimensions? _isoBaseMediaDimensions(List<int> bytes) {
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
    final topLevelBoxes = _readIsoBoxes(bytes, 0, bytes.length);
    if (topLevelBoxes == null || topLevelBoxes.isEmpty) {
      return null;
    }

    var hasApprovedBrand = false;
    var hasMetadata = false;
    var hasMediaData = false;
    final dimensions = <_ImageDimensions>[];
    for (final box in topLevelBoxes) {
      if (box.type == 'ftyp') {
        final payloadLength = box.payloadEnd - box.payloadStart;
        if (payloadLength < 8 || (payloadLength - 8) % 4 != 0) {
          return null;
        }
        for (
          var index = box.payloadStart;
          index + 3 < box.payloadEnd;
          index += index == box.payloadStart ? 8 : 4
        ) {
          final brand = String.fromCharCodes(bytes.sublist(index, index + 4));
          hasApprovedBrand = hasApprovedBrand || brands.contains(brand);
        }
      } else if (box.type == 'meta') {
        if (box.payloadEnd - box.payloadStart < 4) {
          return null;
        }
        final metadataBoxes = _readIsoBoxes(
          bytes,
          box.payloadStart + 4,
          box.payloadEnd,
        );
        if (metadataBoxes == null) {
          return null;
        }
        final metadataDimensions = _readIsoImageDimensions(
          bytes,
          box.payloadStart + 4,
          box.payloadEnd,
        );
        if (metadataDimensions == null) {
          return null;
        }
        hasMetadata = true;
        hasMediaData =
            hasMediaData ||
            metadataBoxes.any(
              (metadataBox) =>
                  metadataBox.type == 'idat' &&
                  metadataBox.payloadEnd > metadataBox.payloadStart,
            );
        dimensions.addAll(metadataDimensions);
      } else if (box.type == 'mdat') {
        hasMediaData = box.payloadEnd > box.payloadStart;
      }
    }

    if (!hasApprovedBrand ||
        !hasMetadata ||
        !hasMediaData ||
        dimensions.isEmpty ||
        dimensions.any(
          (value) => !_hasSafeImageDimensions(value.width, value.height),
        )) {
      return null;
    }

    return dimensions.reduce(
      (largest, value) =>
          value.width * value.height > largest.width * largest.height
          ? value
          : largest,
    );
  }

  static List<_ImageDimensions>? _readIsoImageDimensions(
    List<int> bytes,
    int start,
    int end,
  ) {
    final boxes = _readIsoBoxes(bytes, start, end);
    if (boxes == null) {
      return null;
    }
    final dimensions = <_ImageDimensions>[];
    for (final box in boxes) {
      if (box.type == 'ispe') {
        if (box.payloadEnd - box.payloadStart < 12) {
          return null;
        }
        dimensions.add(
          _ImageDimensions(
            width: _readUint32(bytes, box.payloadStart + 4),
            height: _readUint32(bytes, box.payloadStart + 8),
          ),
        );
      } else if (box.type == 'iprp' || box.type == 'ipco') {
        final nested = _readIsoImageDimensions(
          bytes,
          box.payloadStart,
          box.payloadEnd,
        );
        if (nested == null) {
          return null;
        }
        dimensions.addAll(nested);
      }
    }
    return dimensions;
  }

  static List<_IsoBox>? _readIsoBoxes(List<int> bytes, int start, int end) {
    final boxes = <_IsoBox>[];
    var offset = start;
    while (offset < end) {
      if (end - offset < 8) {
        return null;
      }
      final size32 = _readUint32(bytes, offset);
      var headerSize = 8;
      int boxSize;
      if (size32 == 0) {
        boxSize = end - offset;
      } else if (size32 == 1) {
        if (end - offset < 16 || _readUint32(bytes, offset + 8) != 0) {
          return null;
        }
        headerSize = 16;
        boxSize = _readUint32(bytes, offset + 12);
      } else {
        boxSize = size32;
      }
      if (boxSize < headerSize || boxSize > end - offset) {
        return null;
      }
      boxes.add(
        _IsoBox(
          type: String.fromCharCodes(bytes.sublist(offset + 4, offset + 8)),
          payloadStart: offset + headerSize,
          payloadEnd: offset + boxSize,
        ),
      );
      offset += boxSize;
    }
    return offset == end ? boxes : null;
  }

  static bool _hasSafeImageDimensions(int width, int height) {
    return width > 0 &&
        height > 0 &&
        width <= _maxImageDimension &&
        height <= _maxImageDimension &&
        width * height <= _maxImagePixels;
  }

  static bool _hasSafeImageDescriptor(ui.ImageDescriptor descriptor) {
    return _hasSafeImageDimensions(descriptor.width, descriptor.height) &&
        descriptor.bytesPerPixel > 0 &&
        descriptor.width * descriptor.height * descriptor.bytesPerPixel <=
            _maxDecodedImageBytes;
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
}

class _ImageDimensions {
  const _ImageDimensions({required this.width, required this.height});

  final int width;
  final int height;
}

class _IsoBox {
  const _IsoBox({
    required this.type,
    required this.payloadStart,
    required this.payloadEnd,
  });

  final String type;
  final int payloadStart;
  final int payloadEnd;
}

enum AttachmentPayloadStatus { available, missing, checksumMismatch }
