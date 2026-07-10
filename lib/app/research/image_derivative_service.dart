import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'broker_payload.dart';

class ResearchImageDerivativeException implements Exception {
  const ResearchImageDerivativeException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ResearchImageDerivativeCreator {
  Future<BrokerImageDerivative> create(File source);
}

/// Produces an upload-only JPEG. Decoding and re-encoding intentionally drops
/// source EXIF and other metadata rather than retaining an original artifact.
class ResearchImageDerivativeService implements ResearchImageDerivativeCreator {
  const ResearchImageDerivativeService();

  static const maxLongEdgePx = 1600;
  static const maxByteSize = 1500000;
  static const maxSourceByteSize = 20 * 1024 * 1024;
  static const maxDecodedPixelCount = 16 * 1024 * 1024;

  @override
  Future<BrokerImageDerivative> create(File source) async {
    final sourceLength = await source.length();
    if (sourceLength <= 0 || sourceLength > maxSourceByteSize) {
      throw const ResearchImageDerivativeException(
        'The selected image is too large to prepare for research.',
      );
    }
    final bytes = await source.readAsBytes();
    return createFromBytes(bytes);
  }

  BrokerImageDerivative createFromBytes(Uint8List sourceBytes) {
    final dimensions = _sourceDimensions(sourceBytes);
    if (sourceBytes.isEmpty || sourceBytes.lengthInBytes > maxSourceByteSize) {
      throw const ResearchImageDerivativeException(
        'The selected image is too large to prepare for research.',
      );
    }
    if (dimensions == null ||
        dimensions.width <= 0 ||
        dimensions.height <= 0 ||
        dimensions.width * dimensions.height > maxDecodedPixelCount) {
      throw const ResearchImageDerivativeException(
        'The selected image could not be prepared for research.',
      );
    }
    image.Image? decoded;
    try {
      decoded = image.decodeImage(sourceBytes);
    } on Object {
      throw const ResearchImageDerivativeException(
        'The selected image could not be prepared for research.',
      );
    }
    if (decoded == null) {
      throw const ResearchImageDerivativeException(
        'The selected image could not be prepared for research.',
      );
    }
    var rendered = image.bakeOrientation(decoded);
    if (rendered.width > maxLongEdgePx || rendered.height > maxLongEdgePx) {
      rendered = _resizeToLongEdge(rendered, maxLongEdgePx);
    }
    rendered = _pixelOnlyRgb(rendered);

    for (var quality = 88; quality >= 40; quality -= 8) {
      final bytes = Uint8List.fromList(
        image.encodeJpg(rendered, quality: quality),
      );
      if (bytes.lengthInBytes <= maxByteSize) {
        return BrokerImageDerivative(
          bytes: bytes,
          longEdgePx: _longEdge(rendered),
        );
      }
    }

    while (_longEdge(rendered) > 64) {
      rendered = _resizeToLongEdge(
        rendered,
        (_longEdge(rendered) * 0.85).floor(),
      );
      final bytes = Uint8List.fromList(image.encodeJpg(rendered, quality: 40));
      if (bytes.lengthInBytes <= maxByteSize) {
        return BrokerImageDerivative(
          bytes: bytes,
          longEdgePx: _longEdge(rendered),
        );
      }
    }
    throw const ResearchImageDerivativeException(
      'The selected image could not be reduced to the research upload limit.',
    );
  }

  image.Image _resizeToLongEdge(image.Image source, int maxLongEdge) {
    if (source.width >= source.height) {
      return image.copyResize(source, width: maxLongEdge);
    }
    return image.copyResize(source, height: maxLongEdge);
  }

  int _longEdge(image.Image source) =>
      source.width > source.height ? source.width : source.height;

  image.Image _pixelOnlyRgb(image.Image source) {
    // A new pixel buffer deliberately has no EXIF, ICC, text, palette, or
    // animation state. JPEG encoding only sees this fresh RGB image.
    final pixels = image.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    image.compositeImage(pixels, source);
    return pixels;
  }
}

class _ImageDimensions {
  const _ImageDimensions(this.width, this.height);

  final int width;
  final int height;
}

_ImageDimensions? _sourceDimensions(Uint8List bytes) {
  return _jpegDimensions(bytes) ??
      _pngDimensions(bytes) ??
      _webpDimensions(bytes);
}

_ImageDimensions? _pngDimensions(Uint8List bytes) {
  const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.lengthInBytes < 24 ||
      !_startsWith(bytes, signature) ||
      String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') {
    return null;
  }
  return _ImageDimensions(_readUint32(bytes, 16), _readUint32(bytes, 20));
}

_ImageDimensions? _jpegDimensions(Uint8List bytes) {
  if (bytes.lengthInBytes < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    return null;
  }
  var offset = 2;
  while (offset + 9 < bytes.lengthInBytes) {
    if (bytes[offset] != 0xff) {
      return null;
    }
    while (offset < bytes.lengthInBytes && bytes[offset] == 0xff) {
      offset += 1;
    }
    if (offset >= bytes.lengthInBytes) {
      return null;
    }
    final marker = bytes[offset++];
    if (marker == 0xd8 ||
        marker == 0xd9 ||
        marker == 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 1 >= bytes.lengthInBytes) {
      return null;
    }
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.lengthInBytes) {
      return null;
    }
    if (_isSofMarker(marker) && length >= 7) {
      return _ImageDimensions(
        (bytes[offset + 5] << 8) | bytes[offset + 6],
        (bytes[offset + 3] << 8) | bytes[offset + 4],
      );
    }
    offset += length;
  }
  return null;
}

bool _isSofMarker(int marker) =>
    (marker >= 0xc0 && marker <= 0xc3) ||
    (marker >= 0xc5 && marker <= 0xc7) ||
    (marker >= 0xc9 && marker <= 0xcb) ||
    (marker >= 0xcd && marker <= 0xcf);

_ImageDimensions? _webpDimensions(Uint8List bytes) {
  if (bytes.lengthInBytes < 30 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WEBP') {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final type = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final length = _readUint32LittleEndian(bytes, offset + 4);
    final data = offset + 8;
    if (length < 0 || data + length > bytes.lengthInBytes) {
      return null;
    }
    if (type == 'VP8X' && length >= 10) {
      return _ImageDimensions(
        1 + _readUint24LittleEndian(bytes, data + 4),
        1 + _readUint24LittleEndian(bytes, data + 7),
      );
    }
    if (type == 'VP8 ' &&
        length >= 10 &&
        bytes[data + 3] == 0x9d &&
        bytes[data + 4] == 0x01 &&
        bytes[data + 5] == 0x2a) {
      return _ImageDimensions(
        ((bytes[data + 7] << 8) | bytes[data + 6]) & 0x3fff,
        ((bytes[data + 9] << 8) | bytes[data + 8]) & 0x3fff,
      );
    }
    if (type == 'VP8L' && length >= 5 && bytes[data] == 0x2f) {
      return _ImageDimensions(
        1 + ((bytes[data + 1] | (bytes[data + 2] << 8)) & 0x3fff),
        1 +
            (((bytes[data + 2] >> 6) |
                    (bytes[data + 3] << 2) |
                    (bytes[data + 4] << 10)) &
                0x3fff),
      );
    }
    offset = data + length + (length.isOdd ? 1 : 0);
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> prefix) =>
    bytes.lengthInBytes >= prefix.length &&
    List<int>.generate(
      prefix.length,
      (index) => index,
    ).every((index) => bytes[index] == prefix[index]);

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readUint32LittleEndian(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _readUint24LittleEndian(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
