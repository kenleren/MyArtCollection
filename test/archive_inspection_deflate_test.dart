import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/import/archive_inspection.dart';
import 'package:my_art_collection/app/import/archive_inspection_deflate.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('deflate-test-'),
  );
  tearDown(() async => root.delete(recursive: true));

  Future<void> verify(List<int> compressed, int expanded) async {
    final file = await File('${root.path}/compressed').writeAsBytes(compressed);
    final handle = await file.open();
    try {
      await verifyInspectionDeflate(
        handle,
        0,
        compressed.length,
        expanded,
        ArchiveInspectionCancellation(),
      );
    } finally {
      await handle.close();
    }
  }

  final invalid = throwsA(
    isA<ArchiveInspectionException>().having(
      (e) => e.failure,
      'failure',
      ArchiveInspectionFailure.invalidArchive,
    ),
  );

  for (final mode in ['stored', 'fixed', 'dynamic']) {
    test('$mode stream agrees with native decoder', () async {
      final input = List.generate(12000, (i) => (i % 100) < 80 ? 65 : i % 251);
      final compressed = ZLibEncoder(
        raw: true,
        level: mode == 'stored' ? 0 : 6,
        strategy: mode == 'fixed'
            ? ZLibOption.strategyFixed
            : ZLibOption.strategyDefault,
      ).convert(input);
      expect(
        (compressed.first >> 1) & 3,
        ['stored', 'fixed', 'dynamic'].indexOf(mode),
      );
      expect(ZLibDecoder(raw: true).convert(compressed), input);
      await verify(compressed, input.length);
      await expectLater(
        verify(compressed.sublist(0, compressed.length - 1), input.length),
        invalid,
      );
      await expectLater(verify([...compressed, 0], input.length), invalid);
    });
  }

  test(
    'bounded seeded differential fixtures include incompressible and multiblock data',
    () async {
      final random = Random(194180);
      for (final length in [0, 1, 17, 1024, 65536, 150000]) {
        for (final strategy in [
          ZLibOption.strategyDefault,
          ZLibOption.strategyFixed,
          ZLibOption.strategyHuffmanOnly,
        ]) {
          final input = List.generate(
            length,
            (i) => i % 3 == 0 ? 65 : random.nextInt(256),
          );
          final compressed = ZLibEncoder(
            raw: true,
            strategy: strategy,
          ).convert(input);
          expect(ZLibDecoder(raw: true).convert(compressed), input);
          await verify(compressed, input.length);
        }
      }
    },
  );

  test(
    'exact minimal native truncation regression: 03 lacks final EOB bit',
    () async {
      // Native raw inflate accepts [03] as empty; strict parsing requires [03 00].
      expect(ZLibDecoder(raw: true).convert([0x03]), isEmpty);
      await expectLater(verify([0x03], 0), invalid);
      await verify([0x03, 0x00], 0);
    },
  );

  test('fixed length/distance is valid only with sufficient history', () async {
    final valid = _BitWriter()
      ..bits(3, 3)
      ..literal(65)
      ..literal(257)
      ..huffman(0, 5)
      ..literal(256);
    expect(ZLibDecoder(raw: true).convert(valid.bytes), [65, 65, 65, 65]);
    await verify(valid.bytes, 4);
    final invalidHistory = _BitWriter()
      ..bits(3, 3)
      ..literal(257)
      ..huffman(0, 5)
      ..literal(256);
    await expectLater(verify(invalidHistory.bytes, 3), invalid);
  });

  test(
    'reserved block, literal and distance codes and stored complement fail',
    () async {
      final reservedLiteral = _BitWriter()
        ..bits(3, 3)
        ..literal(286);
      final reservedDistance = _BitWriter()
        ..bits(3, 3)
        ..literal(65)
        ..literal(257)
        ..huffman(30, 5);
      for (final bytes in <List<int>>[
        [7], // Reserved BTYPE 3.
        [1, 0, 0, 0, 0], // Stored LEN/NLEN disagree.
        reservedLiteral.bytes,
        reservedDistance.bytes,
      ]) {
        await expectLater(verify(bytes, 10), invalid);
      }
    },
  );

  test(
    'oversubscribed, incomplete and missing dynamic code tables fail',
    () async {
      for (final lengths in [
        [1, 1, 1, 0],
        [2, 0, 0, 0],
        [0, 0, 0, 0],
      ]) {
        final writer = _BitWriter()
          ..bits(5, 3)
          ..bits(0, 5)
          ..bits(0, 5)
          ..bits(0, 4);
        for (final length in lengths) {
          writer.bits(length, 3);
        }
        await expectLater(verify(writer.bytes, 0), invalid);
      }
    },
  );

  test(
    'output count mismatch fails even when the deflate stream is valid',
    () async {
      final compressed = ZLibEncoder(raw: true).convert([1, 2, 3]);
      await expectLater(verify(compressed, 2), invalid);
      await expectLater(verify(compressed, 4), invalid);
    },
  );
}

class _BitWriter {
  final _bytes = <int>[];
  int _current = 0, _count = 0;
  List<int> get bytes => [..._bytes, if (_count != 0) _current];
  void bits(int value, int count) {
    for (var i = 0; i < count; i++) {
      _current |= ((value >> i) & 1) << _count++;
      if (_count == 8) {
        _bytes.add(_current);
        _current = 0;
        _count = 0;
      }
    }
  }

  void huffman(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      bits((value >> i) & 1, 1);
    }
  }

  void literal(int value) {
    if (value < 144) {
      huffman(0x30 + value, 8);
    } else if (value < 256) {
      huffman(0x190 + value - 144, 9);
    } else if (value < 280) {
      huffman(value - 256, 7);
    } else {
      huffman(0xc0 + value - 280, 8);
    }
  }
}
