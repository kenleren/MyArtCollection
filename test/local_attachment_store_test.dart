import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late LocalAttachmentStore store;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_attachment_test_',
    );
    store = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );

    await repository.create(_record('artwork-001'));
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'saves app-private file and persists linked attachment metadata',
    () async {
      final source = File(p.join(tempDir.path, 'receipt.pdf'));
      final bytes = [1, 2, 3, 4];
      await source.writeAsBytes(bytes);

      final attachment = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-001',
        sourceFile: source,
        originalFileName: 'gallery-receipt-2025.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
        notes: 'Receipt supports purchase record, not authenticity.',
      );
      await repository.addAttachment(attachment);

      expect(await store.exists(attachment), isTrue);
      expect(attachment.relativePath, contains('artworks/artwork-001'));
      expect(attachment.relativePath, contains('attachments/attachment-001'));
      expect(attachment.relativePath, isNot(contains('gallery-receipt')));
      expect(attachment.checksum, sha256.convert(bytes).toString());

      final reloaded = await repository.attachmentsForArtwork('artwork-001');
      expect(reloaded, hasLength(1));
      expect(reloaded.single.artworkId, 'artwork-001');
      expect(reloaded.single.type, AttachmentType.receipt);
      expect(reloaded.single.fileName, 'gallery-receipt-2025.pdf');
      expect(reloaded.single.mimeType, 'application/pdf');
      expect(reloaded.single.source, ArtworkFieldSource.userConfirmed);
      expect(reloaded.single.source.label, 'user-confirmed');
    },
  );

  test('reports missing app-private file without deleting metadata', () async {
    final source = File(p.join(tempDir.path, 'image.png'));
    await source.writeAsBytes([9, 9, 9]);

    final attachment = await store.saveImportedAttachment(
      artworkId: 'artwork-001',
      attachmentId: 'attachment-image',
      sourceFile: source,
      originalFileName: 'living-room.png',
      mimeType: 'image/png',
      type: AttachmentType.photo,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 4, 11),
    );
    await repository.addAttachment(attachment);

    await store.fileFor(attachment).delete();

    expect(await store.exists(attachment), isFalse);
    expect(await repository.getAttachment('attachment-image'), isNotNull);
  });

  test('rejects unsupported MIME types and over-limit imports', () async {
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-missing',
        sourceFile: File(p.join(tempDir.path, 'missing.pdf')),
        originalFileName: 'missing.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.sourceMissing,
        ),
      ),
    );

    final unsupported = File(p.join(tempDir.path, 'note.txt'));
    await unsupported.writeAsString('not supported');

    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-note',
        sourceFile: unsupported,
        originalFileName: 'note.txt',
        mimeType: 'text/plain',
        type: AttachmentType.otherSupportingDocument,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.unsupportedMimeType,
        ),
      ),
    );

    final tooLarge = File(p.join(tempDir.path, 'too-large.png'));
    final handle = await tooLarge.open(mode: FileMode.write);
    await handle.truncate(
      LocalAttachmentStore.allowedMimeTypes['image/png']! + 1,
    );
    await handle.close();

    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-large',
        sourceFile: tooLarge,
        originalFileName: 'too-large.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.fileTooLarge,
        ),
      ),
    );
  });
}

ArtworkRecord _record(String id) {
  final now = DateTime.utc(2026, 7, 4, 9);

  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.draft,
    createdAt: now,
    updatedAt: now,
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Blue Interior Study',
        source: ArtworkFieldSource.userConfirmed,
        note: 'User confirmed.',
      ),
    },
  );
}
