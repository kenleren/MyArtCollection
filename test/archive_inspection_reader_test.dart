import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/import/archive_inspection.dart';
import 'package:my_art_collection/app/import/archive_inspection_json.dart';
import 'package:my_art_collection/app/import/archive_inspection_reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/archive_inspection_fixture.dart';

Matcher failure(ArchiveInspectionFailure value) => throwsA(
  isA<ArchiveInspectionException>().having((e) => e.failure, 'failure', value),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ArchiveInspectionFixture fixture;
  late File original;
  late ArchiveInspectionReader reader;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    fixture = await ArchiveInspectionFixture.create();
    original = await fixture.export();
    reader = ArchiveInspectionReader(scratchDirectory: fixture.scratch);
  });
  tearDown(() async {
    expect(await fixture.scratch.list().toList(), isEmpty);
    await fixture.dispose();
  });

  test(
    'accepts current real export and leaves source/database untouched',
    () async {
      final before = await original.readAsBytes();
      final rows = await fixture.database.query('artworks');
      final result = await reader.inspect(original);
      expect(result.rows.where((r) => r.table == 'artworks'), hasLength(1));
      expect(await original.readAsBytes(), before);
      expect(await fixture.database.query('artworks'), rows);
    },
  );

  test('unknown root version is unsupported, never treated as V2', () async {
    final entries = await archiveEntries(original);
    mutateJson(entries, 'manifest.json', (root) => root['version'] = 3);
    await expectLater(
      reader.inspect(await writeArchive(fixture.root, entries)),
      failure(ArchiveInspectionFailure.unsupportedVersion),
    );
  });

  for (final path in [
    '../outside',
    '/absolute',
    'attachments/id/payload.exe',
    'unlisted.txt',
  ]) {
    test('rejects unapproved entry $path', () async {
      final entries = await archiveEntries(original)
        ..[path] = [1];
      await expectLater(
        reader.inspect(await writeArchive(fixture.root, entries)),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    });
  }

  test('rejects duplicate ZIP names before decoding entries', () async {
    final entries = await archiveEntries(original);
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    archive.modifyAtIndex(
      1,
      ArchiveFile(
        'manifest.json',
        entries['manifest.json']!.length,
        entries['manifest.json']!,
      ),
    );
    final file = await File(
      '${fixture.root.path}/duplicate.zip',
    ).writeAsBytes(ZipEncoder().encode(archive));
    await expectLater(
      reader.inspect(file),
      failure(ArchiveInspectionFailure.invalidArchive),
    );
  });

  for (final mutation in [
    'overlap',
    'local-name',
    'local-size',
    'crc',
    'symlink',
    'trailing',
    'truncated',
    'flags',
  ]) {
    test('rejects ZIP $mutation inconsistency', () async {
      var bytes = await original.readAsBytes();
      final central = _central(bytes);
      switch (mutation) {
        case 'overlap':
          _set32(bytes, central[1] + 42, 0);
        case 'local-name':
          bytes[30] = 120;
        case 'local-size':
          _set32(bytes, 22, 1);
        case 'crc':
          _set32(bytes, 14, 1);
          _set32(bytes, central.first + 16, 1);
        case 'symlink':
          _set32(bytes, central.first + 38, 0xa000 << 16);
        case 'trailing':
          bytes = Uint8List.fromList([...bytes, 1]);
        case 'truncated':
          bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
        case 'flags':
          _set16(bytes, central.first + 8, 1);
      }
      final file = await File(
        '${fixture.root.path}/hostile.zip',
      ).writeAsBytes(bytes);
      await expectLater(
        reader.inspect(file),
        failure(
          mutation == 'flags'
              ? ArchiveInspectionFailure.unsupportedZipFeature
              : ArchiveInspectionFailure.invalidArchive,
        ),
      );
    });
  }

  for (final mutation in [
    'entry-count',
    'manifest-size',
    'metadata-size',
    'payload-size',
    'path-size',
  ]) {
    test('rejects declared $mutation limit before allocation', () async {
      final bytes = await original.readAsBytes();
      final central = _central(bytes);
      switch (mutation) {
        case 'entry-count':
          _set16(bytes, bytes.length - 12, ArchiveInspectionLimits.entries + 1);
        case 'manifest-size':
          _set32(
            bytes,
            central.first + 24,
            ArchiveInspectionLimits.manifestBytes + 1,
          );
        case 'metadata-size':
          _set32(
            bytes,
            central[1] + 24,
            ArchiveInspectionLimits.structuredEntryBytes + 1,
          );
        case 'payload-size':
          _set32(
            bytes,
            central.first + 20,
            ArchiveInspectionLimits.inputBytes + 1,
          );
        case 'path-size':
          _set16(
            bytes,
            central.first + 28,
            ArchiveInspectionLimits.pathBytes + 1,
          );
      }
      final file = await File(
        '${fixture.root.path}/limits.zip',
      ).writeAsBytes(bytes);
      await expectLater(
        reader.inspect(file),
        failure(ArchiveInspectionFailure.unsupportedResourceLimit),
      );
    });
  }

  test('rejects sparse oversized input before creating a snapshot', () async {
    final file = File('${fixture.root.path}/oversized.zip');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(ArchiveInspectionLimits.inputBytes + 1);
    await handle.close();
    await expectLater(
      reader.inspect(file),
      failure(ArchiveInspectionFailure.unsupportedResourceLimit),
    );
  });

  test(
    'aggregate expanded and metadata caps are checked before inflation',
    () async {
      for (final metadata in [true, false]) {
        final entries = await archiveEntries(original);
        if (!metadata) {
          for (var i = 0; i < 9; i++) {
            entries['attachments/p$i/payload.pdf'] = [0];
          }
        }
        final file = await writeArchive(fixture.root, entries);
        final bytes = await file.readAsBytes();
        final headers = _central(bytes);
        for (final offset
            in metadata ? headers.skip(1).take(3) : headers.skip(5)) {
          _set32(
            bytes,
            offset + 24,
            metadata
                ? ArchiveInspectionLimits.structuredEntryBytes
                : ArchiveInspectionLimits.payloadBytes,
          );
        }
        await file.writeAsBytes(bytes);
        await expectLater(
          reader.inspect(file),
          failure(ArchiveInspectionFailure.unsupportedResourceLimit),
        );
      }
    },
  );

  test(
    'payload cap accepts the header boundary and rejects one beyond',
    () async {
      final entries = await archiveEntries(original);
      _addPayload(entries, [0]);
      final file = await writeArchive(fixture.root, entries);
      final bytes = await file.readAsBytes();
      final offset = _central(bytes).last;
      _set32(bytes, offset + 24, ArchiveInspectionLimits.payloadBytes);
      await file.writeAsBytes(bytes);
      // The boundary reaches local consistency checking, not an allocation or
      // resource-limit failure; the deliberately unchanged local size is invalid.
      await expectLater(
        reader.inspect(file),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
      _set32(bytes, offset + 24, ArchiveInspectionLimits.payloadBytes + 1);
      await file.writeAsBytes(bytes);
      await expectLater(
        reader.inspect(file),
        failure(ArchiveInspectionFailure.unsupportedResourceLimit),
      );
    },
  );

  test(
    'source symlinks are not opened and snapshot mutations are rejected',
    () async {
      final link = await Link(
        '${fixture.root.path}/link.zip',
      ).create(original.path);
      await expectLater(
        reader.inspect(File(link.path)),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
      await expectLater(
        reader.inspect(
          original,
          onPhase: (phase) async {
            if (phase == ArchiveInspectionPhase.validated) {
              final directory = (await fixture.scratch.list().toList()).single;
              await File('${directory.path}/input.zip').writeAsBytes([0]);
            }
          },
        ),
        failure(ArchiveInspectionFailure.sourceChanged),
      );
    },
  );

  test(
    'actual inflation exceeding declared length is rejected during streaming',
    () async {
      final entries = await archiveEntries(original);
      entries['manifest.json'] = utf8.encode('x' * (512 * 1024));
      final file = await writeArchive(fixture.root, entries, rehash: false);
      final bytes = await file.readAsBytes();
      _set32(bytes, 22, 1);
      _set32(bytes, _central(bytes).first + 24, 1);
      await file.writeAsBytes(bytes);
      await expectLater(
        reader.inspect(file),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    },
  );

  test(
    'truncated deflate data is rejected even with a consistent ZIP layout',
    () async {
      final bytes = await original.readAsBytes();
      final view = ByteData.sublistView(bytes);
      final compressed = view.getUint32(18, Endian.little);
      final dataStart = 30 + view.getUint16(26, Endian.little);
      final oldCentral = view.getUint32(bytes.length - 6, Endian.little);
      final remove = dataStart + compressed - 1;
      final truncated = Uint8List.fromList([
        ...bytes.take(remove),
        ...bytes.skip(remove + 1),
      ]);
      _set32(truncated, 18, compressed - 1);
      _set32(truncated, truncated.length - 6, oldCentral - 1);
      final headers = _central(truncated);
      _set32(truncated, headers.first + 20, compressed - 1);
      for (final header in headers.skip(1)) {
        final offset = ByteData.sublistView(
          truncated,
        ).getUint32(header + 42, Endian.little);
        _set32(truncated, header + 42, offset - 1);
      }
      final file = await File(
        '${fixture.root.path}/truncated-deflate.zip',
      ).writeAsBytes(truncated);
      await expectLater(
        reader.inspect(file),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    },
  );

  test(
    'manifest checksums do not excuse an attachment-index hash mismatch',
    () async {
      final entries = await archiveEntries(original);
      _addPayload(entries, [1, 2, 3]);
      mutateJson(
        entries,
        'records/attachments.json',
        (r) => r['attachments'][0]['checksum_sha256'] = '0' * 64,
      );
      await expectLater(
        reader.inspect(await writeArchive(fixture.root, entries)),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    },
  );

  test(
    'self-consistent unencrypted bytes are inspected without an authenticity claim',
    () async {
      final entries = await archiveEntries(original);
      _addPayload(entries, [1, 2, 3]);
      final result = await reader.inspect(
        await writeArchive(fixture.root, entries),
      );
      expect(
        result.attachments.single.payloadCoverage,
        ArchivePayloadCoverage.included,
      );
      expect(result.supportsCompleteRecovery, isFalse);
    },
  );

  for (final kind in [
    'attachment',
    'reference',
    'membership',
    'preference',
    'primary',
  ]) {
    test('rejects provably invalid $kind relationship', () async {
      final entries = await archiveEntries(original);
      if (kind == 'attachment' || kind == 'primary') {
        _addPayload(entries, [1]);
        if (kind == 'attachment') {
          mutateJson(
            entries,
            'records/attachments.json',
            (r) => r['attachments'][0]['artwork_id'] = 'missing',
          );
        } else {
          mutateJson(
            entries,
            'records/artworks.json',
            (r) => r['artworks'][0]['primary_image_attachment_id'] = 'payload',
          );
        }
      } else if (kind == 'reference') {
        mutateJson(
          entries,
          'records/external_references.json',
          (r) => r['references'] = [
            {
              'reference_id': 'ref',
              'artwork_id': 'missing',
              'reference_type': 'other',
              'label': null,
              'url': 'https://example.com/',
              'origin': 'ai_suggestion',
              'review_state': 'suggested',
              'last_confirmed_at': null,
              'created_at': ArchiveInspectionFixture.time.toIso8601String(),
              'updated_at': ArchiveInspectionFixture.time.toIso8601String(),
              'sort_order': 0,
            },
          ],
        );
      } else {
        mutateJson(entries, 'records/groupings.json', (r) {
          if (kind == 'membership') {
            r['memberships'] = [
              {
                'artwork_id': 'art-1',
                'group_id': 'missing',
                'created_at': ArchiveInspectionFixture.time.toIso8601String(),
              },
            ];
          } else {
            r['preferences'] = [
              {
                'artwork_id': 'missing',
                'is_favorite': 0,
                'updated_at': ArchiveInspectionFixture.time.toIso8601String(),
              },
            ];
          }
        });
      }
      await expectLater(
        reader.inspect(await writeArchive(fixture.root, entries)),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    });
  }

  test(
    'an absent primary row is unprovable because V2 omitted derivatives',
    () async {
      final entries = await archiveEntries(original);
      mutateJson(
        entries,
        'records/artworks.json',
        (r) => r['artworks'][0]['primary_image_attachment_id'] =
            'omitted-derivative',
      );
      final result = await reader.inspect(
        await writeArchive(fixture.root, entries),
      );
      expect(
        result.relationships.single.coverage,
        ArchiveRelationshipCoverage.unprovableFromVersion,
      );
    },
  );

  test(
    'rejects duplicate artwork identities even when all hashes match',
    () async {
      final entries = await archiveEntries(original);
      mutateJson(
        entries,
        'records/artworks.json',
        (r) => r['artworks'].add(r['artworks'][0]),
      );
      await expectLater(
        reader.inspect(await writeArchive(fixture.root, entries)),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    },
  );

  for (final phase in ArchiveInspectionPhase.values) {
    test('cancellation at ${phase.name} cleans only owned scratch', () async {
      final marker = await File(
        '${fixture.root.path}/retain.txt',
      ).writeAsString('keep');
      final token = ArchiveInspectionCancellation();
      await expectLater(
        reader.inspect(
          original,
          cancellation: token,
          onPhase: (current) {
            if (current == phase) token.cancel();
          },
        ),
        failure(ArchiveInspectionFailure.cancelled),
      );
      expect(await marker.readAsString(), 'keep');
      expect(await fixture.repository.get('art-1'), isNotNull);
    });
  }

  test('cancellation can interrupt a highly compressed payload', () async {
    final entries = await archiveEntries(original);
    _addPayload(entries, Uint8List(4 * 1024 * 1024));
    final file = await writeArchive(fixture.root, entries);
    final token = ArchiveInspectionCancellation();
    Timer? timer;
    try {
      await expectLater(
        reader.inspect(
          file,
          cancellation: token,
          onPhase: (phase) {
            if (phase == ArchiveInspectionPhase.validating) {
              timer = Timer(const Duration(milliseconds: 5), token.cancel);
            }
          },
        ),
        failure(ArchiveInspectionFailure.cancelled),
      );
    } finally {
      timer?.cancel();
    }
  });

  for (final replacement in [false, true]) {
    test(
      'detects source ${replacement ? 'replacement' : 'in-place mutation'} after snapshot',
      () async {
        await expectLater(
          reader.inspect(
            original,
            onPhase: (phase) async {
              if (phase == ArchiveInspectionPhase.copied) {
                if (replacement) {
                  await original.rename('${original.path}.old');
                }
                await original.writeAsBytes([0, 1, 2]);
              }
            },
          ),
          failure(ArchiveInspectionFailure.sourceChanged),
        );
      },
    );
  }

  test(
    'an inspection cannot vouch for a later replacement of the source path',
    () async {
      final result = await reader.inspect(original);
      await original.writeAsBytes([0]);
      expect(result.sourceSha256, isNot(sha256.convert([0]).toString()));
      await expectLater(
        reader.inspect(original),
        failure(ArchiveInspectionFailure.invalidArchive),
      );
    },
  );

  group('JSON allocation preflight', () {
    Future<Object?> decode(String source) => decodeInspectionJson(
      Uint8List.fromList(utf8.encode(source)),
      ArchiveInspectionCancellation(),
    );
    test('accepts string/depth boundaries and rejects one beyond', () async {
      expect(
        await decode(jsonEncode('x' * ArchiveInspectionLimits.stringBytes)),
        hasLength(ArchiveInspectionLimits.stringBytes),
      );
      await expectLater(
        decode(jsonEncode('x' * (ArchiveInspectionLimits.stringBytes + 1))),
        failure(ArchiveInspectionFailure.unsupportedResourceLimit),
      );
      expect(await decode('${'[' * 16}0${']' * 16}'), isList);
      await expectLater(
        decode('${'[' * 17}0${']' * 17}'),
        failure(ArchiveInspectionFailure.unsupportedResourceLimit),
      );
    });
    for (final entry in ArchiveInspectionLimits.arrayRows.entries) {
      test('enforces ${entry.key} row cap before building rows', () async {
        final valid =
            '{"${entry.key}":[${List.filled(entry.value, 'null').join(',')}]}';
        expect(await decode(valid), isMap);
        final invalid =
            '{"${entry.key}":[${List.filled(entry.value + 1, 'null').join(',')}]}';
        await expectLater(
          decode(invalid),
          failure(ArchiveInspectionFailure.unsupportedResourceLimit),
        );
      });
    }
    test(
      'rejects duplicate keys, malformed strings/numbers and deep objects',
      () async {
        for (final text in [
          '{"x":null,"x":1}',
          '"bad\\q"',
          '01',
          'NaN',
          '${'{"x":' * 17}0${'}' * 17}',
        ]) {
          await expectLater(
            decode(text),
            throwsA(isA<ArchiveInspectionException>()),
          );
        }
      },
    );
    test(
      'aggregate fields and JSON values cannot bypass per-array caps',
      () async {
        final half = List.filled(32769, 'null').join(',');
        await expectLater(
          decode('{"artworks":[{"fields":[$half]},{"fields":[$half]}]}'),
          failure(ArchiveInspectionFailure.unsupportedResourceLimit),
        );
        final row = List.filled(1000, 'null').join(',');
        final many = List.filled(301, '[$row]').join(',');
        await expectLater(
          decode('[$many]'),
          failure(ArchiveInspectionFailure.unsupportedResourceLimit),
        );
      },
    );
    test(
      'cancellation interrupts parsing before the object graph is decoded',
      () async {
        final token = ArchiveInspectionCancellation();
        final bytes = Uint8List.fromList(
          utf8.encode('{"fields":[${List.filled(60000, 'null').join(',')}]}'),
        );
        final timer = Timer(Duration.zero, token.cancel);
        try {
          await expectLater(
            decodeInspectionJson(bytes, token),
            failure(ArchiveInspectionFailure.cancelled),
          );
        } finally {
          timer.cancel();
        }
      },
    );
  });
}

List<int> _central(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var offset = view.getUint32(bytes.length - 6, Endian.little);
  final count = view.getUint16(bytes.length - 12, Endian.little);
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    result.add(offset);
    offset +=
        46 +
        view.getUint16(offset + 28, Endian.little) +
        view.getUint16(offset + 30, Endian.little) +
        view.getUint16(offset + 32, Endian.little);
  }
  return result;
}

void _set16(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint16(offset, value, Endian.little);
void _set32(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);

void _addPayload(Map<String, List<int>> entries, List<int> payload) {
  const path = 'attachments/payload/payload.pdf';
  mutateJson(
    entries,
    'records/attachments.json',
    (r) => r['attachments'] = [
      {
        'attachment_id': 'payload',
        'artwork_id': 'art-1',
        'attachment_type': 'receipt',
        'attachment_role': 'supporting_document',
        'file_name': 'receipt.pdf',
        'mime_type': 'application/pdf',
        'file_size_bytes': payload.length,
        'checksum_sha256': sha256.convert(payload).toString(),
        'imported_at': ArchiveInspectionFixture.time.toIso8601String(),
        'lifecycle_status': 'active',
        'archive_status': 'included',
        'payload_path': path,
      },
    ],
  );
  mutateJson(entries, 'manifest.json', (r) {
    r['counts']['attachments_included'] = 1;
    r['files'].add({
      'path': path,
      'size_bytes': payload.length,
      'checksum_sha256': sha256.convert(payload).toString(),
    });
  });
  entries[path] = payload;
}
