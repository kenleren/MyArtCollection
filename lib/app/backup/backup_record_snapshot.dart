import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'backup_record_bundle.dart';
import 'backup_record_schema.dart';

/// Explicit supplied-database capture only. Does not open, upgrade or write a DB.
class BackupRecordSnapshot {
  const BackupRecordSnapshot();
  Future<BackupRecordBundle> capture(
    Database database, {
    BackupRecordCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? BackupRecordCancellation();
    try {
      cancel.check();
      final bundle = await database.transaction((tx) async {
        await _schema(tx, cancel);
        var totalRows = 0, rawBytes = 0;
        final counts = <String, int>{};
        // Preflight all tables before materializing any collector text.
        for (final table in backupRecordTables) {
          cancel.check();
          final sizes = <String>[], bad = <String>[];
          for (final c in table.columns) {
            final name = _q(c.name);
            final expected = c.type == 'INTEGER' ? 'integer' : 'text';
            bad.add(
              "(typeof($name) NOT IN ('$expected'${c.nullable ? ",'null'" : ''}))",
            );
            if (c.type == 'TEXT' && c.name != 'relative_path') {
              final size = 'coalesce(length(CAST($name AS BLOB)),0)';
              sizes.add(size);
            }
          }
          final rowSize = sizes.isEmpty ? '0' : sizes.join('+');
          final result = (await tx.rawQuery(
            'SELECT count(*) AS n, '
            'coalesce(sum($rowSize),0) AS bytes, coalesce(max($rowSize),0) AS rowbytes, '
            'coalesce(max(${sizes.isEmpty
                ? '0'
                : sizes.length == 1
                ? sizes.single
                : 'max(${sizes.join(',')})'}),0) AS cellbytes, '
            'coalesce(sum(CASE WHEN ${bad.join(' OR ')} THEN 1 ELSE 0 END),0) AS bad '
            'FROM ${_q(table.name)}',
          )).single;
          cancel.check();
          final count = result['n']! as int;
          counts[table.name] = count;
          totalRows += count;
          rawBytes += result['bytes']! as int;
          backupLimit(
            count > table.limit ||
                totalRows > BackupRecordLimits.rows ||
                rawBytes > BackupRecordLimits.bytes ||
                (result['rowbytes']! as int) > BackupRecordLimits.rowText ||
                (result['cellbytes']! as int) > BackupRecordLimits.string,
          );
          if (result['bad'] != 0) invalidBackupRecords();
        }
        final tables = <String, List<BackupRecordRow>>{};
        for (final table in backupRecordTables) {
          final rows = <BackupRecordRow>[];
          tables[table.name] = rows;
          final projection = table.columns
              .map(
                (c) => c.name == 'relative_path'
                    ? 'NULL AS ${_q(c.name)}'
                    : c.type == 'TEXT'
                    ? 'CAST(${_q(c.name)} AS BLOB) AS ${_q(c.name)}'
                    : _q(c.name),
              )
              .join(',');
          final order = table.keys
              .map((k) => '${_q(k)} COLLATE BINARY')
              .join(',');
          for (
            var offset = 0;
            offset < counts[table.name]!;
            offset += BackupRecordLimits.batch
          ) {
            cancel.check();
            final batch = await tx.rawQuery(
              'SELECT $projection FROM ${_q(table.name)} '
              'ORDER BY $order LIMIT ${BackupRecordLimits.batch} OFFSET $offset',
            );
            cancel.check();
            for (final record in batch) {
              final values = <String, Object?>{};
              for (final c in table.columns) {
                final value = record[c.name];
                values[c.name] = c.name == 'relative_path'
                    ? BackupDevicePath.reconstructLater
                    : value == null || c.type == 'INTEGER'
                    ? value
                    : utf8.decode(value as Uint8List, allowMalformed: false);
              }
              rows.add(BackupRecordRow(table.name, values));
            }
          }
          if (rows.length != counts[table.name]) invalidBackupRecords();
        }
        cancel.check();
        return BackupRecordBundle(tables);
      });
      cancel.check();
      return await validateBackupBundle(bundle, cancel);
    } on BackupRecordException {
      rethrow;
    } on FormatException {
      invalidBackupRecords();
    } catch (_) {
      throw const BackupRecordException(BackupRecordFailure.sourceUnavailable);
    }
  }
}

String _q(String name) => '"${name.replaceAll('"', '""')}"';
Never _unsupported() =>
    throw const BackupRecordException(BackupRecordFailure.unsupportedSchema);

