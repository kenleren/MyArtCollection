import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/backup_record_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_record_fixture.dart';

Matcher failed(BackupRecordFailure kind) => throwsA(
  isA<BackupRecordException>().having((e) => e.failure, 'fixed failure', kind),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  Future<BackupRecordFixture> fixture({bool rich = true}) async {
    final f = await BackupRecordFixture.create(rich: rich);
    addTearDown(f.close);
    return f;
  }

  test(
    'schema metadata name and DDL lengths checked before text projection',
    () async {
      for (final ddl in [
        'CREATE TABLE "${'x' * 257}" (x TEXT)',
        "CREATE TABLE oversized (x TEXT DEFAULT '${'x' * 32769}')",
      ]) {
        final f = await fixture(rich: false);
        await f.database.execute(ddl);
        final seen = <String>[];
        await expectLater(
          const BackupRecordSnapshot().capture(
            WatchingDatabase(f.database, (sql) async {
              seen.add(sql);
            }),
          ),
          failed(BackupRecordFailure.unsupportedResourceLimit),
        );
        expect(
          seen.any(
            (sql) => sql == 'SELECT type,name,tbl_name,sql FROM sqlite_master',
          ),
          isFalse,
        );
        expect(
          (await f.database.rawQuery(
            'PRAGMA user_version',
          )).single.values.single,
          10,
        );
      }
    },
  );
  test('default length bounded before DDL and PRAGMA text allocation', () async {
    final f = await fixture(rich: false);
    await f.database.execute(
      "ALTER TABLE artworks ADD COLUMN oversized TEXT DEFAULT '${'x' * 1025}'",
    );
    final seen = <String>[];
    await expectLater(
      const BackupRecordSnapshot().capture(
        WatchingDatabase(f.database, (sql) async {
          seen.add(sql);
        }),
      ),
      failed(BackupRecordFailure.unsupportedResourceLimit),
    );
    expect(
      seen.any(
        (sql) => sql == 'SELECT type,name,tbl_name,sql FROM sqlite_master',
      ),
      isFalse,
    );
    expect(
      seen.any((sql) => sql == 'SELECT * FROM pragma_table_info(?)'),
      isFalse,
    );
  });
  test('metadata object count fails before materialization', () async {
    final f = await fixture(rich: false);
    for (var i = 0; i < 129; i++) {
      await f.database.execute('CREATE TABLE extra$i (x TEXT)');
    }
    final seen = <String>[];
    await expectLater(
      const BackupRecordSnapshot().capture(
        WatchingDatabase(f.database, (sql) async {
          seen.add(sql);
        }),
      ),
      failed(BackupRecordFailure.unsupportedResourceLimit),
    );
    expect(seen.any((sql) => sql.startsWith('SELECT type,name')), isFalse);
  });
  for (final entry in <String, String>{
    'missing trigger': 'DROP TRIGGER external_references_immutable_fields',
    'extra table': 'CREATE TABLE extra (x TEXT)',
    'extra column': 'ALTER TABLE artworks ADD COLUMN extra TEXT',
    'extra index': 'CREATE INDEX extra ON artworks(record_state)',
    'wrong schema': 'PRAGMA user_version=9',
    'missing table': 'DROP TABLE artwork_preferences',
  }.entries) {
    test('${entry.key} rejects without repairing source', () async {
      final f = await fixture(rich: false);
      await f.database.execute(entry.value);
      final before = await f.database.rawQuery(
        'SELECT type,name,sql FROM sqlite_master ORDER BY name',
      );
      await expectLater(
        const BackupRecordSnapshot().capture(f.database),
        failed(BackupRecordFailure.unsupportedSchema),
      );
      expect(
        await f.database.rawQuery(
          'SELECT type,name,sql FROM sqlite_master ORDER BY name',
        ),
        before,
      );
    });
  }
  test('changed known trigger and role default are not normalized away', () async {
    final f = await fixture(rich: false);
    await f.database.execute(
      'DROP TRIGGER external_references_immutable_fields',
    );
    await f.database.execute(
      "CREATE TRIGGER external_references_immutable_fields BEFORE UPDATE ON external_references BEGIN SELECT RAISE(ABORT, 'different'); END",
    );
    await expectLater(
      const BackupRecordSnapshot().capture(f.database),
      failed(BackupRecordFailure.unsupportedSchema),
    );
    final other = await fixture(rich: false);
    await other.database.execute('PRAGMA writable_schema=ON');
    await other.database.rawUpdate(
      "UPDATE sqlite_master SET sql=replace(sql, 'attachment_role TEXT NOT NULL', 'attachment_role TEXT NOT NULL DEFAULT ''photo''') WHERE name='attachments'",
    );
    await other.database.execute('PRAGMA writable_schema=OFF');
    await expectLater(
      const BackupRecordSnapshot().capture(other.database),
      failed(BackupRecordFailure.unsupportedSchema),
    );
  });
  test('cell bound preflight never fetches oversized row text', () async {
    final f = await fixture();
    await f.database.update('artwork_fields', {'value': 'x' * 65537});
    final seen = <String>[];
    await expectLater(
      const BackupRecordSnapshot().capture(
        WatchingDatabase(f.database, (sql) async {
          seen.add(sql);
        }),
      ),
      failed(BackupRecordFailure.unsupportedResourceLimit),
    );
    expect(
      seen.any((sql) => sql.contains('ORDER BY') && sql.contains(' LIMIT ')),
      isFalse,
    );
    expect(
      (await f.database.rawQuery(
        'SELECT length(value) n FROM artwork_fields',
      )).single['n'],
      65537,
    );
  });
  test(
    'wrong SQLite dynamic type and malformed UTF8 do not become defaults',
    () async {
      final f = await fixture();
      await f.database.update('attachments', {
        'file_size_bytes': 'not integer',
      });
      await expectLater(
        const BackupRecordSnapshot().capture(f.database),
        failed(BackupRecordFailure.invalidRecords),
      );
      await f.database.update('attachments', {'file_size_bytes': 4});
      await f.database.execute(
        "UPDATE artwork_fields SET value=CAST(x'eda080' AS TEXT)",
      );
      await expectLater(
        const BackupRecordSnapshot().capture(f.database),
        failed(BackupRecordFailure.invalidRecords),
      );
    },
  );
  test(
    'source row and per-table ceilings reject before row text projection',
    () async {
      final f = await fixture();
      await f.database.update('research_source_hits', {
        'title': 'x' * 65536,
        'artist': 'x' * 65536,
        'date_text': 'x' * 65536,
        'medium': 'x' * 65536,
      });
      final seen = <String>[];
      await expectLater(
        const BackupRecordSnapshot().capture(
          WatchingDatabase(f.database, (sql) async {
            seen.add(sql);
          }),
        ),
        failed(BackupRecordFailure.unsupportedResourceLimit),
      );
      expect(seen.any((sql) => sql.contains(' LIMIT ')), isFalse);
      final count = await fixture(rich: false);
      await count.database.rawInsert(
        "WITH RECURSIVE n(x) AS (SELECT 0 UNION ALL SELECT x+1 FROM n WHERE x<4096) INSERT INTO artworks(artwork_id,record_state,lifecycle_status,created_at,updated_at) SELECT 'art-'||x,'draft','active','2026-09-29T00:00:00.000Z','2026-09-29T00:00:00.000Z' FROM n",
      );
      await expectLater(
        const BackupRecordSnapshot().capture(count.database),
        failed(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test(
    'actual SQLite BINARY ordering preserves non-BMP and tuple identities',
    () async {
      final f = await fixture(rich: false);
      for (final id in ['\u{10000}', '\ue000']) {
        await f.database.insert('artworks', {
          'artwork_id': id,
          'record_state': 'draft',
          'lifecycle_status': 'active',
          'created_at': BackupRecordFixture.time,
          'updated_at': BackupRecordFixture.time,
        });
        for (final key in ['bc', 'b']) {
          await f.database.insert('artwork_fields', {
            'artwork_id': id,
            'field_key': key,
            'value': key,
            'source_state': 'unknown',
            'source_note': '',
          });
        }
      }
      final snapshot = await const BackupRecordSnapshot().capture(f.database);
      expect(snapshot.tables['artworks']!.map((r) => r.values['artwork_id']), [
        '\ue000',
        '\u{10000}',
      ]);
      expect(
        snapshot.tables['artwork_fields']!.map((r) => r.values['field_key']),
        ['b', 'bc', 'b', 'bc'],
      );
    },
  );
  test('local path value is never selected, even when huge', () async {
    final f = await fixture();
    await f.database.update('attachments', {'relative_path': 'x' * 100000});
    final seen = <String>[];
    final result = await const BackupRecordSnapshot().capture(
      WatchingDatabase(f.database, (sql) async {
        seen.add(sql);
      }),
    );
    expect(
      result.tables['attachments']!.every(
        (row) =>
            row.values['relative_path'] == BackupDevicePath.reconstructLater,
      ),
      isTrue,
    );
    final rows = seen.where((sql) => sql.contains(' LIMIT '));
    expect(rows.any((sql) => sql.contains('CAST("relative_path"')), isFalse);
    expect(rows.any((sql) => sql.contains('NULL AS "relative_path"')), isTrue);
  });
  test(
    'cancel after SQL await and closed source return only fixed errors',
    () async {
      final f = await fixture();
      final cancel = BackupRecordCancellation();
      await expectLater(
        const BackupRecordSnapshot().capture(
          WatchingDatabase(f.database, (sql) async {
            if (sql.contains('count(*) AS n')) cancel.cancel();
          }),
          cancellation: cancel,
        ),
        failed(BackupRecordFailure.cancelled),
      );
      expect((await f.database.query('artworks')).length, 1);
      await f.database.close();
      await expectLater(
        const BackupRecordSnapshot().capture(f.database),
        failed(BackupRecordFailure.sourceUnavailable),
      );
    },
  );
  test(
    'one real transaction sees committed WAL data and excludes a concurrent writer',
    () async {
      final f = await fixture();
      await f.database.rawQuery('PRAGMA journal_mode=WAL');
      await f.database.update('artwork_fields', {'value': 'before'});
      final other = await databaseFactory.openDatabase(
        f.database.path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(other.close);
      Future<void>? writer;
      var transactions = 0;
      final watched = WatchingDatabase(f.database, (sql) async {
        if (writer == null &&
            sql.contains('FROM "artwork_fields"') &&
            sql.contains(' LIMIT ')) {
          // sqflite's actual transaction uses BEGIN IMMEDIATE. A competing
          // writer fails busy rather than being allowed to tear this snapshot.
          writer = expectLater(
            other.transaction((tx) async {
              await tx.update('artwork_fields', {'value': 'after'});
              await tx.update('artworks', {'record_state': 'draft'});
            }),
            throwsA(
              isA<DatabaseException>().having(
                (e) => e.toString(),
                'SQLite busy',
                contains('database is locked'),
              ),
            ),
          );
        }
      }, onTransaction: () => transactions++);
      final snapshot = await const BackupRecordSnapshot().capture(watched);
      await writer!.timeout(const Duration(seconds: 5));
      expect(transactions, 1);
      expect(
        snapshot.tables['artwork_fields']!.first.values['value'],
        'before',
      );
      expect(
        snapshot.tables['artworks']!.first.values['record_state'],
        'verifiedByYou',
      );
      await other.transaction((tx) async {
        await tx.update('artwork_fields', {'value': 'after'});
        await tx.update('artworks', {'record_state': 'draft'});
      });
      final after = await const BackupRecordSnapshot().capture(f.database);
      expect(after.tables['artwork_fields']!.first.values['value'], 'after');
      expect(after.tables['artworks']!.first.values['record_state'], 'draft');
    },
  );
}

class WatchingDatabase implements Database {
  WatchingDatabase(this.inner, this.afterQuery, {this.onTransaction});
  final Database inner;
  final Future<void> Function(String) afterQuery;
  final void Function()? onTransaction;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) {
    onTransaction?.call();
    return inner.transaction(
      (tx) => action(_WatchingTransaction(tx, afterQuery)),
      exclusive: exclusive,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WatchingTransaction implements Transaction {
  _WatchingTransaction(this.inner, this.afterQuery);
  final Transaction inner;
  final Future<void> Function(String) afterQuery;
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final result = await inner.rawQuery(sql, arguments);
    await afterQuery(sql);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
