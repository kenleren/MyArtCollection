import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/backup_record_codec.dart';
import 'package:my_art_collection/app/backup/backup_record_snapshot.dart';
import 'package:my_art_collection/app/backup/private_backup_content.dart';
import 'package:my_art_collection/app/backup/private_backup_envelope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_record_fixture.dart';

void main() {
  const id = 'e79d856f-de7e-4dc4-a47c-50e28e5c08c8';
  const phrase = 'synthetic recovery passphrase 2026';
  final time = DateTime.utc(2026, 10, 3, 17, 0);
  const codec = PrivateBackupContentCodec();
  late BackupRecordFixture fixture;
  late BackupRecordBundle records;
  late PrivateBackupContent plan;
  final payloads = {
    'original': Uint8List.fromList([1, 2, 3, 4]),
    'derivative': Uint8List.fromList([5, 6, 7, 8]),
  };

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    fixture = await BackupRecordFixture.create();
    await fixture.database.update(
      'attachments',
      {'lifecycle_status': 'removed'},
      where: 'attachment_id = ?',
      whereArgs: ['child-of-removed'],
    );
    for (final entry in payloads.entries) {
      await fixture.database.update(
        'attachments',
        {
          'checksum': sha256.convert(entry.value).toString(),
          'file_size_bytes': entry.value.length,
        },
        where: 'attachment_id = ?',
        whereArgs: [entry.key],
      );
    }
    records = await const BackupRecordSnapshot().capture(fixture.database);
    plan = await codec.prepare(records, snapshotId: id, snapshotAt: time);
  });
  tearDown(() async {
    await fixture.database.close();
    await fixture.root.delete(recursive: true);
  });

  Future<Uint8List> join(Stream<List<int>> stream) async {
    final builder = BytesBuilder();
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Stream<List<int>> plaintext() =>
      plan.stream((p) => Stream.value(payloads[p.attachmentId]!));
  Matcher fails(PrivateBackupFailure failure) => throwsA(
    isA<PrivateBackupException>().having((e) => e.failure, 'failure', failure),
  );
  Future<Object> inspect(List<int> bytes) => codec.inspect(
    Stream.value(bytes),
    stagePayload: (_, stream) async {
      await stream.drain<void>();
    },
  );
  Uint8List alterManifest(
    Uint8List input,
    void Function(Map<String, dynamic>) alter,
  ) {
    final length = ByteData.sublistView(input).getUint32(0);
    final raw =
        jsonDecode(utf8.decode(input.sublist(4, 4 + length)))
            as Map<String, dynamic>;
    alter(raw);
    final metadata = utf8.encode(jsonEncode(raw));
    final prefix = Uint8List(4);
    ByteData.sublistView(prefix).setUint32(0, metadata.length);
    return (BytesBuilder()
          ..add(prefix)
          ..add(metadata)
          ..add(input.sublist(4 + length)))
        .takeBytes();
  }

  test(
    'encrypted container retains every record and only eligible payloads',
    () async {
      final wire = PrivateBackupEnvelope().encrypt(
        plaintext(),
        plaintextLength: plan.plaintextLength,
        passphrase: phrase,
      );
      final staged = <String, Uint8List>{};
      final result = await codec.inspect(
        PrivateBackupEnvelope().decrypt(wire, passphrase: phrase),
        stagePayload: (p, bytes) async {
          staged[p.attachmentId] = await join(bytes);
        },
      );
      expect(result.snapshotId, id);
      expect(result.snapshotAt, time);
      expect(result.supportsActivation, isFalse);
      expect(result.omissions, {
        'removed': 2,
        'unavailable': 1,
        'superseded': 1,
      });
      expect(result.payloads.map((p) => p.attachmentId), [
        'derivative',
        'original',
      ]);
      expect(staged, payloads);
      expect(
        await const BackupRecordCodec().encode(result.records),
        await const BackupRecordCodec().encode(records),
      );
      expect(
        result.records.jobs.map((j) => j.executionDisposition),
        everyElement('history_only'),
      );
      expect(
        result.payloads.every((p) => p.canonicalName == 'payload.jpg'),
        isTrue,
      );
    },
  );

  test('active descendants of removed files cannot form a snapshot', () async {
    await fixture.database.update(
      'attachments',
      {'lifecycle_status': 'active'},
      where: 'attachment_id = ?',
      whereArgs: ['child-of-removed'],
    );
    final input = await const BackupRecordSnapshot().capture(fixture.database);
    await expectLater(
      codec.prepare(input, snapshotId: id, snapshotAt: time),
      fails(PrivateBackupFailure.invalidFormat),
    );
  });

  test(
    'manifest cannot change record/payload targets, omission policy or schemas',
    () async {
      final bytes = await join(plaintext());
      for (final alter in <void Function(Map<String, dynamic>)>[
        (m) => m['sourceSchema'] = 11,
        (m) => m['recordSha256'] = '0' * 64,
        (m) => m['payloadPolicy'] = 'all_files',
        (m) => (m['omissions'] as Map)['removed'] = 0,
        (m) => ((m['payloads'] as List).first as Map)['canonicalName'] =
            '../../outside',
        (m) =>
            ((m['payloads'] as List).first as Map)['artworkId'] = 'other-art',
        (m) => ((m['payloads'] as List).first as Map)['length'] = 3,
        (m) => m['extraPath'] = '/ignored/private-path-sentinel',
        (m) => m['snapshotAt'] = '2026-10-03T17:00:00+00:00',
        (m) => m['snapshotId'] = '../../outside',
      ]) {
        await expectLater(
          inspect(alterManifest(bytes, alter)),
          fails(PrivateBackupFailure.invalidFormat),
        );
      }
    },
  );

  test(
    'metadata ceilings reject before allocation; duplicate JSON keys reject',
    () async {
      final oversized = Uint8List(4);
      ByteData.sublistView(
        oversized,
      ).setUint32(0, PrivateBackupContentCodec.maxManifestBytes + 1);
      await expectLater(
        inspect(oversized),
        fails(PrivateBackupFailure.resourceLimit),
      );
      final bytes = await join(plaintext());
      await expectLater(
        inspect(
          alterManifest(
            bytes,
            (m) => m['recordLength'] = BackupRecordLimits.bytes + 1,
          ),
        ),
        fails(PrivateBackupFailure.resourceLimit),
      );
      final raw = utf8.encode('{"format":"one","format":"two"}');
      final prefix = Uint8List(4);
      ByteData.sublistView(prefix).setUint32(0, raw.length);
      await expectLater(
        inspect([...prefix, ...raw]),
        fails(PrivateBackupFailure.invalidFormat),
      );
    },
  );

  test(
    'changed, short or extra payload input cannot seal an encrypted backup',
    () async {
      for (final bytes in <List<int>>[
        [9, 9, 9, 9],
        [1, 2],
        [1, 2, 3, 4, 5],
      ]) {
        final source = plan.stream(
          (p) => Stream.value(
            p.attachmentId == 'original' ? bytes : payloads[p.attachmentId]!,
          ),
        );
        await expectLater(
          PrivateBackupEnvelope()
              .encrypt(
                source,
                plaintextLength: plan.plaintextLength,
                passphrase: phrase,
              )
              .toList(),
          fails(PrivateBackupFailure.invalidFormat),
        );
      }
    },
  );

  test('tampered or truncated content cannot finish inspection', () async {
    final bytes = await join(plaintext());
    final damaged = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    await expectLater(
      inspect(damaged),
      fails(PrivateBackupFailure.invalidFormat),
    );
    await expectLater(
      inspect(bytes.sublist(0, bytes.length - 1)),
      fails(PrivateBackupFailure.invalidFormat),
    );
    await expectLater(
      inspect([...bytes, 0]),
      fails(PrivateBackupFailure.invalidFormat),
    );
  });

  test(
    'staging must exhaust and verify each payload, even a single chunk',
    () async {
      await expectLater(
        codec.inspect(
          plaintext(),
          stagePayload: (_, bytes) async {
            await bytes.first;
          },
        ),
        fails(PrivateBackupFailure.invalidFormat),
      );
    },
  );

  test(
    'cancellation releases an inspector waiting for a held stager',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final cancellation = BackupRecordCancellation();
      final result = codec.inspect(
        plaintext(),
        cancellation: cancellation,
        stagePayload: (_, bytes) async {
          entered.complete();
          await release.future;
        },
      );
      final assertion = expectLater(
        result,
        fails(PrivateBackupFailure.cancelled),
      );
      await entered.future;
      cancellation.cancel();
      try {
        await assertion.timeout(const Duration(seconds: 2));
      } finally {
        release.complete();
      }
    },
  );

  test(
    'missing envelope final frame rejects after provisional staging',
    () async {
      final encrypted = await join(
        PrivateBackupEnvelope().encrypt(
          plaintext(),
          plaintextLength: plan.plaintextLength,
          passphrase: phrase,
        ),
      );
      var staged = 0;
      await expectLater(
        codec.inspect(
          PrivateBackupEnvelope().decrypt(
            Stream.value(encrypted.sublist(0, encrypted.length - 20)),
            passphrase: phrase,
          ),
          stagePayload: (_, bytes) async {
            await bytes.drain<void>();
            staged++;
          },
        ),
        fails(PrivateBackupFailure.invalidFormat),
      );
      expect(
        staged,
        2,
      ); // Only an already-owned quarantine may have these bytes.
    },
  );

  test(
    'stager timeout invalidates late writes through the shared token',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final cancellation = BackupRecordCancellation();
      var lateWrite = false;
      final result = codec.inspect(
        plaintext(),
        cancellation: cancellation,
        stagePayload: (_, bytes) async {
          await bytes.drain<void>();
          entered.complete();
          await release.future;
          cancellation.check();
          lateWrite = true;
        },
      );
      final assertion = expectLater(
        result,
        fails(PrivateBackupFailure.sourceUnavailable),
      );
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        await assertion.timeout(const Duration(seconds: 35));
        expect(cancellation.check, throwsA(isA<BackupRecordException>()));
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(lateWrite, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        cancellation.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'snapshot identity and impossible active metadata fail before reading files',
    () async {
      await expectLater(
        codec.prepare(records, snapshotId: '../snapshot', snapshotAt: time),
        fails(PrivateBackupFailure.invalidFormat),
      );
      for (final (patch, failure) in [
        ({'mime_type': 'text/html'}, PrivateBackupFailure.invalidFormat),
        (
          {'file_size_bytes': 25 * 1024 * 1024 + 1},
          PrivateBackupFailure.resourceLimit,
        ),
        (
          {'checksum': 'legacy-unverifiable'},
          PrivateBackupFailure.invalidFormat,
        ),
      ]) {
        await fixture.database.update(
          'attachments',
          {
            'mime_type': 'image/jpeg',
            'file_size_bytes': 4,
            'checksum': sha256.convert(payloads['original']!).toString(),
            ...patch,
          },
          where: 'attachment_id = ?',
          whereArgs: ['original'],
        );
        final input = await const BackupRecordSnapshot().capture(
          fixture.database,
        );
        await expectLater(
          codec.prepare(input, snapshotId: id, snapshotAt: time),
          fails(failure),
        );
      }
    },
  );

  test(
    'inactive attachment IDs still cannot become destination paths',
    () async {
      await fixture.database.update(
        'attachments',
        {'attachment_id': '../unsafe'},
        where: 'attachment_id = ?',
        whereArgs: ['unavailable'],
      );
      final input = await const BackupRecordSnapshot().capture(
        fixture.database,
      );
      await expectLater(
        codec.prepare(input, snapshotId: id, snapshotAt: time),
        fails(PrivateBackupFailure.invalidFormat),
      );
    },
  );
}
