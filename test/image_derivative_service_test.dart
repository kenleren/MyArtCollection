import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:my_art_collection/app/research/image_derivative_service.dart';

void main() {
  const service = ResearchImageDerivativeService();

  test('re-encodes an EXIF-marked source as an EXIF-free bounded JPEG', () {
    final source = _jpegWithExifMarker(
      image.encodeJpg(image.Image(width: 2400, height: 1200), quality: 98),
    );
    expect(utf8.decode(source, allowMalformed: true), contains('Exif'));

    final derivative = service.createFromBytes(Uint8List.fromList(source));
    final decoded = image.decodeJpg(derivative.bytes);

    expect(derivative.mimeType, 'image/jpeg');
    expect(derivative.bytes.lengthInBytes, lessThanOrEqualTo(1500000));
    expect(derivative.longEdgePx, lessThanOrEqualTo(1600));
    expect(decoded, isNotNull);
    expect(decoded!.width, 1600);
    expect(decoded.height, 800);
    expect(
      utf8.decode(derivative.bytes, allowMalformed: true),
      isNot(contains('Exif')),
    );
  });

  test('rejects invalid image input without creating a derivative', () {
    expect(
      () => service.createFromBytes(Uint8List.fromList(<int>[1, 2, 3])),
      throwsA(isA<ResearchImageDerivativeException>()),
    );
  });
}

List<int> _jpegWithExifMarker(List<int> jpeg) {
  // Valid APP1 marker with a minimal TIFF header. Re-encoding must omit it.
  const app1 = <int>[
    0xff,
    0xe1,
    0x00,
    0x10,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
    0x4d,
    0x4d,
    0x00,
    0x2a,
    0x00,
    0x00,
    0x00,
    0x08,
  ];
  return <int>[jpeg[0], jpeg[1], ...app1, ...jpeg.skip(2)];
}
