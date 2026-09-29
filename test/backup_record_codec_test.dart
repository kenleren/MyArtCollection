import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/backup_record_codec.dart';
import 'package:my_art_collection/app/backup/backup_record_schema.dart';
import 'package:my_art_collection/app/backup/backup_record_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_record_fixture.dart';

Matcher failure([BackupRecordFailure? kind]) => throwsA(
  isA<BackupRecordException>().having(
    (e) => e.failure,
    'fixed failure',
    kind ?? isNotNull,
  ),
);
Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List rewrite(
  Uint8List original,
  void Function(List<Map<String, dynamic>>) change,
) {
  final frames = utf8
      .decode(original)
      .trimRight()
      .split('\n')
      .map((v) => jsonDecode(v) as Map<String, dynamic>)
      .toList();
  change(frames);
  final body = '${frames.take(frames.length - 1).map(jsonEncode).join('\n')}\n';
  frames.last['bodySha256'] = sha256.convert(utf8.encode(body)).toString();
  return bytes('$body${jsonEncode(frames.last)}\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = BackupRecordCodec();
  late BackupRecordBundle bundle;
  late Uint8List wire;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final f = await BackupRecordFixture.create();
    try {
      bundle = await const BackupRecordSnapshot().capture(f.database);
      wire = await codec.encode(bundle);
    } finally {
      await f.close();
    }
  });
  test('native signed int64 roundtrip never uses a floating number', () {
    for (final decimal in [
      '-9223372036854775808',
      '-9007199254740993',
      '-9007199254740991',
      '0',
      '9007199254740991',
      '9007199254740993',
      '9223372036854775807',
    ]) {
      final v = BigInt.parse(decimal).toInt();
      expect(decodeBackupInteger(encodeBackupInteger(v)), v);
      expect(encodeBackupInteger(v)['decimal'], decimal);
    }
    for (final text in [
      '9223372036854775808',
      '-9223372036854775809',
      '01',
      '-0',
      '+1',
      '1.0',
      '1e2',
      'NaN',
    ]) {
      expect(
        () => decodeBackupInteger({'kind': 'sqlite_int64', 'decimal': text}),
        failure(),
      );
    }
    for (final value in [
      1,
      1.5,
      null,
      {'kind': 'sqlite_int64', 'decimal': '1', 'extra': false},
    ]) {
      expect(() => decodeBackupInteger(value), failure());
    }
  });
  test(
    'integer maximum survives full record and invalid domains reject',
    () async {
      final max = editBackupRow(bundle, 'attachments', 0, {
        'file_size_bytes': 9223372036854775807,
      });
      expect(
        (await codec.decode(
          await codec.encode(max),
        )).tables['attachments']!.first.values['file_size_bytes'],
        9223372036854775807,
      );
      await expectLater(
        codec.encode(
          editBackupRow(bundle, 'attachments', 0, {'file_size_bytes': -1}),
        ),
        failure(),
      );
      await expectLater(
        codec.encode(
          editBackupRow(bundle, 'artwork_preferences', 0, {'is_favorite': 2}),
        ),
        failure(),
      );
    },
  );
  test('UTF8 ordering differs from UTF16 and uses compound tuples', () {
    expect(compareBackupText('\ue000', '\u{10000}'), lessThan(0));
    final table = backupRecordTables.firstWhere(
      (v) => v.name == 'artwork_fields',
    );
    expect(
      compareBackupRows(
        table,
        BackupRecordRow(table.name, {'artwork_id': 'a', 'field_key': 'bc'}),
        BackupRecordRow(table.name, {'artwork_id': 'ab', 'field_key': 'c'}),
      ),
      lessThan(0),
    );
  });
  test(
    'valid surrogate pair and embedded NUL preserved; lone surrogates reject',
    () async {
      final valid = editBackupRow(bundle, 'artwork_fields', 0, {
        'value': '\u{10000}\u0000',
      });
      expect(
        (await codec.decode(
          await codec.encode(valid),
        )).tables['artwork_fields']!.first.values['value'],
        '\u{10000}\u0000',
      );
      for (final text in [
        String.fromCharCode(0xd800),
        String.fromCharCode(0xdc00),
        'x${String.fromCharCode(0xd800)}x',
      ]) {
        await expectLater(
          codec.encode(
            editBackupRow(bundle, 'artwork_fields', 0, {'value': text}),
          ),
          failure(),
        );
      }
      final escaped = utf8
          .decode(wire)
          .replaceFirst('Collector\\nvalue', r'\ud800');
      await expectLater(codec.decode(bytes(escaped)), failure());
    },
  );
  test('input bytes are bound before the first await', () async {
    final source = Uint8List.fromList(wire);
    final pending = codec.decode(source);
    source.fillRange(0, source.length, 0);
    expect((await pending).tables['artworks'], hasLength(1));
  });
  test('caller containers copied and arbitrary mutable cells refused', () {
    final values = <String, Object?>{'id': 'old'};
    final row = BackupRecordRow('x', values);
    values['id'] = 'new';
    expect(row.values['id'], 'old');
    final list = <BackupRecordRow>[row];
    final map = {'x': list};
    final copy = BackupRecordBundle(map);
    list.clear();
    map.clear();
    expect(copy.tables['x'], hasLength(1));
    for (final value in [
      <String, Object?>{},
      <Object?>[],
      Uint8List(1),
      DateTime.utc(2026),
      1.5,
    ]) {
      expect(() => BackupRecordRow('x', {'value': value}), failure());
    }
  });
  test(
    'truncation extra bytes CR invalid UTF8 duplicate keys and hash tamper reject',
    () async {
      final inputs = [
        Uint8List.sublistView(wire, 0, wire.length - 1),
        Uint8List.fromList([...wire, 10]),
        bytes(utf8.decode(wire).replaceFirst('\n', '\r\n')),
        Uint8List.fromList([0xff, 10]),
        bytes('{"kind":"header","kind":"header"}\n'),
        bytes(utf8.decode(wire).replaceFirst('Collector', 'Changed')),
      ];
      for (final input in inputs) {
        await expectLater(codec.decode(input), failure());
      }
    },
  );
  test(
    'exact header rejects activation payload history and schema changes',
    () async {
      for (final entry in {
        'activation': 'enabled',
        'historyExecution': 'pending',
        'sourceSchema': 9,
        'payloadCoverage': 'complete',
        'schemaDigest': '0' * 64,
      }.entries) {
        await expectLater(
          codec.decode(rewrite(wire, (f) => f.first[entry.key] = entry.value)),
          failure(),
        );
      }
      await expectLater(
        codec.decode(rewrite(wire, (f) => f.first['payloads'] = [])),
        failure(),
      );
    },
  );
  test(
    'missing versus null and extra execution columns reject after valid checksum',
    () async {
      await expectLater(
        codec.decode(
          rewrite(
            wire,
            (f) => (f.firstWhere((v) => v['kind'] == 'row')['values'] as Map)
                .remove('primary_image_attachment_id'),
          ),
        ),
        failure(),
      );
      await expectLater(
        codec.decode(
          rewrite(
            wire,
            (f) =>
                (f.firstWhere((v) => v['kind'] == 'row')['values']
                        as Map)['dispatch_ticket'] =
                    'no',
          ),
        ),
        failure(),
      );
      await expectLater(
        codec.decode(
          rewrite(
            wire,
            (f) =>
                (f.firstWhere((v) => v['kind'] == 'row')['values']
                        as Map)['created_at'] =
                    null,
          ),
        ),
        failure(),
      );
    },
  );
  test(
    'table order counts duplicate rows and trailer counts cannot be repaired by hash',
    () async {
      await expectLater(
        codec.decode(rewrite(wire, (f) => f[1]['table'] = 'attachments')),
        failure(),
      );
      await expectLater(
        codec.decode(rewrite(wire, (f) => f[1]['rowCount'] = 2)),
        failure(),
      );
      await expectLater(
        codec.decode(rewrite(wire, (f) => f.last['rowCount'] = 0)),
        failure(),
      );
      await expectLater(
        codec.decode(rewrite(wire, (f) => f[1]['rowCount'] = 4097)),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test('path marker is closed; raw or null paths never portable', () async {
    for (final value in [
      null,
      'source/path',
      {'kind': 'device_path_not_portable', 'path': 'x'},
    ]) {
      await expectLater(
        codec.decode(
          rewrite(wire, (f) {
            for (final row in f) {
              final v = row['values'];
              if (v is Map && v.containsKey('relative_path')) {
                v['relative_path'] = value;
                break;
              }
            }
          }),
        ),
        failure(),
      );
    }
  });
  test(
    'string frame byte and depth bounds reject without truncation',
    () async {
      final at = editBackupRow(bundle, 'artwork_fields', 0, {
        'value': 'a' * 65536,
      });
      expect(
        (await codec.decode(
          await codec.encode(at),
        )).tables['artwork_fields']!.first.values['value'],
        hasLength(65536),
      );
      await expectLater(
        codec.encode(
          editBackupRow(bundle, 'artwork_fields', 0, {'value': 'a' * 65537}),
        ),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      await expectLater(
        codec.decode(Uint8List(BackupRecordLimits.bytes + 1)),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      await expectLater(
        codec.decode(bytes(' ' * BackupRecordLimits.frame + '\n')),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      await expectLater(
        codec.decode(bytes('${'[' * 18}0${']' * 18}\n')),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test(
    'row and escaped-frame limits apply independently of each string',
    () async {
      final row = editBackupRow(bundle, 'research_source_hits', 0, {
        'title': 'x' * 65536,
        'artist': 'x' * 65536,
        'date_text': 'x' * 65536,
        'medium': 'x' * 65536,
      });
      await expectLater(
        codec.encode(row),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      final frame = editBackupRow(bundle, 'artwork_fields', 0, {
        'value': '\u0000' * 65536,
        'source_note': '\u0000' * 65536,
      });
      await expectLater(
        codec.encode(frame),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      expect(
        () => BackupRecordRow('x', {for (var i = 0; i < 65; i++) '$i': null}),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      expect(
        () => BackupRecordBundle({for (var i = 0; i < 13; i++) '$i': []}),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      expect(
        () => BackupRecordBundle({
          'x': List.filled(
            BackupRecordLimits.rows + 1,
            bundle.tables['artworks']!.first,
          ),
        }),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test(
    'every table count and local-id ceiling rejects before interpreting surplus rows',
    () async {
      for (final table in backupRecordTables) {
        final rows = List.filled(
          table.limit + 1,
          bundle.tables[table.name]!.first,
        );
        await expectLater(
          codec.encode(
            BackupRecordBundle({...bundle.tables, table.name: rows}),
          ),
          failure(BackupRecordFailure.unsupportedResourceLimit),
        );
      }
      final at = editBackupRow(bundle, 'artwork_fields', 0, {
        'field_key': 'x' * 1024,
      });
      expect(
        (await codec.decode(
          await codec.encode(at),
        )).tables['artwork_fields']!.first.values['field_key'],
        hasLength(1024),
      );
      await expectLater(
        codec.encode(
          editBackupRow(bundle, 'artwork_fields', 0, {'field_key': 'x' * 1025}),
        ),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test(
    'raw-text and encoded-byte ceilings are independent and symmetric',
    () async {
      final empty = {
        for (final table in backupRecordTables) table.name: <BackupRecordRow>[],
      };
      empty['artworks'] = [
        BackupRecordRow('artworks', {
          ...bundle.tables['artworks']!.first.values,
          'primary_image_attachment_id': null,
        }),
      ];
      final text = 'x' * 65000;
      BackupRecordBundle many(int count) => BackupRecordBundle({
        ...empty,
        'artwork_fields': List.generate(
          count,
          (i) => BackupRecordRow('artwork_fields', {
            'artwork_id': 'art-1',
            'field_key': i.toString().padLeft(5, '0'),
            'value': text,
            'money_amount': null,
            'money_currency_code': null,
            'source_state': 'unknown',
            'source_note': '',
            'last_confirmed_at': null,
          }),
        ),
      });
      final at = await codec.encode(many(257));
      expect(at.length, lessThanOrEqualTo(BackupRecordLimits.bytes));
      expect((await codec.decode(at)).tables['artwork_fields'], hasLength(257));
      // Source text fits, but required JSON framing pushes encoding over16MiB.
      final rawFits = many(258);
      await validateBackupBundle(rawFits, BackupRecordCancellation());
      await expectLater(
        codec.encode(rawFits),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
      await expectLater(
        validateBackupBundle(many(259), BackupRecordCancellation()),
        failure(BackupRecordFailure.unsupportedResourceLimit),
      );
    },
  );
  test(
    'every nullable column preserves explicit null when logically compatible',
    () async {
      for (final table in backupRecordTables) {
        for (final column in table.columns.where((c) => c.nullable)) {
          final changed = editBackupRow(bundle, table.name, 0, {
            column.name: null,
          });
          final result = await codec.decode(await codec.encode(changed));
          expect(
            result.tables[table.name]!.first.values.containsKey(column.name),
            isTrue,
          );
          expect(
            result.tables[table.name]!.first.values[column.name],
            isNull,
            reason: '${table.name}.${column.name}',
          );
        }
      }
    },
  );
  test(
    'cancel before and during encode/decode yields no completed artifact',
    () async {
      final cancelled = BackupRecordCancellation()..cancel();
      await expectLater(
        codec.encode(bundle, cancellation: cancelled),
        failure(BackupRecordFailure.cancelled),
      );
      await expectLater(
        codec.decode(wire, cancellation: cancelled),
        failure(BackupRecordFailure.cancelled),
      );
      final middle = BackupRecordCancellation();
      final future = codec.decode(wire, cancellation: middle);
      middle.cancel();
      await expectLater(future, failure(BackupRecordFailure.cancelled));
      final encoder = BackupRecordCancellation();
      final pending = codec.encode(bundle, cancellation: encoder);
      encoder.cancel();
      await expectLater(pending, failure(BackupRecordFailure.cancelled));
    },
  );
}
