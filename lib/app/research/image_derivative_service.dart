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

/// Produces an upload-only JPEG. Decoding and re-encoding intentionally drops
/// source EXIF and other metadata rather than retaining an original artifact.
class ResearchImageDerivativeService {
  const ResearchImageDerivativeService();

  static const maxLongEdgePx = 1600;
  static const maxByteSize = 1500000;

  Future<BrokerImageDerivative> create(File source) async {
    final bytes = await source.readAsBytes();
    return createFromBytes(bytes);
  }

  BrokerImageDerivative createFromBytes(Uint8List sourceBytes) {
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
}
