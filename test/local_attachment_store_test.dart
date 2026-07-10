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
      final bytes = _pdfBytes;
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
      expect(reloaded.single.role, AttachmentRole.supportingDocument);
      expect(reloaded.single.fileName, 'gallery-receipt-2025.pdf');
      expect(reloaded.single.mimeType, 'application/pdf');
      expect(reloaded.single.source, ArtworkFieldSource.userConfirmed);
      expect(reloaded.single.source.label, 'user-confirmed');
    },
  );

  test('reports missing app-private file without deleting metadata', () async {
    final source = File(p.join(tempDir.path, 'image.png'));
    await source.writeAsBytes(_pngBytes);

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

  test(
    'persists supporting photos without overwriting the primary artwork photo',
    () async {
      await repository.upsert(
        _record('artwork-001', primaryImageAttachmentId: 'attachment-primary'),
      );

      final primarySource = File(p.join(tempDir.path, 'primary.jpg'));
      await primarySource.writeAsBytes(_jpegBytes);
      final primary = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary',
        sourceFile: primarySource,
        originalFileName: 'primary.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
      );
      await repository.addAttachment(primary);

      final supportingSource = File(p.join(tempDir.path, 'detail.png'));
      await supportingSource.writeAsBytes(_pngBytes);
      final supporting = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-supporting',
        sourceFile: supportingSource,
        originalFileName: 'condition-detail.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        role: AttachmentRole.supportingPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 11),
        notes: 'Detail image supports condition notes.',
      );
      await repository.addAttachment(supporting);

      final reloadedRecord = await repository.get('artwork-001');
      expect(reloadedRecord!.primaryImageAttachmentId, 'attachment-primary');

      final attachments = await repository.attachmentsForArtwork('artwork-001');
      expect(
        attachments
            .singleWhere((attachment) => attachment.id == 'attachment-primary')
            .role,
        AttachmentRole.primaryArtworkPhoto,
      );
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'attachment-supporting',
            )
            .role,
        AttachmentRole.supportingPhoto,
      );
    },
  );

  test(
    'stores edited photo derivatives as new attachments with explicit lineage',
    () async {
      final primarySource = File(p.join(tempDir.path, 'primary-capture.jpg'));
      await primarySource.writeAsBytes(_jpegBytes);
      final primary = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary',
        sourceFile: primarySource,
        originalFileName: 'primary-capture.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 9),
      );
      await repository.addAttachment(primary);

      final derivativeSource = File(p.join(tempDir.path, 'primary-edit.jpg'));
      final derivativeBytes = _jpegBytes;
      await derivativeSource.writeAsBytes(derivativeBytes);
      final derivative = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary-edit',
        sourceFile: derivativeSource,
        originalFileName: 'primary-edit.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        role: AttachmentRole.primaryArtworkPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
        derivedFromAttachmentId: 'attachment-primary',
        transformSummary: 'crop=4:3; rotate=90deg; straighten=1.5deg',
        notes: 'Edited locally from the original capture.',
      );
      await repository.addAttachment(derivative);

      expect(await store.exists(primary), isTrue);
      expect(await store.exists(derivative), isTrue);
      expect(derivative.derivedFromAttachmentId, 'attachment-primary');
      expect(
        derivative.transformSummary,
        'crop=4:3; rotate=90deg; straighten=1.5deg',
      );
      expect(derivative.isDerivative, isTrue);
      expect(derivative.isOriginalCapture, isFalse);

      final originalBytes = await store.fileFor(primary).readAsBytes();
      expect(originalBytes, _jpegBytes);
      final derivativeStoredBytes = await store
          .fileFor(derivative)
          .readAsBytes();
      expect(derivativeStoredBytes, derivativeBytes);

      final attachments = await repository.attachmentsForArtwork('artwork-001');
      expect(attachments, hasLength(2));
      final persistedDerivative = attachments.singleWhere(
        (attachment) => attachment.id == 'attachment-primary-edit',
      );
      expect(persistedDerivative.derivedFromAttachmentId, 'attachment-primary');
      expect(
        persistedDerivative.transformSummary,
        'crop=4:3; rotate=90deg; straighten=1.5deg',
      );
      expect(persistedDerivative.type, AttachmentType.photo);
      expect(persistedDerivative.role, AttachmentRole.primaryArtworkPhoto);
    },
  );

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

  test('rejects mismatched extensions and malformed signatures', () async {
    final pdfNamedImage = File(p.join(tempDir.path, 'mismatch.pdf'));
    await pdfNamedImage.writeAsBytes(_pngBytes);
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-mismatch',
        sourceFile: pdfNamedImage,
        originalFileName: 'mismatch.pdf',
        mimeType: 'image/png',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.mimeTypeMismatch,
        ),
      ),
    );

    final malformed = File(p.join(tempDir.path, 'malformed.png'));
    await malformed.writeAsBytes(const [1, 2, 3]);
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-malformed',
        sourceFile: malformed,
        originalFileName: 'malformed.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.malformedFile,
        ),
      ),
    );
    expect(
      await Directory(
        p.join(store.storageRoot.path, '.staging'),
      ).list().toList(),
      isEmpty,
    );
  });
}

const _pdfBytes = <int>[
  0x25,
  0x50,
  0x44,
  0x46,
  0x2d,
  0x31,
  0x2e,
  0x34,
  0x0a,
  0x25,
  0x25,
  0x45,
  0x4f,
  0x46,
];
const _pngBytes = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const _jpegBytes = <int>[0xff, 0xd8, 0xff, 0xe0, 0x00];

ArtworkRecord _record(String id, {String? primaryImageAttachmentId}) {
  final now = DateTime.utc(2026, 7, 4, 9);

  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.draft,
    primaryImageAttachmentId: primaryImageAttachmentId,
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
