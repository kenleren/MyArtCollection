import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';

import 'backup_record_bundle.dart';

enum PrivateBackupFailure {
  invalidFormat,
  invalidPassphrase,
  authenticationFailed,
  resourceLimit,
  cancelled,
  sourceUnavailable,
}

class PrivateBackupException implements Exception {
  const PrivateBackupException(this.failure);
  final PrivateBackupFailure failure;

  @override
  String toString() => 'Private backup: ${failure.name}.';
}

/// Authenticated, bounded v1 transport for a private backup.
///
/// Decrypted chunks belong only in an owned private quarantine. A caller must
/// consume the entire stream successfully (including final authentication and
/// EOF), then validate records/payloads, before activating any restored data.
class PrivateBackupEnvelope {
  PrivateBackupEnvelope() : _cryptography = FlutterCryptography.defaultInstance;

  static const headerBytes = 48;
  static const iterations = 600000;
  static const chunkBytes = 1024 * 1024;
  static const maxPlaintextBytes = 512 * 1024 * 1024;
  static const maxInputChunkBytes = 2 * chunkBytes;
  static const tagBytes = 16;
  static const _magic = <int>[65, 82, 67, 66, 75, 48, 48, 49]; // ARCBK001
  final Cryptography _cryptography;

  static int ciphertextLength(int plaintextLength) {
    _validateLength(plaintextLength);
    final frames = (plaintextLength + chunkBytes - 1) ~/ chunkBytes;
    return headerBytes + plaintextLength + (frames + 1) * (4 + tagBytes);
  }

  Stream<Uint8List> encrypt(
    Stream<List<int>> plaintext, {
    required int plaintextLength,
    required String passphrase,
    BackupRecordCancellation? cancellation,
  }) async* {
    _check(cancellation);
    _validateLength(plaintextLength);
    final header = _newHeader(plaintextLength);
    final reader = PrivateBackupByteReader(plaintext, cancellation);
    SecretKey? key;
    try {
      key = await _derive(passphrase, header.sublist(12, 28));
      _check(cancellation);
      yield Uint8List.fromList(header);
      final cipher = _cryptography.aesGcm(secretKeyLength: 32);
      var remaining = plaintextLength;
      var index = 0;
      while (remaining > 0) {
        _check(cancellation);
        final length = min(chunkBytes, remaining);
        final bytes = await reader.readExact(length);
        final box = await cipher.encrypt(
          bytes,
          secretKey: key,
          nonce: _nonce(header, index),
          aad: _aad(header, index, length, false),
        );
        _check(cancellation);
        yield _frame(length, box);
        remaining -= length;
        index++;
      }
      await reader.requireEnd();
      final finalBox = await cipher.encrypt(
        const <int>[],
        secretKey: key,
        nonce: _nonce(header, index),
        aad: _aad(header, index, 0, true),
      );
      _check(cancellation);
      yield _frame(0, finalBox);
    } on PrivateBackupException {
      rethrow;
    } catch (_) {
      throw const PrivateBackupException(
        PrivateBackupFailure.sourceUnavailable,
      );
    } finally {
      key?.destroy();
      await reader.close();
    }
  }

  Stream<Uint8List> decrypt(
    Stream<List<int>> ciphertext, {
    required String passphrase,
    BackupRecordCancellation? cancellation,
  }) async* {
    _check(cancellation);
    final reader = PrivateBackupByteReader(ciphertext, cancellation);
    SecretKey? key;
    try {
      final header = await reader.readExact(headerBytes);
      final length = _readHeader(header);
      key = await _derive(passphrase, header.sublist(12, 28));
      _check(cancellation);
      final cipher = _cryptography.aesGcm(secretKeyLength: 32);
      var remaining = length;
      var index = 0;
      while (true) {
        _check(cancellation);
        final frameLength = ByteData.sublistView(
          await reader.readExact(4),
        ).getUint32(0);
        final expected = min(chunkBytes, remaining);
        if (frameLength != expected) _invalidFormat();
        final bytes = await reader.readExact(frameLength);
        final tag = await reader.readExact(tagBytes);
        final finalFrame = remaining == 0;
        final plain = await cipher.decrypt(
          SecretBox(bytes, nonce: _nonce(header, index), mac: Mac(tag)),
          secretKey: key,
          aad: _aad(header, index, frameLength, finalFrame),
        );
        _check(cancellation);
        if (finalFrame) {
          await reader.requireEnd();
          return;
        }
        yield Uint8List.fromList(plain);
        remaining -= frameLength;
        index++;
      }
    } on SecretBoxAuthenticationError {
      throw const PrivateBackupException(
        PrivateBackupFailure.authenticationFailed,
      );
    } on PrivateBackupException {
      rethrow;
    } catch (_) {
      throw const PrivateBackupException(
        PrivateBackupFailure.sourceUnavailable,
      );
    } finally {
      key?.destroy();
      await reader.close();
    }
  }