Future<void> _schema(Transaction tx, BackupRecordCancellation cancel) async {
  cancel.check();
  if ((await tx.rawQuery('PRAGMA user_version')).single.values.single != 10) {
    _unsupported();
  }
  // Only scalar lengths/counts cross this boundary, before names or DDL allocation.
  final size = (await tx.rawQuery(
    'SELECT count(*) AS n, '
    'coalesce(max(length(CAST(name AS BLOB))),0) AS namebytes, '
    'coalesce(max(length(CAST(tbl_name AS BLOB))),0) AS tablebytes, '
    'coalesce(max(length(CAST(sql AS BLOB))),0) AS ddlbytes, '
    'coalesce(sum(length(CAST(name AS BLOB))+length(CAST(tbl_name AS BLOB))+coalesce(length(CAST(sql AS BLOB)),0)),0) AS bytes '
    'FROM sqlite_master',
  )).single;
  cancel.check();
  backupLimit(
    (size['n']! as int) > 128 ||
        (size['namebytes']! as int) > 256 ||
        (size['tablebytes']! as int) > 256 ||
        (size['ddlbytes']! as int) > 32768 ||
        (size['bytes']! as int) > 262144,
  );
  var metadataBytes = 0;
  Future<List<Map<String, Object?>>> pragma(
    String function,
    String name,
    Map<String, int> bounds,
  ) async {
    cancel.check();
    final sum = bounds.keys
        .map((k) => 'coalesce(length(CAST(${_q(k)} AS BLOB)),0)')
        .join('+');
    final maxima = bounds.keys
        .map(
          (k) => 'coalesce(max(length(CAST(${_q(k)} AS BLOB))),0) AS ${_q(k)}',
        )
        .join(',');
    final result = (await tx.rawQuery(
      'SELECT count(*) AS n, coalesce(sum($sum),0) AS bytes, $maxima FROM $function(?)',
      [name],
    )).single;
    cancel.check();
    metadataBytes += result['bytes']! as int;
    backupLimit(
      (result['n']! as int) > 64 ||
          metadataBytes > 262144 ||
          bounds.entries.any((e) => (result[e.key]! as int) > e.value),
    );
    final resultRows = await tx.rawQuery('SELECT * FROM $function(?)', [name]);
    cancel.check();
    return resultRows;
  }

  for (final table in backupRecordTables) {
    final columns = await pragma('pragma_table_info', table.name, {
      'name': 256,
      'type': 64,
      'dflt_value': 1024,
    });
    if (columns.length != table.columns.length) _unsupported();
    for (final column in table.columns) {
      final matching = columns.where((r) => r['name'] == column.name).toList();
      if (matching.length != 1 || matching.single['type'] != column.type) {
        _unsupported();
      }
    }
    await pragma('pragma_foreign_key_list', table.name, {
      'table': 256,
      'from': 256,
      'to': 256,
      'on_update': 64,
      'on_delete': 64,
      'match': 64,
    });
    final indexes = await pragma('pragma_index_list', table.name, {
      'name': 256,
      'origin': 64,
    });
    for (final index in indexes) {
      final name = index['name']! as String;
      await pragma('pragma_index_info', name, {'name': 256});
      await pragma('pragma_index_xinfo', name, {'name': 256, 'coll': 64});
    }
  }
  final objects = await tx.rawQuery(
    'SELECT type,name,tbl_name,sql FROM sqlite_master',
  );
  cancel.check();
  final found = <String>{};
  for (final object in objects) {
    final name = object['name']! as String, type = object['type']! as String;
    if (name == 'android_metadata' && type == 'table') continue;
    if (name.startsWith('sqlite_')) {
      if (type == 'index' &&
          name.startsWith('sqlite_autoindex_') &&
          object['sql'] == null &&
          backupRecordTables.any((t) => t.name == object['tbl_name'])) {
        continue;
      }
      if (type == 'table' &&
          ['sqlite_sequence', 'sqlite_stat1', 'sqlite_stat4'].contains(name)) {
        continue;
      }
      _unsupported();
    }
    final expected = backupSchemaSql[name];
    if (expected == null || object['sql'] is! String || !found.add(name)) {
      _unsupported();
    }
    final actualTokens = _tokens(object['sql']! as String),
        expectedTokens = _tokens(expected);
    if (type == 'table') {
      final actual = _clauses(actualTokens), wanted = _clauses(expectedTokens);
      if (name == 'attachments') {
        const migrated =
            "ATTACHMENT_ROLE TEXT NOT NULL DEFAULT 'supporting_document'";
        actual.remove(migrated)
            ? actual.add('ATTACHMENT_ROLE TEXT NOT NULL')
            : null;
      }
      actual.sort();
      wanted.sort();
      if (actual.join('\n') != wanted.join('\n')) _unsupported();
    } else if (actualTokens.join(' ') != expectedTokens.join(' ')) {
      _unsupported();
    }
  }
  if (found.length != backupSchemaSql.length ||
      !backupSchemaSql.keys.every(found.contains)) {
    _unsupported();
  }
}

/// Tiny comparison lexer for the finite known DDL, not an archive SQL evaluator.
List<String> _tokens(String sql) {
  final expression = RegExp(
    r''''(?:''|[^'])*'|"(?:""|[^"])*"|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|!=|>=|<=|<>|[(),.*=<>+;\-]''',
  );
  var offset = 0;
  final result = <String>[];
  for (final match in expression.allMatches(sql)) {
    if (sql.substring(offset, match.start).trim().isNotEmpty) _unsupported();
    final token = match.group(0)!;
    result.add(
      token.startsWith("'")
          ? token
          : token.startsWith('"')
          ? token
                .substring(1, token.length - 1)
                .replaceAll('""', '"')
                .toUpperCase()
          : token.toUpperCase(),
    );
    offset = match.end;
  }
  if (sql.substring(offset).trim().isNotEmpty) _unsupported();
  return result;
}

List<String> _clauses(List<String> tokens) {
  if (tokens.length < 5 ||
      tokens[0] != 'CREATE' ||
      tokens[1] != 'TABLE' ||
      tokens[3] != '(' ||
      tokens.last != ')') {
    _unsupported();
  }
  final result = <String>['CREATE TABLE ${tokens[2]}'];
  var depth = 0, start = 4;
  for (var i = 4; i < tokens.length - 1; i++) {
    if (tokens[i] == '(') depth++;
    if (tokens[i] == ')') depth--;
    if (depth < 0) _unsupported();
    if (depth == 0 && tokens[i] == ',') {
      result.add(tokens.sublist(start, i).join(' '));
      start = i + 1;
    }
  }
  if (depth != 0) _unsupported();
  result.add(tokens.sublist(start, tokens.length - 1).join(' '));
  return result;
}
