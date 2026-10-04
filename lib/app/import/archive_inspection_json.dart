import 'dart:convert';
import 'dart:typed_data';

import 'archive_inspection.dart';
import 'archive_inspection_zip.dart' show inspectionLimit, invalidInspection;

/// Allocation preflight, before jsonDecode or any archive codec. It limits
/// nesting, decoded strings, aggregate values and row arrays and rejects
/// duplicate keys. The caller separately bounds the input metadata bytes.
Future<Object?> decodeInspectionJson(
  Uint8List bytes,
  ArchiveInspectionCancellation cancellation,
) async {
  final scan = _JsonPreflight(bytes, cancellation);
  await scan.value(0, null);
  scan.space();
  if (scan.offset != bytes.length) invalidInspection();
  cancellation.check();
  return jsonDecode(utf8.decode(bytes, allowMalformed: false));
}

class _JsonPreflight {
  _JsonPreflight(this.bytes, this.cancellation);
  final Uint8List bytes;
  final ArchiveInspectionCancellation cancellation;
  int offset = 0;
  int values = 0;
  int fields = 0;
  int get current => offset < bytes.length ? bytes[offset] : -1;
  void space() {
    while (current == 32 || current == 9 || current == 10 || current == 13) {
      offset++;
    }
  }

  Future<void> value(int depth, String? key) async {
    cancellation.check();
    inspectionLimit(
      depth > ArchiveInspectionLimits.jsonDepth ||
          ++values > ArchiveInspectionLimits.jsonValues,
    );
    if ((values & 1023) == 0) {
      await Future<void>.delayed(Duration.zero);
      cancellation.check();
    }
    space();
    if (current == 123) {
      offset++;
      space();
      if (current == 125) {
        offset++;
        return;
      }
      final keys = <String>{};
      while (true) {
        space();
        final name = string();
        if (!keys.add(name)) invalidInspection();
        space();
        if (current != 58) invalidInspection();
        offset++;
        await value(depth + 1, name);
        space();
        if (current == 125) {
          offset++;
          return;
        }
        if (current != 44) invalidInspection();
        offset++;
      }
    }
    if (current == 91) {
      offset++;
      space();
      if (current == 93) {
        offset++;
        return;
      }
      var count = 0;
      final cap =
          ArchiveInspectionLimits.arrayRows[key] ??
          ArchiveInspectionLimits.entries;
      while (true) {
        inspectionLimit(++count > cap);
        if (key == 'fields') {
          inspectionLimit(++fields > ArchiveInspectionLimits.artworkFields);
        }
        await value(depth + 1, null);
        space();
        if (current == 93) {
          offset++;
          return;
        }
        if (current != 44) invalidInspection();
        offset++;
      }
    }
    if (current == 34) {
      string();
      return;
    }
    final start = offset;
    while (current >= 0 &&
        current != 44 &&
        current != 93 &&
        current != 125 &&
        current != 32 &&
        current != 9 &&
        current != 10 &&
        current != 13) {
      if (offset - start >= 64) invalidInspection();
      offset++;
    }
    final text = ascii.decode(
      bytes.sublist(start, offset),
      allowInvalid: false,
    );
    if (text != 'true' &&
        text != 'false' &&
        text != 'null' &&
        !RegExp(
          r'^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$',
        ).hasMatch(text)) {
      invalidInspection();
    }
  }

  String string() {
    if (current != 34) invalidInspection();
    final start = offset++;
    while (current != -1) {
      inspectionLimit(
        offset - start > ArchiveInspectionLimits.stringBytes * 6 + 2,
      );
      if ((offset & 1023) == 0) cancellation.check();
      final byte = bytes[offset++];
      if (byte == 34) {
        final value =
            jsonDecode(
                  utf8.decode(
                    Uint8List.sublistView(bytes, start, offset),
                    allowMalformed: false,
                  ),
                )
                as String;
        inspectionLimit(
          utf8.encode(value).length > ArchiveInspectionLimits.stringBytes,
        );
        return value;
      }
      if (byte < 32) invalidInspection();
      if (byte == 92) {
        if (current == -1) invalidInspection();
        final escape = bytes[offset++];
        if (escape == 117) {
          for (var i = 0; i < 4; i++) {
            if (!(current >= 48 && current <= 57 ||
                current >= 65 && current <= 70 ||
                current >= 97 && current <= 102)) {
              invalidInspection();
            }
            offset++;
          }
        } else if (![34, 92, 47, 98, 102, 110, 114, 116].contains(escape)) {
          invalidInspection();
        }
      }
    }
    invalidInspection();
  }
}