  Future<SecretKey> _derive(String passphrase, List<int> salt) async {
    // The shared validator rejects lone surrogates before UTF-8 can replace them.
    try {
      validateBackupText(passphrase, maximum: 1024);
    } on BackupRecordException {
      throw const PrivateBackupException(
        PrivateBackupFailure.invalidPassphrase,
      );
    }
    final bytes = Uint8List.fromList(utf8.encode(passphrase));
    if (bytes.length < 12) {
      bytes.fillRange(0, bytes.length, 0);
      throw const PrivateBackupException(
        PrivateBackupFailure.invalidPassphrase,
      );
    }
    final password = SecretKey(bytes);
    try {
      return await _cryptography
          .pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: iterations,
            bits: 256,
          )
          .deriveKey(secretKey: password, nonce: salt);
    } finally {
      password.destroy();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Uint8List _newHeader(int length) {
    final header = Uint8List(headerBytes)..setRange(0, 8, _magic);
    final random = Random.secure();
    for (var i = 12; i < 36; i++) {
      header[i] = random.nextInt(256);
    }
    final data = ByteData.sublistView(header);
    data.setUint32(8, iterations);
    data.setUint32(36, chunkBytes);
    data.setUint64(40, length);
    return header;
  }

  static int _readHeader(Uint8List header) {
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i]) _invalidFormat();
    }
    final data = ByteData.sublistView(header);
    if (data.getUint32(8) != iterations || data.getUint32(36) != chunkBytes) {
      _invalidFormat();
    }
    final length = data.getUint64(40);
    _validateLength(length);
    return length;
  }

  static Uint8List _nonce(Uint8List header, int index) {
    final nonce = Uint8List(12)..setRange(0, 8, header, 28);
    ByteData.sublistView(nonce).setUint32(8, index);
    return nonce;
  }

  static Uint8List _aad(
    Uint8List header,
    int index,
    int length,
    bool finalFrame,
  ) {
    final aad = Uint8List(headerBytes + 9)..setRange(0, headerBytes, header);
    final data = ByteData.sublistView(aad);
    data.setUint32(headerBytes, index);
    data.setUint32(headerBytes + 4, length);
    aad[headerBytes + 8] = finalFrame ? 1 : 0;
    return aad;
  }

  static Uint8List _frame(int length, SecretBox box) {
    final frame = Uint8List(4 + length + tagBytes);
    ByteData.sublistView(frame).setUint32(0, length);
    frame.setRange(4, 4 + length, box.cipherText);
    frame.setRange(4 + length, frame.length, box.mac.bytes);
    return frame;
  }
}

void _validateLength(int length) {
  if (length < 0 || length > PrivateBackupEnvelope.maxPlaintextBytes) {
    throw const PrivateBackupException(PrivateBackupFailure.resourceLimit);
  }
}

Never _invalidFormat() =>
    throw const PrivateBackupException(PrivateBackupFailure.invalidFormat);

void _check(BackupRecordCancellation? cancellation) {
  try {
    cancellation?.check();
  } on BackupRecordException {
    throw const PrivateBackupException(PrivateBackupFailure.cancelled);
  }
}

/// Internal bounded stream reader shared by the envelope/content codecs.
/// Cancelling detaches the reader; crypto work already running may finish later.
class PrivateBackupByteReader {
  PrivateBackupByteReader(Stream<List<int>> stream, this.cancellation)
    : _iterator = StreamIterator(stream) {
    cancellation?.whenCancelled.then((_) {
      final waiting = _waiting;
      if (waiting != null && !waiting.isCompleted) {
        waiting.completeError(
          const PrivateBackupException(PrivateBackupFailure.cancelled),
        );
      }
    });
  }
  static const readInactivityTimeout = Duration(seconds: 30);
  static const closeTimeout = Duration(seconds: 1);
  static const maxMaterializedBytes = 16 * 1024 * 1024;
  final StreamIterator<List<int>> _iterator;
  final BackupRecordCancellation? cancellation;
  Completer<bool>? _waiting;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  int _emptyChunks = 0;

  Future<bool> _next() async {
    _check(cancellation);
    final result = Completer<bool>();
    _waiting = result;
    final timer = Timer(readInactivityTimeout, () {
      if (!result.isCompleted) {
        result.completeError(
          const PrivateBackupException(PrivateBackupFailure.sourceUnavailable),
        );
        cancellation?.cancel();
      }
    });
    try {
      _iterator.moveNext().then(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace _) {
          if (!result.isCompleted) {
            result.completeError(
              error is PrivateBackupException
                  ? error
                  : const PrivateBackupException(
                      PrivateBackupFailure.sourceUnavailable,
                    ),
            );
          }
        },
      );
      return await result.future;
    } finally {
      timer.cancel();
      _waiting = null;
    }
  }

  Future<bool> _more() async {
    while (_offset == _chunk.length) {
      _check(cancellation);
      final available = await _next();
      _check(cancellation);
      if (!available) return false;
      final incoming = _iterator.current;
      if (incoming.length > PrivateBackupEnvelope.maxInputChunkBytes) {
        throw const PrivateBackupException(PrivateBackupFailure.resourceLimit);
      }
      if (incoming.isEmpty) {
        if (++_emptyChunks > 1024) {
          throw const PrivateBackupException(
            PrivateBackupFailure.resourceLimit,
          );
        }
        continue;
      }
      for (final byte in incoming) {
        if (byte < 0 || byte > 255) _invalidFormat();
      }
      _chunk = Uint8List.fromList(incoming);
      _offset = 0;
      _emptyChunks = 0;
    }
    return true;
  }

  Future<Uint8List> readExact(int count) async {
    _check(cancellation);
    if (count < 0 || count > maxMaterializedBytes) {
      throw const PrivateBackupException(PrivateBackupFailure.resourceLimit);
    }
    final output = Uint8List(count);
    var used = 0;
    while (used < count) {
      if (!await _more()) _invalidFormat();
      final take = min(count - used, _chunk.length - _offset);
      output.setRange(used, used + take, _chunk, _offset);
      _offset += take;
      used += take;
    }
    return output;
  }

  Future<void> requireEnd() async {
    _check(cancellation);
    if (await _more()) _invalidFormat();
  }

  Future<void> close() async {
    try {
      await _iterator.cancel().timeout(closeTimeout);
    } catch (_) {
      throw const PrivateBackupException(
        PrivateBackupFailure.sourceUnavailable,
      );
    } finally {
      // The cancellation token may outlive a completed file reader.
      _chunk = Uint8List(0);
      _offset = 0;
    }
  }
}
