/// Collection records only. None of these values authorize activation or work.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../import/archive_inspection.dart';

enum BackupRecordFailure {
  invalidRecords,
  unsupportedSchema,
  unsupportedResourceLimit,
  cancelled,
  sourceUnavailable,
}

class BackupRecordException implements Exception {
  const BackupRecordException(this.failure);
  final BackupRecordFailure failure;
  @override
  String toString() => 'Backup records: ${failure.name}.';
}

Never invalidBackupRecords() =>
    throw const BackupRecordException(BackupRecordFailure.invalidRecords);
void backupLimit(bool exceeded) {
  if (exceeded) {
    throw const BackupRecordException(
      BackupRecordFailure.unsupportedResourceLimit,
    );
  }
}

class BackupRecordCancellation extends ArchiveInspectionCancellation {
  @override
  void check() {
    try {
      super.check();
    } on ArchiveInspectionException {
      throw const BackupRecordException(BackupRecordFailure.cancelled);
    }
  }
}

abstract final class BackupRecordLimits {
  static const bytes = 16 * 1024 * 1024;
  static const frame = 512 * 1024;
  static const rowText = 256 * 1024;
  static const string = 64 * 1024;
  static const id = 1024;
  static const values = 300000;
  static const rows = 131072;
  static const batch = 128;
}

/// A marker, not the source path and not a destination path.
enum BackupDevicePath { reconstructLater }

final class BackupRecordRow {
  BackupRecordRow(this.table, Map<String, Object?> values)
    : values = _copyCells(values);
  final String table;
  final Map<String, Object?> values;
}

final class BackupHistoryRecord {
  const BackupHistoryRecord(this.row);
  final BackupRecordRow row;
  String get originalStatus => row.values['status']! as String;
  String get executionDisposition => 'history_only';
}

final class BackupPayloadDiagnostic {
  const BackupPayloadDiagnostic(this.attachmentId);
  final String attachmentId;
  String get kind => 'removedAncestorPayloadPolicyUnresolved';
}

final class BackupRecordBundle {
  BackupRecordBundle(
    Map<String, List<BackupRecordRow>> tables, {
    Iterable<BackupPayloadDiagnostic> diagnostics = const [],
    this.sourceSha256,
  }) : tables = Map.unmodifiable(_copyTables(tables)),
       diagnostics = _copyDiagnostics(diagnostics);
  final Map<String, List<BackupRecordRow>> tables;
  final List<BackupPayloadDiagnostic> diagnostics;
  final String? sourceSha256;
  String get payloadCoverage => 'not_evaluated';
  String get historyExecution => 'inert';
  String get activation => 'unsupported';
  bool get supportsCompleteRecovery => false;
  Iterable<BackupHistoryRecord> get jobs sync* {
    for (final name in ['ai_draft_jobs', 'research_jobs']) {
      for (final row in tables[name] ?? const <BackupRecordRow>[]) {
        yield BackupHistoryRecord(row);
      }
    }
  }
}

Map<String, Object?> _copyCells(Map<String, Object?> values) {
  backupLimit(values.length > 64);
  return Map<String, Object?>.unmodifiable(
    values.map((k, v) => MapEntry(k, _freeze(v))),
  );
}

Map<String, List<BackupRecordRow>> _copyTables(
  Map<String, List<BackupRecordRow>> tables,
) {
  backupLimit(tables.length > 12);
  var rows = 0;
  for (final value in tables.values) {
    backupLimit((rows += value.length) > BackupRecordLimits.rows);
  }
  return tables.map(
    (k, v) => MapEntry(k, List<BackupRecordRow>.unmodifiable(v)),
  );
}

List<BackupPayloadDiagnostic> _copyDiagnostics(
  Iterable<BackupPayloadDiagnostic> input,
) {
  final result = <BackupPayloadDiagnostic>[];
  for (final diagnostic in input) {
    backupLimit(result.length >= 2048);
    result.add(diagnostic);
  }
  return List.unmodifiable(result);
}

Object? _freeze(Object? value) {
  if (value == null ||
      value is String ||
      value is int ||
      value is BackupDevicePath) {
    return value;
  }
  // A portable cell is scalar. In particular, do not retain mutable objects or
  // recursively traverse an untrusted caller's collection.
  invalidBackupRecords();
}

/// Reject replacement-prone UTF-16 before any UTF-8 encoding takes place.
void validateBackupText(
  String value, {
  int maximum = BackupRecordLimits.string,
}) {
  backupLimit(value.length > maximum);
  for (var i = 0; i < value.length; i++) {
    final u = value.codeUnitAt(i);
    if (u >= 0xd800 && u <= 0xdbff) {
      if (++i >= value.length) invalidBackupRecords();
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) invalidBackupRecords();
    } else if (u >= 0xdc00 && u <= 0xdfff) {
      invalidBackupRecords();
    }
  }
  backupLimit(utf8.encode(value).length > maximum);
}

int compareBackupText(String left, String right) {
  final a = utf8.encode(left), b = utf8.encode(right);
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

final _minimumInteger = BigInt.parse('-9223372036854775808');
final _maximumInteger = BigInt.parse('9223372036854775807');
Map<String, String> encodeBackupInteger(int value) => {
  'kind': 'sqlite_int64',
  'decimal': value.toString(),
};
int decodeBackupInteger(Object? cell) {
  if (cell is! Map ||
      cell.length != 2 ||
      cell['kind'] != 'sqlite_int64' ||
      cell['decimal'] is! String) {
    invalidBackupRecords();
  }
  final value = cell['decimal'] as String;
  if (value.length > 20 ||
      !RegExp(r'^(0|-[1-9][0-9]*|[1-9][0-9]*)$').hasMatch(value)) {
    invalidBackupRecords();
  }
  final integer = BigInt.parse(value);
  if (integer < _minimumInteger || integer > _maximumInteger) {
    invalidBackupRecords();
  }
  return integer.toInt();
}

/// Counts JSON nodes/keys before allocation. Syntax, duplicate keys, Unicode and
/// depth are validated by the existing bounded JSON parser immediately after.
Future<int> preflightBackupJson(
  Uint8List bytes,
  BackupRecordCancellation cancel,
) async {
  var count = 0, offset = 0;
  final objects = <int>[];
  while (offset < bytes.length) {
    cancel.check();
    final c = bytes[offset++];
    if (c == 32 || c == 9 || c == 10 || c == 13 || c == 44) continue;
    if (c == 58) {
      if (objects.isNotEmpty && objects.last >= 0) {
        objects[objects.length - 1]++;
        backupLimit(objects.last > 2048);
      }
      continue;
    }
    if (c == 125 || c == 93) {
      if (objects.isNotEmpty) objects.removeLast();
      continue;
    }
    backupLimit(++count > BackupRecordLimits.values);
    if ((count & 1023) == 0) await Future<void>.delayed(Duration.zero);
    if (c == 123 || c == 91) {
      objects.add(c == 123 ? 0 : -1);
      backupLimit(objects.length > 17);
    } else if (c == 34) {
      while (offset < bytes.length) {
        final next = bytes[offset++];
        if (next == 92) {
          offset++; // Existing parser validates the escape and available bytes.
        } else if (next == 34) {
          break;
        }
      }
    } else {
      while (offset < bytes.length &&
          !const [32, 9, 10, 13, 44, 93, 125].contains(bytes[offset])) {
        offset++;
      }
    }
  }
  cancel.check();
  return count;
}
