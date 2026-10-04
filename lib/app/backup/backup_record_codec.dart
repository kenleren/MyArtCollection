import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../import/archive_inspection.dart';
import '../import/archive_inspection_json.dart';
import 'backup_record_bundle.dart';
import 'backup_record_schema.dart';

Map<String, Object?> _header() => {
  'kind': 'header',
  'format': 'archivale-record-component-v1',
  'sourceSchema': 10,
  'schemaDigest': backupRecordSchemaDigest,
  'payloadCoverage': 'not_evaluated',
  'devicePaths': 'reconstruct_later',
  'historyExecution': 'inert',
  'activation': 'unsupported',
};

/// Memory-only records component. No path, payload, database write or execution API.
class BackupRecordCodec {
  const BackupRecordCodec();

  Future<Uint8List> encode(
    BackupRecordBundle input, {
    BackupRecordCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? BackupRecordCancellation();
    final bundle = await validateBackupBundle(input, cancel);
    final builder = BytesBuilder(copy: false);
    void frame(Map<String, Object?> value) {
      cancel.check();
      final bytes = utf8.encode('${jsonEncode(value)}\n');
      backupLimit(
        bytes.length > BackupRecordLimits.frame ||
            builder.length + bytes.length > BackupRecordLimits.bytes,
      );
      builder.add(bytes);
    }

    frame(_header());
    var rows = 0;
    for (final table in backupRecordTables) {
      final values = bundle.tables[table.name]!;
      frame({'kind': 'table', 'table': table.name, 'rowCount': values.length});
      for (final row in values) {
        if ((rows++ & 127) == 0) await Future<void>.delayed(Duration.zero);
        frame({
          'kind': 'row',
          'values': {
            for (final column in table.columns)
              column.name: _wireValue(row.values[column.name]),
          },
        });
      }
    }
    final hash = sha256.convert(builder.toBytes()).toString();
    frame({
      'kind': 'end',
      'tableCount': 12,
      'rowCount': rows,
      'bodySha256': hash,
    });
    cancel.check();
    return builder.takeBytes();
  }

  Future<BackupRecordBundle> decode(
    Uint8List input, {
    BackupRecordCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? BackupRecordCancellation();
    cancel.check();
    backupLimit(input.length > BackupRecordLimits.bytes);
    // Snapshot before the first asynchronous boundary. Later caller mutation is irrelevant.
    final bytes = Uint8List.fromList(input);
    try {
      var offset = 0, rowCount = 0, jsonValues = 0;
      Future<Map<String, Object?>> frame() async {
        cancel.check();
        final start = offset;
        while (offset < bytes.length && bytes[offset] != 10) {
          if (bytes[offset] == 13) invalidBackupRecords();
          backupLimit(offset - start >= BackupRecordLimits.frame - 1);
          offset++;
        }
        if (offset == bytes.length || offset == start) invalidBackupRecords();
        final frameBytes = Uint8List.sublistView(bytes, start, offset++);
        jsonValues += await preflightBackupJson(frameBytes, cancel);
        backupLimit(jsonValues > BackupRecordLimits.values);
        final parsed = await decodeInspectionJson(frameBytes, cancel);
        if (parsed is! Map<String, Object?>) invalidBackupRecords();
        return parsed;
      }

      final header = await frame(), expected = _header();
      if (!backupShape(header, expected.keys) ||
          expected.entries.any((e) => header[e.key] != e.value)) {
        throw const BackupRecordException(
          BackupRecordFailure.unsupportedSchema,
        );
      }
      final tables = <String, List<BackupRecordRow>>{};
      for (final table in backupRecordTables) {
        final section = await frame();
        if (!backupShape(section, ['kind', 'table', 'rowCount']) ||
            section['kind'] != 'table' ||
            section['table'] != table.name ||
            section['rowCount'] is! int ||
            (section['rowCount']! as int) < 0) {
          invalidBackupRecords();
        }
        final count = section['rowCount']! as int;
        backupLimit(
          count > table.limit || rowCount + count > BackupRecordLimits.rows,
        );
        rowCount += count;
        final rows = <BackupRecordRow>[];
        tables[table.name] = rows;
        for (var i = 0; i < count; i++) {
          if ((i & 127) == 0) await Future<void>.delayed(Duration.zero);
          final row = await frame();
          if (!backupShape(row, ['kind', 'values']) ||
              row['kind'] != 'row' ||
              row['values'] is! Map<String, Object?>) {
            invalidBackupRecords();
          }
          final values = row['values']! as Map<String, Object?>;
          if (!backupShape(values, table.columns.map((c) => c.name))) {
            invalidBackupRecords();
          }
          rows.add(
            BackupRecordRow(table.name, {
              for (final c in table.columns)
                c.name: _readValue(c, values[c.name]),
            }),
          );
        }
      }
      final bodyEnd = offset;
      final end = await frame();
      if (offset != bytes.length ||
          !backupShape(end, ['kind', 'tableCount', 'rowCount', 'bodySha256']) ||
          end['kind'] != 'end' ||
          end['tableCount'] != 12 ||
          end['rowCount'] != rowCount ||
          end['bodySha256'] !=
              sha256
                  .convert(Uint8List.sublistView(bytes, 0, bodyEnd))
                  .toString()) {
        invalidBackupRecords();
      }
      return await validateBackupBundle(
        BackupRecordBundle(
          tables,
          sourceSha256: sha256.convert(bytes).toString(),
        ),
        cancel,
      );
    } on BackupRecordException {
      rethrow;
    } on ArchiveInspectionException catch (error) {
      if (error.failure == ArchiveInspectionFailure.unsupportedResourceLimit) {
        throw const BackupRecordException(
          BackupRecordFailure.unsupportedResourceLimit,
        );
      }
      invalidBackupRecords();
    } catch (_) {
      invalidBackupRecords();
    }
  }
}

Object? _wireValue(Object? value) {
  if (value == BackupDevicePath.reconstructLater) {
    return {'kind': 'device_path_not_portable'};
  }
  if (value is int) return encodeBackupInteger(value);
  return value;
}

Object? _readValue(BackupColumn column, Object? value) {
  if (column.name == 'relative_path') {
    if (value is! Map ||
        !backupShape(value, ['kind']) ||
        value['kind'] != 'device_path_not_portable') {
      invalidBackupRecords();
    }
    return BackupDevicePath.reconstructLater;
  }
  if (value == null) return null;
  if (column.type == 'INTEGER') return decodeBackupInteger(value);
  if (value is! String) invalidBackupRecords();
  return value;
}
