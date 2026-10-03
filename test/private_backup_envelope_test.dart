import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/private_backup_envelope.dart';

void main() {
  late String passphrase;
  late Uint8List vector;
  late Uint8List expected;

  setUpAll(() {
    final fixture =
        jsonDecode(
              File(
                'test/fixtures/private-backup-envelope-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    passphrase = fixture['passphrase'] as String;
    vector = base64Decode(fixture['ciphertextBase64'] as String);
    expected = base64Decode(fixture['plaintextBase64'] as String);
  });

  Future<Uint8List> decrypt(List<int> bytes, {String? password}) async {
    final chunks = await PrivateBackupEnvelope()
        .decrypt(
          Stream<List<int>>.fromIterable([
            for (var i = 0; i < bytes.length; i += 65536)
              bytes.sublist(
                i,
                i + 65536 > bytes.length ? bytes.length : i + 65536,
              ),
          ]),
          passphrase: password ?? passphrase,
        )
        .toList();
    return (BytesBuilder()..addAll(chunks)).takeBytes();
  }

  Matcher fails(PrivateBackupFailure failure) => throwsA(
    isA<PrivateBackupException>().having((e) => e.failure, 'failure', failure),
  );

  test('decrypts independent Python PBKDF2/AES-GCM vector', () async {
    final stream = Stream<List<int>>.fromIterable([
      for (var i = 0; i < vector.length; i += 7)
        vector.sublist(i, i + 7 > vector.length ? vector.length : i + 7),
    ]);
    final chunks = await PrivateBackupEnvelope()
        .decrypt(stream, passphrase: passphrase)
        .toList();
    expect((BytesBuilder()..addAll(chunks)).takeBytes(), expected);
    expect(
      vector.length,
      PrivateBackupEnvelope.ciphertextLength(expected.length),
    );
  });

  test('wrong password never returns a completed plaintext result', () async {
    await expectLater(
      decrypt(vector, password: 'another synthetic passphrase'),
      fails(PrivateBackupFailure.authenticationFailed),
    );
  });

  test('ciphertext alteration fails authentication', () async {
    final damaged = Uint8List.fromList(vector)..[53] ^= 1;
    await expectLater(
      decrypt(damaged),
      fails(PrivateBackupFailure.authenticationFailed),
    );
  });

  test('final frame is mandatory; trailing data rejects completion', () async {
    await expectLater(
      decrypt(vector.sublist(0, vector.length - 20)),
      fails(PrivateBackupFailure.invalidFormat),
    );
    await expectLater(
      decrypt([...vector, 0]),
      fails(PrivateBackupFailure.invalidFormat),
    );
    final damagedFinal = Uint8List.fromList(vector)..[vector.length - 1] ^= 1;
    await expectLater(
      decrypt(damagedFinal),
      fails(PrivateBackupFailure.authenticationFailed),
    );
  });

  test('cancellation while awaiting final EOF cannot report success', () async {
    final cancellation = BackupRecordCancellation();
    Stream<List<int>> source() async* {
      yield vector;
      cancellation.cancel();
    }

    await expectLater(
      PrivateBackupEnvelope()
          .decrypt(source(), passphrase: passphrase, cancellation: cancellation)
          .toList(),
      fails(PrivateBackupFailure.cancelled),
    );
  });

  test('cancellation wakes a source stalled before its header', () async {
    final listening = Completer<void>();
    final source = StreamController<List<int>>(onListen: listening.complete);
    final cancellation = BackupRecordCancellation();
    final result = PrivateBackupEnvelope()
        .decrypt(
          source.stream,
          passphrase: passphrase,
          cancellation: cancellation,
        )
        .toList();
    final assertion = expectLater(
      result,
      fails(PrivateBackupFailure.cancelled),
    );
    await listening.future;
    cancellation.cancel();
    await assertion.timeout(const Duration(seconds: 2));
    await source.close();
  });

  test('a held source onCancel cannot keep a rejection pending', () async {
    final release = Completer<void>();
    final source = StreamController<List<int>>(onCancel: () => release.future);
    final result = PrivateBackupEnvelope()
        .decrypt(source.stream, passphrase: passphrase)
        .toList();
    final assertion = expectLater(
      result,
      fails(PrivateBackupFailure.sourceUnavailable),
    );
    source.add(Uint8List(48));
    try {
      await assertion.timeout(const Duration(seconds: 3));
    } finally {
      release.complete();
      await source.close();
    }
  });

  test('header whitelist and allocation bounds reject before KDF', () async {
    for (var i = 0; i < 48; i++) {
      await expectLater(
        decrypt(vector.sublist(0, i)),
        fails(PrivateBackupFailure.invalidFormat),
      );
    }
    for (final offset in [0, 8, 36]) {
      final bad = Uint8List.fromList(vector)..[offset] ^= 1;
      await expectLater(
        decrypt(bad),
        fails(PrivateBackupFailure.invalidFormat),
      );
    }
    final huge = Uint8List.fromList(vector);
    ByteData.sublistView(huge).setUint64(40, 512 * 1024 * 1024 + 1);
    await expectLater(decrypt(huge), fails(PrivateBackupFailure.resourceLimit));
    final overflow = Uint8List.fromList(vector)..fillRange(40, 48, 255);
    await expectLater(
      decrypt(overflow),
      fails(PrivateBackupFailure.resourceLimit),
    );
  });

  test('strict passphrase and cancellation fail closed', () async {
    for (final bad in ['too short', 'a' * 1025, '\ud800' * 12]) {
      await expectLater(
        decrypt(vector, password: bad),
        fails(PrivateBackupFailure.invalidPassphrase),
      );
    }
    final cancellation = BackupRecordCancellation()..cancel();
    await expectLater(
      PrivateBackupEnvelope()
          .decrypt(
            Stream.value(vector),
            passphrase: passphrase,
            cancellation: cancellation,
          )
          .toList(),
      fails(PrivateBackupFailure.cancelled),
    );
  });

  test('empty plaintext still requires an authenticated final frame', () async {
    final wire =
        (BytesBuilder()..addAll(
              await PrivateBackupEnvelope()
                  .encrypt(
                    const Stream<List<int>>.empty(),
                    plaintextLength: 0,
                    passphrase: passphrase,
                  )
                  .toList(),
            ))
            .takeBytes();
    expect(wire.length, 68);
    expect(await decrypt(wire), isEmpty);
  });

  test(
    'multi-chunk boundary roundtrip binds sequence and short last chunk',
    () async {
      final full = Uint8List(PrivateBackupEnvelope.chunkBytes)
        ..fillRange(0, PrivateBackupEnvelope.chunkBytes, 42);
      final second = Uint8List(full.length)..fillRange(0, full.length, 43);
      final last = Uint8List.fromList([0, 255, 7]);
      final wire =
          (BytesBuilder()..addAll(
                await PrivateBackupEnvelope()
                    .encrypt(
                      Stream<List<int>>.fromIterable([full, second, last]),
                      plaintextLength:
                          full.length + second.length + last.length,
                      passphrase: passphrase,
                    )
                    .toList(),
              ))
              .takeBytes();
      expect(
        wire.length,
        PrivateBackupEnvelope.ciphertextLength(full.length * 2 + 3),
      );
      final result = await decrypt(wire);
      expect(result.sublist(0, full.length), full);
      expect(result.sublist(full.length, full.length * 2), second);
      expect(result.sublist(full.length * 2), last);
      final firstEnd = 48 + 4 + full.length + 16;
      final secondEnd = firstEnd + 4 + full.length + 16;
      final swapped = [
        ...wire.sublist(0, 48),
        ...wire.sublist(firstEnd, secondEnd),
        ...wire.sublist(48, firstEnd),
        ...wire.sublist(secondEnd),
      ];
      await expectLater(
        decrypt(swapped),
        fails(PrivateBackupFailure.authenticationFailed),
      );
      final duplicate = [
        ...wire.sublist(0, firstEnd),
        ...wire.sublist(48, firstEnd),
        ...wire.sublist(firstEnd),
      ];
      await expectLater(
        decrypt(duplicate),
        fails(PrivateBackupFailure.authenticationFailed),
      );
    },
  );

  test(
    'declared input length mismatch cannot produce a complete envelope',
    () async {
      await expectLater(
        PrivateBackupEnvelope()
            .encrypt(
              Stream.value(<int>[1]),
              plaintextLength: 0,
              passphrase: passphrase,
            )
            .toList(),
        fails(PrivateBackupFailure.invalidFormat),
      );
      await expectLater(
        PrivateBackupEnvelope()
            .encrypt(
              const Stream<List<int>>.empty(),
              plaintextLength: 1,
              passphrase: passphrase,
            )
            .toList(),
        fails(PrivateBackupFailure.invalidFormat),
      );
    },
  );

  test('stream chunk and plaintext resource ceilings are enforced', () async {
    await expectLater(
      PrivateBackupEnvelope()
          .decrypt(
            Stream.value(
              Uint8List(PrivateBackupEnvelope.maxInputChunkBytes + 1),
            ),
            passphrase: passphrase,
          )
          .toList(),
      fails(PrivateBackupFailure.resourceLimit),
    );
    expect(
      () => PrivateBackupEnvelope.ciphertextLength(
        PrivateBackupEnvelope.maxPlaintextBytes + 1,
      ),
      throwsA(isA<PrivateBackupException>()),
    );
  });
}

extension on BytesBuilder {
  void addAll(Iterable<List<int>> chunks) {
    for (final chunk in chunks) {
      add(chunk);
    }
  }
}
