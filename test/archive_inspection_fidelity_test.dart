import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:my_art_collection/app/import/archive_inspection.dart';
import 'package:my_art_collection/app/import/archive_inspection_reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/archive_inspection_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ArchiveInspectionFixture fixture;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    fixture = await ArchiveInspectionFixture.create(rich: true);
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
    'real export inspection preserves represented values directly from SQLite',
    () async {
      final file = await fixture.export();
      final result = await ArchiveInspectionReader(
        scratchDirectory: fixture.scratch,
      ).inspect(file);
      expect(
        result.sourceSha256,
        sha256.convert(await file.readAsBytes()).toString(),
      );
      expect(result.sourceBytes, await file.length());
      expect(result.supportsCompleteRecovery, isFalse);
      expect(result.derivativeRowCountKnown, isFalse);
      for (final row in result.rows) {
        final sourceRows = await fixture.database.query(row.table);
        final represented = row.fields.entries.where(
          (e) =>
              e.value.coverage != ArchiveFieldCoverage.notRepresentedByVersion,
        );
        final matching = sourceRows.where(
          (source) => represented.every((e) => source[e.key] == e.value.value),
        );
        expect(
          matching,
          hasLength(1),
          reason:
              '${row.table}/${row.identity}: compare source values, not re-exported omissions',
        );
      }
      final original = result.attachments.singleWhere(
        (a) => a.row.identity == 'original',
      );
      expect(original.payloadCoverage, ArchivePayloadCoverage.included);
      for (final field in [
        'notes',
        'captured_at',
        'source_state',
        'extraction_summary',
        'lifecycle_updated_at',
        'superseded_by_attachment_id',
        'derived_from_attachment_id',
        'transform_summary',
      ]) {
        expect(
          original.row.fields[field]!.coverage,
          ArchiveFieldCoverage.notRepresentedByVersion,
          reason: field,
        );
      }
      expect(
        result.attachments.map((a) => a.row.identity),
        isNot(contains('derivative')),
      );
      expect(
        (await fixture.database.query('attachments')).length,
        result.attachments.length + 1,
      );
      final field = result.rows.firstWhere(
        (r) => r.table == 'artwork_fields' && r.identity.endsWith('/title'),
      );
      expect(
        field.fields['last_confirmed_at']!.coverage,
        ArchiveFieldCoverage.presentNull,
      );
      expect(field.fields['source_state']!.value, 'user-confirmed');
      final preference = result.rows.singleWhere(
        (r) => r.table == 'artwork_preferences',
      );
      expect(preference.fields['is_favorite']!.value, 0);
      for (final table in result.unrepresentedTables) {
        expect(await fixture.database.query(table), isNotEmpty);
        expect(result.rows.where((r) => r.table == table), isEmpty);
      }
      expect(await fixture.scratch.list().toList(), isEmpty);
    },
  );

  test(
    'excluded lifecycle rows retain missingness and do not fabricate payload metadata',
    () async {
      final result = await ArchiveInspectionReader(
        scratchDirectory: fixture.scratch,
      ).inspect(await fixture.export());
      for (final id in ['removed', 'superseded', 'unavailable']) {
        final attachment = result.attachments.singleWhere(
          (a) => a.row.identity == id,
        );
        expect(attachment.row.fields['lifecycle_status']!.value, id);
        expect(
          attachment.row.fields['file_name']!.coverage,
          ArchiveFieldCoverage.notRepresentedByVersion,
        );
        expect(
          attachment.row.fields['checksum']!.coverage,
          ArchiveFieldCoverage.notRepresentedByVersion,
        );
        expect(attachment.payloadPath, isNull);
        expect(
          attachment.payloadCoverage,
          id == 'unavailable'
              ? ArchivePayloadCoverage.unavailable
              : ArchivePayloadCoverage.excludedByLifecycle,
        );
      }
      expect(
        result.relationships
            .where((r) => r.kind == 'primary_image')
            .single
            .coverage,
        ArchiveRelationshipCoverage.verified,
      );
      expect(
        result.relationships
            .where((r) => r.kind == 'attachment_lineage')
            .every(
              (r) =>
                  r.coverage ==
                  ArchiveRelationshipCoverage.unprovableFromVersion,
            ),
        isTrue,
      );
      expect(() => result.rows.clear(), throwsUnsupportedError);
      expect(
        () => result.attachments.first.row.fields.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('schema coverage accounts for every durable table and column', () async {
    final tables = (await fixture.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
    )).map((r) => r['name'] as String).toSet();
    expect(tables, archiveV2SchemaCoverage.keys.toSet());
    for (final table in tables) {
      final columns = (await fixture.database.rawQuery(
        'PRAGMA table_info($table)',
      )).map((r) => r['name']).toSet();
      expect(
        archiveV2SchemaCoverage[table]!.keys.toSet(),
        columns,
        reason: table,
      );
    }
  });
}
