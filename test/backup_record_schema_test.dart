import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/backup_record_codec.dart';
import 'package:my_art_collection/app/backup/backup_record_schema.dart';
import 'package:my_art_collection/app/backup/backup_record_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_record_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupRecordBundle rich;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final f = await BackupRecordFixture.create();
    try {
      rich = await const BackupRecordSnapshot().capture(f.database);
    } finally {
      await f.close();
    }
  });
  final invalid = throwsA(isA<BackupRecordException>());
  Future<BackupRecordBundle> check(
    BackupRecordBundle b, {
    BackupRecordCancellation? cancellation,
  }) => validateBackupBundle(b, cancellation ?? BackupRecordCancellation());
  test(
    'unknown enum, missing nullable, wrong type, dates and malformed JSON never default',
    () async {
      for (final patch in [
        {'record_state': 'future'},
        {'created_at': '2026-02-30T00:00:00.000Z'},
        {'created_at': '2026-09-29T12:00:00Z'},
        {'updated_at': '0000-01-01T00:00:00.000Z'},
        {'artwork_id': 'bad\u0000id'},
      ]) {
        await expectLater(
          check(editBackupRow(rich, 'artworks', 0, patch)),
          invalid,
        );
      }
      for (final value in [
        '[1]',
        '["x",null]',
        '["\\ud800"]',
        jsonEncode(List.filled(2049, 'x')),
      ]) {
        await expectLater(
          check(
            editBackupRow(rich, 'ai_draft_jobs', 0, {
              'search_terms_json': value,
            }),
          ),
          invalid,
        );
      }
      for (final value in [
        '{"x":"unknown","x":"unknown"}',
        '{"x":1}',
        '{"x":"future"}',
        '{"":"unknown"}',
        jsonEncode({for (var i = 0; i < 2049; i++) 'k$i': 'unknown'}),
      ]) {
        await expectLater(
          check(
            editBackupRow(rich, 'candidate_attributions', 0, {
              'field_sources_json': value,
            }),
          ),
          invalid,
        );
      }
      final cells = {...rich.tables['artwork_fields']!.first.values}
        ..remove('money_amount');
      final tables = {
        ...rich.tables,
        'artwork_fields': [BackupRecordRow('artwork_fields', cells)],
      };
      await expectLater(check(BackupRecordBundle(tables)), invalid);
    },
  );
  test('all frozen v1 enums retain exact values without fallback', () async {
    for (final entry in backupRecordEnums.entries) {
      var table = entry.key.contains('.')
          ? entry.key.split('.').first
          : switch (entry.key) {
              'source_state' => 'artwork_fields',
              'attachment_type' || 'attachment_role' => 'attachments',
              'source_type' || 'confidence' => 'research_source_hits',
              _ => 'external_references',
            };
      final column = entry.key.split('.').last;
      for (final value in entry.value) {
        final patch = <String, Object?>{column: value};
        if (table == 'attachments') {
          if (column == 'attachment_type') {
            patch['attachment_role'] = value == 'photo'
                ? 'supporting_photo'
                : 'supporting_document';
          }
          if (column == 'attachment_role') {
            patch['attachment_type'] = value == 'supporting_document'
                ? 'receipt'
                : 'photo';
          }
        }
        if (table == 'external_references') {
          if (column == 'review_state' && value == 'confirmed') {
            patch['last_confirmed_at'] = BackupRecordFixture.time;
          }
          if (column == 'origin' && value == 'manual') {
            patch['review_state'] = 'confirmed';
            patch['last_confirmed_at'] = BackupRecordFixture.time;
          }
        }
        expect(
          (await check(
            editBackupRow(rich, table, 0, patch),
          )).tables[table]!.first.values[column],
          value,
        );
      }
    }
  });
  test('nullable and empty evidence strings retain distinct values', () async {
    for (final patch in [
      {'money_amount': null, 'money_currency_code': ''},
      {'money_amount': '', 'money_currency_code': null},
      {'money_amount': '100', 'money_currency_code': null},
    ]) {
      final value = await check(
        editBackupRow(rich, 'artwork_fields', 0, patch),
      );
      for (final entry in patch.entries) {
        expect(
          value.tables['artwork_fields']!.first.values[entry.key],
          entry.value,
        );
      }
    }
  });
  test('missing parents cross-job references and cycles reject', () async {
    for (final pair in [
      ('artwork_fields', {'artwork_id': 'missing'}),
      ('artwork_group_memberships', {'group_id': 'missing'}),
      ('candidate_attributions', {'research_job_id': 'research-running'}),
      ('artworks', {'primary_image_attachment_id': 'derivative'}),
      ('attachments', {'derived_from_attachment_id': 'missing'}),
      ('attachments', {'derived_from_attachment_id': 'child-of-removed'}),
      ('attachments', {'superseded_by_attachment_id': 'child-of-removed'}),
      ('artwork_groups', {'normalized_name': 'WRONG'}),
      ('external_references', {'origin': 'manual'}),
    ]) {
      await expectLater(
        check(editBackupRow(rich, pair.$1, 0, pair.$2)),
        invalid,
      );
    }
    final cycle = editBackupRow(
      rich,
      'attachments',
      rich.tables['attachments']!.indexWhere(
        (r) => r.values['attachment_id'] == 'removed',
      ),
      {'derived_from_attachment_id': 'child-of-removed'},
    );
    await expectLater(check(cycle), invalid);
    final crossArt = BackupRecordBundle({
      ...rich.tables,
      'artworks': [
        ...rich.tables['artworks']!,
        BackupRecordRow('artworks', {
          ...rich.tables['artworks']!.first.values,
          'artwork_id': 'art-2',
          'primary_image_attachment_id': null,
        }),
      ],
    });
    await expectLater(
      check(editBackupRow(crossArt, 'attachments', 0, {'artwork_id': 'art-2'})),
      invalid,
    );
  });
  test('sorted unique tuples cannot merge or reorder records', () async {
    await expectLater(
      check(
        BackupRecordBundle({
          ...rich.tables,
          'attachments': rich.tables['attachments']!.reversed.toList(),
        }),
      ),
      invalid,
    );
    await expectLater(
      check(
        BackupRecordBundle({
          ...rich.tables,
          'artwork_fields': [
            rich.tables['artwork_fields']!.first,
            rich.tables['artwork_fields']!.first,
          ],
        }),
      ),
      invalid,
    );
  });
  test(
    'reader and writer share exact high-count aggregate budget including wire keys',
    () async {
      final art = rich.tables['artworks']!.first;
      final empty = {
        for (final table in backupRecordTables) table.name: <BackupRecordRow>[],
      };
      empty['artworks'] = [
        BackupRecordRow('artworks', {
          ...art.values,
          'primary_image_attachment_id': null,
        }),
      ];
      BackupRecordBundle many(int count) => BackupRecordBundle({
        ...empty,
        'artwork_fields': List.generate(
          count,
          (i) => BackupRecordRow('artwork_fields', {
            'artwork_id': 'art-1',
            'field_key': i.toString().padLeft(5, '0'),
            'value': '',
            'money_amount': null,
            'money_currency_code': null,
            'source_state': 'unknown',
            'source_note': '',
            'last_confirmed_at': null,
          }),
        ),
      });
      // Header/table/trailer110 + artwork18 + N*(row5 + eight key/value pairs16).
      final under = many(14279); // 299987 nodes
      final wire = await const BackupRecordCodec().encode(under);
      expect(
        (await const BackupRecordCodec().decode(wire)).tables['artwork_fields'],
        hasLength(14279),
      );
      await expectLater(
        const BackupRecordCodec().encode(many(14280)),
        throwsA(
          isA<BackupRecordException>().having(
            (e) => e.failure,
            'limit',
            BackupRecordFailure.unsupportedResourceLimit,
          ),
        ),
      );
    },
  );
  test(
    'embedded nodes consume the same component budget and map2048 cap',
    () async {
      final value = jsonEncode(List.filled(2048, 'x'));
      final at = editBackupRow(rich, 'ai_draft_jobs', 0, {
        'search_terms_json': value,
      });
      expect(
        (await const BackupRecordCodec().decode(
          await const BackupRecordCodec().encode(at),
        )).tables['ai_draft_jobs']!.first.values['search_terms_json'],
        value,
      );
    },
  );
  test('timer cancellation runs during long lineage pass', () async {
    final tables = {
      for (final t in backupRecordTables) t.name: <BackupRecordRow>[],
    };
    tables['artworks'] = [
      BackupRecordRow('artworks', {
        ...rich.tables['artworks']!.first.values,
        'primary_image_attachment_id': null,
      }),
    ];
    tables['attachments'] = List.generate(
      1000,
      (i) => BackupRecordRow('attachments', {
        ...rich.tables['attachments']!.first.values,
        'attachment_id': i.toString().padLeft(4, '0'),
        'derived_from_attachment_id': i == 0
            ? null
            : (i - 1).toString().padLeft(4, '0'),
        'superseded_by_attachment_id': null,
        'lifecycle_status': 'active',
      }),
    );
    final cancel = _LineageCancellation();
    await expectLater(
      check(BackupRecordBundle(tables), cancellation: cancel),
      throwsA(
        isA<BackupRecordException>().having(
          (e) => e.failure,
          'cancelled',
          BackupRecordFailure.cancelled,
        ),
      ),
    );
    expect(cancel.timerFired, isTrue);
    expect(cancel.checks, greaterThan(5000));
  });
}

// Schedule after scalar/relationship passes, while graph work is in progress.
class _LineageCancellation extends BackupRecordCancellation {
  var checks = 0;
  var timerFired = false;
  @override
  void check() {
    if (++checks == 6000) {
      Timer.run(() {
        timerFired = true;
        cancel();
      });
    }
    super.check();
  }
}
