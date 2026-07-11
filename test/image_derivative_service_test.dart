import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:my_art_collection/app/research/image_derivative_service.dart';

void main() {
  const service = ResearchImageDerivativeService();

  test(
    're-encodes parsed EXIF GPS/owner/comment and ICC metadata as pixel-only JPEG',
    () {
      final sourceImage = image.Image(width: 2400, height: 1200)
        ..exif.imageIfd['Artist'] = 'collector@example.test'
        ..exif.gpsIfd['GPSLatitude'] = image.IfdValueRational(59, 1)
        ..exif.exifIfd['UserComment'] = image.IfdValueUndefined.list(
          utf8.encode('private-comment'),
        )
        ..iccProfile = image.IccProfile(
          'collector-profile',
          image.IccProfileCompression.none,
          Uint8List.fromList(utf8.encode('private-icc-profile')),
        );
      final source = image.encodeJpg(sourceImage, quality: 98);
      final decodedSource = image.decodeJpg(source)!;
      expect(decodedSource.exif.getTag(0x013b), isNotNull);
      final sourceExifTags = _parseJpegExifTags(Uint8List.fromList(source));
      expect(sourceExifTags, containsAll(<int>[0x013b, 0x0002, 0x9286]));
      expect(
        utf8.decode(source, allowMalformed: true),
        contains('ICC_PROFILE'),
      );

      final derivative = service.createFromBytes(Uint8List.fromList(source));
      final decoded = image.decodeJpg(derivative.bytes);

      expect(derivative.mimeType, 'image/jpeg');
      expect(derivative.bytes.lengthInBytes, lessThanOrEqualTo(1500000));
      expect(derivative.longEdgePx, lessThanOrEqualTo(1600));
      expect(decoded, isNotNull);
      expect(decoded!.width, 1600);
      expect(decoded.height, 800);
      expect(decoded.exif.isEmpty, isTrue);
      expect(decoded.iccProfile, isNull);
      expect(decoded.textData, isNull);
      final output = utf8.decode(derivative.bytes, allowMalformed: true);
      expect(output, isNot(contains('Exif')));
      expect(output, isNot(contains('ICC_PROFILE')));
      expect(output, isNot(contains('collector@example.test')));
      expect(output, isNot(contains('private-comment')));
      expect(output, isNot(contains('private-icc-profile')));
    },
  );

  test('rejects invalid image input without creating a derivative', () {
    expect(
      () => service.createFromBytes(Uint8List.fromList(<int>[1, 2, 3])),
      throwsA(isA<ResearchImageDerivativeException>()),
    );
  });

  test(
    'rejects oversized source bytes and extreme dimensions before decode',
    () {
      expect(
        () => service.createFromBytes(
          Uint8List(ResearchImageDerivativeService.maxSourceByteSize + 1),
        ),
        throwsA(isA<ResearchImageDerivativeException>()),
      );
      expect(
        () =>
            service.createFromBytes(_pngHeader(width: 100000, height: 100000)),
        throwsA(isA<ResearchImageDerivativeException>()),
      );
    },
  );
}

Uint8List _pngHeader({required int width, required int height}) =>
    Uint8List.fromList(<int>[
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      (width >> 24) & 0xff,
      (width >> 16) & 0xff,
      (width >> 8) & 0xff,
      width & 0xff,
      (height >> 24) & 0xff,
      (height >> 16) & 0xff,
      (height >> 8) & 0xff,
      height & 0xff,
    ]);

Set<int> _parseJpegExifTags(Uint8List bytes) {
  var offset = 2;
  while (offset + 4 <= bytes.lengthInBytes) {
    if (bytes[offset] != 0xff) {
      return const {};
    }
    final marker = bytes[offset + 1];
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2 || offset + 2 + length > bytes.lengthInBytes) {
      return const {};
    }
    if (marker == 0xe1 &&
        bytes[offset + 4] == 0x45 &&
        bytes[offset + 5] == 0x78 &&
        bytes[offset + 6] == 0x69 &&
        bytes[offset + 7] == 0x66) {
      return _parseTiffIfds(bytes, offset + 10);
    }
    offset += length + 2;
  }
  return const {};
}

Set<int> _parseTiffIfds(Uint8List bytes, int tiff) {
  if (tiff + 8 > bytes.lengthInBytes ||
      bytes[tiff] != 0x4d ||
      bytes[tiff + 1] != 0x4d) {
    return const {};
  }
  final tags = <int>{};
  void parseIfd(int relativeOffset) {
    final start = tiff + relativeOffset;
    if (start + 2 > bytes.lengthInBytes) {
      return;
    }
    final count = _readUint16(bytes, start);
    for (var index = 0; index < count; index += 1) {
      final entry = start + 2 + index * 12;
      if (entry + 12 > bytes.lengthInBytes) {
        return;
      }
      final tag = _readUint16(bytes, entry);
      tags.add(tag);
      if (tag == 0x8769 || tag == 0x8825) {
        parseIfd(_readUint32(bytes, entry + 8));
      }
    }
  }

  parseIfd(_readUint32(bytes, tiff + 4));
  return tags;
}

int _readUint16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
