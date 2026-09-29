import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'archive_inspection.dart';

/// Structural RFC 1951 check only: no decompressed bytes or output window.
/// RawZLibFilter does not expose stream completion/consumed input and accepts
/// some truncated streams. archive 4.0.9 Inflate also conflates invalid/EOF
/// and final block completion. Neither can enforce this boundary alone.
Future<void> verifyInspectionDeflate(
  RandomAccessFile file,
  int start,
  int compressedBytes,
  int expandedBytes,
  ArchiveInspectionCancellation token,
) async {
  final bits = _Bits(file, start, compressedBytes, token);
  var output = 0;
  var blocks = 0;
  var symbols = 0;
  var finalBlock = false;
  while (!finalBlock) {
    token.check();
    if (++blocks > ArchiveInspectionLimits.deflateBlocks) {
      throw const ArchiveInspectionException(
        ArchiveInspectionFailure.unsupportedResourceLimit,
      );
    }
    if ((blocks & 255) == 0) await Future<void>.delayed(Duration.zero);
    finalBlock = bits.read(1) == 1;
    final type = bits.read(2);
    if (type == 0) {
      bits.align();
      final length = bits.read(16);
      if ((bits.read(16) ^ 0xffff) != length) _invalid();
      output += length;
      if (output > expandedBytes) _invalid();
      for (var i = 0; i < length; i++) {
        bits.read(8);
      }
      continue;
    }
    if (type == 3) _invalid();
    late _Huffman literals;
    late _Huffman distances;
    if (type == 1) {
      literals = _fixedLiterals;
      distances = _fixedDistances;
    } else {
      final literalCount = bits.read(5) + 257;
      final distanceCount = bits.read(5) + 1;
      final codeCount = bits.read(4) + 4;
      if (literalCount > 286) _invalid();
      final codeLengths = List<int>.filled(19, 0);
      for (var i = 0; i < codeCount; i++) {
        codeLengths[_codeOrder[i]] = bits.read(3);
      }
      final codes = _Huffman(codeLengths, complete: true);
      final lengths = <int>[];
      final total = literalCount + distanceCount; // At most 318 entries.
      while (lengths.length < total) {
        final symbol = codes.decode(bits);
        if (symbol < 16) {
          lengths.add(symbol);
        } else {
          int value = 0;
          late int count;
          if (symbol == 16) {
            if (lengths.isEmpty) _invalid();
            value = lengths.last;
            count = bits.read(2) + 3;
          } else if (symbol == 17) {
            count = bits.read(3) + 3;
          } else if (symbol == 18) {
            count = bits.read(7) + 11;
          } else {
            _invalid();
          }
          if (lengths.length + count > total) _invalid();
          lengths.addAll(List.filled(count, value));
        }
      }
      if (lengths[256] == 0) _invalid();
      literals = _Huffman(lengths.sublist(0, literalCount));
      distances = _Huffman(lengths.sublist(literalCount), allowEmpty: true);
    }
    while (true) {
      if ((++symbols & 4095) == 0) {
        await Future<void>.delayed(Duration.zero);
        token.check();
      }
      final symbol = literals.decode(bits);
      if (symbol == 256) break;
      if (symbol < 256) {
        output++;
      } else {
        if (symbol > 285) _invalid();
        final index = symbol - 257;
        final length = _lengthBase[index] + bits.read(_lengthExtra[index]);
        final distanceCode = distances.decode(bits);
        if (distanceCode > 29) _invalid();
        final distance =
            _distanceBase[distanceCode] +
            bits.read(_distanceExtra[distanceCode]);
        if (distance > output || distance > 32768) _invalid();
        output += length;
      }
      if (output > expandedBytes) _invalid();
    }
  }
  // The final byte may contain padding bits, but no extra byte/second stream.
  if (bits.consumed != compressedBytes || output != expandedBytes) _invalid();
  token.check();
}

Never _invalid() => throw const ArchiveInspectionException(
  ArchiveInspectionFailure.invalidArchive,
);

class _Bits {
  _Bits(this.file, this.start, this.length, this.token);
  final RandomAccessFile file;
  final int start, length;
  final ArchiveInspectionCancellation token;
  Uint8List buffer = Uint8List(0);
  int offset = 0, loaded = 0, word = 0, available = 0;
  int get consumed => loaded - buffer.length + offset;
  int read(int count) {
    while (available < count) {
      if (offset == buffer.length) {
        token.check();
        if (loaded == length) _invalid();
        file.setPositionSync(start + loaded);
        buffer = file.readSync(
          min(length - loaded, ArchiveInspectionLimits.bufferBytes),
        );
        if (buffer.isEmpty) _invalid();
        loaded += buffer.length;
        offset = 0;
      }
      word |= buffer[offset++] << available;
      available += 8;
    }
    final result = word & ((1 << count) - 1);
    word >>= count;
    available -= count;
    return result;
  }

  void align() {
    word = 0;
    available = 0;
  }
}

class _Huffman {
  _Huffman(
    List<int> lengths, {
    bool complete = false,
    bool allowEmpty = false,
  }) {
    final counts = List<int>.filled(16, 0);
    for (final length in lengths) {
      if (length < 0 || length > 15) _invalid();
      if (length != 0) {
        counts[length]++;
        maximum = max(maximum, length);
      }
    }
    if (maximum == 0) {
      if (!allowEmpty) _invalid();
      return;
    }
    var left = 1;
    for (var i = 1; i <= 15; i++) {
      left = left * 2 - counts[i];
      if (left < 0) _invalid();
    }
    if (left > 0 && (complete || maximum != 1)) _invalid();
    final next = List<int>.filled(16, 0);
    var code = 0;
    for (var i = 1; i <= 15; i++) {
      code = (code + counts[i - 1]) << 1;
      next[i] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length != 0) codes[length][next[length]++] = symbol;
    }
  }
  final codes = List.generate(16, (_) => <int, int>{});
  int maximum = 0;
  int decode(_Bits bits) {
    var code = 0;
    for (var length = 1; length <= maximum; length++) {
      code = (code << 1) | bits.read(1);
      final symbol = codes[length][code];
      if (symbol != null) return symbol;
    }
    _invalid();
  }
}

final _fixedLiterals = _Huffman(
  List.generate(
    288,
    (i) => i < 144
        ? 8
        : i < 256
        ? 9
        : i < 280
        ? 7
        : 8,
  ),
);
final _fixedDistances = _Huffman(List.filled(32, 5));
const _codeOrder = [
  16,
  17,
  18,
  0,
  8,
  7,
  9,
  6,
  10,
  5,
  11,
  4,
  12,
  3,
  13,
  2,
  14,
  1,
  15,
];
const _lengthBase = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  13,
  15,
  17,
  19,
  23,
  27,
  31,
  35,
  43,
  51,
  59,
  67,
  83,
  99,
  115,
  131,
  163,
  195,
  227,
  258,
];
const _lengthExtra = [
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
];
const _distanceBase = [
  1,
  2,
  3,
  4,
  5,
  7,
  9,
  13,
  17,
  25,
  33,
  49,
  65,
  97,
  129,
  193,
  257,
  385,
  513,
  769,
  1025,
  1537,
  2049,
  3073,
  4097,
  6145,
  8193,
  12289,
  16385,
  24577,
];
const _distanceExtra = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
];
